import Foundation

enum DetailGraphQLOperation: CaseIterable, Sendable {
    case core, media

    var name: String {
        self == .core ? "MarketplacePDPContainerQuery" : "MarketplacePDPC2CMediaViewerWithImagesQuery"
    }

    var documentID: String { self == .core ? "38856723643971385" : "10059604367394414" }

    func variables(itemID: String) throws -> String {
        guard !itemID.isEmpty, itemID.utf8.allSatisfy({ (48...57).contains($0) }) else {
            throw GraphQLFeedError.unsupportedQuery
        }
        var variables = self == .core
            ? try JSONSerialization.jsonObject(with: Data(Self.coreVariables.utf8)) as! [String: Any]
            : [:]
        variables["targetId"] = itemID
        return String(decoding: try JSONSerialization.data(withJSONObject: variables), as: UTF8.self)
    }

    func request(itemID: String) throws -> URLRequest {
        let fields = ["__user": "0", "av": "0", "__a": "1", "__comet_req": "15",
                      "fb_api_caller_class": "RelayModern", "fb_api_req_friendly_name": name,
                      "server_timestamps": "true", "doc_id": documentID,
                      "variables": try variables(itemID: itemID)]
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-._~"))
        let body = fields.sorted { $0.key < $1.key }.map {
            $0.key.addingPercentEncoding(withAllowedCharacters: allowed)! + "=" +
                $0.value.addingPercentEncoding(withAllowedCharacters: allowed)!
        }.joined(separator: "&")
        var request = URLRequest(url: URL(string: "https://www.facebook.com/api/graphql/")!)
        request.httpMethod = "POST"
        request.httpBody = Data(body.utf8)
        request.httpShouldHandleCookies = false
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("OpenMarket/0.0.1 (iOS)", forHTTPHeaderField: "User-Agent")
        return request
    }

    // Observed page preload metadata; see docs/detail-graphql-2026-10-02.md.
    private static let coreVariables = #"""
    {
      "feedbackSource": 56,
      "feedLocation": "MARKETPLACE_MEGAMALL",
      "referralSurfaceString": null,
      "scale": 3,
      "useDefaultActor": false,
      "__relay_internal__pv__MarketplacePDPCometSimilarListingsrelayprovider": false,
      "__relay_internal__pv__MarketplacePDPShouldShowRelatedSearchesrelayprovider": true,
      "__relay_internal__pv__MarketplacePDPShouldShowLoggedOutSellerTrustrelayprovider": false,
      "__relay_internal__pv__ShouldUpdateMarketplaceBoostListingBoostedStatusrelayprovider": false,
      "__relay_internal__pv__CometUFIShareActionMigrationrelayprovider": true,
      "__relay_internal__pv__GHLShouldChangeSponsoredDataFieldNamerelayprovider": true,
      "__relay_internal__pv__GHLShouldChangeAdIdFieldNamerelayprovider": true,
      "__relay_internal__pv__CometUFI_dedicated_comment_routable_dialog_gkrelayprovider": true,
      "__relay_internal__pv__CometUFICommentAutoTranslationTyperelayprovider": "AUTO_TRANSLATE",
      "__relay_internal__pv__CometUFICommentAvatarStickerAnimatedImagerelayprovider": false,
      "__relay_internal__pv__CometUFICommentActionLinksRewriteEnabledrelayprovider": true,
      "__relay_internal__pv__IsWorkUserrelayprovider": false,
      "__relay_internal__pv__CometUFIReactionsEnableShortNamerelayprovider": false,
      "__relay_internal__pv__CometUFISingleLineUFIrelayprovider": true,
      "__relay_internal__pv__MarketplacePDPShouldShowBSGRecommendationsrelayprovider": false,
      "__relay_internal__pv__MarketplacePDPJobShouldShowSharedGroupsSectionrelayprovider": false,
      "__relay_internal__pv__MarketplacePDPJobIsShareToGroupsEnabledOnCometrelayprovider": false
    }
    """#
}
