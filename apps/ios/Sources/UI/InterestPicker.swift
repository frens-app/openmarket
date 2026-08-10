import SwiftUI

/// The chip cloud, shared by onboarding and Settings so there is one place
/// where interests get picked and one set of rules about it.
///
/// Chips are sized by `Interest.prominence` rather than drawn identically. That
/// is the only reason eighteen categories fit on one screen without turning
/// into a list: the broad five carry the layout, and the specific ones sit in
/// the gaps between them, reachable but not competing.
struct InterestPicker: View {
    @Binding var selected: [String]

    /// Whether the last few can be taken off.
    ///
    /// Off during onboarding, where the Continue button is the thing that says
    /// "not yet" and deselecting freely is how anyone corrects a mis-tap. On in
    /// Settings, where dropping below the minimum would satisfy
    /// `Preferences.needsOnboarding` and throw the whole onboarding flow back
    /// over the app — technically correct enforcement, and a baffling thing to
    /// have happen while editing a list.
    var enforcesMinimum = false

    var body: some View {
        WrapLayout(spacing: 10) {
            ForEach(Interest.catalogue) { interest in
                chip(interest)
            }
        }
    }

    private func chip(_ interest: Interest) -> some View {
        let isOn = selected.contains(interest.id)
        let locked = enforcesMinimum && isOn && selected.count <= Interest.minimum
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
        .disabled(locked)
        .opacity(locked ? 0.75 : 1)
        .accessibilityAddTraits(isOn ? [.isSelected] : [])
    }

    private func toggle(_ interest: Interest) {
        if let index = selected.firstIndex(of: interest.id) {
            guard !(enforcesMinimum && selected.count <= Interest.minimum) else { return }
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

/// The Settings route back to the same choice.
///
/// Onboarding asks once and never again, which would leave a standing statement
/// about what someone shops for frozen at whatever they tapped in their first
/// thirty seconds with the app. What it drives is smaller than it was — the
/// search field's suggestions, not the home feed — but it is still a statement
/// about the user, and those go stale.
struct InterestSettingsView: View {
    @EnvironmentObject private var prefs: Preferences

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("The search field offers these as a starting point, so what you pick here is what it suggests when you haven't searched for anything lately.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)

                InterestPicker(selected: $prefs.interests, enforcesMinimum: true)

                Text("At least \(Interest.minimum), so there's a choice to make rather than one thing to tap.")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
            .padding(16)
        }
        .navigationTitle("Interests")
        .navigationBarTitleDisplayMode(.inline)
    }
}
