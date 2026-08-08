import SwiftUI
import UIKit

/// What to say when the user asks for location and iOS won't ask on our behalf.
///
/// The permission dialog is a once-per-install event. After a refusal
/// `requestWhenInUseAuthorization` is a no-op — it returns silently and nothing
/// appears — so a tap on "Use my current location" in that state does visibly
/// nothing. The only honest response is to say where the switch actually lives
/// and offer to open it, because the app genuinely cannot ask again itself.
///
/// An alert rather than inline text: this is the direct answer to a button the
/// user just pressed, and it carries the one action that can undo the state.
/// The refusal used to surface as a grey footnote under the button, which
/// mentioned Settings but left the user to go and find it.
private struct LocationSettingsAlert: ViewModifier {
    @Binding var isPresented: Bool
    @Environment(\.openURL) private var openURL

    func body(content: Content) -> some View {
        content.alert("Location is off for Open Market", isPresented: $isPresented) {
            Button("Open Settings") {
                if let url = URL(string: UIApplication.openSettingsURLString) { openURL(url) }
            }
            // Not a dead end: every screen that raises this also offers a city
            // search, which needs no permission at all.
            Button("Not Now", role: .cancel) { }
        } message: {
            Text("Open Market can't use your location because permission was turned off. "
                 + "You can turn it back on in Settings under Privacy, or search for a city instead.")
        }
    }
}

extension View {
    /// Presents the "turn it back on in Settings" alert. Bind to whatever
    /// records that a deliberate request for location was refused.
    func locationSettingsAlert(isPresented: Binding<Bool>) -> some View {
        modifier(LocationSettingsAlert(isPresented: isPresented))
    }
}
