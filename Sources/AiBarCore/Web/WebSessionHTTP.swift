import Foundation

/// Plain `URLSession` client seeded with cookies exported from the app's persistent WebKit store.
///
/// Every refresh used to boot a hidden `WKWebView` (a WebContent process, the provider's whole SPA,
/// and its JavaScript) just to run a few same-origin `fetch()` calls. This client issues those calls
/// directly. `URLSession` and WebKit share CFNetwork, so with the same Safari User-Agent and the
/// browser's `cf_clearance` cookie, Cloudflare normally treats it as the same browser.
///
/// The session uses its own in-memory cookie storage: `Set-Cookie` responses (rotated session tokens)
/// are collected there and read back via `cookies`, so the caller can write them to WebKit.
public final class WebCookieHTTPClient: @unchecked Sendable {
    public static let safariUserAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.4 Safari/605.1.15"

    private let session: URLSession
    private let storage: HTTPCookieStorage?

    public init(cookies: [HTTPCookie], userAgent: String = WebCookieHTTPClient.safariUserAgent) {
        let cfg = URLSessionConfiguration.ephemeral
        cfg.httpCookieAcceptPolicy = .always
        cfg.httpShouldSetCookies = true
        cfg.timeoutIntervalForRequest = 15
        cfg.timeoutIntervalForResource = 30
        cfg.httpAdditionalHeaders = [
            "User-Agent": userAgent,
            "Accept-Language": Locale.preferredLanguages.first ?? "en-US",
        ]
        for cookie in cookies {
            cfg.httpCookieStorage?.setCookie(cookie)
        }
        self.storage = cfg.httpCookieStorage
        self.session = URLSession(configuration: cfg)
    }

    deinit {
        session.finishTasksAndInvalidate()
    }

    /// Current cookie jar contents, including any cookies set or rotated by responses.
    public var cookies: [HTTPCookie] {
        storage?.cookies ?? []
    }

    public func send(
        _ url: URL,
        method: String = "GET",
        accept: String = "application/json",
        headers: [String: String] = [:],
        body: Data? = nil,
        timeout: TimeInterval = 15
    ) async throws -> (Data, HTTPURLResponse) {
        var req = URLRequest(url: url)
        req.httpMethod = method
        req.timeoutInterval = timeout
        req.httpBody = body
        req.setValue(accept, forHTTPHeaderField: "Accept")
        for (k, v) in headers {
            req.setValue(v, forHTTPHeaderField: k)
        }
        let (data, resp) = try await session.data(for: req)
        guard let http = resp as? HTTPURLResponse else {
            throw ProviderFetchError.networkError("Invalid HTTP response from \(url.host ?? "server")")
        }
        if Self.isCloudflareChallenge(http, data: data) {
            throw ProviderFetchError.cloudflareChallenge
        }
        return (data, http)
    }

    /// Best-effort JSON GET: nil on any failure (used for optional enrichments).
    public func optionalJSON(_ url: URL, timeout: TimeInterval = 4) async -> Any? {
        guard let (data, http) = try? await send(url, timeout: timeout),
              (200...299).contains(http.statusCode) else { return nil }
        return try? JSONSerialization.jsonObject(with: data)
    }

    public static func isCloudflareChallenge(_ http: HTTPURLResponse, data: Data) -> Bool {
        if (http.value(forHTTPHeaderField: "cf-mitigated") ?? "").lowercased().contains("challenge") {
            return true
        }
        guard http.statusCode == 403 || http.statusCode == 503 || http.statusCode == 429 else { return false }
        guard let body = String(data: data.prefix(16_384), encoding: .utf8) else { return false }
        return body.contains("Just a moment") || body.contains("cf-chl") || body.contains("challenge-platform")
    }

    /// Whether a cookie belongs to one of the given registrable domains (e.g. `claude.ai`).
    public static func cookie(_ cookie: HTTPCookie, matchesAnyOf domains: [String]) -> Bool {
        let host = cookie.domain.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "."))
        return domains.contains { host == $0 || host.hasSuffix("." + $0) }
    }
}

/// Same-origin quota requests that previously ran as JavaScript probes inside a `WKWebView`,
/// now issued over plain HTTP. Responses are packed into the same "web bundle" JSON shapes and
/// handed to the existing `parseWebBundleJSON` / `parseUsageHTML` parsers.
public enum WebSessionHTTPFetcher {
    /// Cookie domains needed for each provider's web session.
    public static func cookieDomains(for provider: ProviderID) -> [String] {
        switch provider {
        case .anthropic: return ["claude.ai"]
        case .openai: return ["chatgpt.com", "openai.com"]
        case .google: return ["google.com"]
        case .grok: return ["grok.com", "x.ai"]
        }
    }

    public static func fetch(_ provider: ProviderID, using client: WebCookieHTTPClient) async throws -> ProviderSnapshot {
        switch provider {
        case .anthropic: return try await fetchAnthropic(client)
        case .openai: return try await fetchOpenAI(client)
        case .google: return try await fetchGoogle(client)
        case .grok: return try await fetchGrok(client)
        }
    }

    // MARK: - Anthropic (claude.ai)

    static func fetchAnthropic(_ client: WebCookieHTTPClient) async throws -> ProviderSnapshot {
        let base = "https://claude.ai"
        let (orgData, orgHTTP) = try await client.send(URL(string: "\(base)/api/organizations")!)
        if orgHTTP.statusCode == 401 || orgHTTP.statusCode == 403 {
            throw ProviderFetchError.unauthorized("Not signed in to Claude (HTTP \(orgHTTP.statusCode))")
        }
        guard (200...299).contains(orgHTTP.statusCode) else {
            throw ProviderFetchError.networkError("Claude HTTP \(orgHTTP.statusCode)")
        }
        let list = (try? JSONSerialization.jsonObject(with: orgData) as? [[String: Any]]) ?? []
        func capabilities(_ o: [String: Any]) -> [String] { (o["capabilities"] as? [String]) ?? [] }
        let chatOrg = list.first { o in
            capabilities(o).contains { $0.contains("chat") || $0.contains("claude_pro") || $0.contains("claude_max") }
        } ?? list.first
        guard let org = chatOrg, let orgUUID = org["uuid"] as? String, !orgUUID.isEmpty else {
            throw ProviderFetchError.unauthorized("Not signed in to Claude (no organization)")
        }

        async let usageReq = client.send(URL(string: "\(base)/api/organizations/\(orgUUID)/usage")!)
        async let account = client.optionalJSON(URL(string: "\(base)/api/account")!)
        async let primaryCredits = client.optionalJSON(URL(string: "\(base)/api/organizations/\(orgUUID)/prepaid/credits")!)

        let (usageData, usageHTTP) = try await usageReq
        if usageHTTP.statusCode == 401 || usageHTTP.statusCode == 403 {
            throw ProviderFetchError.unauthorized("Not signed in to Claude (HTTP \(usageHTTP.statusCode))")
        }
        guard (200...299).contains(usageHTTP.statusCode),
              let usage = try? JSONSerialization.jsonObject(with: usageData) else {
            throw ProviderFetchError.networkError("Failed to read Claude usage (HTTP \(usageHTTP.statusCode))")
        }

        var prepaid = await primaryCredits
        if prepaid == nil,
           let apiOrg = list.first(where: { o in
               (o["uuid"] as? String).map { $0 != orgUUID } == true && capabilities(o).contains("api")
           }),
           let apiUUID = apiOrg["uuid"] as? String {
            prepaid = await client.optionalJSON(URL(string: "\(base)/api/organizations/\(apiUUID)/prepaid/credits")!)
        }

        var bundle: [String: Any] = ["org": org, "usage": usage]
        if let acct = await account { bundle["account"] = acct }
        if let prepaid { bundle["prepaidCredits"] = prepaid }
        return try AnthropicProvider.parseWebBundleJSON(JSONSerialization.data(withJSONObject: bundle))
    }

    // MARK: - OpenAI (chatgpt.com)

    static func fetchOpenAI(_ client: WebCookieHTTPClient) async throws -> ProviderSnapshot {
        let base = "https://chatgpt.com"
        let (sessData, sessHTTP) = try await client.send(URL(string: "\(base)/api/auth/session")!)
        guard (200...299).contains(sessHTTP.statusCode) else {
            if sessHTTP.statusCode == 401 || sessHTTP.statusCode == 403 {
                throw ProviderFetchError.unauthorized("Not signed in to ChatGPT (HTTP \(sessHTTP.statusCode))")
            }
            throw ProviderFetchError.networkError("ChatGPT HTTP \(sessHTTP.statusCode)")
        }
        guard let sess = try? JSONSerialization.jsonObject(with: sessData) as? [String: Any],
              let accessToken = sess["accessToken"] as? String, !accessToken.isEmpty else {
            throw ProviderFetchError.unauthorized("Not signed in to ChatGPT")
        }

        var headers = [
            "Authorization": "Bearer \(accessToken)",
            "Origin": base,
            "Referer": base + "/",
        ]
        if let accountID = (sess["account"] as? [String: Any])?["id"] as? String, !accountID.isEmpty {
            headers["ChatGPT-Account-Id"] = accountID
        }
        let (usageData, usageHTTP) = try await client.send(URL(string: "\(base)/backend-api/wham/usage")!, headers: headers)
        if usageHTTP.statusCode == 401 || usageHTTP.statusCode == 403 {
            throw ProviderFetchError.unauthorized("Not signed in to ChatGPT (HTTP \(usageHTTP.statusCode))")
        }
        guard (200...299).contains(usageHTTP.statusCode),
              let usage = try? JSONSerialization.jsonObject(with: usageData) else {
            throw ProviderFetchError.networkError("Failed to read ChatGPT usage (HTTP \(usageHTTP.statusCode))")
        }
        let email = (sess["user"] as? [String: Any])?["email"] as? String
        var session: [String: Any] = [:]
        if let email { session["email"] = email }
        let bundle: [String: Any] = ["session": session, "usage": usage]
        return try OpenAIProvider.parseWebBundleJSON(JSONSerialization.data(withJSONObject: bundle))
    }

    // MARK: - Google (gemini.google.com)

    static func fetchGoogle(_ client: WebCookieHTTPClient) async throws -> ProviderSnapshot {
        let (data, http) = try await client.send(
            URL(string: "https://gemini.google.com/usage")!,
            accept: "text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8"
        )
        if let host = http.url?.host, host.contains("accounts.google.com") {
            throw ProviderFetchError.unauthorized("Not signed in to Google Gemini")
        }
        if http.statusCode == 401 || http.statusCode == 403 {
            throw ProviderFetchError.unauthorized("Not signed in to Google Gemini (HTTP \(http.statusCode))")
        }
        guard (200...299).contains(http.statusCode), let html = String(data: data, encoding: .utf8) else {
            throw ProviderFetchError.networkError("Google Gemini HTTP \(http.statusCode)")
        }
        return try GoogleProvider.parseUsageHTML(html, authSource: .webSession)
    }

    // MARK: - Grok (grok.com gRPC-Web)

    static func fetchGrok(_ client: WebCookieHTTPClient) async throws -> ProviderSnapshot {
        let (data, http) = try await client.send(
            URL(string: "https://grok.com/grok_api_v2.GrokBuildBilling/GetGrokCreditsConfig")!,
            method: "POST",
            accept: "application/grpc-web+proto",
            headers: [
                "Content-Type": "application/grpc-web+proto",
                "X-Grpc-Web": "1",
                "Origin": "https://grok.com",
                "Referer": "https://grok.com/",
            ],
            body: Data([0, 0, 0, 0, 2, 8, 0])
        )
        if http.statusCode == 401 || http.statusCode == 403 {
            throw ProviderFetchError.unauthorized("Not signed in to Grok (HTTP \(http.statusCode))")
        }
        guard (200...299).contains(http.statusCode), data.count > 5 else {
            throw ProviderFetchError.networkError("Grok billing HTTP \(http.statusCode)")
        }
        let bundle: [String: Any] = ["grpcBase64": data.base64EncodedString()]
        return try GrokProvider.parseWebBundleJSON(JSONSerialization.data(withJSONObject: bundle))
    }
}
