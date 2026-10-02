import Combine
import Foundation
import OpenMarketProtos

@MainActor
final class ShoppingModel: ObservableObject {
    @Published private(set) var session: ShoppingSession?
    @Published private(set) var busy = false
    @Published private(set) var paused = false
    @Published private(set) var status = ""
    @Published var error: String?
    @Published private var pendingMessage: ShoppingMessage?
    let tools = ShoppingTools()
    private let service = ShoppingService()
    private var task: Task<Void, Never>?
    private var generation = UUID()
    private var startID = UUID().uuidString
    private var cachedResults: [String: ShoppingToolResult] = [:]
    private var pendingSend: SendShoppingMessageRequest?
    private var area: ShoppingTools.Area?
    private var owner: String?
    private var pauseRequest: Task<Void, Never>?

    var messages: [ShoppingMessage] {
        var values = session?.messages ?? []
        if let pendingMessage, !values.contains(where: { $0.id == pendingMessage.id }) { values.append(pendingMessage) }
        return values
    }
    var canResume: Bool { paused && (session != nil || pendingMessage != nil) }

    func send(_ text: String, area: ShoppingTools.Area) {
        let clean = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty, clean.count <= 6000 else { return }
        let previousTask = task
        previousTask?.cancel()
        let token = UUID(); generation = token
        busy = true; paused = false; error = nil; status = "Starting your search"
        self.area = area
        owner = AccountSession.shared.state.viewer?.id
        cachedResults = [:]
        var optimistic = ShoppingMessage()
        optimistic.id = UUID().uuidString; optimistic.role = "user"; optimistic.text = clean
        pendingMessage = optimistic
        task = Task {
            do {
                await previousTask?.value
                await pauseRequest?.value
                try check(token)
                try await ensureSignedIn()
                if session == nil {
                    let started = try await service.start(requestID: startID)
                    try check(token)
                    session = started
                }
                try check(token)
                tools.begin(area)
                tools.remember(session?.listings ?? [])
                var request = SendShoppingMessageRequest()
                request.sessionID = session!.id
                request.requestID = optimistic.id
                request.text = clean
                request.searchArea = area.summary
                request.facebookConnected = true
                pendingSend = request
                let response = try await service.send(request)
                try check(token)
                pendingSend = nil; pendingMessage = nil
                apply(response)
                try await loop(token)
            } catch { handle(error, token: token) }
        }
    }

    func pause() {
        guard busy else { return }
        task?.cancel(); generation = UUID(); tools.stopLoading()
        busy = false; paused = true; status = "Paused — resume when you're ready"
        if let current = session {
            pauseRequest = Task { _ = try? await service.control(session: current, action: "pause") }
        }
    }
    func resume() {
        guard let area else { return }
        guard area == ShoppingTools.Area(prefs: .shared) else {
            stop(); error = "Your search area changed. Send a new request to search there."; return
        }
        if pendingSend == nil, let text = pendingMessage?.text {
            send(text, area: area)
            return
        }
        guard let current = session else { return }
        let previousTask = task
        previousTask?.cancel()
        let token = UUID(); generation = token
        busy = true; paused = false; error = nil
        task = Task {
            do {
                await previousTask?.value
                await pauseRequest?.value
                try check(token)
                try await ensureSignedIn()
                if let request = pendingSend {
                    var response = try await service.send(request)
                    try check(token)
                    if response.paused { response = try await service.control(session: response, action: "resume") }
                    try check(token); pendingSend = nil; pendingMessage = nil; apply(response)
                } else {
                    let response = try await service.control(session: current, action: "resume")
                    try check(token); apply(response)
                }
                try await loop(token)
            } catch { handle(error, token: token) }
        }
    }
    func stop() {
        task?.cancel(); generation = UUID(); tools.stopLoading()
        busy = false; paused = false; pendingSend = nil; pendingMessage = nil; status = "Stopped"
        if let current = session {
            pauseRequest = Task { _ = try? await service.control(session: current, action: "stop") }
        }
    }
    func clear() {
        stop()
        if let current = session {
            Task { _ = try? await service.control(session: current, action: "clear") }
        }
        session = nil; error = nil; status = ""; area = nil
        startID = UUID().uuidString; cachedResults = [:]; tools.reset()
    }
    func accountChanged() {
        if owner != nil && owner != AccountSession.shared.state.viewer?.id { clear(); owner = nil }
    }
    func locationChanged() {
        if let area, area != ShoppingTools.Area(prefs: .shared), busy || paused {
            stop(); error = "Your search area changed. Send a new request to search there."
        }
    }
    private func check(_ token: UUID) throws {
        try Task.checkCancellation()
        guard generation == token else { throw CancellationError() }
    }
    private func ensureSignedIn() async throws {
        guard AccountSession.shared.isSignedIn, await SessionState.isSignedIn() else {
            throw APIError.message("Sign in to Openmarket and connect Facebook to continue.")
        }
        await AccountSession.shared.reportFacebookConnection(true)
    }
    private func apply(_ value: ShoppingSession) {
        session = value
        tools.remember(value.listings)
        status = value.progress
    }
    private func loop(_ token: UUID) async throws {
        while let current = session {
            try check(token)
            guard area == ShoppingTools.Area(prefs: .shared) else {
                throw APIError.message("Your search area changed. Send a new request.")
            }
            if current.paused { paused = true; busy = false; return }
            switch current.status {
            case "completed", "cancelled", "ready": busy = false; paused = false; return
            case "failed": busy = false; paused = false; error = current.error; return
            case "awaiting_client":
                guard let call = current.pendingCalls.first else { throw APIError.message("The assistant returned no executable action.") }
                try await ensureSignedIn()
                try check(token)
                let result: ShoppingToolResult
                if let cached = cachedResults[call.id] { result = cached }
                else {
                    switch call.action {
                    case .search(let q): status = "Searching for \(q.query)"
                    case .inspect: status = "Checking product details"
                    case .display(let group):
                        status = "Showing your options"
                        if session?.messages.contains(where: { $0.id == call.id }) == false {
                            var message = ShoppingMessage()
                            message.id = call.id; message.role = "assistant"; message.display = group
                            session?.messages.append(message)
                        }
                        await Task.yield()
                    case nil: break
                    }
                    do { result = try await tools.execute(call) }
                    catch {
                        try check(token)
                        var failure = ShoppingToolResult()
                        failure.callID = call.id
                        failure.error = String(error.localizedDescription.prefix(500))
                        result = failure
                    }
                    try check(token)
                    cachedResults[call.id] = result
                }
                let response = try await service.submit(session: current, result: result)
                try check(token); apply(response)
            default:
                try await Task.sleep(for: .milliseconds(500))
                let response = try await service.get(current.id)
                try check(token); apply(response)
            }
        }
    }
    private func handle(_ failure: Error, token: UUID) {
        guard token == generation, !(failure is CancellationError) else { return }
        busy = false
        error = failure.localizedDescription
        // A temporary server session may disappear on deployment or eviction.
        if error?.contains("temporary chat ended") == true {
            paused = pendingMessage != nil; status = "Session ended"; session = nil
            pendingSend = nil; startID = UUID().uuidString
        } else {
            paused = session != nil || pendingMessage != nil; status = "Paused"
        }
    }
}
