import SwiftUI

/// The listing's photos as one paginated deck, and the full-screen viewer a tap
/// on it opens.
///
/// Facebook's own item page is the reference: a single photo occupying the top
/// of the page, swiped horizontally, with page dots over it and a count when
/// blown up. The strip of thumbnails this replaced showed every photo at once
/// but at 96pt, which is small enough that nobody could actually judge a photo
/// from it — the deck trades simultaneity for a photo you can see.
///
/// The height is fixed for the same reason the old hero's was: an `AsyncImage`
/// placeholder has no intrinsic size, so a box sized by its content collapses
/// on the first frame and then shoves the whole page down when a photo decodes.
struct PhotoGallery: View {
    let photos: [URL]
    /// Drawn over the deck when the listing is gone — the deck owns the hero
    /// slot now, so it also owns the dimming and the stamp that used to sit on
    /// the hero.
    let overlay: AnyView?
    /// The id `DetailView` animates from the grid card, applied to the first
    /// page only: that's the photo the card was showing.
    let matchedID: String
    let namespace: Namespace.ID

    static let height: CGFloat = 360

    @State private var index = 0
    @State private var fullScreenIndex: Index?

    var body: some View {
        Color(.tertiarySystemFill)
            .frame(maxWidth: .infinity)
            .frame(height: Self.height)
            .overlay {
                if photos.isEmpty {
                    // Nothing to page through yet. Keeping the empty box rather
                    // than an empty `TabView` avoids a dot appearing for a page
                    // that holds no photo.
                    EmptyView()
                } else {
                    deck
                }
            }
            .overlay { overlay }
            .clipShape(RoundedRectangle(cornerRadius: 16))
            .matchedGeometryEffect(id: matchedID, in: namespace)
            .overlay(alignment: .bottom) {
                if photos.count > 1 { pageDots.padding(.bottom, 12) }
            }
            .fullScreenCover(item: $fullScreenIndex) { start in
                PhotoViewer(photos: photos, index: start.value)
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(photos.count > 1
                ? "Photo \(index + 1) of \(photos.count). Double tap to view full screen."
                : "Listing photo. Double tap to view full screen.")
    }

    private var deck: some View {
        TabView(selection: $index) {
            ForEach(Array(photos.enumerated()), id: \.offset) { offset, url in
                // Each page is its own fixed box, filled and cropped, matching
                // `ListingCard` so the transition animates fill to fill.
                Color.clear
                    .overlay {
                        AsyncImage(url: url) { phase in
                            if let image = phase.image {
                                image.resizable().scaledToFill()
                            }
                        }
                    }
                    .clipped()
                    .contentShape(Rectangle())
                    .onTapGesture { fullScreenIndex = Index(offset) }
                    .tag(offset)
            }
        }
        // The built-in dots sit inside the page area and can't be styled, and
        // they render against the photo with no scrim. `pageDots` below draws
        // them over the clipped deck instead.
        .tabViewStyle(.page(indexDisplayMode: .never))
    }

    private var pageDots: some View {
        HStack(spacing: 6) {
            ForEach(photos.indices, id: \.self) { page in
                Circle()
                    .fill(.white.opacity(page == index ? 0.95 : 0.45))
                    .frame(width: 6, height: 6)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(Capsule().fill(.black.opacity(0.3)))
        .animation(.easeOut(duration: 0.15), value: index)
        .allowsHitTesting(false)
    }
}

/// `fullScreenCover(item:)` needs an `Identifiable`, and a bare `Int` isn't one
/// — nor should page 0 be indistinguishable from "not presented", which is what
/// a boolean plus a separate index would risk.
private struct Index: Identifiable, Equatable {
    let value: Int
    var id: Int { value }
    init(_ value: Int) { self.value = value }
}

/// Full-screen, black, one photo per page — opened by tapping the deck and
/// starting on whichever photo was tapped.
///
/// Photos here are *fitted*, not filled: cropping is right for a fixed slot in
/// a scrolling page, and wrong for the screen someone opened specifically to
/// see the whole photo.
///
/// A drag up or down dismisses, which is how every photo viewer on the phone
/// behaves and is far easier to hit than the close button in the corner.
private struct PhotoViewer: View {
    let photos: [URL]
    @State var index: Int
    @Environment(\.dismiss) private var dismiss

    /// How far the photo has been dragged, and whether this drag counts as a
    /// dismissal at all — a drag that starts out horizontal belongs to the
    /// `TabView` paging underneath, so it's ignored for the rest of its life.
    @State private var drag: CGSize = .zero
    @State private var dragIsVertical: Bool?
    /// Set by the page on screen. While zoomed, a drag pans the photo, so the
    /// dismiss gesture stands down rather than fighting it.
    @State private var isZoomed = false

    /// Past this much vertical travel the photo goes away on release; a flick
    /// gets there on velocity alone via the gesture's predicted end.
    private static let dismissDistance: CGFloat = 100

    var body: some View {
        ZStack {
            Color.black.opacity(backdropOpacity).ignoresSafeArea()

            TabView(selection: $index) {
                ForEach(Array(photos.enumerated()), id: \.offset) { offset, url in
                    ZoomablePhoto(url: url, isZoomed: binding(for: offset)).tag(offset)
                }
            }
            .tabViewStyle(.page(indexDisplayMode: .never))
            .onChange(of: index) { isZoomed = false }
            .offset(y: drag.height)
            .scaleEffect(photoScale)
            // Simultaneous, not exclusive: the `TabView` keeps its horizontal
            // paging, and the vertical check below decides which of the two a
            // given drag was meant for.
            .simultaneousGesture(dismissDrag)
        }
        .overlay(alignment: .top) { chrome.opacity(backdropOpacity) }
        .statusBarHidden()
    }

    private var dismissDrag: some Gesture {
        DragGesture(minimumDistance: 10)
            .onChanged { value in
                guard !isZoomed else { return }
                if dragIsVertical == nil {
                    dragIsVertical = abs(value.translation.height) > abs(value.translation.width)
                }
                guard dragIsVertical == true else { return }
                drag = value.translation
            }
            .onEnded { value in
                defer { dragIsVertical = nil }
                guard dragIsVertical == true else { return }
                if abs(value.predictedEndTranslation.height) > Self.dismissDistance {
                    dismiss()
                } else {
                    withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                        drag = .zero
                    }
                }
            }
    }

    /// The photo shrinks and the black recedes as it's pulled away, so the drag
    /// reads as "letting go of this" long before it crosses the threshold.
    private var dragProgress: CGFloat {
        min(abs(drag.height) / (Self.dismissDistance * 2), 1)
    }

    private var backdropOpacity: Double { 1 - Double(dragProgress) * 0.6 }

    private var photoScale: CGFloat { 1 - dragProgress * 0.15 }

    /// Only the page on screen reports its zoom; a neighbour left zoomed would
    /// otherwise keep the dismiss gesture switched off after paging away.
    private func binding(for offset: Int) -> Binding<Bool> {
        Binding(
            get: { offset == index && isZoomed },
            set: { if offset == index { isZoomed = $0 } }
        )
    }

    /// Close on the left, count in the middle — the same furniture Facebook's
    /// own viewer puts there, in the same places.
    private var chrome: some View {
        ZStack {
            if photos.count > 1 {
                Text("\(index + 1) of \(photos.count)")
                    .font(.body.weight(.semibold))
                    .foregroundStyle(.white)
            }
            HStack {
                Button { dismiss() } label: {
                    Image(systemName: "xmark")
                        .font(.title3.weight(.semibold))
                        .foregroundStyle(.white)
                        .padding(12)
                        .contentShape(Rectangle())
                }
                .accessibilityLabel("Close")
                Spacer()
            }
        }
        .padding(.horizontal, 8)
        .padding(.top, 4)
    }
}

/// Pinch to zoom, drag to pan while zoomed, double tap to toggle.
///
/// Panning is only enabled above 1× so a normal drag still reaches the
/// `TabView` underneath and swipes to the next photo — a pan gesture that's
/// always live would swallow every page swipe.
private struct ZoomablePhoto: View {
    let url: URL
    /// Reported upward so the viewer's swipe-to-dismiss can stand down while
    /// this photo is zoomed and a drag means "pan" instead.
    @Binding var isZoomed: Bool

    @State private var scale: CGFloat = 1
    @State private var committedScale: CGFloat = 1
    @State private var offset: CGSize = .zero
    @State private var committedOffset: CGSize = .zero

    private static let maxScale: CGFloat = 4

    var body: some View {
        AsyncImage(url: url) { phase in
            if let image = phase.image {
                image
                    .resizable()
                    .scaledToFit()
                    .scaleEffect(scale)
                    .offset(offset)
                    .gesture(magnification)
                    .gesture(scale > 1 ? pan : nil)
                    .onTapGesture(count: 2) { toggleZoom() }
            } else if phase.error != nil {
                Image(systemName: "photo")
                    .font(.largeTitle)
                    .foregroundStyle(.white.opacity(0.5))
            } else {
                ProgressView().tint(.white)
            }
        }
        .onChange(of: scale) { isZoomed = scale > 1 }
        // The binding reads false as soon as this page stops being the one on
        // screen, which is the cue to drop the zoom: paging back to a photo
        // shows it whole again, and no off-screen page is left claiming a zoom.
        .onChange(of: isZoomed) { if !isZoomed && scale > 1 { toggleZoom() } }
    }

    private var magnification: some Gesture {
        MagnifyGesture()
            .onChanged { value in
                scale = min(max(committedScale * value.magnification, 1), Self.maxScale)
            }
            .onEnded { _ in
                committedScale = scale
                if scale == 1 { resetPan() }
            }
    }

    private var pan: some Gesture {
        DragGesture()
            .onChanged { value in
                offset = CGSize(width: committedOffset.width + value.translation.width,
                                height: committedOffset.height + value.translation.height)
            }
            .onEnded { _ in committedOffset = offset }
    }

    private func toggleZoom() {
        withAnimation(.easeOut(duration: 0.2)) {
            if scale > 1 {
                scale = 1
                committedScale = 1
                resetPan()
            } else {
                scale = 2
                committedScale = 2
            }
        }
    }

    private func resetPan() {
        offset = .zero
        committedOffset = .zero
    }
}
