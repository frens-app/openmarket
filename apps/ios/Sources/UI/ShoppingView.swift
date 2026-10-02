import SwiftUI
import OpenMarketProtos

struct ShoppingView: View {
    @EnvironmentObject private var shopping: ShoppingModel
    @EnvironmentObject private var prefs: Preferences
    @EnvironmentObject private var account: AccountSession
    @State private var draft = ""
    @State private var showGate = false
    @State private var showLocation = false
    @State private var sendAfterGate = false
    @State private var resumeAfterGate = false
    @Namespace private var namespace

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                Button { showLocation = true } label: {
                    Label(searchAreaLabel, systemImage: "location")
                        .font(.subheadline).padding(.vertical, 10)
                }
                ScrollViewReader { reader in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 18) {
                            if shopping.messages.isEmpty { introduction }
                            ForEach(shopping.messages, id: \.id) { message in
                                VStack(alignment: .leading, spacing: 10) {
                                    if !message.text.isEmpty {
                                        Text(message.text)
                                            .textSelection(.enabled)
                                            .padding(12)
                                            .background(message.role == "user" ? Color.accentColor.opacity(0.12) : Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 14))
                                            .frame(maxWidth: .infinity, alignment: message.role == "user" ? .trailing : .leading)
                                    }
                                    if message.hasDisplay {
                                        if !message.display.title.isEmpty { Text(message.display.title).font(.headline) }
                                        ScrollView(.horizontal, showsIndicators: false) {
                                            HStack(alignment: .top, spacing: 12) {
                                                ForEach(message.display.products, id: \.listingID) { product in
                                                    if let listing = shopping.tools.listings[product.listingID] {
                                                        NavigationLink {
                                                            DetailView(listing: listing, namespace: namespace)
                                                        } label: {
                                                            ShoppingProductCard(listing: listing, recommendation: product)
                                                        }.buttonStyle(.plain)
                                                    }
                                                }
                                            }
                                            .padding(.horizontal, 2)
                                        }
                                    }
                                }.id(message.id)
                            }
                            if !shopping.status.isEmpty {
                                HStack {
                                    if shopping.busy { ProgressView() }
                                    Text(shopping.status).font(.footnote).foregroundStyle(.secondary)
                                }.accessibilityElement(children: .combine)
                            }
                            if let error = shopping.error { Text(error).font(.footnote).foregroundStyle(.red) }
                            if shopping.canResume { Button("Resume", action: resume).buttonStyle(.bordered) }
                            Color.clear.frame(height: 1).id("bottom")
                        }.padding()
                    }
                    .onChange(of: shopping.messages.count) { _, _ in
                        withAnimation { reader.scrollTo("bottom", anchor: .bottom) }
                    }
                }
                composer
            }
            .navigationTitle("AI Search")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) { Button("New chat") { shopping.clear() } }
            }
            .sheet(isPresented: $showGate, onDismiss: {
                if sendAfterGate {
                    sendAfterGate = false
                    if resumeAfterGate { resumeAfterGate = false; shopping.resume() } else { submit() }
                }
            }) {
                AccountGateView(feature: .shopping) { sendAfterGate = true }
            }
            .sheet(isPresented: $showLocation) { LocationPickerSheet() }
        }
    }
    private var searchAreaLabel: String {
        guard let name = prefs.locationName else { return "Choose a search area" }
        return name + (prefs.radiusKM == 0 ? " · Any distance" : " · \(prefs.radiusKM) km")
    }
    private var introduction: some View {
        VStack(alignment: .leading, spacing: 16) {
            Image(systemName: "sparkle.magnifyingglass").font(.largeTitle).foregroundStyle(.tint)
            Text("Describe what you're looking for").font(.title2.bold())
            Text("I'll search Marketplace and check listing details to find options that fit.").foregroundStyle(.secondary)
            Button("A solid wood desk under $150 with drawers") { draft = "Find a solid wood desk under $150 with drawers." }
                .buttonStyle(.bordered)
            Text("Chats are temporary. Messages and product information are processed by AI services.")
                .font(.caption).foregroundStyle(.secondary)
        }.padding(.vertical, 24)
    }
    private var composer: some View {
        HStack(alignment: .bottom, spacing: 12) {
            TextField("What are you looking for?", text: $draft, axis: .vertical)
                .lineLimit(1...5).textFieldStyle(.roundedBorder)
            if shopping.busy {
                Button("Stop", action: shopping.stop).buttonStyle(.bordered)
            }
            Button(action: submit) { Image(systemName: "arrow.up.circle.fill").font(.title) }
                .accessibilityLabel("Send message")
                .disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || draft.count > 6000)
        }.padding().background(.bar)
    }
    private func resume() {
        Task {
            guard account.isSignedIn, await SessionState.isSignedIn() else {
                resumeAfterGate = true; showGate = true; return
            }
            shopping.resume()
        }
    }
    private func submit() {
        Task {
            guard account.isSignedIn, await SessionState.isSignedIn() else { resumeAfterGate = false; showGate = true; return }
            guard let area = ShoppingTools.Area(prefs: prefs) else { showLocation = true; return }
            let text = draft
            draft = ""
            shopping.send(text, area: area)
        }
    }
}

private struct ShoppingProductCard: View {
    let listing: Listing
    let recommendation: ShoppingRecommendation

    private var product: MarketComp {
        var value = MarketComp(listing: listing)
        value.relevance = .included
        return value
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            CompCard(comp: product, footnote: listing.locationText, side: 160)
            if !recommendation.reason.isEmpty {
                Text(recommendation.reason).font(.caption)
            }
            if !recommendation.caveat.isEmpty {
                Text(recommendation.caveat).font(.caption2).foregroundStyle(.secondary)
            }
        }
        .frame(width: 160, alignment: .leading)
        .fixedSize(horizontal: false, vertical: true)
        .contentShape(Rectangle())
    }
}
