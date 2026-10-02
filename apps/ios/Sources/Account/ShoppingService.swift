import Connect
import Foundation
import OpenMarketProtos
import SwiftProtobuf

@MainActor
final class ShoppingService {
    private let account: AccountSession
    private lazy var client = ShoppingServiceClient(client: API.makeProtocolClient())
    init(account: AccountSession = .shared) { self.account = account }

    private func unwrap<T>(_ response: ResponseMessage<T>) throws -> T {
        if let error = response.error { throw error.asAPIError }
        guard let message = response.message else { throw APIError.network }
        return message
    }

    func start(requestID: String) async throws -> ShoppingSession {
        var request = StartShoppingRequest()
        request.requestID = requestID
        request.facebookConnected = true
        return try unwrap(await client.startShopping(request: request, headers: try await account.authorizedHeaders())).session
    }
    func send(_ request: SendShoppingMessageRequest) async throws -> ShoppingSession {
        try unwrap(await client.sendShoppingMessage(request: request, headers: try await account.authorizedHeaders())).session
    }
    func get(_ id: String) async throws -> ShoppingSession {
        var request = GetShoppingSessionRequest()
        request.sessionID = id
        return try unwrap(await client.getShoppingSession(request: request, headers: try await account.authorizedHeaders())).session
    }
    func submit(session: ShoppingSession, result: ShoppingToolResult) async throws -> ShoppingSession {
        var request = SubmitShoppingToolResultRequest()
        request.sessionID = session.id
        request.runID = session.runID
        request.result = result
        return try unwrap(await client.submitShoppingToolResult(request: request, headers: try await account.authorizedHeaders())).session
    }
    func control(session: ShoppingSession, action: String) async throws -> ShoppingSession {
        var request = ControlShoppingSessionRequest()
        request.sessionID = session.id
        request.runID = session.runID
        request.action = action
        return try unwrap(await client.controlShoppingSession(request: request, headers: try await account.authorizedHeaders())).session
    }
}
