import Foundation

public enum OpenAIProvider {
    private static let codexClientID = "app_EMoamEEZ73f0CkXaXp7hrann"

    // MARK: - OAuth Refresh & Fetch

    public static func refreshOAuthToken(_ refreshToken: String) async throws -> (accessToken: String, refreshToken: String?, expiresAt: Date?) {
        var req = URLRequest(url: URL(string: "https://auth.openai.com/oauth/token")!)
        req.httpMethod = "POST"
        req.timeoutInterval = 15
        req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")

        var comps = URLComponents()
        comps.queryItems = [
            URLQueryItem(name: "grant_type", value: "refresh_token"),
            URLQueryItem(name: "client_id", value: codexClientID),
            URLQueryItem(name: "refresh_token", value: refreshToken)
        ]
        req.httpBody = comps.percentEncodedQuery?.data(using: .utf8)

        let (data, resp) = try await URLSession.shared.data(for: req)
        guard let http = resp as? HTTPURLResponse, (200...299).contains(http.statusCode),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let access = json["access_token"] as? String, !access.isEmpty else {
            throw ProviderFetchError.unauthorized("OpenAI OAuth refresh failed — please sign in again")
        }
        let newRefresh = json["refresh_token"] as? String
        let expiresIn = (json["expires_in"] as? Double) ?? Double(json["expires_in"] as? Int ?? 3600)
        return (access, newRefresh, Date().addingTimeInterval(expiresIn))
    }

    public static func fetchViaOAuth(
        accessToken: String,
        accountID: String? = nil,
        fallbackEmail: String? = nil,
        source: AuthSourceKind = .localOAuth
    ) async throws -> ProviderSnapshot {
        var req = URLRequest(url: URL(string: "https://chatgpt.com/backend-api/wham/usage")!)
        req.timeoutInterval = 15
        req.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        if let accountID, !accountID.isEmpty {
            req.setValue(accountID, forHTTPHeaderField: "ChatGPT-Account-Id")
        }
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        req.setValue("https://chatgpt.com", forHTTPHeaderField: "Origin")
        req.setValue("https://chatgpt.com/", forHTTPHeaderField: "Referer")
        req.setValue("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7)", forHTTPHeaderField: "User-Agent")

        let (data, resp) = try await URLSession.shared.data(for: req)
        guard let http = resp as? HTTPURLResponse else {
            throw ProviderFetchError.networkError("Invalid HTTP response from OpenAI")
        }
        if http.statusCode == 403,
           let body = String(data: data, encoding: .utf8),
           body.contains("Just a moment") || body.contains("cf-chl") {
            throw ProviderFetchError.cloudflareChallenge
        }
        if http.statusCode == 401 || http.statusCode == 403 {
            throw ProviderFetchError.unauthorized("OpenAI token expired or unauthorized")
        }
        guard (200...299).contains(http.statusCode) else {
            throw ProviderFetchError.networkError("OpenAI HTTP \(http.statusCode)")
        }

        return try parseWhamUsage(
            data: data,
            authSource: source,
            fallbackEmail: fallbackEmail
        )
    }

    // MARK: - Parsing

    public static func parseWebBundleJSON(_ jsonData: Data) throws -> ProviderSnapshot {
        guard let root = try JSONSerialization.jsonObject(with: jsonData) as? [String: Any] else {
            throw ProviderFetchError.parseError("Invalid OpenAI web bundle")
        }
        if let authErr = root["authError"] as? Int {
            throw ProviderFetchError.unauthorized("Not signed in to ChatGPT (HTTP \(authErr))")
        }
        guard let usageObj = root["usage"] as? [String: Any] else {
            throw ProviderFetchError.parseError("Missing OpenAI usage payload")
        }
        let usageData = try JSONSerialization.data(withJSONObject: usageObj)
        let email = (root["session"] as? [String: Any])?["email"] as? String
        return try parseWhamUsage(
            data: usageData,
            authSource: .webSession,
            fallbackEmail: email
        )
    }

    public static func parseWhamUsage(
        data: Data,
        authSource: AuthSourceKind,
        fallbackEmail: String? = nil
    ) throws -> ProviderSnapshot {
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ProviderFetchError.parseError("Invalid OpenAI usage JSON")
        }

        let email = (json["email"] as? String) ?? fallbackEmail
        let rawPlan = (json["plan_type"] as? String) ?? ((json["usage"] as? [String: Any])?["plan_type"] as? String)
        let planName = formatPlanType(rawPlan)

        let rateLimit = (json["rate_limit"] as? [String: Any])
            ?? ((json["usage"] as? [String: Any])?["rate_limit"] as? [String: Any])

        var shortWindow: QuotaWindow?
        var longWindow: QuotaWindow?
        var extraWindows: [QuotaWindow] = []
        var details: [ExtraDetailItem] = []

        func classifyAndInsert(_ winObj: [String: Any]?, fallbackIsPrimary: Bool) {
            guard let win = parseWindow(winObj, idPrefix: "openai", defaultTitle: fallbackIsPrimary ? "5-Hour Limit" : "7-Day Weekly") else {
                return
            }
            if let secs = win.windowSeconds {
                if secs <= 21_600 {
                    var updated = win
                    updated.id = "openai-5h"
                    updated.title = "5-Hour Window"
                    shortWindow = updated
                } else {
                    var updated = win
                    updated.id = "openai-long"
                    updated.title = secs >= 2_000_000 ? "30-Day Window" : "7-Day Weekly"
                    if longWindow == nil {
                        longWindow = updated
                    } else {
                        extraWindows.append(updated)
                    }
                }
            } else if fallbackIsPrimary && shortWindow == nil {
                shortWindow = win
            } else if longWindow == nil {
                longWindow = win
            } else {
                extraWindows.append(win)
            }
        }

        if let rateLimit {
            classifyAndInsert(rateLimit["primary_window"] as? [String: Any], fallbackIsPrimary: true)
            classifyAndInsert(rateLimit["secondary_window"] as? [String: Any], fallbackIsPrimary: false)
        }

        if let additional = json["additional_rate_limits"] as? [[String: Any]] {
            for item in additional {
                let baseId = (item["id"] as? String) ?? "extra"
                let baseTitle = (item["title"] as? String) ?? "Model Limit"
                if let p = parseWindow(item["primary_window"] as? [String: Any], idPrefix: baseId, defaultTitle: baseTitle) {
                    extraWindows.append(p)
                }
                if let s = parseWindow(item["secondary_window"] as? [String: Any], idPrefix: "\(baseId)-weekly", defaultTitle: "\(baseTitle) Weekly") {
                    extraWindows.append(s)
                }
            }
        }

        var availableCredit: String?
        if let credits = json["credits"] as? [String: Any] {
            if (credits["unlimited"] as? Bool) == true {
                availableCredit = "Unlimited"
            } else if let bal = credits["balance"] as? String {
                let trimmed = bal.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty {
                    if let numericVal = Double(trimmed) {
                        availableCredit = String(format: "$%.2f", numericVal)
                    } else {
                        availableCredit = trimmed
                    }
                }
            } else if let numBal = numericDouble(credits["balance"]) {
                availableCredit = String(format: "$%.2f", numBal)
            }
        }

        if let resets = json["rate_limit_reset_credits"] as? [String: Any],
           let count = resets["available_count"] as? Int, count > 0 {
            details.append(ExtraDetailItem(id: "openai-resets", label: "Reset Credits", value: "\(count) available"))
        }

        let state: ProviderStatusState = (shortWindow == nil && longWindow == nil && extraWindows.isEmpty)
            ? .freeDynamic
            : .ready

        return ProviderSnapshot(
            provider: .openai,
            state: state,
            authSource: authSource,
            accountEmail: email,
            planName: planName,
            shortWindow: shortWindow,
            longWindow: longWindow,
            extraWindows: extraWindows,
            availableCredit: availableCredit,
            details: details,
            fetchedAt: Date()
        )
    }

    private static func parseWindow(_ obj: [String: Any]?, idPrefix: String, defaultTitle: String) -> QuotaWindow? {
        guard let obj,
              let used = numericDouble(obj["used_percent"]) else {
            return nil
        }
        let windowSeconds = (obj["limit_window_seconds"] as? Int)
            ?? (numericDouble(obj["limit_window_seconds"]).map { Int($0) })

        var resetDate: Date?
        if let resetAt = numericDouble(obj["reset_at"]), resetAt > 1_000_000_000 {
            resetDate = Date(timeIntervalSince1970: resetAt)
        } else if let resetStr = obj["reset_at"] as? String {
            resetDate = ISO8601Parser.parse(resetStr)
        } else if let resetAfter = numericDouble(obj["reset_after_seconds"]), resetAfter > 0 {
            resetDate = Date().addingTimeInterval(resetAfter)
        }

        return QuotaWindow(
            id: idPrefix,
            title: defaultTitle,
            usedPercent: used,
            resetsAt: resetDate,
            windowSeconds: windowSeconds
        )
    }

    private static func formatPlanType(_ raw: String?) -> String? {
        guard let raw = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else {
            return nil
        }
        switch raw.lowercased() {
        case "plus": return "Plus"
        case "pro": return "Pro"
        case "team": return "Team"
        case "enterprise": return "Enterprise"
        case "free": return "Free"
        default: return raw.capitalized
        }
    }

    private static func numericDouble(_ value: Any?) -> Double? {
        if value is Bool { return nil }
        if let d = value as? Double { return d }
        if let i = value as? Int { return Double(i) }
        if let n = value as? NSNumber { return n.doubleValue }
        return nil
    }
}
