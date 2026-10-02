import Foundation
import WebKit
import os

/// Uses the app's signed-in browser for transport; cookies and request tokens
/// never leave WebKit. Each feed warms its browser once, then pages by cursor.
@MainActor
final class AuthenticatedFeedClient: GraphQLFeedLoading {
    private let webView: WKWebView
    private let pacer: RequestPacer
    private var bootstrap: Task<Void, Error>?
    private var cursorActor: String?

    init(webView: WKWebView, pacer: RequestPacer = .shared, cursorActor: String? = nil) {
        self.cursorActor = cursorActor
        self.webView = webView
        self.pacer = pacer
    }

    func page(for query: SearchQuery, cursor: String?) async throws -> GraphQLFeedPage {
        let request = try AnonymousFeedClient.request(for: query, cursor: cursor)
        let form = String(decoding: request.httpBody!, as: UTF8.self)
        let fields = URLComponents(string: "?" + form)?.queryItems ?? []
        guard let operation = fields.first(where: { $0.name == "fb_api_req_friendly_name" })?.value,
              let variables = fields.first(where: { $0.name == "variables" })?.value,
              let actor = await SessionState.facebookActor() else {
            throw GraphQLFeedError.invalidResponse
        }
        try Task.checkCancellation()
        guard cursor == nil || cursorActor == actor else { throw GraphQLFeedError.sessionChanged }
        if cursor == nil { cursorActor = actor }
        try await prepare(query, operation: operation, actor: actor)
        try Task.checkCancellation()
        guard await pacer.waitForSlot() else { throw GraphQLFeedError.paused }
        try Task.checkCancellation()

        let requestID = UUID().uuidString
        let started = ContinuousClock.now
        let webView = self.webView
        let result: Any?
        do {
            result = try await withTaskCancellationHandler {
                try await webView.callAsyncJavaScript(Self.fetchScript,
                    arguments: ["operationName": operation, "variables": variables,
                                "expectedActor": actor, "requestID": requestID],
                    in: nil, contentWorld: .page)
            } onCancel: {
                Task { @MainActor in
                    _ = try? await webView.callAsyncJavaScript(Self.abortScript,
                        arguments: ["requestID": requestID], in: nil, contentWorld: .page)
                }
            }
        } catch {
            try Task.checkCancellation()
            throw GraphQLFeedError.invalidResponse
        }
        try Task.checkCancellation()
        guard await SessionState.facebookActor() == actor else { throw GraphQLFeedError.sessionChanged }
        let page = try await Self.decode(result, kind: query.kind, pacer: pacer)
        let milliseconds = Int(started.duration(to: .now) / .milliseconds(1))
        Logger(subsystem: "lol.frens.openmarket", category: "authenticated-feed")
            .info("\(operation, privacy: .public): \(page.listings.count, privacy: .public) cards in \(milliseconds, privacy: .public)ms, more=\(page.hasNextPage, privacy: .public)")
        return page
    }

    private func isReady(operation: String, actor: String) async -> Bool {
        (try? await webView.callAsyncJavaScript(Self.readyScript,
            arguments: ["operationName": operation, "expectedActor": actor],
            in: nil, contentWorld: .page)) as? Bool == true
    }

    private func prepare(_ query: SearchQuery, operation: String, actor: String) async throws {
        if let bootstrap { try await bootstrap.value }
        try Task.checkCancellation()
        if await isReady(operation: operation, actor: actor) { return }
        let task = Task { @MainActor in
            guard await pacer.waitForSlot() else { throw GraphQLFeedError.paused }
            var request = URLRequest(url: query.url)
            request.timeoutInterval = 10
            webView.load(request)
            let deadline = ContinuousClock.now.advanced(by: .seconds(10))
            while ContinuousClock.now < deadline {
                if await isReady(operation: operation, actor: actor) { return }
                try await Task.sleep(for: .milliseconds(100))
            }
            webView.stopLoading()
            throw GraphQLFeedError.invalidResponse
        }
        bootstrap = task
        defer { bootstrap = nil }
        try await task.value
    }

    static func decode(_ result: Any?, kind: SearchQuery.Kind, pacer: RequestPacer) async throws -> GraphQLFeedPage {
        guard let envelope = result as? [String: Any] else { throw GraphQLFeedError.invalidResponse }
        if let failure = envelope["failure"] as? String {
            if failure == "timeout" { throw URLError(.timedOut) }
            if failure == "network" { throw URLError(.networkConnectionLost) }
            throw GraphQLFeedError.invalidResponse
        }
        guard let status = envelope["status"] as? Int else { throw GraphQLFeedError.invalidResponse }
        if status == 403 || status == 429 {
            await pacer.recordBlock()
            throw GraphQLFeedError.blocked
        }
        guard (200..<300).contains(status) else {
            if status >= 500 { throw URLError(.badServerResponse) }
            throw GraphQLFeedError.invalidResponse
        }
        guard let text = envelope["text"] as? String else { throw GraphQLFeedError.invalidResponse }
        let data = Data(text.utf8)
        do {
            let page = try await Task.detached { try GraphQLFeedDecoder.decode(data, kind: kind) }.value
            try Task.checkCancellation()
            await pacer.recordSuccess()
            return page
        } catch GraphQLFeedError.blocked {
            await pacer.recordBlock()
            throw GraphQLFeedError.blocked
        }
    }

    static let readyScript = #"""
    try {
        if (location.origin !== 'https://www.facebook.com') return false;
        const actor = require('CurrentUserInitialData').USER_ID;
        const operation = require(operationName + '.graphql').params;
        return actor === expectedActor && actor !== '0' &&
            operation.name === operationName && operation.operationKind === 'query' &&
            !!operation.id && typeof require('getAsyncParams') === 'function';
    } catch (_) { return false; }
    """#

    static let fetchScript = #"""
    if (location.origin !== 'https://www.facebook.com') return {failure: 'context'};
    let fields;
    try {
        const actor = require('CurrentUserInitialData').USER_ID;
        const operation = require(operationName + '.graphql').params;
        const params = require('getAsyncParams')('POST');
        if (!actor || actor === '0' || actor !== expectedActor || params.__user !== actor ||
            !params.fb_dtsg || operation.name !== operationName ||
            operation.operationKind !== 'query' || !operation.id) return {failure: 'context'};
        fields = new URLSearchParams(params);
        fields.set('av', actor);
        fields.set('fb_api_caller_class', 'RelayModern');
        fields.set('fb_api_req_friendly_name', operation.name);
        fields.set('doc_id', operation.id);
        fields.set('variables', variables);
        fields.set('server_timestamps', 'true');
    } catch (_) { return {failure: 'context'}; }
    const requests = window.__openmarketFeedRequests ||= new Map();
    const controller = new AbortController();
    requests.set(requestID, controller);
    const timeout = setTimeout(() => controller.abort(), 8000);
    try {
        const response = await fetch('/api/graphql/', {
            method: 'POST', credentials: 'same-origin', body: fields, signal: controller.signal
        });
        if (!response.ok) return {status: response.status};
        const text = await response.text();
        if (text.length > 5000000) return {failure: 'size'};
        return {status: response.status, text};
    } catch (_) {
        return {failure: controller.signal.aborted ? 'timeout' : 'network'};
    } finally {
        clearTimeout(timeout);
        requests.delete(requestID);
    }
    """#

    static let abortScript = #"""
    window.__openmarketFeedRequests?.get(requestID)?.abort();
    """#
}
