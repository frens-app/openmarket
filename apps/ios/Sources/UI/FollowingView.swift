import SwiftUI

struct FollowingView: View {
    @EnvironmentObject private var following: FollowedSellers
    @StateObject private var sellerAccess = SellerAccess()

    var body: some View {
        Group {
            if following.profiles.isEmpty {
                ContentUnavailableView("No followed sellers yet", systemImage: "person.badge.plus",
                    description: Text("Open a seller's profile and tap Follow to keep them here."))
            } else {
                List(following.profiles) { seller in
                    Button {
                        Task { await sellerAccess.open(seller) }
                    } label: {
                        HStack(spacing: 12) {
                            SellerAvatar(profile: seller)
                            VStack(alignment: .leading, spacing: 4) {
                                Text(seller.name).font(.headline)
                                if let joined = seller.joinedText {
                                    Text(joined).font(.caption).foregroundStyle(.secondary)
                                }
                            }
                        }
                        .padding(.vertical, 4)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .swipeActions {
                        Button("Unfollow", role: .destructive) { following.toggle(seller) }
                    }
                }
            }
        }
        .modifier(SellerNavigation(access: sellerAccess))
        .navigationTitle("Following")
        .navigationBarTitleDisplayMode(.inline)
    }
}

struct SellerAvatar: View {
    let name: String
    let photoURL: URL?
    var size: CGFloat = 48

    init(profile: SellerProfile) {
        name = profile.name
        photoURL = profile.photoURL
    }

    init(name: String, photoURL: URL?, size: CGFloat = 48) {
        self.name = name
        self.photoURL = photoURL
        self.size = size
    }

    var body: some View {
        RemoteImage(url: photoURL) { phase in
            if let image = phase.image {
                image.resizable().scaledToFill()
            } else {
                Color(.tertiarySystemFill).overlay {
                    Text(name.split(separator: " ").prefix(2).compactMap(\.first).map(String.init).joined())
                        .font(.system(size: size * 0.35, weight: .semibold))
                        .foregroundStyle(.secondary)
                }
            }
        }
            .frame(width: size, height: size)
            .clipShape(Circle())
            .accessibilityHidden(true)
    }
}
