import SwiftUI

/// The chip cloud. Settings-only now — onboarding stopped asking for these.
///
/// Chips are sized by `Interest.prominence` rather than drawn identically. That
/// is the only reason eighteen categories fit on one screen without turning
/// into a list: the broad five carry the layout, and the specific ones sit in
/// the gaps between them, reachable but not competing.
struct InterestPicker: View {
    @Binding var selected: [String]

    var body: some View {
        WrapLayout(spacing: 10) {
            ForEach(Interest.catalogue) { interest in
                chip(interest)
            }
        }
    }

    private func chip(_ interest: Interest) -> some View {
        let isOn = selected.contains(interest.id)
        return Button {
            withAnimation(.easeOut(duration: 0.15)) { toggle(interest) }
        } label: {
            Text(interest.label)
                .font(font(for: interest))
                .fontWeight(isOn ? .semibold : .regular)
                .padding(.horizontal, padding(for: interest))
                .padding(.vertical, padding(for: interest) * 0.62)
                .background(
                    Capsule().fill(isOn ? Color.accentColor.opacity(0.16) : Color(.secondarySystemBackground))
                )
                .overlay(
                    Capsule().stroke(isOn ? Color.accentColor : Color.clear, lineWidth: 1.5)
                )
                .foregroundStyle(isOn ? Color.accentColor : Color.primary)
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isOn ? [.isSelected] : [])
    }

    private func toggle(_ interest: Interest) {
        if let index = selected.firstIndex(of: interest.id) {
            // No minimum to defend any more. Emptying the list is allowed and
            // falls back to `Interest.defaults` — see `Preferences`.
            selected.remove(at: index)
        } else {
            // Appended, so the array stays in the order things were picked —
            // Discover reads it as a ranking when it takes a subset.
            selected.append(interest.id)
        }
    }

    private func font(for interest: Interest) -> Font {
        switch interest.prominence {
        case .broad: .title3
        case .common: .body
        case .specific: .subheadline
        }
    }

    private func padding(for interest: Interest) -> CGFloat {
        switch interest.prominence {
        case .broad: 20
        case .common: 17
        case .specific: 15
        }
    }
}

/// The only place interests are chosen.
///
/// The only place these are chosen — onboarding does not ask, since they drive
/// the search field's suggestions and nothing else, which is too little to
/// charge a required question about taste for. Editable because a standing
/// statement about what someone shops for shouldn't be frozen at whatever they
/// tapped in their first thirty seconds with the app.
struct InterestSettingsView: View {
    @EnvironmentObject private var prefs: Preferences

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("The search field offers these as a starting point, so what you pick here is what it suggests when you haven't searched for anything lately.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)

                InterestPicker(selected: $prefs.interests)

                Text("Pick as many as you like, or none — with nothing chosen, the field suggests a broad default set until your own searches take over.")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
            .padding(16)
        }
        .navigationTitle("Interests")
        .navigationBarTitleDisplayMode(.inline)
    }
}
