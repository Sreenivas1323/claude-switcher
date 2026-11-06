import Foundation

/// One account's Claude login: `{"claudeAiOauth": {"accessToken", "refreshToken", "expiresAt", ...}}`.
/// Claude Code's keychain item holds more than this (e.g. `mcpOAuth` for MCP servers);
/// only the `claudeAiOauth` part is per-account.
struct Credentials: Equatable {
    let raw: String

    private var oauth: [String: Any] {
        guard let data = raw.data(using: .utf8),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let oauth = root["claudeAiOauth"] as? [String: Any]
        else { return [:] }
        return oauth
    }

    var accessToken: String? { oauth["accessToken"] as? String }
    var refreshToken: String? { oauth["refreshToken"] as? String }
    var subscriptionType: String? { oauth["subscriptionType"] as? String }
    var scopes: [String] { oauth["scopes"] as? [String] ?? [] }

    var expiresAt: Date? {
        guard let ms = oauth["expiresAt"] as? Double else { return nil }
        return Date(timeIntervalSince1970: ms / 1000)
    }

    /// True if the access token expires within `margin` seconds.
    func isExpiring(within margin: TimeInterval = 300) -> Bool {
        guard let expiresAt else { return true }
        return expiresAt.timeIntervalSinceNow < margin
    }

    var isValid: Bool { accessToken != nil && refreshToken != nil }

    /// Returns a copy with fresh tokens from a refresh response, keeping every other field.
    func updated(accessToken: String, refreshToken: String?, expiresIn: Double) -> Credentials {
        var o = oauth
        o["accessToken"] = accessToken
        if let refreshToken { o["refreshToken"] = refreshToken }
        o["expiresAt"] = Int((Date().timeIntervalSince1970 + expiresIn) * 1000)
        return Credentials(oauth: o)
    }

    init(raw: String) { self.raw = raw }

    init(oauth: [String: Any]) {
        let data = (try? JSONSerialization.data(withJSONObject: ["claudeAiOauth": oauth], options: .sortedKeys)) ?? Data()
        raw = String(decoding: data, as: UTF8.self)
    }

    var oauthObject: [String: Any] { oauth }
}

/// Reads and writes the state Claude Code uses to decide who is logged in:
/// the keychain credential item and the `oauthAccount` block in `~/.claude.json`.
enum ClaudeCode {
    static let keychainService = "Claude Code-credentials"
    static var keychainAccount: String { NSUserName() }

    static var configURL: URL {
        if let dir = ProcessInfo.processInfo.environment["CLAUDE_CONFIG_DIR"], !dir.isEmpty {
            return URL(fileURLWithPath: dir).appendingPathComponent(".claude.json")
        }
        return FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude.json")
    }

    // MARK: Credentials

    private static func liveBlob() -> [String: Any]? {
        guard let raw = Keychain.read(service: keychainService, account: keychainAccount),
              let root = (try? JSONSerialization.jsonObject(with: Data(raw.utf8))) as? [String: Any]
        else { return nil }
        return root
    }

    static func liveCredentials() -> Credentials? {
        guard let oauth = liveBlob()?["claudeAiOauth"] as? [String: Any] else { return nil }
        let creds = Credentials(oauth: oauth)
        return creds.isValid ? creds : nil
    }

    /// Swaps in this account's `claudeAiOauth`, keeping everything else in the item as is.
    static func setLiveCredentials(_ creds: Credentials) throws {
        var root = liveBlob() ?? [:]
        root["claudeAiOauth"] = creds.oauthObject
        let data = try JSONSerialization.data(withJSONObject: root)
        try Keychain.write(service: keychainService, account: keychainAccount,
                           value: String(decoding: data, as: UTF8.self))
    }

    // MARK: ~/.claude.json oauthAccount

    /// The `oauthAccount` object as JSON data, or nil when logged out.
    static func liveOAuthAccount() -> Data? {
        guard let root = readConfig(), let account = root["oauthAccount"] as? [String: Any] else { return nil }
        return try? JSONSerialization.data(withJSONObject: account)
    }

    /// Replaces only the `oauthAccount` key, leaving the rest of the file alone.
    static func setLiveOAuthAccount(_ data: Data) throws {
        guard var root = readConfig() else {
            throw NSError(domain: "ClaudeSwitcher", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "Could not read \(configURL.path)"])
        }
        root["oauthAccount"] = try JSONSerialization.jsonObject(with: data)
        let out = try JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .withoutEscapingSlashes])
        try out.write(to: configURL, options: .atomic)
    }

    private static func readConfig() -> [String: Any]? {
        guard let data = try? Data(contentsOf: configURL) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }
}

/// The handful of `oauthAccount` fields the UI cares about.
struct OAuthAccountInfo {
    let accountUuid: String
    let organizationUuid: String
    let email: String
    let displayName: String?
    let organizationName: String?

    /// Same login in two orgs (personal vs. team) counts as two accounts.
    var key: String { "\(accountUuid):\(organizationUuid)" }

    init?(data: Data) {
        guard let dict = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let accountUuid = dict["accountUuid"] as? String,
              let email = dict["emailAddress"] as? String
        else { return nil }
        self.accountUuid = accountUuid
        self.organizationUuid = dict["organizationUuid"] as? String ?? ""
        self.email = email
        self.displayName = dict["displayName"] as? String
        self.organizationName = dict["organizationName"] as? String
    }
}
