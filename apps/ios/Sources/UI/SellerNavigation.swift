import SwiftUI

struct SellerNavigation: ViewModifier {
    @ObservedObject var access: SellerAccess
    @EnvironmentObject private var store: ListingStore

    func body(content: Content) -> some View {
        content
            .navigationDestination(item: $access.destination) { seller in
                SellerView(profile: seller)
            }
            .sheet(isPresented: $access.showSignIn, onDismiss: { access.cancelSignIn() }) {
                SignInView(surface: .listingDetail, onCancel: { access.cancelSignIn() }) {
                    Task {
                        if await access.finishSignIn() { store.setSession(.authed) }
                    }
                }
            }
    }
}
