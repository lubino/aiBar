import Foundation

public struct OAuthCredential: Sendable, Codable {
    public var accessToken: String
    public var refreshToken: String?
    public var expiresAt: Date?
    public var accountID: String?
    public var email: String?
    public var planHint: String?
    public var sourceLabel: String

    public init(
        accessToken: String,
        refreshToken: String? = nil,
        expiresAt: Date? = nil,
        accountID: String? = nil,
        email: String? = nil,
        planHint: String? = nil,
        sourceLabel: String
    ) {
        self.accessToken = accessToken
        self.refreshToken = refreshToken
        self.expiresAt = expiresAt
        self.accountID = accountID
        self.email = email
        self.planHint = planHint
        self.sourceLabel = sourceLabel
    }

    public func isExpired(skewSeconds: TimeInterval = 60) -> Bool {
        guard let expiresAt else { return false }
        return expiresAt.timeIntervalSinceNow <= skewSeconds
    }
}

public enum LocalCredentialReader {
    private static var home: URL {
        FileManager.default.homeDirectoryForCurrentUser
    }

    // MARK: - Anthropic local OAuth (~/.claude/.credentials.json or ~/.local/share/opencode/auth.json)

    public static func readAnthropicOAuth() -> OAuthCredential? {
        // 1. Claude Code ~/.claude/.credentials.json
        let claudeCredURL = home.appendingPathComponent(".claude/.credentials.json")
        if let data = try? Data(contentsOf: claudeCredURL),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let oauth = json["claudeAiOauth"] as? [String: Any],
           let access = oauth["accessToken"] as? String, !access.isEmpty {
            let refresh = oauth["refreshToken"] as? String
            let expiresAt = parseEpochTimestamp(oauth["expiresAt"])
            let subType = oauth["subscriptionType"] as? String
            return OAuthCredential(
                accessToken: access,
                refreshToken: refresh,
                expiresAt: expiresAt,
                planHint: subType,
                sourceLabel: "Claude CLI"
            )
        }

        // 2. OpenCode ~/.local/share/opencode/auth.json
        if let openCode = readOpenCodeOAuth(providerKey: "anthropic") {
            return openCode
        }

        return nil
    }

    // MARK: - OpenAI local OAuth (~/.codex/auth.json or ~/.local/share/opencode/auth.json)

    public static func readOpenAIOAuth() -> OAuthCredential? {
        // 1. Codex CLI ~/.codex/auth.json (or $CODEX_HOME/auth.json)
        let codexHome: URL
        if let envHome = ProcessInfo.processInfo.environment["CODEX_HOME"], !envHome.isEmpty {
            codexHome = URL(fileURLWithPath: (envHome as NSString).expandingTildeInPath)
        } else {
            codexHome = home.appendingPathComponent(".codex")
        }
        let codexAuthURL = codexHome.appendingPathComponent("auth.json")
        if let data = try? Data(contentsOf: codexAuthURL),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            let tokens = (json["tokens"] as? [String: Any]) ?? json
            if let access = (tokens["access_token"] as? String) ?? (tokens["accessToken"] as? String),
               !access.isEmpty {
                let refresh = (tokens["refresh_token"] as? String) ?? (tokens["refreshToken"] as? String)
                let accountID = (tokens["account_id"] as? String) ?? extractJWTClaim(access, key: "account_id")
                let email = extractJWTEmail(from: (tokens["id_token"] as? String) ?? access)
                let expiresAt = extractJWTExpiry(from: access)
                return OAuthCredential(
                    accessToken: access,
                    refreshToken: refresh,
                    expiresAt: expiresAt,
                    accountID: accountID,
                    email: email,
                    sourceLabel: "Codex CLI"
                )
            }
        }

        // 2. OpenCode ~/.local/share/opencode/auth.json ("openai" or "codex")
        if let openCode = readOpenCodeOAuth(providerKey: "openai") ?? readOpenCodeOAuth(providerKey: "codex") {
            return openCode
        }

        return nil
    }

    // MARK: - Grok local OAuth (~/.grok/auth.json)

    public static func readGrokOAuth() -> OAuthCredential? {
        let grokHome: URL
        if let env = ProcessInfo.processInfo.environment["GROK_HOME"], !env.isEmpty {
            grokHome = URL(fileURLWithPath: (env as NSString).expandingTildeInPath)
        } else {
            grokHome = home.appendingPathComponent(".grok")
        }
        let authURL = grokHome.appendingPathComponent("auth.json")
        guard let data = try? Data(contentsOf: authURL),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }

        // Prefer SuperGrok scope keys ("https://auth.x.ai::...") then fallback to any entry with a "key" field
        let sortedKeys = root.keys.sorted { a, b in
            let aSuper = a.hasPrefix("https://auth.x.ai")
            let bSuper = b.hasPrefix("https://auth.x.ai")
            if aSuper != bSuper { return aSuper }
            return a < b
        }

        for scopeKey in sortedKeys {
            guard let entry = root[scopeKey] as? [String: Any],
                  let bearer = entry["key"] as? String,
                  !bearer.isEmpty else {
                continue
            }
            let refresh = entry["refresh_token"] as? String
            let email = entry["email"] as? String
            let teamID = entry["team_id"] as? String
            let expiresAt = parseFlexibleDate(entry["expires_at"])
            let authMode = entry["auth_mode"] as? String
            let planHint = scopeKey.hasPrefix("https://auth.x.ai") ? "SuperGrok" : authMode
            return OAuthCredential(
                accessToken: bearer,
                refreshToken: refresh,
                expiresAt: expiresAt,
                accountID: teamID,
                email: email,
                planHint: planHint,
                sourceLabel: "Grok CLI"
            )
        }
        return nil
    }

    public static func findGrokExecutable() -> String? {
        let candidates = [
            home.appendingPathComponent(".grok/bin/grok").path,
            home.appendingPathComponent(".local/bin/grok").path,
            "/opt/homebrew/bin/grok",
            "/usr/local/bin/grok"
        ]
        for path in candidates where FileManager.default.isExecutableFile(atPath: path) {
            return path
        }
        return nil
    }

    // MARK: - OpenCode helper

    private static func readOpenCodeOAuth(providerKey: String) -> OAuthCredential? {
        let xdgData = ProcessInfo.processInfo.environment["XDG_DATA_HOME"]
        let baseURL: URL
        if let xdgData, !xdgData.isEmpty {
            baseURL = URL(fileURLWithPath: (xdgData as NSString).expandingTildeInPath)
        } else {
            baseURL = home.appendingPathComponent(".local/share")
        }
        let authURL = baseURL.appendingPathComponent("opencode/auth.json")
        guard let data = try? Data(contentsOf: authURL),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let entry = json[providerKey] as? [String: Any] else {
            return nil
        }
        guard (entry["type"] as? String) == "oauth",
              let access = entry["access"] as? String,
              !access.isEmpty else {
            return nil
        }
        let refresh = entry["refresh"] as? String
        let expiresAt = parseEpochTimestamp(entry["expires"]) ?? extractJWTExpiry(from: access)
        let accountID = entry["accountId"] as? String
        let email = extractJWTEmail(from: access)
        return OAuthCredential(
            accessToken: access,
            refreshToken: refresh,
            expiresAt: expiresAt,
            accountID: accountID,
            email: email,
            sourceLabel: "OpenCode OAuth"
        )
    }

    // MARK: - Date & JWT helpers

    private static func parseEpochTimestamp(_ raw: Any?) -> Date? {
        let number: Double?
        if let d = raw as? Double {
            number = d
        } else if let i = raw as? Int {
            number = Double(i)
        } else if let i64 = raw as? Int64 {
            number = Double(i64)
        } else if let str = raw as? String, let d = Double(str) {
            number = d
        } else {
            number = nil
        }
        guard let val = number, val > 0 else { return nil }
        // Values > 10^11 are milliseconds
        let seconds = val > 100_000_000_000 ? (val / 1000.0) : val
        return Date(timeIntervalSince1970: seconds)
    }

    private static func parseFlexibleDate(_ raw: Any?) -> Date? {
        if let epoch = parseEpochTimestamp(raw) {
            return epoch
        }
        if let str = raw as? String {
            return ISO8601Parser.parse(str)
        }
        return nil
    }

    public static func decodeJWTPayload(_ jwt: String) -> [String: Any]? {
        let parts = jwt.split(separator: ".")
        guard parts.count >= 2 else { return nil }
        var base64 = String(parts[1])
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        let rem = base64.count % 4
        if rem > 0 {
            base64 += String(repeating: "=", count: 4 - rem)
        }
        guard let data = Data(base64Encoded: base64),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        return obj
    }

    private static func extractJWTExpiry(from jwt: String) -> Date? {
        guard let payload = decodeJWTPayload(jwt) else { return nil }
        return parseEpochTimestamp(payload["exp"])
    }

    private static func extractJWTEmail(from jwt: String) -> String? {
        guard let payload = decodeJWTPayload(jwt) else { return nil }
        if let email = payload["email"] as? String, !email.isEmpty {
            return email
        }
        if let profile = payload["https://api.openai.com/profile"] as? [String: Any],
           let email = profile["email"] as? String, !email.isEmpty {
            return email
        }
        return nil
    }

    private static func extractJWTClaim(_ jwt: String, key: String) -> String? {
        guard let payload = decodeJWTPayload(jwt) else { return nil }
        if let v = payload[key] as? String { return v }
        if let auth = payload["https://api.openai.com/auth"] as? [String: Any],
           let v = auth["chatgpt_account_id"] as? String {
            return v
        }
        return nil
    }
}

public enum ISO8601Parser {
    public static func parse(_ raw: String?) -> Date? {
        guard let raw = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else {
            return nil
        }
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = fractional.date(from: raw) {
            return d
        }
        let standard = ISO8601DateFormatter()
        standard.formatOptions = [.withInternetDateTime]
        if let d = standard.date(from: raw) {
            return d
        }
        if let seconds = Double(raw), seconds > 1_000_000_000 {
            let normalized = seconds > 100_000_000_000 ? seconds / 1000.0 : seconds
            return Date(timeIntervalSince1970: normalized)
        }
        return nil
    }
}
