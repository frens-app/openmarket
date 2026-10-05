import SwiftUI
import OpenMarketProtos

struct ShoppingView: View {
    @EnvironmentObject private var shopping: ShoppingModel
    @EnvironmentObject private var prefs: Preferences
    @EnvironmentObject private var account: AccountSession
    @State private var draft = ""
    @State private var showGate = false
    @State private var showLocation = false
    @State private var showInfo = false
    @State private var sendAfterGate = false
    @State private var resumeAfterGate = false
    @Namespace private var namespace

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                Button { showLocation = true } label: {
                    HStack(spacing: 6) {
                        Label(searchAreaLabel, systemImage: "location")
                        Image(systemName: "chevron.down").font(.caption2.weight(.semibold))
                    }
                    .font(.caption.weight(.medium))
                    .padding(.horizontal, 14).padding(.vertical, 10)
                    .background(Color(.secondarySystemBackground), in: Capsule())
                }
                .buttonStyle(.plain)
                .padding(.vertical, 8)
                ScrollViewReader { reader in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 18) {
                            if shopping.messages.isEmpty { introduction }
                            ForEach(shopping.messages, id: \.id) { message in
                                VStack(alignment: .leading, spacing: 10) {
                                    if !message.text.isEmpty {
                                        Text(message.text)
                                            .textSelection(.enabled)
                                            .padding(.horizontal, 16).padding(.vertical, 12)
                                            .background(message.role == "user" ? Color.accentColor.opacity(0.12) : Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 22, style: .continuous))
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
                                                            ShoppingProductCard(listing: listing)
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
                            if shopping.canResume { Button("Resume", action: resume).buttonStyle(.bordered).buttonBorderShape(.capsule) }
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
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button { showInfo = true } label: { Image(systemName: "info.circle") }
                        .accessibilityLabel("About AI Search")
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button { shopping.clear() } label: { Image(systemName: "square.and.pencil") }
                        .accessibilityLabel("New chat")
                }
            }
            .alert("About AI Search", isPresented: $showInfo) {
                Button("OK", role: .cancel) { }
            } message: {
                Text("Chats are temporary. Messages and product information are processed by AI services.")
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
        guard let name = prefs.locationName else { return "Search area" }
        return name + (prefs.radiusKM == 0 ? " · Any distance" : " · \(prefs.radiusKM) km")
    }
    private var introduction: some View {
        Image(systemName: "sparkle.magnifyingglass")
            .font(.system(size: 36, weight: .light))
            .foregroundStyle(.tint)
            .frame(width: 88, height: 88)
            .background(Color.accentColor.opacity(0.08), in: RoundedRectangle(cornerRadius: 30, style: .continuous))
            .frame(maxWidth: .infinity)
            .padding(.vertical, 48)
            .accessibilityHidden(true)
    }
    private var composer: some View {
        HStack(alignment: .bottom, spacing: 10) {
            TextField("Find something…", text: $draft, axis: .vertical)
                .lineLimit(1...5).textFieldStyle(.plain)
                .padding(.vertical, 11).padding(.leading, 8)
                .accessibilityLabel("Message")
            if shopping.busy {
                Button(action: shopping.stop) {
                    Image(systemName: "stop.fill").font(.system(size: 14, weight: .semibold))
                        .frame(width: 44, height: 44)
                        .background(Color(.tertiarySystemFill), in: Circle())
                }.accessibilityLabel("Stop")
            } else {
                Button(action: submit) {
                    Image(systemName: "arrow.up").font(.system(size: 18, weight: .semibold))
                        .frame(width: 44, height: 44)
                        .foregroundStyle(.white)
                        .background(Color.accentColor, in: Circle())
                }
                .accessibilityLabel("Send message")
                .disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || draft.count > 6000)
                .opacity(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || draft.count > 6000 ? 0.4 : 1)
            }
        }
        .buttonStyle(.plain)
        .padding(8)
        .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 30, style: .continuous))
        .padding(.horizontal, 16).padding(.vertical, 10)
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

    private var product: MarketComp {
        var value = MarketComp(listing: listing)
        value.relevance = .included
        return value
    }

    var body: some View {
        CompCard(comp: product, side: 160, imageCornerRadius: 20)
            .padding(10)
            .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 28, style: .continuous))
    }
}
