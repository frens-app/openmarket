import Connect
import Foundation
import OpenMarketProtos
import SwiftProtobuf
import os

/// A view keeps the account it started under, even if sign-in changes mid-fetch.
@MainActor
final class ListingViewSubmission {
    private let userID = AccountSession.shared.state.viewer?.id
    private let viewedAt = Date()
    private let referrer: Analytics.Surface
    private var didSubmit = false

    init(referrer: Analytics.Surface) {
        self.referrer = referrer
    }

    func submit(_ listing: Listing, source: ListingViewSource = .unspecified) {
        guard !didSubmit, let userID, let id = listing.facebookListingID else { return }
        didSubmit = true
        var request = SubmitListingViewRequest()
        request.facebookListingID = id
        request.viewedAt = Google_Protobuf_Timestamp(date: viewedAt)
        request.referrer = referrer.rawValue
        if source != .unspecified {
            request.snapshot = listing.savedSnapshot
            request.source = source
        }
        // The upload should finish even if the detail screen disappears.
        Task {
            do {
                let account = AccountSession.shared
                guard account.state.viewer?.id == userID else { return }
                let headers = try await account.authorizedHeaders()
                guard account.state.viewer?.id == userID else { return }
                let client = ListingViewServiceClient(client: API.makeProtocolClient())
                let response = await client.submitListingView(request: request, headers: headers)
                if let error = response.error { throw error }
            } catch {
                Logger.store.warning("Listing view upload failed: \(error.localizedDescription, privacy: .public)")
            }
        }
    }
}
