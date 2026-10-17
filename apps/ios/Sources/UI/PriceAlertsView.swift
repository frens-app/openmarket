import SwiftUI
import UIKit

private struct AlertRoute: Hashable {
    let alertID: String
    var source = "alerts_tab"
    var notificationID: String?
    let interactionID = UUID().uuidString
}

struct PriceAlertsView: View {
    @EnvironmentObject private var account: AccountSession
    @EnvironmentObject private var prefs: Preferences
    @ObservedObject private var coordinator = PriceAlertCoordinator.shared
    @ObservedObject private var push = PushRegistrar.shared
    @Environment(\.scenePhase) private var scenePhase
    @State private var alerts: [PriceAlert] = []
    @State private var feed: [AlertNotificationGroup] = []
    @State private var feedMore = false
    @State private var feedLoading = false
    @State private var refreshing = false
    @State private var feedGeneration = 0
    @State private var showManage = false
    @State private var path: [AlertRoute] = []
    @State private var query = ""
    @State private var alertTime = AlertSchedule.defaultTime()
    @State private var error: String?
    @State private var busy = false
    @State private var connected = false
    @State private var showCreate = false
    @State private var showLimit = false
    @State private var showAccount = false
    private let service = PriceAlertsService()

    var body: some View {
        NavigationStack(path: $path) {
            List {
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
                if feed.isEmpty && account.isSignedIn && !refreshing {
                    ContentUnavailableView(alerts.isEmpty ? "No alerts yet" : "No matches yet", systemImage: "bell",
                        description: Text(alerts.isEmpty ? "Create an alert for something you’re looking for." : "New finds from your alerts will appear here."))
                }
                ForEach(feed) { group in
                    Button {
                        path.append(AlertRoute(alertID: group.alertID, notificationID: group.id))
                    } label: {
                        AlertNotificationRow(group: group)
                    }
                    .buttonStyle(.plain)
                    .listRowBackground(Color(.secondarySystemGroupedBackground))
                }
                if feedMore {
                    Button("Load earlier matches") { Task { await loadMore() } }.disabled(feedLoading || refreshing)
                }
                if feedLoading || (refreshing && feed.isEmpty) { ProgressView().frame(maxWidth: .infinity) }
            }
            .navigationTitle("Alerts")
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Manage", systemImage: "slider.horizontal.3") { showManage = true }
                        .disabled(alerts.isEmpty)
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        if alerts.count >= 3 {
                            showLimit = true
                        } else {
                            query = ""; alertTime = AlertSchedule.defaultTime(); error = nil; showCreate = true
                        }
                    } label: { Image(systemName: "plus") }
                        .accessibilityLabel("Create alert")
                        .disabled(!account.isSignedIn || !connected || !push.isEnabled || busy)
                }
            }
            .navigationDestination(for: AlertRoute.self) { route in
                AlertMatchesView(route: route, alert: alerts.first { $0.id == route.alertID }, changed: { Task { await refresh() } })
            }
            .refreshable { await refresh() }
            .task { await refresh(); navigateToPush() }
            .onChange(of: coordinator.matchRevision) { _, _ in Task { await refresh() } }
            .onChange(of: coordinator.openAlertID) { _, _ in navigateToPush() }
            .onChange(of: scenePhase) { _, phase in if phase == .active { Task { await refresh() } } }
            .onChange(of: account.state.viewer?.id) { _, _ in
                alerts = []; feed = []; feedGeneration += 1; path = []; error = nil
                Task { await refresh() }
            }
            .sheet(isPresented: $showAccount, onDismiss: { Task { await refresh() } }) {
                AccountGateView(feature: .priceAlerts, done: { showAccount = false })
            }
            .sheet(isPresented: $showCreate) { createSheet }
            .sheet(isPresented: $showManage) { manageSheet }
            .alert("Alert limit reached", isPresented: $showLimit) {
                Button("OK", role: .cancel) {}
            } message: {
                Text("You can have up to 3 alerts, including paused alerts. Delete an alert to create another.")
            }

        }
    }

    private var manageSheet: some View {
        NavigationStack {
            List(alerts) { alert in
                NavigationLink {
                    AlertMatchesView(route: AlertRoute(alertID: alert.id), alert: alert, changed: { Task { await refresh() } })
                } label: {
                    VStack(alignment: .leading, spacing: 5) {
                        Text(alert.query).font(.headline)
                        Text(alert.paused ? "Paused" : "Active").font(.subheadline).foregroundStyle(.secondary)
                    }
                }
            }
            .navigationTitle("Your alerts")
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { showManage = false } } }
        }
    }

    private var createSheet: some View {
        NavigationStack {
            Form {
                Section("What are you looking for?") {
                    TextField("e.g. Nintendo Switch OLED", text: $query, axis: .vertical).lineLimit(3...6)
                    Text("Include the model and any requirements that matter to you.").font(.caption).foregroundStyle(.secondary)
                }
                DatePicker("Daily around", selection: $alertTime, displayedComponents: .hourAndMinute)
                if let error { Text(error).foregroundStyle(.red) }
            }
            .navigationTitle("New alert")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { showCreate = false } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Create") { Task { await create() } }
                        .disabled(busy || query.trimmingCharacters(in: .whitespacesAndNewlines).count < 2 || query.count > 300 || prefs.resolvedPlace == nil)
                }
            }
        }
    }

    private func create() async {
        guard let place = prefs.resolvedPlace else { return }
        busy = true; error = nil
        defer { busy = false }
        do {
            let location = AlertLocation(citySlug: place.segment, name: place.name, radiusKM: prefs.radiusKM, latitude: place.latitude, longitude: place.longitude)
            let schedule = AlertSchedule(date: alertTime)
            let created = try await service.call("create", .init(query: query, location: location,
                alertHour: schedule.hour, alertMinute: schedule.minute, timeZone: schedule.timeZone), as: PriceAlertsService.Created.self)
            showCreate = false
            await refresh()
            path = [AlertRoute(alertID: created.id, source: "creation")]
        } catch { self.error = error.localizedDescription }
    }

    private func refresh() async {
        guard !refreshing else { return }
        refreshing = true
        feedGeneration += 1
        defer { refreshing = false }
        let owner = account.state.viewer?.id
        await push.refreshStatus()
        push.registerIfAuthorized()
        connected = await SessionState.isSignedIn()
        await account.reportFacebookConnection(connected)
        guard account.isSignedIn else { alerts = []; feed = []; return }
        do {
            async let loadedAlerts = service.call("list", as: PriceAlertsService.AlertList.self)
            async let loadedFeed = service.call("notification-feed", as: PriceAlertsService.NotificationFeed.self)
            let (alertList, recent) = try await (loadedAlerts, loadedFeed)
            guard owner == account.state.viewer?.id else { return }
            alerts = alertList.alerts
            feed = recent.groups; feedMore = recent.groups.count == 50; error = nil
        } catch { self.error = error.localizedDescription }
    }

    private func loadMore() async {
        guard !feedLoading, !refreshing, let last = feed.last else { return }
        feedLoading = true
        defer { feedLoading = false }
        let generation = feedGeneration
        do {
            let loaded = try await service.call("notification-feed", .init(beforeID: last.id, before: last.createdCursor), as: PriceAlertsService.NotificationFeed.self)
            guard generation == feedGeneration else { return }
            feed += loaded.groups.filter { item in !feed.contains { $0.id == item.id } }
            feedMore = loaded.groups.count == 50; error = nil
        } catch { self.error = error.localizedDescription }
    }

    private func navigateToPush() {
        guard let id = coordinator.openAlertID else { return }
        path = [AlertRoute(alertID: id, source: "notification", notificationID: coordinator.openNotificationID)]
        coordinator.openAlertID = nil
    }
}

private struct AlertMatchesView: View {
    let route: AlertRoute
    private var alertID: String { route.alertID }
    let alert: PriceAlert?
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
    @Environment(\.dismiss) private var dismiss
    @Namespace private var listingNamespace
    private let service = PriceAlertsService()

    var body: some View {
        List {
            if let notification {
                Section {
                    Text("\(notification.matchCount) listings · \(alertDayLabel(notification.createdAt))")
                        .font(.subheadline).foregroundStyle(.secondary)
                }
            } else if route.notificationID == nil, let alert {
                Section {
                    LabeledContent("Checks", value: "Daily around \(alert.nextCheckAt.formatted(date: .omitted, time: .shortened))")
                    if paused { Text("Paused").foregroundStyle(.secondary) }
                }
            }
            if let error { Text(error).foregroundStyle(.red) }
            if matches.isEmpty && !loading {
                ContentUnavailableView("No matches yet", systemImage: "bell", description: Text("Matching listings will appear here after a check completes."))
            }
            ForEach(matches) { match in
                Button { listingInteractionID = UUID().uuidString; selected = match } label: {
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
        }
        .confirmationDialog("Delete this alert and its saved matches?", isPresented: $confirmDelete) {
            Button("Delete alert", role: .destructive) {
                Task {
                    do {
                        let _: PriceAlertsService.Empty = try await service.call("delete", .init(id: alertID), as: PriceAlertsService.Empty.self)
                        changed(); dismiss()
                    } catch { self.error = error.localizedDescription }
                }
            }
        }
        .task { paused = alert?.paused ?? false; await load(reset: true) }
        .onChange(of: alert?.paused) { _, value in if let value { paused = value } }
        .refreshable { await load(reset: true) }
        .sheet(item: $selected) { match in
            NavigationStack {
                DetailView(listing: match.listing.listing, namespace: listingNamespace, referrer: .priceAlerts)
                    .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Done") { selected = nil } } }
            }
            .task {
                do {
                    let _: PriceAlertsService.Empty = try await service.call("interaction", .init(id: alertID, event: "listing_opened",
                        interactionID: listingInteractionID, notificationID: route.notificationID, source: route.source, listingID: match.id), as: PriceAlertsService.Empty.self)
                    if let index = matches.firstIndex(where: { $0.id == match.id }) { matches[index].viewedAt = Date() }
                    changed()
                } catch { self.error = error.localizedDescription }
            }
        }
    }

    private func load(reset: Bool) async {
        guard !loading else { return }
        loading = true; defer { loading = false }
        do {
            let _: PriceAlertsService.Empty = try await service.call("interaction", .init(id: alertID, event: "alert_opened",
                interactionID: route.interactionID, notificationID: route.notificationID, source: route.source), as: PriceAlertsService.Empty.self)
            let last = reset ? nil : matches.last
            let loaded = try await service.call("matches", .init(id: alertID, beforeID: last?.id, before: last?.matchedCursor,
                notificationID: route.notificationID), as: PriceAlertsService.MatchList.self)
            notification = loaded.notification
            if reset { matches = loaded.matches } else { matches += loaded.matches.filter { item in !matches.contains { $0.id == item.id } } }
            more = loaded.matches.count == 100; error = nil
        } catch { self.error = error.localizedDescription }
    }

    private func setPaused() async {
        do {
            let _: PriceAlertsService.Empty = try await service.call("state", .init(id: alertID, paused: !paused), as: PriceAlertsService.Empty.self)
            paused.toggle(); changed()
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

struct AlertNotificationRow: View {
    let group: AlertNotificationGroup

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 12) {
                Text("Listings matching \(group.query)")
                    .font(.headline).lineLimit(2).multilineTextAlignment(.leading)
                Spacer(minLength: 0)
                if group.unreadCount > 0 {
                    Text("New").font(.caption.bold()).foregroundStyle(.blue)
                        .padding(.horizontal, 8).padding(.vertical, 4)
                        .background(.blue.opacity(0.1), in: Capsule())
                }
                Image(systemName: "chevron.right").font(.caption.weight(.semibold)).foregroundStyle(.tertiary)
            }
            if !group.previews.isEmpty {
                GeometryReader { geometry in
                    let count = group.previews.count
                    let width = min(geometry.size.height, (geometry.size.width - CGFloat(count - 1) * 8) / CGFloat(count))
                    HStack(spacing: 8) {
                        ForEach(Array(group.previews.enumerated()), id: \.element.id) { index, listing in
                            AsyncImage(url: URL(string: listing.thumbnailURL)) { image in
                                image.resizable().scaledToFill()
                            } placeholder: {
                                Rectangle().fill(Color(.tertiarySystemFill))
                                    .overlay { Image(systemName: "photo").foregroundStyle(.secondary) }
                            }
                            .frame(width: width, height: geometry.size.height)
                            .clipped()
                            .overlay {
                                if index == count - 1 && group.matchCount > count {
                                    Color.black.opacity(0.45)
                                    Text("+\(group.matchCount - count)").font(.title3.bold()).foregroundStyle(.white)
                                }
                            }
                            .clipShape(RoundedRectangle(cornerRadius: 10))
                            .accessibilityLabel(listing.title)
                        }
                    }
                }
                .frame(height: group.previews.count == 1 ? 128 : 96)
            }
            Text(alertDayLabel(group.createdAt)).font(.caption).foregroundStyle(.secondary)
        }
        .foregroundStyle(.primary)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
    }
}
