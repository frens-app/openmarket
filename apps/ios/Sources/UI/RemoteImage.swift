import SwiftUI

/// A photo from the CDN, drawn through `ImageLoader`.
///
/// Shaped like `AsyncImage` so the call sites read the same, with two
/// deliberate differences.
///
/// **A cache hit paints on the first frame.** The phase is seeded synchronously
/// in `init`, so a photo already decoded — the same listing in Discover and in
/// Saved, or a card returned to after a detail view — never flashes grey.
///
/// **Failure is one state, everywhere.** `docs/discover.md` §5.1 asks for this:
/// "a card whose image won't load needs a visible state, or *expired* and
/// *still loading* look identical forever". They looked identical *and*
/// inconsistent — `ListingCard` drew a `photo` glyph on failure while
/// `RecentCard` and the gallery deck drew nothing at all, so one dead photo
/// rendered two different ways on one screen depending on which view got it.
/// Top-level, and not nested inside `RemoteImage`, for the same reason
/// `AsyncImagePhase` is: nested in a generic, the phase handed to the content
/// closure is `RemoteImage<Content>.Phase`, so the compiler cannot know the
/// parameter's type until `Content` is resolved and cannot resolve `Content`
/// until it has type-checked the closure. Every call site fails to compile with
/// "generic parameter 'Content' could not be inferred". Hoisting it breaks the
/// cycle: the parameter is concrete, so the closure checks on its own.
enum RemoteImagePhase {
    case loading
    case success(Image)
    /// Loaded and won't: the signature expired, the photo is gone, or the
    /// card was captured before its `<img>` had a `src` at all.
    case failed

    var image: Image? {
        if case .success(let image) = self { return image }
        return nil
    }

    var hasFailed: Bool {
        if case .failed = self { return true }
        return false
    }
}

struct RemoteImage<Content: View>: View {
    typealias Phase = RemoteImagePhase

    let url: URL?
    @ViewBuilder let content: (Phase) -> Content

    @State private var phase: Phase

    init(url: URL?, @ViewBuilder content: @escaping (Phase) -> Content) {
        self.url = url
        self.content = content
        _phase = State(initialValue: Self.seed(for: url))
    }

    /// What to draw before anything is awaited. A resident image is the whole
    /// reason this is synchronous; a nil URL is already a final answer, since
    /// nothing will ever arrive for it.
    private static func seed(for url: URL?) -> Phase {
        guard let url else { return .failed }
        guard let hit = ImageLoader.shared.cached(url) else { return .loading }
        return .success(Image(uiImage: hit))
    }

    var body: some View {
        content(phase)
            // Keyed on the URL so a recycled cell re-loads rather than keeping
            // the previous listing's photo.
            .task(id: url) { await load() }
    }

    private func load() async {
        phase = Self.seed(for: url)
        guard let url, case .loading = phase else { return }

        do {
            let image = try await ImageLoader.shared.image(for: url)
            phase = .success(Image(uiImage: image))
        } catch {
            // Transient exhaustion isn't remembered by the loader, so a later
            // render of this URL gets a fresh set of attempts.
            phase = .failed
        }
    }
}

/// The one failed-photo treatment, so a dead image looks the same wherever it
/// lands. Sized by its container rather than by the glyph, which is why it's a
/// fill with an overlay and not just an `Image`.
struct MissingPhoto: View {
    var body: some View {
        Color(.tertiarySystemFill)
            .overlay {
                Image(systemName: "photo")
                    .foregroundStyle(.tertiary)
            }
            .accessibilityLabel("Photo unavailable")
    }
}
