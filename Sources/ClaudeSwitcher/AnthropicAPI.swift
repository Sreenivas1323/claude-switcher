import Foundation

struct UsageWindow: Equatable {
    /// 0–100.
    let percent: Double
    let resetsAt: Date?
}

struct Usage: Equatable {
    let session: UsageWindow?      // rolling 5-hour window
    let weekly: UsageWindow?       // 7-day, all models
    let weeklyOpus: UsageWindow?
    let weeklySonnet: UsageWindow?
    let extraUsageEnabled: Bool
    let fetchedAt: Date

    /// The tightest limit right now; what decides whether this account can keep working.
    var worstPercent: Double {
        [session, weekly].compactMap { $0?.percent }.max() ?? 0
    }
}

struct Profile {
    let accountUuid: String
    let organizationUuid: String
    let email: String
    let displayName: String?
    let organizationName: String?
    let plan: String?

    var key: String { "\(accountUuid):\(organizationUuid)" }
}

enum APIError: LocalizedError {
    case http(Int, String)
    case badResponse
    case needsLogin

    var errorDescription: String? {
        switch self {
        case .http(429, _): return "Rate limited, will retry"
        case .http(let code, _): return "HTTP \(code)"
        case .badResponse: return "Unexpected response"
        case .needsLogin: return "Session expired: /login again with this account"
        }
    }
}

/// The same endpoints Claude Code's `/usage` and login flow use.
enum AnthropicAPI {
    private static let base = URL(string: "https://api.anthropic.com")!
    private static let tokenURL = URL(string: "https://platform.claude.com/v1/oauth/token")!
    private static let clientID = "9d1c250a-e61b-44d9-88ed-5944d1962f5e"

    private static let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 20
        return URLSession(configuration: config)
    }()

    static func usage(accessToken: String) async throws -> Usage {
        let json = try await get("/api/oauth/usage", token: accessToken)
        func window(_ key: String) -> UsageWindow? {
            guard let w = json[key] as? [String: Any], let pct = number(w["utilization"]) else { return nil }
            return UsageWindow(percent: pct, resetsAt: parseDate(w["resets_at"] as? String))
        }
        let extra = json["extra_usage"] as? [String: Any]
        return Usage(
            session: window("five_hour"),
            weekly: window("seven_day"),
            weeklyOpus: window("seven_day_opus"),
            weeklySonnet: window("seven_day_sonnet"),
            extraUsageEnabled: extra?["is_enabled"] as? Bool ?? false,
            fetchedAt: Date()
        )
    }

    static func profile(accessToken: String) async throws -> Profile {
        let json = try await get("/api/oauth/profile", token: accessToken)
        guard let account = json["account"] as? [String: Any],
              let uuid = account["uuid"] as? String,
              let email = account["email"] as? String
        else { throw APIError.badResponse }
        let org = json["organization"] as? [String: Any] ?? [:]
        let plan: String? =
            (account["has_claude_max"] as? Bool == true) ? "Max" :
            (account["has_claude_pro"] as? Bool == true) ? "Pro" : nil
        return Profile(
            accountUuid: uuid,
            organizationUuid: org["uuid"] as? String ?? "",
            email: email,
            displayName: account["display_name"] as? String,
            organizationName: org["name"] as? String,
            plan: plan
        )
    }

    /// Exchanges the refresh token for a new pair. Refresh tokens rotate, so the
    /// returned credentials must be saved; the old refresh token stops working.
    static func refresh(_ creds: Credentials) async throws -> Credentials {
        guard let refreshToken = creds.refreshToken else { throw APIError.needsLogin }
        var request = URLRequest(url: tokenURL)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        var body: [String: Any] = [
            "grant_type": "refresh_token",
            "refresh_token": refreshToken,
            "client_id": clientID,
        ]
        if !creds.scopes.isEmpty { body["scope"] = creds.scopes.joined(separator: " ") }
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, response) = try await session.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        if status == 400 || status == 401 { throw APIError.needsLogin }
        guard status == 200 else { throw APIError.http(status, String(decoding: data, as: UTF8.self)) }
        guard let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let access = json["access_token"] as? String
        else { throw APIError.badResponse }
        return creds.updated(
            accessToken: access,
            refreshToken: json["refresh_token"] as? String,
            expiresIn: number(json["expires_in"]) ?? 3600
        )
    }

    // MARK: helpers

    private static func get(_ path: String, token: String) async throws -> [String: Any] {
        var request = URLRequest(url: base.appendingPathComponent(path))
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        request.setValue("claude-switcher/1.0", forHTTPHeaderField: "User-Agent")
        let (data, response) = try await session.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        if status == 401 { throw APIError.needsLogin }
        guard status == 200 else { throw APIError.http(status, String(decoding: data, as: UTF8.self)) }
        guard let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            throw APIError.badResponse
        }
        return json
    }

    private static func number(_ any: Any?) -> Double? {
        (any as? NSNumber)?.doubleValue
    }

    private static let isoFractional: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
    private static let iso = ISO8601DateFormatter()

    private static func parseDate(_ s: String?) -> Date? {
        guard let s else { return nil }
        return isoFractional.date(from: s) ?? iso.date(from: s)
    }
}
