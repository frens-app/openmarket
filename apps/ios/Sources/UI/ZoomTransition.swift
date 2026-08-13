import SwiftUI

/// The card-to-detail transition, expressed as a *navigation* transition rather
/// than as a geometry match.
///
/// **Not** a `matchedGeometryEffect` sharing one id between the grid card's
/// thumbnail and the detail's photo deck. That effect matches two views within a
/// single hierarchy by electing one the geometry source, but a
/// `navigationDestination` push leaves both on screen at once, each declaring
/// itself the source for the same id, and the result is undefined — visibly so
/// on the interactive back swipe (FRE-6481), where the detail's photo snapped
/// into the card's 180pt frame while the page dots stayed put.
///
/// `.zoom` is the supported spelling of the same intent: the source is only a
/// marker, and the navigation stack drives the animation, so it knows about the
/// interactive pop and can run backwards with the user's thumb. iOS 18+; on 17
/// both modifiers below do nothing and the push is the standard slide.
extension View {
    /// Marks the card a push should zoom out of.
    @ViewBuilder
    func zoomTransitionSource(id: String, in namespace: Namespace.ID) -> some View {
        if #available(iOS 18, *) {
            matchedTransitionSource(id: id, in: namespace)
        } else {
            self
        }
    }

    /// Marks the pushed screen that zooms out of that card.
    ///
    /// Applied to the destination as a whole, not to the photo deck inside it:
    /// the system scales the entire incoming screen up out of the card, which
    /// is why nothing within the detail view needs to know this is happening.
    /// A destination whose `id` matches no source on screen — a listing opened
    /// from the recents rail, say — simply gets the standard push.
    @ViewBuilder
    func zoomTransitionDestination(id: String, in namespace: Namespace.ID) -> some View {
        if #available(iOS 18, *) {
            navigationTransition(.zoom(sourceID: id, in: namespace))
        } else {
            self
        }
    }
}
