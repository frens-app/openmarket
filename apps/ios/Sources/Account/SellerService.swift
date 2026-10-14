import Connect
import Foundation
import OpenMarketProtos

@MainActor
protocol SellerSyncService {
    func upsert(_ profile: SellerProfile, userID: String) async throws
    func setFollow(_ profile: SellerProfile, following: Bool, userID: String) async throws
    func listFollows(userID: String) async throws -> [SellerProfile]
}

@MainActor
final class SellerService: SellerSyncService {
    private let account: AccountSession
    private lazy var client = SellerServiceClient(client: API.makeProtocolClient())
    init(account: AccountSession? = nil) { self.account = account ?? .shared }

    private func headers(userID: String) async throws -> Headers {
        guard account.state.viewer?.id == userID else { throw CancellationError() }
        let headers = try await account.authorizedHeaders()
        // Token refresh can suspend while the user signs into another account.
        guard account.state.viewer?.id == userID else { throw CancellationError() }
        return headers
    }

    private func unwrap<T>(_ response: ResponseMessage<T>) throws -> T {
        if let error = response.error { throw error.asAPIError }
        guard let message = response.message else { throw APIError.network }
        return message
    }

    func upsert(_ profile: SellerProfile, userID: String) async throws {
        var request = UpsertSellerRequest()
        request.seller = profile.serverProfile
        _ = try unwrap(await client.upsertSeller(request: request, headers: try await headers(userID: userID)))
    }

    func setFollow(_ profile: SellerProfile, following: Bool, userID: String) async throws {
        var request = SetSellerFollowRequest()
        request.sellerID = profile.id
        request.following = following
        if following { request.seller = profile.serverProfile }
        _ = try unwrap(await client.setSellerFollow(request: request, headers: try await headers(userID: userID)))
    }

    func listFollows(userID: String) async throws -> [SellerProfile] {
        var profiles: [SellerProfile] = []
        var request = ListFollowedSellersRequest()
        repeat {
            let response = try unwrap(await client.listFollowedSellers(request: request, headers: try await headers(userID: userID)))
            profiles.append(contentsOf: response.sellers.compactMap(SellerProfile.init(serverProfile:)))
            request.afterID = response.nextAfterID
        } while !request.afterID.isEmpty
        return profiles
    }
}

extension SellerProfile {
    var serverProfile: FacebookSeller {
        var seller = FacebookSeller()
        seller.id = id
        seller.name = name
        if let photoURL = Self.validatedPhotoURL(photoURL?.absoluteString) { seller.photoURL = photoURL.absoluteString }
        if let joinedText { seller.joinedText = joinedText }
        if let rating, rating.isFinite, (0...5).contains(rating) { seller.rating = rating }
        if let ratingCount, let count = Int32(exactly: ratingCount), count >= 0 { seller.ratingCount = count }
        if let isHighlyRated { seller.isHighlyRated = isHighlyRated }
        return seller
    }

    init?(serverProfile: FacebookSeller) {
        self.init(detail: ListingDetail(
            sellerProfileID: serverProfile.id, sellerName: serverProfile.name,
            sellerPhotoURL: Self.validatedPhotoURL(serverProfile.hasPhotoURL ? serverProfile.photoURL : nil),
            sellerJoined: serverProfile.hasJoinedText ? serverProfile.joinedText : nil,
            sellerRating: serverProfile.hasRating ? serverProfile.rating : nil,
            sellerRatingCount: serverProfile.hasRatingCount ? Int(serverProfile.ratingCount) : nil,
            sellerIsHighlyRated: serverProfile.hasIsHighlyRated ? serverProfile.isHighlyRated : nil
        ))
    }
}
