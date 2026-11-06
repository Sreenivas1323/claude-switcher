import Foundation

/// An account the switcher has captured. Metadata lives in Application Support;
/// the OAuth tokens live in the keychain under service "ClaudeSwitcher".
struct SavedAccount: Codable, Identifiable, Equatable {
    /// `accountUuid:organizationUuid`
    let id: String
    var email: String
    var displayName: String?
    var organizationName: String?
    var plan: String?
    var nickname: String?
    /// Claude Code's `oauthAccount` block, restored into ~/.claude.json on switch.
    var oauthAccount: Data
    var addedAt: Date

    var title: String { nickname?.isEmpty == false ? nickname! : email }
}

@MainActor
final class AccountStore {
    private static let keychainService = "ClaudeSwitcher"

    private let fileURL: URL = {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("ClaudeSwitcher", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("accounts.json")
    }()

    private(set) var accounts: [SavedAccount] = []

    init() {
        if let data = try? Data(contentsOf: fileURL),
           let decoded = try? JSONDecoder().decode([SavedAccount].self, from: data) {
            accounts = decoded
        }
    }

    func account(_ id: String) -> SavedAccount? { accounts.first { $0.id == id } }

    func upsert(_ account: SavedAccount) {
        if let i = accounts.firstIndex(where: { $0.id == account.id }) {
            accounts[i] = account
        } else {
            accounts.append(account)
        }
        save()
    }

    func remove(_ id: String) {
        accounts.removeAll { $0.id == id }
        Keychain.delete(service: Self.keychainService, account: id)
        save()
    }

    func credentials(for id: String) -> Credentials? {
        Keychain.read(service: Self.keychainService, account: id).map(Credentials.init(raw:))
    }

    func setCredentials(_ creds: Credentials, for id: String) throws {
        guard credentials(for: id) != creds else { return }
        try Keychain.write(service: Self.keychainService, account: id, value: creds.raw)
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(accounts) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }
}
