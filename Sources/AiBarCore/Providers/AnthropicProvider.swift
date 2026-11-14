import Foundation

public enum ProviderFetchError: LocalizedError, Sendable {
    case unauthorized(String)
    case cloudflareChallenge
    case networkError(String)
    case parseError(String)

    public var errorDescription: String? {
        switch self {
        case .unauthorized(let msg): return msg
        case .cloudflareChallenge: return "Protected by Cloudflare — use Web Sign-In"
        case .networkError(let msg): return msg
        case .parseError(let msg): return msg
        }
    }
}

public enum AnthropicProvider {
    private static let safariUA = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.4 Safari/605.1.15"

    // MARK: - HTTP OAuth Fetch

    public static func fetchViaOAuth(
        token: String,
        source: AuthSourceKind = .localOAuth,
        fallbackPlan: String? = nil
    ) async throws -> ProviderSnapshot {
        var req = URLRequest(url: URL(string: "https://api.anthropic.com/api/oauth/usage")!)
        req.timeoutInterval = 15
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        req.setValue("claude-code/2.1.0", forHTTPHeaderField: "User-Agent")
        req.setValue("application/json", forHTTPHeaderField: "Accept")

        let (data, response) = try await URLSession.shared.data(for: req)
        guard let http = response as? HTTPURLResponse else {
            throw ProviderFetchError.networkError("Invalid HTTP response from Anthropic")
        }
        if http.statusCode == 401 || http.statusCode == 403 {
            throw ProviderFetchError.unauthorized("Anthropic OAuth session expired — please sign in again")
        }
        guard (200...299).contains(http.statusCode) else {
            throw ProviderFetchError.networkError("Anthropic HTTP \(http.statusCode)")
        }

        // Best-effort profile lookup with short timeout
        let profile = await fetchOAuthProfile(token: token)
        return try parseUsagePayload(
            usageData: data,
            profileData: profile,
            authSource: source,
            fallbackPlan: fallbackPlan
        )
    }

    private static func fetchOAuthProfile(token: String) async -> Data? {
        var req = URLRequest(url: URL(string: "https://api.anthropic.com/api/oauth/profile")!)
        req.timeoutInterval = 3.0
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        req.setValue("claude-code/2.1.0", forHTTPHeaderField: "User-Agent")
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        return try? await URLSession.shared.data(for: req).0
    }

    public static func fetchViaCookieHeader(cookieHeader: String) async throws -> ProviderSnapshot {
        let normalizedCookie = cookieHeader.contains("=") ? cookieHeader : "sessionKey=\(cookieHeader)"

        var orgReq = URLRequest(url: URL(string: "https://claude.ai/api/organizations")!)
        orgReq.timeoutInterval = 15
        orgReq.setValue(normalizedCookie, forHTTPHeaderField: "Cookie")
        orgReq.setValue(safariUA, forHTTPHeaderField: "User-Agent")
        orgReq.setValue("application/json", forHTTPHeaderField: "Accept")

        let (orgData, orgResp) = try await URLSession.shared.data(for: orgReq)
        guard let orgHTTP = orgResp as? HTTPURLResponse else {
            throw ProviderFetchError.networkError("Invalid response from claude.ai")
        }
        if orgHTTP.statusCode == 403,
           let body = String(data: orgData, encoding: .utf8),
           body.contains("Just a moment") || body.contains("cf-chl") {
            throw ProviderFetchError.cloudflareChallenge
        }
        if orgHTTP.statusCode == 401 || orgHTTP.statusCode == 403 {
            throw ProviderFetchError.unauthorized("Claude session cookie expired")
        }
        guard (200...299).contains(orgHTTP.statusCode),
              let orgs = try? JSONSerialization.jsonObject(with: orgData) as? [[String: Any]],
              let firstOrg = orgs.first,
              let orgUUID = firstOrg["uuid"] as? String else {
            throw ProviderFetchError.parseError("Could not read Claude organization")
        }

        var usageReq = URLRequest(url: URL(string: "https://claude.ai/api/organizations/\(orgUUID)/usage")!)
        usageReq.timeoutInterval = 15
        usageReq.setValue(normalizedCookie, forHTTPHeaderField: "Cookie")
        usageReq.setValue(safariUA, forHTTPHeaderField: "User-Agent")
        usageReq.setValue("application/json", forHTTPHeaderField: "Accept")

        let (usageData, usageResp) = try await URLSession.shared.data(for: usageReq)
        guard let usageHTTP = usageResp as? HTTPURLResponse, (200...299).contains(usageHTTP.statusCode) else {
            throw ProviderFetchError.networkError("Failed to read Claude usage")
        }

        let plan = inferWebOrgPlan(firstOrg)
        return try parseUsagePayload(
            usageData: usageData,
            profileData: nil,
            authSource: .manualToken,
            fallbackPlan: plan
        )
    }

    // MARK: - Parsing (OAuth & Web combined)

    public static func parseWebBundleJSON(_ jsonData: Data) throws -> ProviderSnapshot {
        guard let root = try JSONSerialization.jsonObject(with: jsonData) as? [String: Any] else {
            throw ProviderFetchError.parseError("Invalid Claude web bundle")
        }
        if let authErr = root["authError"] as? Int {
            throw ProviderFetchError.unauthorized("Not signed in to Claude (HTTP \(authErr))")
        }
        guard let usageObj = root["usage"] as? [String: Any] else {
            throw ProviderFetchError.parseError("Missing Claude usage object")
        }
        let usageData = try JSONSerialization.data(withJSONObject: usageObj)

        var email: String?
        if let account = root["account"] as? [String: Any] {
            email = (account["email_address"] as? String) ?? (account["email"] as? String)
        }
        var plan: String?
        if let org = root["org"] as? [String: Any] {
            plan = inferWebOrgPlan(org)
        }

        var snapshot = try parseUsagePayload(
            usageData: usageData,
            profileData: nil,
            authSource: .webSession,
            fallbackPlan: plan
        )
        if let email, !email.isEmpty {
            snapshot.accountEmail = email
        }
        return snapshot
    }

    public static func parseUsagePayload(
        usageData: Data,
        profileData: Data? = nil,
        authSource: AuthSourceKind,
        fallbackPlan: String? = nil
    ) throws -> ProviderSnapshot {
        guard let usage = try JSONSerialization.jsonObject(with: usageData) as? [String: Any] else {
            throw ProviderFetchError.parseError("Invalid Anthropic usage JSON")
        }

        var shortWindow: QuotaWindow?
        var longWindow: QuotaWindow?
        var extraWindows: [QuotaWindow] = []
        var details: [ExtraDetailItem] = []

        // 1. Legacy/standard top-level objects: five_hour, seven_day, seven_day_sonnet, seven_day_opus
        if let fiveHour = usage["five_hour"] as? [String: Any],
           let pct = numericDouble(fiveHour["utilization"]) {
            shortWindow = QuotaWindow(
                id: "claude-5h",
                title: "5-Hour Session",
                usedPercent: pct,
                resetsAt: ISO8601Parser.parse(fiveHour["resets_at"] as? String),
                windowSeconds: 5 * 3600
            )
        }

        let sevenDaySource = (usage["seven_day"] as? [String: Any]) ?? (usage["seven_day_oauth_apps"] as? [String: Any])
        if let sevenDay = sevenDaySource,
           let pct = numericDouble(sevenDay["utilization"]) {
            longWindow = QuotaWindow(
                id: "claude-7d",
                title: "7-Day Weekly",
                usedPercent: pct,
                resetsAt: ISO8601Parser.parse(sevenDay["resets_at"] as? String),
                windowSeconds: 7 * 86400
            )
        }

        if let sonnet = usage["seven_day_sonnet"] as? [String: Any],
           let pct = numericDouble(sonnet["utilization"]) {
            extraWindows.append(QuotaWindow(
                id: "claude-sonnet-7d",
                title: "Sonnet (7-Day)",
                usedPercent: pct,
                resetsAt: ISO8601Parser.parse(sonnet["resets_at"] as? String),
                windowSeconds: 7 * 86400
            ))
        }

        if let opus = usage["seven_day_opus"] as? [String: Any],
           let pct = numericDouble(opus["utilization"]) {
            extraWindows.append(QuotaWindow(
                id: "claude-opus-7d",
                title: "Opus (7-Day)",
                usedPercent: pct,
                resetsAt: ISO8601Parser.parse(opus["resets_at"] as? String),
                windowSeconds: 7 * 86400
            ))
        }

        // 2. Modern `limits[]` array fallback / model-scoped enrichment
        if let limits = usage["limits"] as? [[String: Any]] {
            for entry in limits {
                let kind = (entry["kind"] as? String) ?? ""
                let group = (entry["group"] as? String) ?? ""
                guard let pct = numericDouble(entry["percent"]) ?? numericDouble(entry["utilization"]) else {
                    continue
                }
                let reset = ISO8601Parser.parse(entry["resets_at"] as? String)
                if (kind == "session" || group == "session") && shortWindow == nil {
                    shortWindow = QuotaWindow(
                        id: "claude-5h",
                        title: "5-Hour Session",
                        usedPercent: pct,
                        resetsAt: reset,
                        windowSeconds: 5 * 3600
                    )
                } else if (kind == "weekly_all" || (group == "weekly" && entry["scope"] is NSNull)) && longWindow == nil {
                    longWindow = QuotaWindow(
                        id: "claude-7d",
                        title: "7-Day Weekly",
                        usedPercent: pct,
                        resetsAt: reset,
                        windowSeconds: 7 * 86400
                    )
                } else if kind == "weekly_scoped",
                          let scope = entry["scope"] as? [String: Any],
                          let modelName = (scope["model"] as? String) ?? (scope["title"] as? String),
                          !modelName.isEmpty,
                          modelName.lowercased() != "all models" {
                    let cleanId = "claude-scoped-\(modelName.lowercased())"
                    if !extraWindows.contains(where: { $0.id == cleanId || $0.title.lowercased().contains(modelName.lowercased()) }) {
                        extraWindows.append(QuotaWindow(
                            id: cleanId,
                            title: "\(modelName.capitalized) (7-Day)",
                            usedPercent: pct,
                            resetsAt: reset,
                            windowSeconds: 7 * 86400
                        ))
                    }
                }
            }
        }

        // 3. Extra usage / spend summary
        if let extra = usage["extra_usage"] as? [String: Any],
           (extra["is_enabled"] as? Bool) == true {
            let currency = (extra["currency"] as? String) ?? "USD"
            if let used = numericDouble(extra["used_credits"]) {
                if let limit = numericDouble(extra["monthly_limit"]), limit > 0 {
                    details.append(ExtraDetailItem(
                        id: "claude-extra",
                        label: "Extra Usage",
                        value: String(format: "%.2f / %.2f %@", used / 100.0, limit / 100.0, currency)
                    ))
                } else if used > 0 {
                    details.append(ExtraDetailItem(
                        id: "claude-extra",
                        label: "Extra Usage",
                        value: String(format: "%.2f %@", used / 100.0, currency)
                    ))
                }
            }
        }

        // 4. Profile email + plan
        var email: String?
        var planName: String? = fallbackPlan
        if let profileData,
           let prof = try? JSONSerialization.jsonObject(with: profileData) as? [String: Any] {
            if let acct = prof["account"] as? [String: Any] {
                email = acct["email"] as? String
                if planName == nil {
                    if (acct["has_claude_max"] as? Bool) == true { planName = "Max" }
                    else if (acct["has_claude_pro"] as? Bool) == true { planName = "Pro" }
                }
            }
            if let org = prof["organization"] as? [String: Any] {
                if let display = org["plan_display_name"] as? String, !display.isEmpty {
                    planName = display
                } else if let tier = org["rate_limit_tier"] as? String {
                    planName = formatTierLabel(tier) ?? planName
                }
            }
        }

        let state: ProviderStatusState
        if shortWindow == nil && longWindow == nil && extraWindows.isEmpty {
            state = .freeDynamic
            planName = planName ?? "Free"
        } else {
            state = .ready
        }

        return ProviderSnapshot(
            provider: .anthropic,
            state: state,
            authSource: authSource,
            accountEmail: email,
            planName: formatPlanLabel(planName),
            shortWindow: shortWindow,
            longWindow: longWindow,
            extraWindows: extraWindows,
            details: details,
            fetchedAt: Date()
        )
    }

    private static func inferWebOrgPlan(_ org: [String: Any]) -> String? {
        if let display = org["plan_display_name"] as? String, !display.isEmpty {
            return display
        }
        if let tier = org["rate_limit_tier"] as? String, let mapped = formatTierLabel(tier) {
            return mapped
        }
        if let caps = org["capabilities"] as? [String] {
            if caps.contains(where: { $0.contains("claude_max") }) { return "Max" }
            if caps.contains(where: { $0.contains("claude_pro") }) { return "Pro" }
        }
        return nil
    }

    private static func formatTierLabel(_ raw: String) -> String? {
        let lower = raw.lowercased()
        if lower.contains("max_20x") || lower.contains("ultra") { return "Ultra" }
        if lower.contains("max_5x") || lower.contains("max") { return "Max" }
        if lower.contains("pro") { return "Pro" }
        if lower.contains("team") { return "Team" }
        if lower.contains("enterprise") { return "Enterprise" }
        return nil
    }

    private static func formatPlanLabel(_ raw: String?) -> String? {
        guard let raw, !raw.isEmpty else { return nil }
        if let mapped = formatTierLabel(raw) { return mapped }
        return raw.prefix(1).uppercased() + raw.dropFirst()
    }

    private static func numericDouble(_ value: Any?) -> Double? {
        if value is Bool { return nil }
        if let d = value as? Double { return d }
        if let i = value as? Int { return Double(i) }
        if let n = value as? NSNumber { return n.doubleValue }
        return nil
    }
}
