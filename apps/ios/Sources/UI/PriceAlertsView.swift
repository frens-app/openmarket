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
    @State private var path: [AlertRoute] = []
    @State private var query = ""
    @State private var alertTime = AlertSchedule.defaultTime()
    @State private var error: String?
    @State private var busy = false
    @State private var connected = false
    @State private var showCreate = false
    @State private var showLimit = false
    @State private var showAccount = false
    @State private var deleteID: String?
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
                if alerts.isEmpty && account.isSignedIn {
                    ContentUnavailableView("No listing alerts yet", systemImage: "bell", description: Text("Create an alert for a product you want to find."))
                }
                ForEach(alerts) { alert in
                    NavigationLink(value: AlertRoute(alertID: alert.id)) {
                        VStack(alignment: .leading, spacing: 6) {
                            HStack {
                                Text(alert.query).font(.headline)
                                if alert.unreadCount > 0 {
                                    Text("\(alert.unreadCount) new").font(.caption.bold()).foregroundStyle(.blue)
                                }
                            }
                            Text(alert.paused ? "Paused" : "Daily around \(alert.nextCheckAt.formatted(date: .omitted, time: .shortened))")
                                .font(.subheadline).foregroundStyle(.secondary)
                            Text("\(alert.matchCount) matches")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        .contextMenu { options(alert) }
                    }
                    .swipeActions { Button("Delete", role: .destructive) { deleteID = alert.id } }
                }
            }
            .navigationTitle("Listing alerts")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        if alerts.count >= 3 {
                            showLimit = true
                        } else {
                            query = ""; alertTime = AlertSchedule.defaultTime(); error = nil; showCreate = true
                        }
                    } label: { Image(systemName: "plus") }
                        .accessibilityLabel("Create listing alert")
                        .disabled(!account.isSignedIn || !connected || !push.isEnabled || busy)
                }
            }
            .navigationDestination(for: AlertRoute.self) { route in
                AlertMatchesView(route: route, alert: alerts.first { $0.id == route.alertID }, changed: { Task { await refresh() } })
            }
            .refreshable { await refresh() }
            .task { await refresh(); navigateToPush() }
            .onChange(of: coordinator.openAlertID) { _, _ in navigateToPush() }
            .onChange(of: scenePhase) { _, phase in if phase == .active { Task { await refresh() } } }
            .onChange(of: account.state.viewer?.id) { _, _ in
                alerts = []; path = []; error = nil
                Task { await refresh() }
            }
            .sheet(isPresented: $showAccount, onDismiss: { Task { await refresh() } }) {
                AccountGateView(feature: .priceAlerts, done: { showAccount = false })
            }
            .sheet(isPresented: $showCreate) { createSheet }
            .alert("Alert limit reached", isPresented: $showLimit) {
                Button("OK", role: .cancel) {}
            } message: {
                Text("You can have up to 3 alerts, including paused alerts. Delete an alert to create another.")
            }
            .confirmationDialog("Delete this alert and its saved matches?", isPresented: Binding(get: { deleteID != nil }, set: { if !$0 { deleteID = nil } })) {
                Button("Delete alert", role: .destructive) {
                    if let id = deleteID { Task { await mutate("delete", .init(id: id)) } }
                    deleteID = nil
                }
            }
        }
    }

    @ViewBuilder private func options(_ alert: PriceAlert) -> some View {
        Button(alert.paused ? "Resume alert" : "Pause alert", systemImage: alert.paused ? "play" : "pause") {
            Task { await mutate("state", .init(id: alert.id, paused: !alert.paused)) }
        }
        Button("Delete alert", systemImage: "trash", role: .destructive) { deleteID = alert.id }
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
            .navigationTitle("New listing alert")
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

    private func mutate(_ action: String, _ request: PriceAlertsService.Request) async {
        busy = true; error = nil
        defer { busy = false }
        do {
            let _: PriceAlertsService.Empty = try await service.call(action, request, as: PriceAlertsService.Empty.self)
            await refresh()
        } catch { self.error = error.localizedDescription }
    }

    private func refresh() async {
        let owner = account.state.viewer?.id
        await push.refreshStatus()
        push.registerIfAuthorized()
        connected = await SessionState.isSignedIn()
        await account.reportFacebookConnection(connected)
        guard account.isSignedIn else { alerts = []; return }
        do {
            let loaded = try await service.call("list", as: PriceAlertsService.AlertList.self).alerts
            guard owner == account.state.viewer?.id else { return }
            alerts = loaded; error = nil
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
            if let error { Text(error).foregroundStyle(.red) }
            if matches.isEmpty && !loading {
                ContentUnavailableView("No matches yet", systemImage: "bell", description: Text("Matching listings will appear here after a check completes."))
            }
            ForEach(matches) { match in
                Button { listingInteractionID = UUID().uuidString; selected = match } label: {
                    HStack(spacing: 12) {
                        AsyncImage(url: URL(string: match.listing.thumbnailURL)) { image in image.resizable().scaledToFill() } placeholder: { Color(.secondarySystemBackground) }
                            .frame(width: 72, height: 72).clipShape(RoundedRectangle(cornerRadius: 10))
                        VStack(alignment: .leading, spacing: 4) {
                            Text(match.listing.title).font(.headline)
                            Text(match.listing.priceText)
                            Text(match.listing.locationText).font(.caption).foregroundStyle(.secondary)
                            if match.viewedAt == nil { Text("New").font(.caption.bold()).foregroundStyle(.blue) }
                        }
                    }.foregroundStyle(.primary)
                }
            }
            if more { Button("Load more matches") { Task { await load(reset: false) } }.disabled(loading) }
            if loading { ProgressView() }
        }
        .navigationTitle(alert?.query ?? "Alert matches")
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
            let loaded = try await service.call("matches", .init(id: alertID, beforeID: last?.id, before: last?.matchedCursor), as: PriceAlertsService.MatchList.self).matches
            if reset { matches = loaded } else { matches += loaded.filter { item in !matches.contains { $0.id == item.id } } }
            more = loaded.count == 100; error = nil
        } catch { self.error = error.localizedDescription }
    }

    private func setPaused() async {
        do {
            let _: PriceAlertsService.Empty = try await service.call("state", .init(id: alertID, paused: !paused), as: PriceAlertsService.Empty.self)
            paused.toggle(); changed()
        } catch { self.error = error.localizedDescription }
    }
}
