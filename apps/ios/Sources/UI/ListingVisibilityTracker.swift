import SwiftUI

struct ListingVisibilityTracker: ViewModifier {
    let isEnabled: Bool
    let onVisible: () -> Void
    @State private var isInViewport = false

    func body(content: Content) -> some View {
        content
            .onGeometryChange(for: Bool.self) { proxy in
                guard let viewport = proxy.bounds(of: .scrollView(axis: .vertical)) else { return false }
                let bounds = CGRect(origin: .zero, size: proxy.size)
                let visible = bounds.intersection(viewport)
                return !visible.isNull && bounds.width > 0 && bounds.height > 0
                    && visible.width * visible.height >= bounds.width * bounds.height / 2
            } action: { isInViewport = $0 }
            // Both feeds stay mounted; geometry alone also sees the hidden feed.
            .onChange(of: isEnabled && isInViewport, initial: true) { _, isVisible in
                if isVisible { onVisible() }
            }
    }
}
