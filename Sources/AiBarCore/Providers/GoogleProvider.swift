import Foundation

public enum GoogleProvider {
    private static let safariUA = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.4 Safari/605.1.15"

    // MARK: - Cookie Header Fetch

    public static func fetchViaCookieHeader(cookieHeader: String) async throws -> ProviderSnapshot {
        var req = URLRequest(url: URL(string: "https://gemini.google.com/usage")!)
        req.timeoutInterval = 15
        req.setValue(cookieHeader, forHTTPHeaderField: "Cookie")
        req.setValue(safariUA, forHTTPHeaderField: "User-Agent")
        req.setValue("text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8", forHTTPHeaderField: "Accept")

        let (data, resp) = try await URLSession.shared.data(for: req)
        guard let http = resp as? HTTPURLResponse else {
            throw ProviderFetchError.networkError("Invalid response from gemini.google.com")
        }
        if let finalHost = resp.url?.host, finalHost.contains("accounts.google.com") {
            throw ProviderFetchError.unauthorized("Google session cookie expired — please sign in again")
        }
        guard (200...299).contains(http.statusCode),
              let html = String(data: data, encoding: .utf8) else {
            throw ProviderFetchError.networkError("Google Gemini HTTP \(http.statusCode)")
        }

        return try parseUsageHTML(html, authSource: .manualToken)
    }

    // MARK: - Parsing SSR HTML or WebView JSON

    public static func parseWebBundleJSON(_ jsonData: Data) throws -> ProviderSnapshot {
        guard let root = try JSONSerialization.jsonObject(with: jsonData) as? [String: Any] else {
            throw ProviderFetchError.parseError("Invalid Gemini web bundle")
        }
        if (root["signedOut"] as? Bool) == true {
            throw ProviderFetchError.unauthorized("Not signed in to Google Gemini")
        }
        let email = root["email"] as? String
        if let info = root["usageInfo"] as? [String: Any] {
            return parseGetUsageInfoObject(info, email: email, authSource: .webSession)
        }
        if let html = root["html"] as? String {
            var snap = try parseUsageHTML(html, authSource: .webSession)
            if let email, !email.isEmpty {
                snap.accountEmail = email
            }
            return snap
        }
        if let err = root["error"] as? String {
            throw ProviderFetchError.parseError(err)
        }
        throw ProviderFetchError.parseError("Could not locate Gemini usage data")
    }

    public static func parseUsageHTML(_ html: String, authSource: AuthSourceKind) throws -> ProviderSnapshot {
        if html.contains("accounts.google.com/ServiceLogin") && !html.contains("getUsageInfo") && !html.contains("WIZ_global_data") {
            throw ProviderFetchError.unauthorized("Not signed in to Google Gemini")
        }

        let email = extractEmail(from: html)

        // Extract streamed JSON chunks embedded in <script> tags on gemini.google.com/usage
        let scriptPattern = #"<script(?:\s+[^>]*)?>([\s\S]*?)</script>"#
        var fullChunk = ""
        if let regex = try? NSRegularExpression(pattern: scriptPattern, options: [.caseInsensitive]) {
            let nsHTML = html as NSString
            let matches = regex.matches(in: html, range: NSRange(location: 0, length: nsHTML.length))
            for m in matches where m.numberOfRanges >= 2 {
                let content = nsHTML.substring(with: m.range(at: 1)).trimmingCharacters(in: .whitespacesAndNewlines)
                guard content.hasPrefix("{"), content.contains("\"chunk\"") else { continue }
                if let cData = content.data(using: .utf8),
                   let parsed = try? JSONSerialization.jsonObject(with: cData) as? [String: Any],
                   let events = parsed["events"] as? [[String: Any]] {
                    for ev in events where (ev["kind"] as? String) == "chunk" {
                        if let piece = ev["chunk"] as? String {
                            fullChunk += piece
                        }
                    }
                }
            }
        }

        if !fullChunk.isEmpty,
           let arrData = fullChunk.data(using: .utf8),
           let arr = try? JSONSerialization.jsonObject(with: arrData) as? [[String: Any]] {
            for item in arr {
                if let dataObj = item["data"] as? [String: Any],
                   let viewer = dataObj["viewer"] as? [String: Any],
                   let rpcs = viewer["rpcs"] as? [String: Any],
                   let info = rpcs["getUsageInfo"] as? [String: Any] {
                    return parseGetUsageInfoObject(info, email: email, authSource: authSource)
                }
            }

            let viewerNull = arr.contains { item in
                guard let dataObj = item["data"] as? [String: Any] else { return false }
                return dataObj["viewer"] is NSNull
            }
            if viewerNull || html.contains("gemini_out_of_quota_input_inline_upgrade_banner") || html.contains("DATA_FETCHING_EXCEPTION") {
                return ProviderSnapshot(
                    provider: .google,
                    state: .freeDynamic,
                    authSource: authSource,
                    accountEmail: email,
                    planName: "Free",
                    details: [
                        ExtraDetailItem(id: "gemini-free", label: "Quota Mode", value: "Dynamic capacity (Free plan)")
                    ],
                    fetchedAt: Date()
                )
            }
        }

        throw ProviderFetchError.parseError("Could not parse Gemini /usage response")
    }

    public static func parseGetUsageInfoObject(
        _ info: [String: Any],
        email: String?,
        authSource: AuthSourceKind
    ) -> ProviderSnapshot {
        let rawTier = (info["subscriptionTier"] as? String)?.uppercased() ?? "PRO"
        let isFree = (info["isFree"] as? Bool) == true || rawTier == "FREE"
        let planName: String
        if rawTier.contains("TIER2") || rawTier.contains("ULTRA") {
            planName = "AI Ultra"
        } else if rawTier.contains("TIER1") || rawTier.contains("PRO") {
            planName = "AI Pro"
        } else if isFree {
            planName = "Free"
        } else {
            planName = rawTier.capitalized
        }

        if isFree && ((info["pools"] as? [[String: Any]])?.isEmpty ?? true) {
            return ProviderSnapshot(
                provider: .google,
                state: .freeDynamic,
                authSource: authSource,
                accountEmail: email,
                planName: "Free",
                details: [
                    ExtraDetailItem(id: "gemini-free", label: "Quota Mode", value: "Dynamic capacity (Free plan)")
                ],
                fetchedAt: Date()
            )
        }

        var shortWindow: QuotaWindow?
        var longWindow: QuotaWindow?
        var details: [ExtraDetailItem] = []

        if let pools = info["pools"] as? [[String: Any]] {
            for pool in pools {
                let poolType = (pool["poolType"] as? String) ?? (pool["budgetPoolType"] as? String) ?? ""
                // `percentageUsed` is a 0.0...1.0 fraction on Gemini's GetUsageInfo schema
                let rawPct = numericDouble(pool["percentageUsed"]) ?? numericDouble(pool["pctUsed"])
                let usedPercent: Double? = rawPct.map { val in
                    // If server sends 0..1 fraction, scale by 100; if already > 1.0001 treat as percentage
                    val <= 1.0 ? (val * 100.0) : val
                }

                let gxu = pool["gxu"] as? [String: Any]
                let resetStr = (gxu?["windowRefreshesAt"] as? String)
                    ?? (pool["windowRefreshesAt"] as? String)
                let resetDate = ISO8601Parser.parse(resetStr)

                if poolType == "GXU_FIVE_HOURLY", let usedPercent {
                    shortWindow = QuotaWindow(
                        id: "gemini-5h",
                        title: "5-Hour Window",
                        usedPercent: usedPercent,
                        resetsAt: resetDate,
                        windowSeconds: 5 * 3600
                    )
                } else if poolType == "GXU_WEEKLY", let usedPercent {
                    longWindow = QuotaWindow(
                        id: "gemini-7d",
                        title: "7-Day Weekly",
                        usedPercent: usedPercent,
                        resetsAt: resetDate,
                        windowSeconds: 7 * 86400
                    )
                } else if poolType == "OVERAGE_CREDITS",
                          let overage = pool["overageCreditPool"] as? [String: Any],
                          let remaining = numericDouble(overage["creditsRemaining"]) {
                    details.append(ExtraDetailItem(
                        id: "gemini-overage",
                        label: "Overage AI Credits",
                        value: "\(Int(remaining))"
                    ))
                }
            }
        }

        let state: ProviderStatusState = (shortWindow == nil && longWindow == nil) ? .freeDynamic : .ready
        return ProviderSnapshot(
            provider: .google,
            state: state,
            authSource: authSource,
            accountEmail: email,
            planName: planName,
            shortWindow: shortWindow,
            longWindow: longWindow,
            details: details,
            fetchedAt: Date()
        )
    }

    private static func extractEmail(from html: String) -> String? {
        let pattern = #"([A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,})"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let ns = html as NSString
        let matches = regex.matches(in: html, range: NSRange(location: 0, length: min(ns.length, 250_000)))
        for m in matches {
            let candidate = ns.substring(with: m.range(at: 1))
            if !candidate.hasSuffix("@google.com") || candidate.contains("gmail.com") {
                if !candidate.contains("example.") && !candidate.contains("sentry") {
                    return candidate
                }
            }
        }
        return nil
    }

    private static func numericDouble(_ value: Any?) -> Double? {
        if value is Bool { return nil }
        if let d = value as? Double { return d }
        if let i = value as? Int { return Double(i) }
        if let n = value as? NSNumber { return n.doubleValue }
        return nil
    }
}
