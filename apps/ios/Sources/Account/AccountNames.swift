import Foundation

struct AccountNames: Codable, Equatable {
    let firstName: String?
    let lastName: String?
    let displayName: String?

    init(firstName: String? = nil, lastName: String? = nil, displayName: String? = nil) {
        func normalized(_ value: String?) -> String? {
            guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else { return nil }
            return value
        }
        self.firstName = normalized(firstName)
        self.lastName = normalized(lastName)
        self.displayName = normalized(displayName)
    }

    init(appleFullName: PersonNameComponents?) {
        self.init(
            firstName: appleFullName?.givenName,
            lastName: appleFullName?.familyName,
            displayName: appleFullName.map { PersonNameComponentsFormatter.localizedString(from: $0, style: .default) }
        )
    }
}

enum AppleSignInNames {
    private static func key(_ userID: String) -> String { "pending_apple_names." + userID }

    // Apple may return names only once. Keep them through failed API requests
    // and app restarts, scoped to the Apple user who supplied them.
    static func saveAndLoad(_ provided: AccountNames, userID: String) -> AccountNames {
        let cached = Keychain.get(key(userID)).flatMap { $0.data(using: .utf8) }
            .flatMap { try? JSONDecoder().decode(AccountNames.self, from: $0) }
        let names = AccountNames(
            firstName: provided.firstName ?? cached?.firstName,
            lastName: provided.lastName ?? cached?.lastName,
            displayName: provided.displayName ?? cached?.displayName
        )
        if names != AccountNames(), let data = try? JSONEncoder().encode(names),
           let encoded = String(data: data, encoding: .utf8) {
            Keychain.set(encoded, for: key(userID))
        }
        return names
    }

    static func clear(userID: String) { Keychain.delete(key(userID)) }
}
