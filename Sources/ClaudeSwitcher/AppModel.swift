import AppKit
import Foundation
import ServiceManagement
import UserNotifications

@MainActor
final class AppModel: ObservableObject {
    @Published private(set) var accounts: [SavedAccount] = []
    @Published private(set) var activeID: String?
    @Published private(set) var usage: [String: Usage] = [:]
    @Published private(set) var errors: [String: String] = [:]
    /// Accounts whose saved login was rejected; they need a fresh `claude auth login`.
    @Published private(set) var needsLogin: Set<String> = []
    /// Account we opened a Terminal login for, until the new login shows up.
    @Published private(set) var awaitingLogin: String?
    @Published private(set) var switchingTo: String?
    @Published private(set) var isRefreshing = false
    @Published var banner: String?

    @Published var autoSwitch: Bool {
        didSet { UserDefaults.standard.set(autoSwitch, forKey: "autoSwitch") }
    }
    @Published var threshold: Double {
        didSet { UserDefaults.standard.set(threshold, forKey: "threshold") }
    }
    @Published var launchAtLogin: Bool = SMAppService.mainApp.status == .enabled {
        didSet { setLaunchAtLogin(launchAtLogin) }
    }

    private let store = AccountStore()
    /// accessToken -> account id, so the profile endpoint is only hit when the token changes.
    private var tokenOwner: [String: String] = [:]
    private var syncing = false
    private var lastAutoSwitch: Date?
    /// Minimum gap between automatic switches, so a burst of usage can't ping-pong accounts.
    static let autoSwitchCooldown: TimeInterval = 300
    private var timers: [Timer] = []

    static let syncInterval: TimeInterval = 10
    static let usageInterval: TimeInterval = 180

    /// Fake accounts for screenshots; never touches the keychain or ~/.claude.json.
    let isDemo: Bool

    init(demo: Bool = CommandLine.arguments.contains("--demo")) {
        let defaults = UserDefaults.standard
        isDemo = demo
        autoSwitch = defaults.object(forKey: "autoSwitch") as? Bool ?? false
        threshold = defaults.object(forKey: "threshold") as? Double ?? 90
        if demo {
            loadDemoData()
            return
        }
        accounts = store.accounts

        Task {
            await syncLive()
            await refreshUsage()
        }
        timers = [
            Timer.scheduledTimer(withTimeInterval: Self.syncInterval, repeats: true) { [weak self] _ in
                Task { @MainActor in await self?.syncLive() }
            },
            Timer.scheduledTimer(withTimeInterval: Self.usageInterval, repeats: true) { [weak self] _ in
                Task { @MainActor in await self?.refreshUsage() }
            },
        ]
        if Bundle.main.bundleIdentifier != nil {
            UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
        }
    }

    var activeAccount: SavedAccount? { accounts.first { $0.id == activeID } }

    /// Lowest-usage account other than the active one that still has headroom.
    var bestAlternative: SavedAccount? {
        accounts
            .filter { $0.id != activeID && errors[$0.id] == nil }
            .compactMap { acct in usage[acct.id].map { (acct, Self.effective($0)) } }
            .filter { $0.1 < threshold }
            .min { $0.1 < $1.1 }?.0
    }

    /// Usage with windows whose reset time has passed treated as 0%.
    static func effective(_ usage: Usage) -> Double {
        [usage.session, usage.weekly].compactMap { w -> Double? in
            guard let w else { return nil }
            if let reset = w.resetsAt, reset < Date() { return 0 }
            return w.percent
        }.max() ?? 0
    }

    // MARK: - Live sync

    /// Figures out who Claude Code is logged in as, captures new logins, and keeps
    /// the saved copy of the active account's tokens current (Claude Code refreshes them).
    func syncLive() async {
        guard !isDemo, !syncing, switchingTo == nil else { return }
        syncing = true
        defer { syncing = false }

        guard let live = ClaudeCode.liveCredentials(), let token = live.accessToken else {
            activeID = nil
            return
        }

        var id = tokenOwner[token]
        var profile: Profile?
        if id == nil {
            do {
                let p = try await AnthropicAPI.profile(accessToken: token)
                profile = p
                id = p.key
                tokenOwner[token] = p.key
            } catch {
                // Offline or expired token: only trust an exact token match with a saved
                // account. Guessing from ~/.claude.json could file one account's tokens
                // under another during a /login.
                id = store.accounts.first { acct in
                    guard let saved = store.credentials(for: acct.id) else { return false }
                    return saved.accessToken == token
                        || (saved.refreshToken != nil && saved.refreshToken == live.refreshToken)
                }?.id
                if let id { tokenOwner[token] = id }
            }
        }
        guard let id else { return }

        // Re-read in case Claude Code rotated the token while we were on the network.
        guard let current = ClaudeCode.liveCredentials(), current.accessToken == token else { return }

        let liveAccountData = ClaudeCode.liveOAuthAccount()
        let liveInfo = liveAccountData.flatMap(OAuthAccountInfo.init(data:))

        if var saved = store.account(id) {
            try? store.setCredentials(current, for: id)
            if let liveAccountData, liveInfo?.key == id {
                saved.oauthAccount = liveAccountData
            } else if liveInfo?.key != id {
                // Keychain says one account, ~/.claude.json another (a running session
                // wrote stale config). Put the matching account block back.
                try? ClaudeCode.setLiveOAuthAccount(saved.oauthAccount)
            }
            if let profile { apply(profile, to: &saved) }
            store.upsert(saved)
            if needsLogin.contains(id) || awaitingLogin == id {
                markLoggedIn(id)
                banner = "\(saved.title) is logged in again."
                Task { await refreshUsage(only: id) }
            }
        } else if let liveAccountData, let liveInfo, liveInfo.key == id {
            var account = SavedAccount(
                id: id,
                email: liveInfo.email,
                displayName: liveInfo.displayName,
                organizationName: liveInfo.organizationName,
                plan: current.subscriptionType.map { $0.capitalized },
                nickname: nil,
                oauthAccount: liveAccountData,
                addedAt: Date()
            )
            if let profile { apply(profile, to: &account) }
            do {
                try store.setCredentials(current, for: id)
                store.upsert(account)
                awaitingLogin = nil
                banner = "Added \(account.email)"
                Task { await refreshUsage(only: id) }
            } catch {
                banner = error.localizedDescription
            }
        } else {
            // New login whose ~/.claude.json block isn't written yet; next tick will catch it.
            return
        }

        if activeID != id {
            activeID = id
            errors[id] = nil
        }
        accounts = store.accounts
    }

    private func apply(_ profile: Profile, to account: inout SavedAccount) {
        account.email = profile.email
        account.displayName = profile.displayName ?? account.displayName
        account.organizationName = profile.organizationName ?? account.organizationName
        account.plan = profile.plan ?? account.plan
    }

    // MARK: - Usage

    func refreshUsage(only: String? = nil) async {
        guard !isDemo else { return }
        if only == nil {
            guard !isRefreshing else { return }
            isRefreshing = true
        }
        defer { if only == nil { isRefreshing = false } }

        for account in store.accounts where only == nil || account.id == only {
            do {
                let creds = try await freshCredentials(for: account.id)
                guard let token = creds.accessToken else { throw APIError.needsLogin }
                usage[account.id] = try await AnthropicAPI.usage(accessToken: token)
                markLoggedIn(account.id)
            } catch {
                record(error, for: account.id)
            }
        }
        if only == nil { await maybeAutoSwitch() }
    }

    /// Valid credentials for an account, refreshing (and persisting the rotated
    /// tokens) when needed. For the active account, refreshed tokens are written
    /// back to Claude Code's keychain item too, as any second Claude Code process would.
    private func freshCredentials(for id: String) async throws -> Credentials {
        let isActive = id == activeID
        guard let creds = isActive ? ClaudeCode.liveCredentials() : store.credentials(for: id) else {
            throw APIError.needsLogin
        }
        // Leave the active token to Claude Code unless it has actually expired.
        let needsRefresh = isActive ? creds.isExpiring(within: 0) : creds.isExpiring()
        guard needsRefresh else { return creds }

        let refreshed = try await AnthropicAPI.refresh(creds)
        try store.setCredentials(refreshed, for: id)
        if isActive {
            try ClaudeCode.setLiveCredentials(refreshed)
        }
        if let token = refreshed.accessToken { tokenOwner[token] = id }
        return refreshed
    }

    // MARK: - Switching

    func switchTo(_ id: String, reason: String? = nil) async {
        if isDemo { activeID = id; return }
        guard id != activeID, switchingTo == nil, let target = store.account(id) else { return }

        // Capture the outgoing account's newest tokens before overwriting them.
        await syncLive()
        switchingTo = id
        defer { switchingTo = nil }

        do {
            guard let stored = store.credentials(for: id) else { throw APIError.needsLogin }
            var creds = stored
            if creds.isExpiring() {
                creds = try await AnthropicAPI.refresh(creds)
                try store.setCredentials(creds, for: id)
            }
            try ClaudeCode.setLiveCredentials(creds)
            try ClaudeCode.setLiveOAuthAccount(target.oauthAccount)
            if let token = creds.accessToken { tokenOwner[token] = id }
            activeID = id
            markLoggedIn(id)
            banner = "Switched to \(target.title). New Claude Code sessions use it now."
            if let reason { notify(title: "Switched to \(target.title)", body: reason) }
            Task { await refreshUsage(only: id) }
        } catch {
            record(error, for: id)
            banner = "Couldn't switch: \(error.localizedDescription)"
        }
    }

    private func record(_ error: Error, for id: String) {
        errors[id] = error.localizedDescription
        if case APIError.needsLogin = error { needsLogin.insert(id) }
    }

    private func markLoggedIn(_ id: String) {
        errors[id] = nil
        needsLogin.remove(id)
        if awaitingLogin == id { awaitingLogin = nil }
    }

    private func maybeAutoSwitch() async {
        if let last = lastAutoSwitch, Date().timeIntervalSince(last) < Self.autoSwitchCooldown { return }
        guard autoSwitch, let activeID, let current = usage[activeID],
              Self.effective(current) >= threshold,
              let next = bestAlternative
        else { return }
        let pct = Int(Self.effective(current))
        lastAutoSwitch = Date()
        await switchTo(next.id, reason: "\(activeAccount?.title ?? "Previous account") hit \(pct)%.")
    }

    private func loadDemoData() {
        func account(_ id: String, _ email: String, _ nick: String?, _ plan: String) -> SavedAccount {
            SavedAccount(id: id, email: email, displayName: nil, organizationName: nil, plan: plan,
                         nickname: nick, oauthAccount: Data("{}".utf8), addedAt: Date())
        }
        func demoUsage(_ session: Double, _ sessionIn: Double, _ weekly: Double, _ weeklyIn: Double) -> Usage {
            Usage(session: UsageWindow(percent: session, resetsAt: Date().addingTimeInterval(sessionIn * 3600)),
                  weekly: UsageWindow(percent: weekly, resetsAt: Date().addingTimeInterval(weeklyIn * 86400)),
                  weeklyOpus: nil, weeklySonnet: nil, extraUsageEnabled: false, fetchedAt: Date())
        }
        accounts = [
            account("a", "ada@lovelace.dev", "Work", "Max"),
            account("b", "ada.personal@gmail.com", "Personal", "Max"),
            account("c", "ada@side-project.io", nil, "Pro"),
        ]
        usage = ["a": demoUsage(87, 1.6, 52, 3.2), "b": demoUsage(12, 3.9, 31, 5.5), "c": demoUsage(0, 5, 64, 1.4)]
        activeID = "a"
        if CommandLine.arguments.contains("--demo-expired") {
            errors["c"] = APIError.needsLogin.localizedDescription
            needsLogin = ["c"]
        }
    }

    // MARK: - Account management

    func rename(_ id: String, to nickname: String) {
        guard var account = store.account(id) else { return }
        account.nickname = nickname.trimmingCharacters(in: .whitespaces).isEmpty ? nil : nickname
        store.upsert(account)
        accounts = store.accounts
    }

    func remove(_ id: String) {
        guard id != activeID else { return }
        store.remove(id)
        usage[id] = nil
        markLoggedIn(id)
        accounts = store.accounts
    }

    /// Opens Terminal with `claude auth login`. The new account is picked up automatically
    /// once the login finishes; the current one is already saved.
    func addAccount() {
        openLogin(email: nil)
    }

    /// Opens Terminal with `claude auth login --email <account>` for an account whose saved
    /// login stopped working. Once it finishes, the fresh tokens are captured automatically.
    func relogin(_ id: String) {
        guard let account = accounts.first(where: { $0.id == id }) else { return }
        if isDemo { banner = "Demo: would run claude auth login --email \(account.email)"; return }
        if openLogin(email: account.email) {
            awaitingLogin = id
            banner = "Finish signing in as \(account.email) in Terminal. Claude Code will be on that account afterwards."
        }
    }

    @discardableResult
    private func openLogin(email: String?) -> Bool {
        var command = "\(shellQuote(Self.claudePath)) auth login"
        if let email { command += " --email \(shellQuote(email))" }
        let script = """
        tell application "Terminal"
            activate
            do script "\(appleScriptEscape(command))"
        end tell
        """
        var error: NSDictionary?
        NSAppleScript(source: script)?.executeAndReturnError(&error)
        if error != nil {
            banner = "Couldn't open Terminal. Run `\(command)` yourself."
            return false
        }
        return true
    }

    /// Terminal opens a login shell, which normally has `claude` on PATH, but GUI apps don't
    /// inherit it; prefer a known install location when there is one.
    static let claudePath: String = {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let candidates = ["\(home)/.local/bin/claude", "\(home)/.claude/local/claude",
                          "/opt/homebrew/bin/claude", "/usr/local/bin/claude"]
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0) } ?? "claude"
    }()

    private func shellQuote(_ s: String) -> String {
        "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    private func appleScriptEscape(_ s: String) -> String {
        s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
    }

    private func setLaunchAtLogin(_ enabled: Bool) {
        do {
            if enabled { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
        } catch {
            banner = "Launch at login: \(error.localizedDescription)"
        }
    }

    private func notify(title: String, body: String) {
        guard Bundle.main.bundleIdentifier != nil else { return }
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        UNUserNotificationCenter.current().add(
            UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        )
    }
}
