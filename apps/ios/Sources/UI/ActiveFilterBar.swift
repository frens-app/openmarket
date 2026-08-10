import SwiftUI

/// What the results on screen are actually filtered by, stated rather than
/// counted.
///
/// The toolbar's filter button carries a dot when anything is narrowing the
/// results, which answers "is something on?" and nothing else. That is the
/// wrong question: a result set that looks thin is usually thin for a *reason*,
/// and the reason was two taps away inside a sheet.
///
/// So the two things that shape every search — where, and in what order — get
/// permanent readouts, and every other active filter appears as a chip that can
/// be removed where it is read. Nothing hides behind a badge.
struct ActiveFilterBar: View {
    @EnvironmentObject private var prefs: Preferences
    /// A location change in flight, or one that just failed. The bar is where
    /// the place is read, so it is where a change to it should be reported.
    @EnvironmentObject private var chooser: PlaceChooser

    /// Opens the location picker.
    let onLocation: () -> Void
    /// Called after a change Facebook applies server-side, which needs a fresh
    /// search. Client-side filters don't call it — see `Chip.needsRerun`.
    let onRerun: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                locationReadout
                sortReadout
            }
            if !chips.isEmpty {
                chipRow
            }
            switchNotice
        }
        .padding(.horizontal, 16)
        // Tight to the search field above. The bar reads as belonging to it —
        // where, how sorted, what else — so the two want to look like one
        // block rather than two stacked controls with air between them.
        .padding(.top, 2)
        .padding(.bottom, 10)
        .background(.bar)
    }

    // MARK: - Readouts

    private var locationReadout: some View {
        Button(action: onLocation) {
            readout(caption: "LOCATION", value: locationValue,
                    isPending: chooser.switching != nil)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(chooser.switching == nil
                            ? "Location, \(locationValue). Change"
                            : "Location, switching to \(locationValue). Change")
    }

    /// A menu rather than a route into the filter sheet: sorting is one of two
    /// things people change constantly, and it should cost one tap.
    private var sortReadout: some View {
        Menu {
            ForEach(SearchQuery.Sort.allCases, id: \.self) { option in
                Button {
                    guard option != prefs.sort else { return }
                    prefs.sort = option
                    onRerun()
                } label: {
                    if option == prefs.sort {
                        Label(option.label, systemImage: "checkmark")
                    } else {
                        Text(option.label)
                    }
                }
            }
        } label: {
            readout(caption: "SORT", value: prefs.sort.label)
        }
        // A `Menu` tints its label with the accent colour, which made the two
        // halves of the bar look like different kinds of thing — one a value,
        // one a link — when they are the same kind of control.
        .tint(Color.primary)
        .accessibilityLabel("Sort, \(prefs.sort.label). Change")
    }

    /// Caption above value, both always legible. The caption is what makes the
    /// pair readable at a glance — two bare strings side by side don't say
    /// which is the place and which is the order.
    private func readout(caption: String, value: String,
                         isPending: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(caption)
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.tertiary)
            HStack(spacing: 6) {
                Text(value)
                    .font(.subheadline.weight(.medium))
                    // Dimmed while unconfirmed, which is the cheapest honest
                    // signal available: the name is what the user asked for,
                    // not yet what the results are.
                    .foregroundStyle(isPending ? .secondary : .primary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                if isPending { ProgressView().controlSize(.mini) }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 12))
        .contentShape(Rectangle())
    }

    /// The radius lives here rather than in a chip of its own.
    ///
    /// "San Francisco · 10 mi" is one fact — the catchment — and splitting it
    /// across a readout and a removable chip invites the reading that they are
    /// two separate filters that could disagree.
    /// The place the user has asked for, which is not always the place the
    /// results are from — `switchNotice` is what keeps that distinction
    /// visible while a change is in flight.
    private var locationValue: String {
        let place = chooser.displayName ?? "Choose a location"
        guard prefs.radiusKM > 0 else { return place }
        return "\(place) · \(SearchQuery.kilometresToMiles(prefs.radiusKM)) mi"
    }

    // MARK: - Switching

    /// The one line that stops the optimistic label from being a lie.
    ///
    /// A location change takes about ten seconds to agree with Facebook
    /// (`docs/location.md` §4) and the results on screen belong to the old
    /// place for all of it. The pill says where the user is going; this says
    /// what they are currently looking at, and afterwards says whether they got
    /// there. Both readings matter — a result set that silently belongs to
    /// another city is this whole area's characteristic failure.
    @ViewBuilder
    private var switchNotice: some View {
        if let change = chooser.switching {
            notice(icon: "arrow.triangle.2.circlepath", tint: .secondary) {
                Text(change.previous.map { "Switching to \(change.name) — these results are still \($0)." }
                     ?? "Switching to \(change.name)…")
            }
        } else if let failed = chooser.failure {
            notice(icon: "exclamationmark.triangle", tint: .orange, onDismiss: chooser.dismissFailure) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(failed.summary)
                    if failed.hasDetail {
                        Text(failed.reason).foregroundStyle(.tertiary)
                    }
                }
            }
        }
    }

    private func notice<Content: View>(icon: String,
                                       tint: Color,
                                       onDismiss: (() -> Void)? = nil,
                                       @ViewBuilder content: () -> Content) -> some View {
        HStack(alignment: .top, spacing: 6) {
            Image(systemName: icon)
                .foregroundStyle(tint)
            content()
                .frame(maxWidth: .infinity, alignment: .leading)
            if let onDismiss {
                Button(action: onDismiss) {
                    Image(systemName: "xmark")
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Dismiss")
            }
        }
        .font(.footnote)
        .foregroundStyle(.secondary)
        // Announced rather than left to be noticed: the user's attention is on
        // the grid, which is the part that hasn't changed yet.
        .accessibilityAddTraits(.updatesFrequently)
    }

    // MARK: - Chips

    private var chipRow: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(chips) { chip in
                    chipView(chip)
                }
                Button("Clear all") {
                    // Radius and location are deliberately untouched: they are
                    // the readouts above, not chips, and wiping the place a
                    // user chose because they cleared a price filter would be
                    // its own bug.
                    let neededRerun = chips.contains { $0.needsRerun }
                    for chip in chips { chip.clear() }
                    if neededRerun { onRerun() }
                }
                .font(.footnote)
                .padding(.leading, 4)
            }
            .padding(.horizontal, 1)    // keeps focus rings from clipping
        }
    }

    private func chipView(_ chip: Chip) -> some View {
        HStack(spacing: 5) {
            Text(chip.label)
                .font(.footnote.weight(.medium))
            Image(systemName: "xmark")
                .font(.caption2.weight(.bold))
                .foregroundStyle(.secondary)
        }
        .padding(.leading, 11)
        .padding(.trailing, 9)
        .padding(.vertical, 6)
        .background(Color.accentColor.opacity(0.12), in: Capsule())
        .overlay(Capsule().stroke(Color.accentColor.opacity(0.25), lineWidth: 0.5))
        .contentShape(Capsule())
        .onTapGesture {
            chip.clear()
            if chip.needsRerun { onRerun() }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(chip.label). Remove")
        .accessibilityAddTraits(.isButton)
    }

    private struct Chip: Identifiable {
        let id: String
        let label: String
        /// Whether removing it costs a fresh search. Price, condition and
        /// delivery are applied by Facebook; "only new" is applied here, so
        /// clearing it should not spend a page load.
        let needsRerun: Bool
        let clear: () -> Void
    }

    private var chips: [Chip] {
        var chips: [Chip] = []

        if prefs.minPrice != nil || prefs.maxPrice != nil {
            chips.append(Chip(id: "price", label: priceLabel, needsRerun: true) {
                prefs.minPrice = nil
                prefs.maxPrice = nil
            })
        }
        for condition in prefs.conditions {
            chips.append(Chip(id: "condition-\(condition.rawValue)",
                              label: condition.label, needsRerun: true) {
                prefs.conditions.removeAll { $0 == condition }
            })
        }
        if let delivery = deliveryLabel {
            chips.append(Chip(id: "delivery", label: delivery, needsRerun: true) {
                prefs.delivery = .localPickup
            })
        }
        if prefs.hideViewed {
            chips.append(Chip(id: "viewed", label: "Only new", needsRerun: false) {
                prefs.hideViewed = false
            })
        }
        return chips
    }

    /// Nil for the default. `Delivery` carries no display name of its own —
    /// the filter sheet labels its own pills inline — so the wording lives here
    /// rather than being invented twice.
    private var deliveryLabel: String? {
        switch prefs.delivery {
        case .localPickup: nil
        case .shipping: "Shipping"
        case .any: "Any delivery"
        }
    }

    private var priceLabel: String {
        switch (prefs.minPrice, prefs.maxPrice) {
        case let (min?, max?): "$\(min)–$\(max)"
        case let (nil, max?): "Under $\(max)"
        case let (min?, nil): "Over $\(min)"
        default: "Any price"
        }
    }
}
