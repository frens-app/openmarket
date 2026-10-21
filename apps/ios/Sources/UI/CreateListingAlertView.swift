import SwiftUI
import UIKit

struct ListingAlertDraft: Identifiable {
    let id = UUID()
    var query = ""
    var minPrice: Int?
    var maxPrice: Int?
    var source = "alerts_tab"
}

struct CreateListingAlertView: View {
    let draft: ListingAlertDraft
    let created: (String) -> Void
    @EnvironmentObject private var account: AccountSession
    @EnvironmentObject private var prefs: Preferences
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @ObservedObject private var push = PushRegistrar.shared
    @State private var query: String
    @State private var priceInput: AlertPriceInput
    @State private var showPrices = false
    @State private var alertTime = AlertSchedule.defaultTime()
    @State private var connected = false
    @State private var checkedSetup = false
    @State private var showAccount = false
    @State private var busy = false
    @State private var error: String?
    private let service = ListingAlertsService()

    init(draft: ListingAlertDraft, created: @escaping (String) -> Void) {
        self.draft = draft
        self.created = created
        _query = State(initialValue: draft.query)
        _priceInput = State(initialValue: AlertPriceInput(minimum: draft.minPrice.map(String.init) ?? "",
                                                         maximum: draft.maxPrice.map(String.init) ?? ""))
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("What are you looking for?") {
                    TextField("e.g. Nintendo Switch OLED", text: $query, axis: .vertical).lineLimit(2...4)
                        .accessibilityIdentifier("alert-query-field")
                }
                AlertPriceFields(input: $priceInput, expanded: $showPrices)
                Section {
                    DatePicker("Daily around", selection: $alertTime, displayedComponents: .hourAndMinute)
                }
                if let error { Section { Text(error).foregroundStyle(.red) } }
                Section {
                    Button { Task { await continueSetupOrCreate() } } label: {
                        HStack {
                            Spacer()
                            if busy { ProgressView().tint(.white) }
                            Text(actionTitle).font(.headline)
                            Spacer()
                        }
                        .padding(.vertical, 8)
                    }
                    .buttonStyle(.borderedProminent)
                    .listRowBackground(Color.clear)
                    .listRowInsets(EdgeInsets())
                    .disabled(busy || !checkedSetup || query.trimmingCharacters(in: .whitespacesAndNewlines).count < 2
                              || query.count > 300 || priceInput.validationMessage != nil || prefs.resolvedPlace == nil)
                    .accessibilityIdentifier("create-alert-button")
                }
            }
            .disabled(busy)
            .navigationTitle(draft.source == "search" ? "Get Daily Alerts" : "New alert")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() }.disabled(busy) } }
            .interactiveDismissDisabled(busy)
            .sheet(isPresented: $showAccount, onDismiss: { Task { await refreshSetup() } }) {
                AccountGateView(feature: .listingAlerts, done: { showAccount = false })
            }
            .task { await refreshSetup() }
            .onChange(of: scenePhase) { _, phase in if phase == .active { Task { await refreshSetup() } } }
            .onChange(of: account.state.viewer?.id) { old, new in
                if old != nil && old != new { dismiss() }
            }
        }
    }

    private var actionTitle: String {
        if !account.state.hasSocialSignIn { return "Continue with Apple or Google" }
        if !connected { return "Connect Facebook" }
        if !push.isEnabled { return push.status == .denied ? "Open notification settings" : "Enable notifications" }
        return "Create alert"
    }

    private func refreshSetup() async {
        await push.refreshStatus()
        push.registerIfAuthorized()
        connected = await SessionState.isSignedIn()
        await account.reportFacebookConnection(connected)
        checkedSetup = true
    }

    private func continueSetupOrCreate() async {
        guard !busy else { return }
        error = nil
        guard account.state.hasSocialSignIn, connected else { showAccount = true; return }
        if !push.isEnabled {
            if push.status == .denied {
                if let url = URL(string: UIApplication.openSettingsURLString) { await UIApplication.shared.open(url) }
            } else {
                busy = true
                await push.requestAuthorization()
                busy = false
            }
            return
        }
        guard let owner = account.state.viewer?.id, let place = prefs.resolvedPlace,
              priceInput.validationMessage == nil else { return }
        busy = true
        defer { busy = false }
        do {
            let alertRevision = SearchAlerts.shared.revision
            let loaded = try await service.call("list", as: ListingAlertsService.AlertList.self)
            guard account.state.viewer?.id == owner else { return }
            let existing = loaded.alerts
            SearchAlerts.shared.replace(existing, for: owner, since: alertRevision)
            if existing.contains(where: { SearchAlert.normalizedQuery($0.query) == SearchAlert.normalizedQuery(query)
                && $0.minPrice == priceInput.minPrice && $0.maxPrice == priceInput.maxPrice }) {
                error = "You already have an alert for this search. You can manage it in Alerts."
                return
            }
            if let allowance = loaded.allowance, !allowance.hasAvailableSlot {
                error = allowance.limitMessage
                return
            }
            let location = AlertLocation(citySlug: place.segment, name: place.name, radiusKM: prefs.radiusKM,
                                         latitude: place.latitude, longitude: place.longitude)
            let schedule = AlertSchedule(date: alertTime)
            let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
            let result = try await service.call("create", .init(query: trimmed, location: location,
                alertHour: schedule.hour, alertMinute: schedule.minute, timeZone: schedule.timeZone,
                minPrice: priceInput.minPrice, maxPrice: priceInput.maxPrice), as: ListingAlertsService.Created.self)
            guard account.state.viewer?.id == owner else { return }
            SearchAlerts.shared.created(SearchAlert(id: result.id, query: trimmed, minPrice: priceInput.minPrice,
                                                   maxPrice: priceInput.maxPrice), for: owner)
            Analytics.capture(.listingAlertCreated, ["alert_id": result.id, "alert_hour": schedule.hour,
                "alert_minute": schedule.minute, "time_zone": schedule.timeZone, "entry_point": draft.source])
            created(result.id)
            dismiss()
        } catch { if account.state.viewer?.id == owner { self.error = error.localizedDescription } }
    }
}

struct AlertAllowanceSummary: View {
    let allowance: ListingAlertAllowance

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            LabeledContent("Active alerts", value: "\(allowance.active) of \(allowance.limit)")
            Text(allowance.hasAvailableSlot
                 ? "Paused alerts don't use a slot."
                 : "Pause or delete an alert in Alerts to free up a slot.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }
}

struct SearchAlertButton: View {
    var alert: SearchAlert?
    var iconOnly = false
    let action: () -> Void

    private var title: String {
        alert.map { $0.paused ? "Alerts paused" : "Alerts on" } ?? "Get alerts"
    }

    private var isActive: Bool { alert?.paused == false }

    var body: some View {
        Button(action: action) {
            if iconOnly {
                icon
            } else {
                Label(title, systemImage: alert.map { $0.paused ? "bell.slash" : "bell.badge.fill" } ?? "bell.badge")
                    .labelStyle(.titleAndIcon)
                    .font(.footnote.weight(.semibold))
                    .padding(.horizontal, 10).padding(.vertical, 6)
                    .foregroundStyle(isActive ? Color.accentColor : Color.secondary)
                    .background(isActive ? Color.accentColor.opacity(0.12) : Color(.secondarySystemFill), in: Capsule())
                    .frame(minHeight: 44)
                    .contentShape(Rectangle())
            }
        }
        .buttonStyle(.plain)
        .fixedSize(horizontal: true, vertical: true)
        .accessibilityLabel(title)
        .accessibilityIdentifier("search-alert-button")
        .accessibilityHint(alert == nil ? "Create a daily alert for this search" : "Manage this alert")
    }

    private var icon: some View {
        Image(systemName: alert.map { $0.paused ? "bell.slash" : "bell.fill" } ?? "bell")
            .font(.system(size: 18, weight: .semibold))
            .foregroundStyle(isActive ? Color.white : Color.secondary)
            .overlay(alignment: .topTrailing) {
                if isActive {
                    Image(systemName: "checkmark")
                        .font(.system(size: 8, weight: .bold))
                        .foregroundStyle(.white)
                        .frame(width: 13, height: 13)
                        .background(Color.accentColor, in: Circle())
                        .offset(x: 6, y: -4)
                }
            }
            .frame(width: 44, height: 44)
            .background(isActive ? Color.accentColor : Color(.secondarySystemFill),
                        in: RoundedRectangle(cornerRadius: 12))
            .contentShape(RoundedRectangle(cornerRadius: 12))
    }
}

struct SearchAlertDetailsSheet: View {
    let route: AlertRoute
    @EnvironmentObject private var account: AccountSession
    @Environment(\.dismiss) private var dismiss
    @State private var alert: ListingAlert?
    @State private var loadError: String?
    @State private var generation = 0

    var body: some View {
        NavigationStack {
            AlertMatchesView(route: route, alert: alert, changed: { Task { await refresh() } })
                .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Done") { dismiss() } } }
                .safeAreaInset(edge: .bottom) {
                    if let loadError {
                        InlineNotice(text: loadError, actionTitle: "Try again") { Task { await refresh() } }
                            .background(.bar)
                    }
                }
        }
        .task { await refresh() }
        .onChange(of: account.state.viewer?.id) { _, _ in dismiss() }
    }

    private func refresh() async {
        generation += 1
        let current = generation
        let owner = account.state.viewer?.id
        let alertRevision = SearchAlerts.shared.revision
        do {
            let loaded = try await ListingAlertsService().call("list", as: ListingAlertsService.AlertList.self)
            guard account.state.viewer?.id == owner, current == generation else { return }
            SearchAlerts.shared.replace(loaded.alerts, for: owner, since: alertRevision)
            alert = loaded.alerts.first { $0.id == route.alertID }
            loadError = nil
            if alert == nil { dismiss() }
        } catch {
            guard !Task.isCancelled, !(error is CancellationError),
                  (error as? URLError)?.code != .cancelled else { return }
            if current == generation, account.state.viewer?.id == owner { loadError = error.localizedDescription }
        }
    }
}
