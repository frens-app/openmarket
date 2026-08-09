import SwiftUI

/// The card-to-detail transition, expressed as a *navigation* transition rather
/// than as a geometry match.
///
/// This used to be a `matchedGeometryEffect` with one id shared between the
/// grid card's thumbnail and the detail screen's photo deck. That is not what
/// the effect is for. It matches two views **within a single hierarchy** by
/// electing one the geometry source and forcing the other into its frame — but
/// a `navigationDestination` push leaves both on screen at once, each declaring
/// itself a source for the same id, and what happens then is undefined.
///
/// The visible symptom (FRE-6481) was the interactive back swipe: part-way
/// through the pop, with the grid and the detail both mounted, the detail's
/// photo snapped into the card's 180pt frame at the left edge while the page
/// dots stayed where they were — a sliver of photo down the side of an empty
/// black box.
///
/// `.zoom` is the supported spelling of the same intent. The source is only a
/// marker; the animation is driven by the navigation stack itself, so it knows
/// about the interactive pop and can run backwards with the user's thumb. It
/// arrived in iOS 18, and on 17 both modifiers below do nothing and the push is
/// the system's standard slide — the right fallback, given the choice is
/// between a transition that is merely plain and one that was visibly broken.
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
