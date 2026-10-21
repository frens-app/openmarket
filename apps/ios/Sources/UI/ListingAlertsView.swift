import SwiftUI
import UIKit

struct AlertRoute: Hashable {
    let alertID: String
    var source = "alerts_tab"
    var notificationID: String?
    let interactionID = UUID().uuidString
}

struct ListingAlertsView: View {
    @EnvironmentObject private var account: AccountSession
    @EnvironmentObject private var prefs: Preferences
    @EnvironmentObject private var saved: SavedListings
    @EnvironmentObject private var store: ListingStore
    @ObservedObject private var coordinator = ListingAlertCoordinator.shared
    @ObservedObject private var push = PushRegistrar.shared
    @Environment(\.scenePhase) private var scenePhase
    @State private var alerts: [ListingAlert] = []
    @State private var allowance: ListingAlertAllowance?
    @State private var feed: [AlertInboxItem] = []
    @State private var feedCursor: AlertInboxItem?
    @State private var filter: AlertInboxFilter = .all
    @State private var selected: AlertInboxItem?
    @State private var listingInteractionID = UUID().uuidString
    @Namespace private var listingNamespace
    @State private var feedMore = false
    @State private var feedLoading = false
    @State private var refreshing = false
    @State private var feedGeneration = 0
    @State private var showManage = false
    @State private var path: [AlertRoute] = []
    @State private var error: String?
    @State private var connected = false
    @State private var showCreate = false
    @State private var showAccount = false
    private let service = ListingAlertsService()

    var body: some View {
        NavigationStack(path: $path) {
            List {
                AlertInboxFilters(selection: $filter)
                    .listRowSeparator(.hidden)
                    .listRowInsets(EdgeInsets(top: 6, leading: 20, bottom: 14, trailing: 20))
                if !account.isSignedIn || !connected {
                    Section {
                        Button("Sign in and connect Facebook") { showAccount = true }
                    }
                }
                if !push.isEnabled {
                    Section {
                        Button("Enable notifications") {
                            Task {
                                if push.status == .denied {
                                    if let url = URL(string: UIApplication.openSettingsURLString) { await UIApplication.shared.open(url) }
                                } else { await push.requestAuthorization() }
                            }
                        }
                    }
                }
                if let error { Section { Text(error).foregroundStyle(.red) } }
                if visibleFeed.isEmpty && account.isSignedIn && !refreshing {
                    ContentUnavailableView(emptyTitle, systemImage: filter == .saved ? "bookmark" : "bell",
                        description: Text(emptyDescription))
                        .listRowSeparator(.hidden)
                }
                ForEach(inboxDays, id: \.self) { day in
                    Section {
                        ForEach(visibleFeed.filter { Calendar.current.startOfDay(for: $0.createdAt) == day }) { item in
                            AlertInboxRow(item: item, isSaved: saved.contains(item.displayedListing),
                                open: { open(item) }, save: { toggleSave(item) })
                                .listRowInsets(EdgeInsets(top: 10, leading: 16, bottom: 10, trailing: 12))
                                .alignmentGuide(.listRowSeparatorLeading) { _ in 96 }
                        }
                    } header: {
                        Text(alertDayLabel(day)).font(.subheadline.weight(.semibold))
                            .foregroundStyle(.primary).textCase(nil)
                    }
                }
                if feedMore {
                    Button("Load earlier matches") { Task { await loadMore() } }.disabled(feedLoading || refreshing)
                }
                if feedLoading || (refreshing && feed.isEmpty) { ProgressView().frame(maxWidth: .infinity) }
            }
            .listStyle(.plain)
            .navigationTitle("Alerts")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Button("Create alert", systemImage: "plus") { showCreate = true }
                        Button("Manage alerts", systemImage: "slider.horizontal.3") { showManage = true }
                            .disabled(alerts.isEmpty)
                    } label: { Image(systemName: "ellipsis.circle") }
                    .accessibilityLabel("Alert options")
                }
            }
            .navigationDestination(for: AlertRoute.self) { route in
                AlertMatchesView(route: route, alert: alerts.first { $0.id == route.alertID }, changed: {
                    Task { await refresh() }
                })
            }
            .refreshable { await refresh() }
            .task { saved.synchronize(); await refresh(); navigateToPush() }
            .onChange(of: filter) { _, _ in Task { await refresh() } }
            .onChange(of: saved.isSyncing) { wasSyncing, syncing in
                if wasSyncing && !syncing && filter == .saved { Task { await refresh() } }
            }
            .onChange(of: coordinator.matchRevision) { _, _ in Task { await refresh() } }
            .onChange(of: coordinator.openAlertID) { _, _ in navigateToPush() }
            .onChange(of: scenePhase) { _, phase in if phase == .active { Task { await refresh() } } }
            .onChange(of: account.state.viewer?.id) { _, _ in
                alerts = []; allowance = nil; feed = []; feedCursor = nil; feedGeneration += 1; path = []; selected = nil; error = nil
                Task { await refresh() }
            }
            .sheet(isPresented: $showAccount, onDismiss: { Task { await refresh() } }) {
                AccountGateView(feature: .listingAlerts, done: { showAccount = false })
            }
            .sheet(item: $selected) { item in
                NavigationStack {
                    DetailView(listing: item.displayedListing, namespace: listingNamespace, referrer: .listingAlerts,
                        alertSaveContext: item.saveContext)
                        .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Done") { selected = nil } } }
                }
                .task { await recordOpen(item) }
            }
            .sheet(isPresented: $showCreate) {
                CreateListingAlertView(draft: ListingAlertDraft()) { id in
                    Task { await refresh() }
                    path = [AlertRoute(alertID: id, source: "creation")]
                }
            }
            .sheet(isPresented: $showManage) { manageSheet }
        }
    }

    private var manageSheet: some View {
        NavigationStack {
            List {
                if let allowance {
                    Section { AlertAllowanceSummary(allowance: allowance) }
                }
                ForEach(alerts) { alert in
                    NavigationLink {
                        AlertMatchesView(route: AlertRoute(alertID: alert.id), alert: alert, changed: { Task { await refresh() } })
                    } label: {
                        VStack(alignment: .leading, spacing: 5) {
                            Text(alert.query).font(.headline)
                            if alert.minPrice != nil || alert.maxPrice != nil {
                                Text(AlertPriceInput.summary(min: alert.minPrice, max: alert.maxPrice)).font(.subheadline).foregroundStyle(.secondary)
                            }
                            Text(alert.paused ? "Paused" : "Active").font(.subheadline).foregroundStyle(.secondary)
                        }
                    }
                }
            }
            .navigationTitle("Your alerts")
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { showManage = false } } }
        }
    }

    private var visibleFeed: [AlertInboxItem] {
        feed.filter { item in
            switch filter {
            case .all: return true
            case .unread: return item.viewedAt == nil
            case .saved: return saved.contains(item.displayedListing)
            }
        }
    }

    private var inboxDays: [Date] {
        Array(Set(visibleFeed.map { Calendar.current.startOfDay(for: $0.createdAt) })).sorted(by: >)
    }

    private var emptyTitle: String {
        switch filter {
        case .all: return alerts.isEmpty ? "No alerts yet" : "No matches yet"
        case .unread: return "You’re all caught up"
        case .saved: return "No saved matches"
        }
    }

    private var emptyDescription: String {
        switch filter {
        case .all: return alerts.isEmpty ? "Create an alert for something you’re looking for." : "New finds from your alerts will appear here."
        case .unread: return "New listings from your alerts will appear here."
        case .saved: return "Tap the bookmark beside a listing to keep it here and in Saved."
        }
    }

    private func toggleSave(_ item: AlertInboxItem) {
        let listing = item.displayedListing
        let wasSaved = saved.contains(listing)
        store.remember(listing)
        withAnimation(.snappy(duration: 0.2)) { saved.toggle(listing, alertContext: item.saveContext) }
        Analytics.capture(wasSaved ? .listingUnsaved : .listingSaved, [
            "listing_id": listing.id, "alert_id": item.alertID, "notification_id": item.notificationID,
            "surface": Analytics.Surface.listingAlerts.rawValue
        ])
    }

    private func open(_ item: AlertInboxItem) {
        listingInteractionID = UUID().uuidString
        var properties = Analytics.listingOpenProperties(item.displayedListing, surface: .listingAlerts,
            position: visibleFeed.firstIndex(where: { $0.id == item.id }) ?? 0,
            isSaved: saved.contains(item.displayedListing), isSeen: item.viewedAt != nil)
        properties["alert_id"] = item.alertID; properties["notification_id"] = item.notificationID
        properties["interaction_id"] = listingInteractionID
        Analytics.capture(.listingOpened, properties)
        selected = item
    }

    private func recordOpen(_ item: AlertInboxItem) async {
        let owner = account.state.viewer?.id
        do {
            let _: ListingAlertsService.Empty = try await service.call("interaction", .init(id: item.alertID, event: "listing_opened",
                interactionID: listingInteractionID, notificationID: item.notificationID, source: "alerts_tab", listingID: item.listing.id), as: ListingAlertsService.Empty.self)
            guard owner == account.state.viewer?.id else { return }
            for index in feed.indices where feed[index].alertID == item.alertID && feed[index].listing.id == item.listing.id {
                feed[index].viewedAt = feed[index].viewedAt ?? Date()
            }
        } catch { if owner == account.state.viewer?.id { self.error = error.localizedDescription } }
    }

    private func refresh() async {
        refreshing = true
        feedGeneration += 1
        let generation = feedGeneration
        let selectedFilter = filter
        let localSaved = selectedFilter == .saved ? feed.filter { saved.contains($0.displayedListing) } : []
        defer { if generation == feedGeneration { refreshing = false } }
        let owner = account.state.viewer?.id
        await push.refreshStatus()
        push.registerIfAuthorized()
        connected = await SessionState.isSignedIn()
        await account.reportFacebookConnection(connected)
        guard generation == feedGeneration else { return }
        guard account.isSignedIn else { alerts = []; allowance = nil; feed = []; feedCursor = nil; return }
        let alertRevision = SearchAlerts.shared.revision
        do {
            async let loadedAlerts = service.call("list", as: ListingAlertsService.AlertList.self)
            async let loadedFeed = service.call("inbox", .init(filter: selectedFilter.rawValue), as: ListingAlertsService.Inbox.self)
            let (alertList, recent) = try await (loadedAlerts, loadedFeed)
            guard owner == account.state.viewer?.id, generation == feedGeneration, selectedFilter == filter else { return }
            alerts = alertList.alerts
            allowance = alertList.allowance
            SearchAlerts.shared.replace(alertList.alerts, for: owner, since: alertRevision)
            feed = recent.items + localSaved.filter { local in !recent.items.contains { $0.id == local.id } && alertList.alerts.contains { $0.id == local.alertID } }
            feed.sort { $0.createdAt == $1.createdAt ? $0.id > $1.id : $0.createdAt > $1.createdAt }
            feedCursor = recent.items.last
            feedMore = recent.items.count == 50; error = nil
        } catch { if generation == feedGeneration { self.error = error.localizedDescription } }
    }

    private func loadMore() async {
        guard !feedLoading, !refreshing, let last = feedCursor else { return }
        feedLoading = true
        defer { feedLoading = false }
        let generation = feedGeneration
        do {
            let loaded = try await service.call("inbox", .init(beforeID: last.listing.id, before: last.createdCursor,
                notificationID: last.notificationID, filter: filter.rawValue), as: ListingAlertsService.Inbox.self)
            guard generation == feedGeneration else { return }
            feed += loaded.items.filter { item in !feed.contains { $0.id == item.id } }
            feedCursor = loaded.items.last
            feedMore = loaded.items.count == 50; error = nil
        } catch { if generation == feedGeneration { self.error = error.localizedDescription } }
    }

    private func navigateToPush() {
        guard let id = coordinator.openAlertID else { return }
        path = [AlertRoute(alertID: id, source: "notification", notificationID: coordinator.openNotificationID)]
        coordinator.openAlertID = nil
    }
}

struct AlertMatchesView: View {
    @EnvironmentObject private var account: AccountSession
    let route: AlertRoute
    private var alertID: String { route.alertID }
    let alert: ListingAlert?
    let changed: () -> Void
    @State private var matches: [AlertMatch] = []
    @State private var notification: AlertNotificationDetails?
    @State private var error: String?
    @State private var more = false
    @State private var loading = false
    @State private var selected: AlertMatch?
    @State private var listingInteractionID = UUID().uuidString
    @State private var paused = false
    @State private var confirmDelete = false
    @State private var changingState = false
    @State private var trackedGroupInteractionID: String?
    @Environment(\.dismiss) private var dismiss
    @Namespace private var listingNamespace
    private let service = ListingAlertsService()

    var body: some View {
        List {
            if let notification {
                Section {
                    Text("\(notification.matchCount) listings · \(alertDayLabel(notification.createdAt))")
                        .font(.subheadline).foregroundStyle(.secondary)
                }
            } else if route.notificationID == nil, let alert {
                Section {
                    LabeledContent("Price", value: AlertPriceInput.summary(min: alert.minPrice, max: alert.maxPrice))
                    LabeledContent("Checks", value: "Daily around \(alert.nextCheckAt.formatted(date: .omitted, time: .shortened))")
                    if paused { Text("Paused").foregroundStyle(.secondary) }
                }
            }
            if let error { Text(error).foregroundStyle(.red) }
            if matches.isEmpty && !loading {
                ContentUnavailableView("No matches yet", systemImage: "bell", description: Text("Matching listings will appear here after a check completes."))
            }
            ForEach(matches) { match in
                Button { open(match) } label: {
                    AlertListingRow(match: match)
                }
            }
            if more { Button("Load more matches") { Task { await load(reset: false) } }.disabled(loading) }
            if loading { ProgressView() }
        }
        .navigationTitle(notification?.query ?? alert?.query ?? "Alert matches")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            Menu {
                Button(paused ? "Resume alert" : "Pause alert", systemImage: paused ? "play" : "pause") {
                    Task { await setPaused() }
                }
                Button("Delete alert", systemImage: "trash", role: .destructive) { confirmDelete = true }
            } label: { Image(systemName: "ellipsis.circle") }
            .disabled(changingState || alert == nil)
        }
        .confirmationDialog("Delete this alert and its saved matches?", isPresented: $confirmDelete) {
            Button("Delete alert", role: .destructive) {
                Task {
                    guard !changingState else { return }
                    let owner = account.state.viewer?.id
                    changingState = true
                    defer { changingState = false }
                    do {
                        let _: ListingAlertsService.Empty = try await service.call("delete", .init(id: alertID), as: ListingAlertsService.Empty.self)
                        guard owner == account.state.viewer?.id else { return }
                        SearchAlerts.shared.remove(id: alertID, for: owner)
                        Analytics.capture(.listingAlertStateChanged, ["alert_id": alertID, "action": "deleted"])
                        changed(); dismiss()
                    } catch { self.error = error.localizedDescription }
                }
            }
        }
        .task(id: route.interactionID) {
            paused = alert?.paused ?? false
            if route.notificationID != nil, trackedGroupInteractionID != route.interactionID {
                trackedGroupInteractionID = route.interactionID
                var properties = interactionProperties
                properties["interaction_id"] = route.interactionID
                Analytics.capture(.listingAlertGroupOpened, properties)
            }
            await load(reset: true)
        }
        .onChange(of: alert?.paused) { _, value in if let value { paused = value } }
        .refreshable { await load(reset: true) }
        .sheet(item: $selected) { match in
            NavigationStack {
                DetailView(listing: match.displayedListing, namespace: listingNamespace, referrer: .listingAlerts,
                    alertSaveContext: .init(alertID: alertID, notificationID: route.notificationID, source: route.source))
                    .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Done") { selected = nil } } }
            }
            .task {
                do {
                    let _: ListingAlertsService.Empty = try await service.call("interaction", .init(id: alertID, event: "listing_opened",
                        interactionID: listingInteractionID, notificationID: route.notificationID, source: route.source, listingID: match.id), as: ListingAlertsService.Empty.self)
                    if let index = matches.firstIndex(where: { $0.id == match.id }) { matches[index].viewedAt = Date() }
                    changed()
                } catch { self.error = error.localizedDescription }
            }
        }
    }

    private var interactionProperties: [String: Any] {
        var properties: [String: Any] = [
            "alert_id": alertID,
            "surface": Analytics.Surface.listingAlerts.rawValue,
            "entry_point": route.source
        ]
        properties["notification_id"] = route.notificationID
        return properties
    }

    private func open(_ match: AlertMatch) {
        listingInteractionID = UUID().uuidString
        let listing = match.displayedListing
        var properties = Analytics.listingOpenProperties(listing, surface: .listingAlerts,
            position: matches.firstIndex(where: { $0.id == match.id }) ?? 0,
            isSaved: SavedListings.shared.contains(listing), isSeen: ViewedListings.shared.contains(listing.id))
        properties.merge(interactionProperties) { _, value in value }
        properties["interaction_id"] = listingInteractionID
        Analytics.capture(.listingOpened, properties)
        selected = match
    }

    private func load(reset: Bool) async {
        guard !loading else { return }
        loading = true; defer { loading = false }
        do {
            let _: ListingAlertsService.Empty = try await service.call("interaction", .init(id: alertID, event: "alert_opened",
                interactionID: route.interactionID, notificationID: route.notificationID, source: route.source), as: ListingAlertsService.Empty.self)
            if route.notificationID != nil { changed() }
            let last = reset ? nil : matches.last
            let loaded = try await service.call("matches", .init(id: alertID, beforeID: last?.id, before: last?.matchedCursor,
                notificationID: route.notificationID), as: ListingAlertsService.MatchList.self)
            notification = loaded.notification
            if reset { matches = loaded.matches } else { matches += loaded.matches.filter { item in !matches.contains { $0.id == item.id } } }
            more = loaded.matches.count == 100; error = nil
        } catch { self.error = error.localizedDescription }
    }

    private func setPaused() async {
        guard !changingState else { return }
        changingState = true
        defer { changingState = false }
        let nextPaused = !paused
        let owner = account.state.viewer?.id
        do {
            let _: ListingAlertsService.Empty = try await service.call("state", .init(id: alertID, paused: nextPaused), as: ListingAlertsService.Empty.self)
            guard owner == account.state.viewer?.id else { return }
            SearchAlerts.shared.setPaused(nextPaused, id: alertID, for: owner)
            paused = nextPaused
            Analytics.capture(.listingAlertStateChanged, ["alert_id": alertID, "action": paused ? "paused" : "resumed"])
            changed()
        } catch { self.error = error.localizedDescription }
    }
}

private struct AlertListingRow: View {
    let match: AlertMatch
    var showNew = true

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            AsyncImage(url: URL(string: match.listing.thumbnailURL)) { image in
                image.resizable().scaledToFill()
            } placeholder: {
                RoundedRectangle(cornerRadius: 12).fill(Color(.tertiarySystemFill))
                    .overlay { Image(systemName: "photo").foregroundStyle(.secondary) }
            }
            .frame(width: 104, height: 104).clipShape(RoundedRectangle(cornerRadius: 12))
            VStack(alignment: .leading, spacing: 6) {
                Text(match.listing.title).font(.subheadline.weight(.medium)).lineLimit(3)
                Text(match.listing.priceText).font(.headline)
                Text(match.listing.locationText).font(.caption).foregroundStyle(.secondary)
                if showNew && match.viewedAt == nil { Text("New").font(.caption.bold()).foregroundStyle(.blue) }
            }
            Spacer(minLength: 0)
        }
        .foregroundStyle(.primary)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
    }
}

private func alertDayLabel(_ date: Date) -> String {
    let calendar = Calendar.current
    let days = calendar.dateComponents([.day], from: calendar.startOfDay(for: date),
                                       to: calendar.startOfDay(for: Date())).day ?? 0
    switch days {
    case ...0: return "Today"
    case 1: return "Yesterday"
    default: return "\(days) days ago"
    }
}

struct AlertPriceFields: View {
    @Binding var input: AlertPriceInput
    @Binding var expanded: Bool

    var body: some View {
        Section {
            DisclosureGroup(isExpanded: $expanded) {
                LabeledContent("Minimum") {
                    TextField("No minimum", text: $input.minimum)
                        .keyboardType(.numberPad).multilineTextAlignment(.trailing)
                        .accessibilityLabel("Minimum price")
                }
                LabeledContent("Maximum") {
                    TextField("No maximum", text: $input.maximum)
                        .keyboardType(.numberPad).multilineTextAlignment(.trailing)
                        .accessibilityLabel("Maximum price")
                }
                Text("Optional. Use whole amounts in the marketplace’s currency. Leave either blank for no limit.")
                    .font(.caption).foregroundStyle(.secondary)
                if !input.minimum.isEmpty || !input.maximum.isEmpty {
                    Button("Clear price limits") { input = AlertPriceInput() }
                }
            } label: {
                LabeledContent("Price", value: input.validationMessage == nil
                    ? AlertPriceInput.summary(min: input.minPrice, max: input.maxPrice) : "Check limits")
            }
            if let message = input.validationMessage {
                Text(message).font(.caption).foregroundStyle(.red)
            }
        }
    }
}

struct AlertInboxFilters: View {
    @Binding var selection: AlertInboxFilter

    var body: some View {
        HStack(spacing: 10) {
            ForEach(AlertInboxFilter.allCases, id: \.self) { filter in
                Button { selection = filter } label: {
                    Text(filter.title).font(.subheadline.weight(.medium))
                        .padding(.horizontal, 22).padding(.vertical, 8)
                        .foregroundStyle(selection == filter ? Color.black : Color.primary)
                        .background(selection == filter ? Color.mint : Color(.secondarySystemFill), in: Capsule())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(selection == filter ? .isSelected : [])
            }
            Spacer(minLength: 0)
        }
    }
}

struct AlertInboxRow: View {
    let item: AlertInboxItem
    let isSaved: Bool
    let open: () -> Void
    let save: () -> Void

    var body: some View {
        HStack(spacing: 4) {
            Button(action: open) {
                HStack(alignment: .top, spacing: 12) {
                    Circle().fill(item.viewedAt == nil ? Color.mint : Color.clear)
                        .frame(width: 7, height: 7).padding(.top, 9)
                        .accessibilityHidden(true)
                    AsyncImage(url: item.displayedListing.thumbnailURL) { image in
                        image.resizable().scaledToFill()
                    } placeholder: {
                        RoundedRectangle(cornerRadius: 11).fill(Color(.tertiarySystemFill))
                            .overlay { Image(systemName: "photo").foregroundStyle(.secondary) }
                    }
                    .frame(width: 72, height: 72).clipShape(RoundedRectangle(cornerRadius: 11))
                    VStack(alignment: .leading, spacing: 5) {
                        Text(item.listing.title).font(.subheadline.weight(.medium)).lineLimit(2)
                        Text(item.displayedListing.displayPrice ?? item.listing.priceText)
                            .font(.subheadline.weight(.semibold))
                        Text([item.listing.locationText, item.createdAt.formatted(.relative(presentation: .named))]
                            .filter { !$0.isEmpty }.joined(separator: " · "))
                            .font(.caption).foregroundStyle(.secondary).lineLimit(2)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityElement(children: .combine)
            .accessibilityValue(item.viewedAt == nil ? "Unread" : "Read")
            Button(action: save) {
                Image(systemName: isSaved ? "bookmark.fill" : "bookmark")
                    .font(.system(size: 20, weight: .regular))
                    .foregroundStyle(isSaved ? Color.mint : Color.primary)
                    .frame(width: 44, height: 44).contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(isSaved ? "Remove saved listing" : "Save listing")
            .accessibilityValue(item.listing.title)
        }
    }
}
