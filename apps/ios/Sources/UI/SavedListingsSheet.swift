import SwiftUI

/// A separate navigation stack keeps saved-item details inside the sheet and
/// leaves the underlying Discover or search scroll position untouched.
struct SavedListingsSheet: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var store: ListingStore
    @EnvironmentObject private var saved: SavedListings
    @State private var selected: Listing?
    @Namespace private var namespace

    let onOpen: (Listing, Int) -> Void

    var body: some View {
        let items = store.listings(for: saved.ids)

        NavigationStack {
            Group {
                if items.isEmpty {
                    ContentUnavailableView(
                        "No saved listings yet",
                        systemImage: "bookmark",
                        description: Text("Tap the bookmark on a listing to keep it here.")
                    )
                } else {
                    ScrollView {
                        ListingGrid(items: items, columns: 2, spacing: 12) { listing in
                            Button {
                                onOpen(listing, items.firstIndex { $0.id == listing.id } ?? 0)
                                selected = listing
                            } label: {
                                ListingCard(listing: listing, namespace: namespace)
                            }
                            .buttonStyle(.plain)
                        }
                        .padding(12)
                    }
                }
            }
            .navigationTitle("Saved")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .navigationDestination(item: $selected) { listing in
                DetailView(listing: listing, namespace: namespace)
            }
        }
        .presentationDetents([.large])
        .presentationDragIndicator(.visible)
    }
}
