import SwiftUI

struct AmazonCheckBlock: View {
    let listing: Listing
    let canAsk: Bool
    @EnvironmentObject private var checks: AmazonCheckModel
    @EnvironmentObject private var account: AccountSession
    @State private var showSignIn = false
    @State private var resumeAfterSignIn = false

    var body: some View {
        Group {
            switch checks.phases[listing.id] {
            case nil:
                if canAsk {
                    Button {
                        Analytics.capture(.amazonComparisonClicked, [
                            "listing_id": listing.id,
                            "is_signed_in": account.isSignedIn
                        ])
                        start()
                    } label: {
                        Label("Compare with Amazon", systemImage: "shippingbox")
                            .font(.subheadline.weight(.medium))
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 8)
                    }
                    .buttonStyle(.bordered)
                    .tint(.orange)
                }
            case .running(let stage):
                HStack(spacing: 10) {
                    ProgressView().controlSize(.small)
                    Text(stage).font(.subheadline)
                    Spacer()
                }
                .padding(14)
                .background(.orange.opacity(0.08), in: RoundedRectangle(cornerRadius: 14))
            case .failed(let message):
                InlineNotice(text: message, actionTitle: "Try again", action: start)
            case .done(let products):
                results(products)
            }
        }
        .sheet(isPresented: $showSignIn, onDismiss: {
            if resumeAfterSignIn {
                resumeAfterSignIn = false
                checks.check(listing)
            }
        }) {
            NavigationStack {
                PhoneLoginView(prompt: "Sign in to compare this item with Amazon products.") { _ in
                    resumeAfterSignIn = true
                    showSignIn = false
                }
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Cancel") { showSignIn = false }
                    }
                }
            }
        }
    }

    private func start() {
        if account.isSignedIn { checks.check(listing) }
        else { showSignIn = true }
    }

    private func results(_ products: [MarketComp]) -> some View {
        let matches = products.filter(\.isComparable)
        return VStack(alignment: .leading, spacing: 12) {
            Label("Buy similar new", systemImage: "shippingbox.fill")
                .font(.headline)
            Text(matches.isEmpty
                 ? "No similar new products found on Amazon."
                 : "\(matches.count) similar new \(matches.count == 1 ? "product" : "products") on Amazon")
                .font(.subheadline)
            if !matches.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    LazyHStack(alignment: .top, spacing: 12) {
                        ForEach(matches) { product in
                            if let url = product.listing.itemURL {
                                Link(destination: url) {
                                    VStack(alignment: .leading, spacing: 8) {
                                        RemoteImage(url: product.listing.thumbnailURL) { phase in
                                            switch phase {
                                            case .success(let image):
                                                image.resizable().scaledToFit()
                                            case .loading:
                                                ProgressView()
                                            case .failed:
                                                MissingPhoto()
                                            }
                                        }
                                        .frame(width: 136, height: 96)
                                        .background(.white, in: RoundedRectangle(cornerRadius: 8))
                                        Text(product.listing.title ?? "Amazon product")
                                            .font(.subheadline.weight(.medium))
                                            .lineLimit(3, reservesSpace: true)
                                        Text(product.listing.priceText ?? "Price unavailable")
                                            .font(.subheadline.bold())
                                        Text("View on Amazon ↗")
                                            .font(.caption2).foregroundStyle(.secondary)
                                    }
                                    .frame(width: 136, alignment: .leading)
                                    .padding(10)
                                    .background(Color(.systemBackground), in: RoundedRectangle(cornerRadius: 12))
                                }
                                .buttonStyle(.plain)
                                .environment(\.openURL, OpenURLAction { destination in
                                    Analytics.capture(.amazonProductClicked, [
                                        "listing_id": listing.id,
                                        "amazon_product_id": product.id,
                                        "matching_products_count": matches.count
                                    ])
                                    return .systemAction(destination)
                                })
                            }
                        }
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(.orange.opacity(0.08), in: RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(.orange.opacity(0.25)))
    }
}
