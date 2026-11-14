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
        let scrapedCredits = root["scrapedCredits"] as? String
        if let info = root["usageInfo"] as? [String: Any] {
            var snap = parseGetUsageInfoObject(info, email: email, authSource: .webSession)
            if snap.availableCredit == nil, let items = root["g1Interventions"] as? [Any] {
                snap.availableCredit = extractAiCreditsBalance(fromChunkItems: items)
            }
            if snap.availableCredit == nil, let scrapedCredits, !scrapedCredits.isEmpty {
                snap.availableCredit = scrapedCredits
            }
            return snap
        }
        if let html = root["html"] as? String {
            var snap = try parseUsageHTML(html, authSource: .webSession)
            if let email, !email.isEmpty {
                snap.accountEmail = email
            }
            if snap.availableCredit == nil, let scrapedCredits, !scrapedCredits.isEmpty {
                snap.availableCredit = scrapedCredits
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
                    var snap = parseGetUsageInfoObject(info, email: email, authSource: authSource)
                    if snap.availableCredit == nil {
                        snap.availableCredit = extractAiCreditsBalance(fromChunkItems: arr)
                    }
                    return snap
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
        var availableCredit: String?
        let details: [ExtraDetailItem] = []

        if let topCredits = numericDouble(info["aiCreditsRemaining"]) ?? numericDouble(info["creditsRemaining"]) {
            availableCredit = formatCreditsCount(Int(topCredits))
        }

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
                } else if poolType == "OVERAGE_CREDITS" {
                    let overage = (pool["overageCreditPool"] as? [String: Any])
                        ?? (pool["overage_credit_pool"] as? [String: Any])
                    if let remaining = numericDouble(overage?["creditsRemaining"])
                        ?? numericDouble(overage?["credits_remaining"])
                        ?? numericDouble(pool["creditsRemaining"]) {
                        availableCredit = formatCreditsCount(Int(remaining))
                    }
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
            availableCredit: availableCredit,
            details: details,
            fetchedAt: Date()
        )
    }

    // MARK: - Gemini API billing (AI Studio)

    /// Merges Gemini API billing info captured from `aistudio.google.com/billing` into the Google snapshot.
    ///
    /// Expected bundle (built by the WebKit probe):
    /// - `billingAccounts`: raw `MakerSuiteService/ListBillingAccounts` JSPB response
    ///   (`[[[name, displayName, currency, ?, ?, [..], tierCapAmount, ...]]]`)
    /// - `credits`: raw `MakerSuiteService/BatchGetCredits` response
    ///   (`[[[title, account, original Money, [currency], remaining Money, id, [status], [start], [expire]]]]`,
    ///   Money = `[currency, "units", nanos]`)
    /// - `eligibleText`: page text such as "CZK 0 eligible GCP credits" (the amount AI Studio counts for the API)
    /// - `totalCostText`: this month's total cost as rendered on the page (e.g. "Kč 176.92")
    public static func applyAIStudioBilling(_ data: Data, to snapshot: inout ProviderSnapshot) {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
        var items: [ExtraDetailItem] = []

        var accountCurrency: String?
        var tierCap: Double?
        if let outer = root["billingAccounts"] as? [Any],
           let accounts = outer.first as? [Any],
           let account = accounts.first as? [Any] {
            if account.count > 2 { accountCurrency = account[2] as? String }
            if account.count > 6 { tierCap = numericDouble(account[6]) }
        }

        if let text = (root["eligibleText"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
           let eligible = parseEligibleCreditsText(text) {
            items.append(ExtraDetailItem(id: "gemini-api-credits", label: "API Credits (eligible)", value: eligible))
        }

        if let cost = (root["totalCostText"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
           !cost.isEmpty, cost.count <= 32 {
            items.append(ExtraDetailItem(id: "gemini-api-cost", label: "API Cost (This Month)", value: cost))
        }

        if let tierCap, let accountCurrency {
            items.append(ExtraDetailItem(id: "gemini-api-cap", label: "API Billing Tier Cap", value: formatMoney(tierCap, currency: accountCurrency)))
        }

        if let outer = root["credits"] as? [Any], let credits = outer.first as? [Any] {
            for (idx, raw) in credits.enumerated() {
                guard let credit = raw as? [Any], credit.count > 4,
                      let remaining = parseMoney(credit[4]), remaining.amount > 0 else { continue }
                let title = (credit[0] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? "GCP Credit"
                var value = formatMoney(remaining.amount, currency: remaining.currency)
                if credit.count > 8,
                   let expire = credit[8] as? [Any],
                   let secs = numericDouble(expire.first) {
                    let fmt = DateFormatter()
                    fmt.locale = Locale(identifier: "en_US_POSIX")
                    fmt.dateFormat = "d MMM yyyy"
                    value += " · until " + fmt.string(from: Date(timeIntervalSince1970: secs))
                }
                items.append(ExtraDetailItem(id: "gemini-gcp-credit-\(idx)", label: title, value: value))
            }
        }

        snapshot.details.removeAll { $0.id.hasPrefix("gemini-api-") || $0.id.hasPrefix("gemini-gcp-credit-") }
        snapshot.details.append(contentsOf: items)
    }

    /// "CZK 0 eligible GCP credits" -> "CZK 0"
    static func parseEligibleCreditsText(_ text: String) -> String? {
        let normalized = text.replacingOccurrences(of: "\u{00A0}", with: " ")
        guard let range = normalized.range(of: "eligible", options: .caseInsensitive) else { return nil }
        let amount = normalized[..<range.lowerBound].trimmingCharacters(in: .whitespaces)
        guard amount.contains(where: \.isNumber) else { return nil }
        return amount
    }

    private static func parseMoney(_ raw: Any?) -> (amount: Double, currency: String)? {
        guard let arr = raw as? [Any], arr.count >= 2, let currency = arr[0] as? String else { return nil }
        let units = numericDouble(arr[1]) ?? 0
        let nanos = arr.count > 2 ? (numericDouble(arr[2]) ?? 0) : 0
        return (units + nanos / 1_000_000_000, currency)
    }

    private static func formatMoney(_ amount: Double, currency: String) -> String {
        let fmt = NumberFormatter()
        fmt.numberStyle = .decimal
        fmt.locale = Locale(identifier: "en_US")
        fmt.minimumFractionDigits = 2
        fmt.maximumFractionDigits = 2
        let num = fmt.string(from: NSNumber(value: amount)) ?? String(format: "%.2f", amount)
        switch currency.uppercased() {
        case "USD": return "$" + num
        case "EUR": return "€" + num
        case "GBP": return "£" + num
        default: return "\(currency.uppercased()) \(num)"
        }
    }

    /// Reads the Google AI credits balance from the `/usage` page's deferred `getG1Interventions`
    /// chunks. The balance is not part of `getUsageInfo`; it is only rendered as the title of the
    /// `geminiUsageSettingsAiCreditsUpsellCard` intervention card (e.g. "0 AI credits", "+ Add").
    public static func extractAiCreditsBalance(fromChunkItems items: [Any]) -> String? {
        var found: String?
        func walk(_ node: Any) {
            guard found == nil else { return }
            if let dict = node as? [String: Any] {
                if let entries = dict["interventionEntries"] as? [[String: Any]] {
                    for entry in entries {
                        guard let ctx = entry["onrampContext"] as? [String: Any],
                              ctx["geminiUsageSettingsAiCreditsUpsellCard"] is [String: Any],
                              let intervention = entry["intervention"] as? [String: Any],
                              let card = intervention["interventionCard"] as? [String: Any],
                              let title = card["title"] as? [String: Any] else { continue }
                        let text = ((title["htmlText"] as? [String: Any])?["privateDoNotAccessOrElseSafeHtmlWrappedValue"] as? String)
                            ?? (title["markdownText"] as? String)
                        if let text, let parsed = parseAiCreditsTitle(text) {
                            found = parsed
                            return
                        }
                    }
                }
                for value in dict.values { walk(value) }
            } else if let arr = node as? [Any] {
                for value in arr { walk(value) }
            }
        }
        for item in items { walk(item) }
        return found
    }

    private static func parseAiCreditsTitle(_ text: String) -> String? {
        let pattern = #"([0-9][0-9.,\s\u00A0\u202F]*)\s*AI\s+credits?"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]),
              let m = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              let r = Range(m.range(at: 1), in: text) else { return nil }
        let digits = text[r].filter(\.isNumber)
        guard let count = Int(digits) else { return nil }
        return formatCreditsCount(count)
    }

    private static func formatCreditsCount(_ count: Int) -> String {
        let fmt = NumberFormatter()
        fmt.numberStyle = .decimal
        fmt.locale = Locale(identifier: "en_US")
        let num = fmt.string(from: NSNumber(value: count)) ?? "\(count)"
        return "\(num) AI credits"
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
        if let str = value as? String { return Double(str.trimmingCharacters(in: .whitespaces)) }
        return nil
    }
}
