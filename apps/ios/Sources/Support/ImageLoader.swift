import UIKit
import os

extension Logger {
    static let images = Logger(subsystem: "lol.frens.openmarket", category: "images")
}

/// The one image loader. Everything that draws a photo goes through it.
///
/// `AsyncImage` was doing this job and lost images under load: a card would
/// render a permanent grey placeholder while the *same URL* loaded first try
/// elsewhere on the screen, returned HTTP 200 to `curl`, and had four days left
/// on its signature. Three things about `AsyncImage` combine to produce that,
/// and this type exists to fix all three:
///
/// - **It never retries.** One failed request is final for the life of the
///   view, and `LazyVStack` keeps the view alive rather than rebuilding it, so
///   scrolling away and back doesn't help either.
/// - **It never shares.** The home screen draws the same listing in Discover
///   and in Saved; that was two independent fetches of one URL, racing.
/// - **It never yields.** ~26 thumbnails start at once, against three
///   `WKWebView`s rendering full pages. Measured on this cache the grid alone
///   is 2.4 MB in one burst (avg 95 KB × 26), and the requests that lose the
///   contention are exactly the ones that came back `.failure`.
///
/// So: one shared decode cache, one in-flight request per URL however many
/// views want it, a ceiling on how many are in the air at once, and a bounded
/// retry with backoff.
actor ImageLoader {
    static let shared = ImageLoader()

    enum Failure: Error {
        /// The CDN answered, and the answer was no. A signed fbcdn URL that has
        /// passed its `oe` expiry gives 403 forever — retrying is just noise,
        /// and the card should say so rather than spin.
        case permanent
        /// Ran out of attempts. Not cached: the next render tries again, which
        /// is the whole point given the failure is contention.
        case transient
    }

    /// Decoded images, so the second view asking for a URL pays nothing. Cost
    /// is the bitmap's real size — a 843×403 thumbnail is ~1.4 MB decoded, and
    /// counting entries instead would let a screenful of galleries through.
    ///
    /// `NSCache` is thread-safe on its own, hence `nonisolated`: a cache hit is
    /// then readable synchronously from `RemoteImage.init`, which is what lets
    /// an already-loaded photo paint on the first frame instead of flashing
    /// grey for one.
    private nonisolated let cache: NSCache<NSURL, UIImage> = {
        let cache = NSCache<NSURL, UIImage>()
        cache.totalCostLimit = 96 * 1024 * 1024
        return cache
    }()

    private var inFlight: [URL: Task<UIImage, Error>] = [:]
    private var expired: Set<URL> = []
    private let gate = Gate(limit: 6)

    /// Separate from anything that talks to Facebook proper.
    ///
    /// Deliberately *not* behind `RequestPacer`: that exists to keep the app's
    /// page traffic unlike a crawler's, and it has a 300-request session cap.
    /// Thumbnails are CDN reads that any browser would make in a burst, and
    /// spending the page budget on them would stop the app fetching listings
    /// after a few screens of scrolling.
    ///
    /// The disk cache is the useful part beyond speed: fbcdn sends a long
    /// `max-age`, so bytes already fetched keep rendering after the URL's own
    /// signature expires (README's ~4.5-day saved-thumbnail defect). That is a
    /// mitigation, not the fix — an evicted entry is still a dead card.
    private let session: URLSession = {
        let config = URLSessionConfiguration.default
        config.urlCache = URLCache(memoryCapacity: 16 * 1024 * 1024,
                                   diskCapacity: 256 * 1024 * 1024,
                                   diskPath: "marketplace-images")
        config.requestCachePolicy = .useProtocolCachePolicy
        config.httpMaximumConnectionsPerHost = 6
        config.timeoutIntervalForRequest = 20
        return URLSession(configuration: config)
    }()

    /// A hit, if this URL is already decoded and resident.
    nonisolated func cached(_ url: URL) -> UIImage? {
        cache.object(forKey: url as NSURL)
    }

    /// Whether this URL has already answered 403/404 — a card can render
    /// "expired" immediately rather than spinning through three doomed
    /// attempts.
    func isKnownExpired(_ url: URL) -> Bool { expired.contains(url) }

    func image(for url: URL) async throws -> UIImage {
        if let hit = cached(url) { return hit }
        if expired.contains(url) { throw Failure.permanent }

        // Coalesced: the same photo in Discover and in Saved is one request.
        if let existing = inFlight[url] { return try await existing.value }

        let task = Task<UIImage, Error> { [session, gate] in
            try await Self.fetch(url, session: session, gate: gate)
        }
        inFlight[url] = task

        do {
            let image = try await task.value
            inFlight[url] = nil
            cache.setObject(image, forKey: url as NSURL, cost: image.byteCost)
            return image
        } catch {
            inFlight[url] = nil
            if case Failure.permanent = error { expired.insert(url) }
            throw error
        }
    }

    /// Up to three attempts, backing off, behind the concurrency gate.
    ///
    /// `nonisolated static` on purpose: the actor must not be held while a
    /// request is in the air, or the gate below would be the only thing running
    /// concurrently and every other caller would queue behind the network.
    private static func fetch(_ url: URL, session: URLSession, gate: Gate) async throws -> UIImage {
        let backoff: [Duration] = [.milliseconds(400), .milliseconds(1200)]

        for attempt in 0...backoff.count {
            do {
                let image = try await request(url, session: session, gate: gate)
                if attempt > 0 {
                    Logger.images.info("recovered \(url.lastPathComponent, privacy: .public) on attempt \(attempt + 1)")
                }
                return image
            } catch Failure.permanent {
                throw Failure.permanent
            } catch {
                guard attempt < backoff.count else {
                    Logger.images.error("giving up on \(url.lastPathComponent, privacy: .public): \(error.localizedDescription, privacy: .public)")
                    throw Failure.transient
                }
                // Backing off *outside* the gate, deliberately. Sleeping while
                // still holding a slot would mean a retrying request occupied
                // one of six for its whole backoff — starving the queue at
                // exactly the moment things are already going badly, which is
                // the contention this type exists to relieve.
                try? await Task.sleep(for: backoff[attempt])
            }
        }
        throw Failure.transient
    }

    /// One attempt, holding a slot for the transport and nothing else.
    private static func request(_ url: URL, session: URLSession, gate: Gate) async throws -> UIImage {
        // Acquire, transport, release — unconditionally, on one path. An
        // earlier shape released inside both a success and a failure branch,
        // which is how a slot gets handed back twice or not at all; the gate
        // then either throttles to nothing or stops throttling, and both look
        // like the bug this is fixing. Status and decode are checked *after*
        // the release: neither touches the network, so neither needs a slot.
        await gate.acquire()
        let outcome: Result<(Data, URLResponse), Error>
        do {
            outcome = .success(try await session.data(from: url))
        } catch {
            outcome = .failure(error)
        }
        await gate.release()

        let (data, response) = try outcome.get()

        if let http = response as? HTTPURLResponse {
            // 403 is the expired signature, 404 the deleted photo. Neither
            // improves by asking again — verified against fbcdn directly: a URL
            // with a mutated `stp` returns 403 every time, because the resize
            // directive is inside the `oh` signature.
            if http.statusCode == 403 || http.statusCode == 404 {
                Logger.images.info("permanent \(http.statusCode) for \(url.lastPathComponent, privacy: .public)")
                throw Failure.permanent
            }
            guard (200..<300).contains(http.statusCode) else { throw Failure.transient }
        }
        guard let image = UIImage(data: data) else { throw Failure.transient }
        return image
    }
}

private extension UIImage {
    /// What this bitmap actually costs resident, rather than its point size.
    var byteCost: Int {
        guard let cgImage else { return 1 }
        return cgImage.bytesPerRow * cgImage.height
    }
}

/// Caps how many image requests are in the air at once.
///
/// Six, chosen against the measured burst: the grid asks for ~26 thumbnails the
/// moment it appears, and the failures being fixed here are what happens when
/// all of them plus three page-rendering `WKWebView`s compete. Low enough to
/// leave the webviews room, high enough that the visible rows still fill
/// promptly.
///
/// No cancellation handling, deliberately — nothing cancels these. A fetch is
/// owned by `ImageLoader`, not by whichever view happened to ask first, so a
/// card scrolling offscreen can't abandon a request that another card is
/// waiting on.
private actor Gate {
    private let limit: Int
    private var active = 0
    private var waiting: [CheckedContinuation<Void, Never>] = []

    init(limit: Int) { self.limit = limit }

    func acquire() async {
        if active < limit {
            active += 1
            return
        }
        await withCheckedContinuation { waiting.append($0) }
    }

    func release() {
        if let next = waiting.first {
            waiting.removeFirst()
            next.resume()          // hands the slot straight over; `active` unchanged
        } else {
            active -= 1
        }
    }
}
