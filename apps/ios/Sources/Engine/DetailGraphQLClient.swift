import Foundation
import WebKit

@MainActor
protocol GraphQLDetailLoading {
    func load(itemID: String, actor: String?,
              onPartial: @escaping @MainActor (ListingDetail) -> Void) async throws -> ListingDetail
}

@MainActor
final class DetailGraphQLClient: GraphQLDetailLoading {
    private let session: URLSession
    private let pacer: RequestPacer
    private let webViews: () -> [WKWebView]
    private let currentActor: () async -> String?

    init(pacer: RequestPacer = .shared, configuration: URLSessionConfiguration = .ephemeral,
         webViews: @escaping () -> [WKWebView] = { [] },
         currentActor: @escaping () async -> String? = { await SessionState.facebookActor() }) {
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.httpCookieAcceptPolicy = .never
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.timeoutIntervalForRequest = 8
        configuration.timeoutIntervalForResource = 12
        session = URLSession(configuration: configuration)
        self.pacer = pacer
        self.webViews = webViews
        self.currentActor = currentActor
    }

    deinit { session.invalidateAndCancel() }

    private enum Part {
        case core(ListingDetail)
        case media([URL])
    }

    func load(itemID: String, actor: String?,
              onPartial: @escaping @MainActor (ListingDetail) -> Void = { _ in }) async throws -> ListingDetail {
        try await checkSession(actor)
        var browser: WKWebView?
        if let actor {
            for candidate in webViews() {
                if (try? await candidate.callAsyncJavaScript(Self.readyScript,
                    arguments: ["expectedActor": actor], in: nil, contentWorld: .page)) as? Bool == true {
                    browser = candidate
                    break
                }
            }
            // A first detail open can warm its own browser through the fallback.
            guard browser != nil else { throw GraphQLFeedError.unsupportedQuery }
        }
        let context = browser
        do {
            let result = try await withThrowingTaskGroup(of: Part.self) { group in
                for operation in DetailGraphQLOperation.allCases {
                    group.addTask { @MainActor in
                        let data = try await self.fetch(operation, itemID: itemID, actor: actor, browser: context)
                        return try await Task.detached {
                            switch operation {
                            case .core: return Part.core(try GraphQLDetailDecoder.core(data, itemID: itemID))
                            case .media: return Part.media(try GraphQLDetailDecoder.photos(data, itemID: itemID))
                            }
                        }.value
                    }
                }
                var detail: ListingDetail?
                var photos: [URL]?
                for try await part in group {
                    try await checkSession(actor)
                    switch part {
                    case .core(let value): detail = value
                    case .media(let value): photos = value
                    }
                    if var staged = detail {
                        if let photos { staged.photoURLs = photos }
                        onPartial(staged)
                    }
                }
                guard var result = detail, let photos else { throw GraphQLFeedError.invalidResponse }
                result.photoURLs = photos
                return result
            }
            try await checkSession(actor)
            await pacer.recordSuccess()
            return result
        } catch GraphQLFeedError.blocked {
            await pacer.recordBlock()
            throw GraphQLFeedError.blocked
        }
    }

    private func checkSession(_ actor: String?) async throws {
        try Task.checkCancellation()
        guard await currentActor() == actor else { throw GraphQLFeedError.sessionChanged }
        try Task.checkCancellation()
    }

    private func fetch(_ operation: DetailGraphQLOperation, itemID: String, actor: String?, browser: WKWebView?) async throws -> Data {
        guard await pacer.waitForSlot() else { throw GraphQLFeedError.paused }
        try await checkSession(actor)
        if let actor {
            guard let browser else { throw GraphQLFeedError.sessionChanged }
            let requestID = UUID().uuidString
            let variables = try operation.variables(itemID: itemID)
            let result: Any?
            do {
                result = try await withTaskCancellationHandler {
                    try await browser.callAsyncJavaScript(Self.fetchScript,
                        arguments: ["operationName": operation.name, "documentID": operation.documentID,
                                    "variables": variables, "expectedActor": actor, "requestID": requestID],
                        in: nil, contentWorld: .page)
                } onCancel: {
                    Task { @MainActor in
                        _ = try? await browser.callAsyncJavaScript(
                            "window.__openmarketDetailRequests?.get(requestID)?.abort();",
                            arguments: ["requestID": requestID], in: nil, contentWorld: .page)
                    }
                }
            } catch {
                try Task.checkCancellation()
                throw URLError(.networkConnectionLost)
            }
            try await checkSession(actor)
            return try Self.decodeEnvelope(result)
        }
        let (data, response) = try await session.data(for: operation.request(itemID: itemID))
        try await checkSession(actor)
        guard let http = response as? HTTPURLResponse else { throw GraphQLFeedError.invalidResponse }
        try Self.checkStatus(http.statusCode)
        return data
    }

    static func decodeEnvelope(_ result: Any?) throws -> Data {
        guard let envelope = result as? [String: Any] else { throw GraphQLFeedError.invalidResponse }
        if let failure = envelope["failure"] as? String {
            switch failure {
            case "session": throw GraphQLFeedError.sessionChanged
            case "timeout": throw URLError(.timedOut)
            case "network": throw URLError(.networkConnectionLost)
            default: throw GraphQLFeedError.invalidResponse
            }
        }
        guard let status = envelope["status"] as? Int else { throw GraphQLFeedError.invalidResponse }
        try checkStatus(status)
        guard let text = envelope["text"] as? String else { throw GraphQLFeedError.invalidResponse }
        return Data(text.utf8)
    }

    private static func checkStatus(_ status: Int) throws {
        if status == 403 || status == 429 { throw GraphQLFeedError.blocked }
        if status >= 500 { throw URLError(.badServerResponse) }
        guard (200..<300).contains(status) else { throw GraphQLFeedError.invalidResponse }
    }

    static let readyScript = #"""
    try {
        return location.origin === 'https://www.facebook.com' &&
            require('CurrentUserInitialData').USER_ID === expectedActor &&
            expectedActor !== '0' && !!require('getAsyncParams')('POST').fb_dtsg;
    } catch (_) { return false; }
    """#

    static let fetchScript = #"""
    if (location.origin !== 'https://www.facebook.com') return {failure:'session'};
    let fields;
    try {
        const actor = require('CurrentUserInitialData').USER_ID;
        const params = require('getAsyncParams')('POST');
        if (!actor || actor === '0' || actor !== expectedActor || params.__user !== actor || !params.fb_dtsg)
            return {failure:'session'};
        let id = documentID;
        try {
            const op = require(operationName + '.graphql').params;
            if (op.name === operationName && op.operationKind === 'query' && op.id) id = op.id;
        } catch (_) {}
        fields = new URLSearchParams(params);
        fields.set('av', actor);
        fields.set('fb_api_caller_class', 'RelayModern');
        fields.set('fb_api_req_friendly_name', operationName);
        fields.set('doc_id', id);
        fields.set('variables', variables);
        fields.set('server_timestamps', 'true');
    } catch (_) { return {failure:'session'}; }
    const requests = window.__openmarketDetailRequests ||= new Map();
    const controller = new AbortController();
    requests.set(requestID, controller);
    const timeout = setTimeout(() => controller.abort(), 8000);
    try {
        const response = await fetch('/api/graphql/', {
            method:'POST', credentials:'same-origin', body:fields, signal:controller.signal
        });
        if (!response.ok) return {status:response.status};
        const text = await response.text();
        if (text.length > 5000000) return {failure:'size'};
        return {status:response.status, text};
    } catch (_) {
        return {failure:controller.signal.aborted ? 'timeout' : 'network'};
    } finally {
        clearTimeout(timeout);
        requests.delete(requestID);
    }
    """#
}
