import AppKit
import WebKit
import AiBarCore

@MainActor
public final class WebSessionManager: NSObject {
    public static let shared = WebSessionManager()

    public static let safariUserAgent = WebCookieHTTPClient.safariUserAgent

    /// Minimum gap between `WKWebView` fallbacks for one provider after plain-HTTP failures.
    static let webViewFallbackCooldown: TimeInterval = 30 * 60
    /// A full page load every so often lets the site's own JavaScript rotate session cookies
    /// (e.g. Google `__Secure-*PSIDTS`) that plain HTTP requests never refresh.
    static let webViewMaintenanceInterval: TimeInterval = 12 * 60 * 60
    /// AI Studio billing changes slowly and still needs a full SPA load, so it is fetched at most hourly.
    static let aiStudioBillingInterval: TimeInterval = 60 * 60

    private var lastWebViewLoad: [ProviderID: Date] = [:]
    private var aiStudioCache: (fetchedAt: Date, data: Data?)?

    /// Script injected at document start on grok.com to passively capture signed WKE billing responses
    public static let grokInterceptorSource = """
    (() => {
      if (window.__aibarHooked) return;
      window.__aibarHooked = true;
      window.__aibarGrokCapture = window.__aibarGrokCapture || {};
      const origFetch = window.fetch;
      window.fetch = async function(...args) {
        const res = await origFetch.apply(this, args);
        try {
          const url = typeof args[0] === 'string' ? args[0] : (args[0]?.url || '');
          if (url.includes('GetGrokCreditsConfig') || url.includes('/v1/billing')) {
            const clone = res.clone();
            const buf = await clone.arrayBuffer();
            const bytes = new Uint8Array(buf);
            if (url.includes('/v1/billing')) {
              const txt = new TextDecoder().decode(bytes);
              window.__aibarGrokCapture.billingJSON = JSON.parse(txt);
            } else if (bytes.length > 0) {
              let bin = '';
              for (let i = 0; i < bytes.length; i++) bin += String.fromCharCode(bytes[i]);
              window.__aibarGrokCapture.grpcBase64 = btoa(bin);
            }
          }
        } catch (_) {}
        return res;
      };
    })();
    """

    public func makeWebViewConfiguration(for provider: ProviderID) -> WKWebViewConfiguration {
        let cfg = WKWebViewConfiguration()
        cfg.websiteDataStore = .default()
        cfg.preferences.javaScriptCanOpenWindowsAutomatically = true

        if provider == .grok {
            let script = WKUserScript(
                source: Self.grokInterceptorSource,
                injectionTime: .atDocumentStart,
                forMainFrameOnly: true
            )
            cfg.userContentController.addUserScript(script)
        }
        return cfg
    }

    /// Captures AI Studio `MakerSuiteService` billing RPC responses (XHR, JSPB) issued by the billing page.
    static let aiStudioInterceptorSource = """
    (() => {
      if (window.__aibarAISHooked) return;
      window.__aibarAISHooked = true;
      window.__aibarAIS = {};
      const wanted = ['ListBillingAccounts', 'BatchGetCredits'];
      const oo = XMLHttpRequest.prototype.open, os = XMLHttpRequest.prototype.send;
      XMLHttpRequest.prototype.open = function(m, u) { this.__aibarUrl = String(u || ''); return oo.apply(this, arguments); };
      XMLHttpRequest.prototype.send = function() {
        const key = wanted.find(k => this.__aibarUrl && this.__aibarUrl.includes('MakerSuiteService/' + k));
        if (key) {
          this.addEventListener('load', () => {
            try { window.__aibarAIS[key] = JSON.parse(this.responseText); } catch (_) {}
          });
        }
        return os.apply(this, arguments);
      };
    })();
    """

    static let aiStudioProbeSource = """
    const cap = window.__aibarAIS || {};
    const credEl = document.querySelector('ms-billing-credits');
    const eligibleText = credEl ? (credEl.innerText || '').trim() : null;
    let totalCostText = null;
    const txt = document.body ? (document.body.innerText || '') : '';
    const m = txt.match(/\\n\\s*Total cost\\s*\\n\\s*([^\\n]{1,32})/);
    if (m) totalCostText = m[1].trim();
    return JSON.stringify({
      signedOut: location.hostname.includes('accounts.google.com'),
      billingAccounts: cap.ListBillingAccounts || null,
      credits: cap.BatchGetCredits || null,
      eligibleText, totalCostText
    });
    """

    /// AI Studio billing, cached for `aiStudioBillingInterval` (including "no billing account" results).
    public func cachedAIStudioBilling() async -> Data? {
        if let cache = aiStudioCache, Date().timeIntervalSince(cache.fetchedAt) < Self.aiStudioBillingInterval {
            return cache.data
        }
        let data = await fetchAIStudioBilling()
        aiStudioCache = (Date(), data)
        return data
    }

    /// Best-effort Gemini API billing probe on `aistudio.google.com/billing` (same Google session cookies).
    /// Returns nil when the user has no AI Studio billing account or the page did not load in time.
    public func fetchAIStudioBilling(timeout: TimeInterval = 20) async -> Data? {
        let cfg = WKWebViewConfiguration()
        cfg.websiteDataStore = .default()
        cfg.userContentController.addUserScript(WKUserScript(
            source: Self.aiStudioInterceptorSource,
            injectionTime: .atDocumentStart,
            forMainFrameOnly: true
        ))
        let webView = WKWebView(frame: NSRect(x: 0, y: 0, width: 1280, height: 900), configuration: cfg)
        webView.customUserAgent = Self.safariUserAgent
        defer { webView.stopLoading() }

        let loader = PageLoadAwaiter()
        webView.navigationDelegate = loader
        guard let url = URL(string: "https://aistudio.google.com/billing") else { return nil }
        do {
            try await loader.load(url: url, in: webView, timeout: timeout)
        } catch {
            return nil
        }

        // The SPA issues billing RPCs and renders the cost chart after the initial load.
        let deadline = Date().addingTimeInterval(timeout)
        var last: [String: Any]?
        while Date() < deadline {
            try? await Task.sleep(nanoseconds: 700_000_000)
            guard let raw = try? await webView.callAsyncJavaScript(
                Self.aiStudioProbeSource, arguments: [:], in: nil, contentWorld: .page
            ) as? String,
                let obj = try? JSONSerialization.jsonObject(with: Data(raw.utf8)) as? [String: Any] else { continue }
            if (obj["signedOut"] as? Bool) == true { return nil }
            last = obj
            let hasAccounts = !(obj["billingAccounts"] is NSNull) && obj["billingAccounts"] != nil
            let hasCredits = !(obj["credits"] is NSNull) && obj["credits"] != nil
            let hasEligible = (obj["eligibleText"] as? String)?.isEmpty == false
            let hasCost = (obj["totalCostText"] as? String)?.isEmpty == false
            if hasAccounts && hasCredits && hasEligible && hasCost { break }
        }
        guard let last, last["billingAccounts"] as? [Any] != nil else { return nil }
        let data = try? JSONSerialization.data(withJSONObject: last)
        if let data, let dumpDir = ProcessInfo.processInfo.environment["AIBAR_DUMP_DIR"], !dumpDir.isEmpty {
            try? data.write(to: URL(fileURLWithPath: dumpDir).appendingPathComponent("google-aistudio-billing.json"))
        }
        return data
    }

    /// Refreshes quota for a web-signed-in provider.
    ///
    /// Normally this is plain HTTP with cookies exported from the persistent WebKit store (no WebContent
    /// process, no page JavaScript). A hidden `WKWebView` is used only when the HTTP path fails
    /// (Cloudflare challenge, expired cookies, endpoint change) at most once per
    /// `webViewFallbackCooldown`, and every `webViewMaintenanceInterval` so the site can rotate cookies.
    public func fetchWebQuota(for provider: ProviderID) async throws -> ProviderSnapshot {
        let now = Date()
        let lastLoad = lastWebViewLoad[provider]
        if let lastLoad, now.timeIntervalSince(lastLoad) >= Self.webViewMaintenanceInterval {
            return try await fetchWebQuotaUsingWebView(for: provider)
        }
        if lastLoad == nil {
            // Treat app launch as a fresh baseline so maintenance loads start 12h later.
            lastWebViewLoad[provider] = now.addingTimeInterval(-Self.webViewFallbackCooldown)
        }

        do {
            return try await fetchWebQuotaOverHTTP(for: provider)
        } catch let error as URLError {
            // Offline / DNS / timeout: a web view would fail the same way.
            throw ProviderFetchError.networkError(error.localizedDescription)
        } catch {
            if let last = lastWebViewLoad[provider], Date().timeIntervalSince(last) < Self.webViewFallbackCooldown {
                throw error
            }
            NSLog("aiBar: %@ HTTP refresh failed (%@); falling back to WKWebView", provider.rawValue, error.localizedDescription)
            return try await fetchWebQuotaUsingWebView(for: provider)
        }
    }

    /// Plain `URLSession` refresh using the WebKit session cookies; rotated cookies are written back.
    public func fetchWebQuotaOverHTTP(for provider: ProviderID) async throws -> ProviderSnapshot {
        let store = WKWebsiteDataStore.default().httpCookieStore
        let domains = WebSessionHTTPFetcher.cookieDomains(for: provider)
        let original = await store.allCookies().filter { WebCookieHTTPClient.cookie($0, matchesAnyOf: domains) }
        guard !original.isEmpty else {
            throw ProviderFetchError.unauthorized("Not signed in to \(provider.displayName)")
        }
        let client = WebCookieHTTPClient(cookies: original, userAgent: Self.safariUserAgent)
        defer {
            let updated = client.cookies
            Task { @MainActor in await Self.syncCookies(original: original, updated: updated, into: store) }
        }
        return try await WebSessionHTTPFetcher.fetch(provider, using: client)
    }

    /// Writes cookies added/changed by HTTP responses back to WebKit and drops ones the server expired.
    private static func syncCookies(original: [HTTPCookie], updated: [HTTPCookie], into store: WKHTTPCookieStore) async {
        func key(_ c: HTTPCookie) -> String { "\(c.name)|\(c.domain)|\(c.path)" }
        let before = Dictionary(original.map { (key($0), $0) }, uniquingKeysWith: { a, _ in a })
        let after = Dictionary(updated.map { (key($0), $0) }, uniquingKeysWith: { a, _ in a })
        for (k, cookie) in after where before[k]?.value != cookie.value || before[k]?.expiresDate != cookie.expiresDate {
            await store.setCookie(cookie)
        }
        for (k, cookie) in before where after[k] == nil {
            await store.deleteCookie(cookie)
        }
    }

    /// Runs an off-screen WKWebView refresh using the persistent WebsiteDataStore.
    public func fetchWebQuotaUsingWebView(for provider: ProviderID) async throws -> ProviderSnapshot {
        lastWebViewLoad[provider] = Date()
        let cfg = makeWebViewConfiguration(for: provider)
        let webView = WKWebView(frame: NSRect(x: 0, y: 0, width: 960, height: 700), configuration: cfg)
        webView.customUserAgent = Self.safariUserAgent

        defer {
            webView.stopLoading()
        }

        let loader = PageLoadAwaiter()
        webView.navigationDelegate = loader
        try await loader.load(url: provider.webOriginURL, in: webView, timeout: 18.0)

        // Small settle window for SPA bootstrap / WKE fetch
        if provider == .grok || provider == .google {
            try? await Task.sleep(nanoseconds: 1_800_000_000)
        } else {
            try? await Task.sleep(nanoseconds: 500_000_000)
        }

        let jsonString = try await runProviderScript(for: provider, in: webView)
        guard let data = jsonString.data(using: .utf8) else {
            throw ProviderFetchError.parseError("Empty response from \(provider.displayName) web session")
        }
        // Opt-in diagnostics: AIBAR_DUMP_DIR=/some/dir dumps raw web payloads (may contain account data).
        if let dumpDir = ProcessInfo.processInfo.environment["AIBAR_DUMP_DIR"], !dumpDir.isEmpty {
            let url = URL(fileURLWithPath: dumpDir).appendingPathComponent("\(provider.rawValue)-web.json")
            try? data.write(to: url)
        }

        switch provider {
        case .anthropic:
            return try AnthropicProvider.parseWebBundleJSON(data)
        case .openai:
            return try OpenAIProvider.parseWebBundleJSON(data)
        case .google:
            return try GoogleProvider.parseWebBundleJSON(data)
        case .grok:
            return try GrokProvider.parseWebBundleJSON(data)
        }
    }

    public func runProviderScript(for provider: ProviderID, in webView: WKWebView) async throws -> String {
        let script = jsProbeSource(for: provider)
        let raw = try await webView.callAsyncJavaScript(
            script,
            arguments: [:],
            in: nil,
            contentWorld: .page
        )
        guard let text = raw as? String else {
            throw ProviderFetchError.parseError("Unexpected response format from \(provider.displayName)")
        }
        return text
    }

    public func clearWebSession(for provider: ProviderID) async {
        lastWebViewLoad[provider] = nil
        if provider == .google { aiStudioCache = nil }
        let domainKeywords: [String]
        switch provider {
        case .google:
            domainKeywords = ["google.com", "gstatic.com", "googleapis.com"]
        case .anthropic:
            domainKeywords = ["claude.ai", "anthropic.com"]
        case .openai:
            domainKeywords = ["chatgpt.com", "openai.com", "oaistatic.com"]
        case .grok:
            domainKeywords = ["grok.com", "x.ai"]
        }

        let store = WKWebsiteDataStore.default()
        let types = WKWebsiteDataStore.allWebsiteDataTypes()
        let records = await store.dataRecords(ofTypes: types)
        let matching = records.filter { rec in
            let name = rec.displayName.lowercased()
            return domainKeywords.contains { name.contains($0) }
        }
        if !matching.isEmpty {
            await store.removeData(ofTypes: types, for: matching)
        }
    }

    // MARK: - Per-provider JavaScript probes executed inside same-origin WKWebView

    private func jsProbeSource(for provider: ProviderID) -> String {
        switch provider {
        case .anthropic:
            return """
            if (location.pathname.startsWith('/login')) {
              return JSON.stringify({ authError: 401 });
            }
            const orgsRes = await fetch('/api/organizations', { credentials: 'include' });
            if (!orgsRes.ok) {
              return JSON.stringify({ authError: orgsRes.status });
            }
            const orgs = await orgsRes.json();
            const list = Array.isArray(orgs) ? orgs : [];
            const org = list.find(o => Array.isArray(o.capabilities) && o.capabilities.some(c => c.includes('chat') || c.includes('claude_pro') || c.includes('claude_max')))
              || list[0];
            if (!org || !org.uuid) {
              return JSON.stringify({ authError: 401 });
            }
            const [usageRes, acctRes, primaryCreditsRes] = await Promise.all([
              fetch(`/api/organizations/${org.uuid}/usage`, { credentials: 'include' }),
              fetch('/api/account', { credentials: 'include' }).catch(() => null),
              fetch(`/api/organizations/${org.uuid}/prepaid/credits`, { credentials: 'include' }).catch(() => null)
            ]);
            if (!usageRes.ok) {
              return JSON.stringify({ authError: usageRes.status });
            }
            const usage = await usageRes.json();
            const account = (acctRes && acctRes.ok) ? await acctRes.json().catch(() => null) : null;
            let prepaidCredits = (primaryCreditsRes && primaryCreditsRes.ok) ? await primaryCreditsRes.json().catch(() => null) : null;
            if (!prepaidCredits) {
              const apiOrg = list.find(o => o.uuid && o.uuid !== org.uuid && Array.isArray(o.capabilities) && o.capabilities.includes('api'));
              if (apiOrg) {
                const apiCredRes = await fetch(`/api/organizations/${apiOrg.uuid}/prepaid/credits`, { credentials: 'include' }).catch(() => null);
                if (apiCredRes && apiCredRes.ok) {
                  prepaidCredits = await apiCredRes.json().catch(() => null);
                }
              }
            }
            return JSON.stringify({ org, usage, account, prepaidCredits });
            """

        case .openai:
            return """
            if (location.hostname.includes('auth.openai.com') || location.pathname.includes('/auth/login')) {
              return JSON.stringify({ authError: 401 });
            }
            const sessRes = await fetch('/api/auth/session', { credentials: 'include' });
            if (!sessRes.ok) {
              return JSON.stringify({ authError: sessRes.status });
            }
            const sess = await sessRes.json();
            if (!sess || !sess.accessToken) {
              return JSON.stringify({ authError: 401 });
            }
            const headers = {
              'Authorization': 'Bearer ' + sess.accessToken,
              'Accept': 'application/json'
            };
            if (sess.account && sess.account.id) {
              headers['ChatGPT-Account-Id'] = sess.account.id;
            }
            const usageRes = await fetch('/backend-api/wham/usage', { credentials: 'include', headers });
            if (!usageRes.ok) {
              return JSON.stringify({ authError: usageRes.status });
            }
            const usage = await usageRes.json();
            return JSON.stringify({
              session: { email: sess.user ? sess.user.email : null },
              usage
            });
            """

        case .google:
            return """
            if (location.hostname.includes('accounts.google.com')) {
              return JSON.stringify({ signedOut: true });
            }
            const signOutLink = document.querySelector('a[href*="SignOutOptions"]');
            const signInLink = document.querySelector('a[href*="ServiceLogin"]');
            if (!signOutLink && signInLink) {
              return JSON.stringify({ signedOut: true });
            }
            const aria = signOutLink ? (signOutLink.getAttribute('aria-label') || '') : '';
            const emailMatch = aria.match(/\\(([^)]+@[^)]+)\\)/);
            const email = emailMatch ? emailMatch[1].trim() : null;

            let pathPrefix = '';
            const uMatch = location.pathname.match(/^\\/u\\/(\\d+)/);
            if (uMatch) pathPrefix = '/u/' + uMatch[1];
            const res = await fetch((pathPrefix || '') + '/usage', { credentials: 'include' });
            if (!res.ok) {
              return JSON.stringify({ signedOut: res.status === 401 || res.status === 403, error: 'HTTP ' + res.status });
            }
            const html = await res.text();
            if (html.includes('accounts.google.com/ServiceLogin') && !html.includes('WIZ_global_data')) {
              return JSON.stringify({ signedOut: true });
            }
            // Fallback: rendered "N AI credits" text, only when the live page is the usage page
            // (other Gemini pages may contain arbitrary chat text mentioning credits).
            let scrapedCredits = null;
            if (/\\/usage\\/?$/.test(location.pathname) && document.body) {
              const bodyTxt = document.body.innerText || '';
              const credMatch = bodyTxt.match(/([0-9][0-9,]*)\\s+AI\\s+credits?/i)
                || bodyTxt.match(/([0-9][0-9,]*)\\s+credits?\\s+(?:left|remaining|available)/i);
              if (credMatch) {
                scrapedCredits = credMatch[1] + ' AI credits';
              }
            }
            let fullChunk = '';
            const scripts = html.matchAll(/<script(?:\\s+[^>]*)?>([\\s\\S]*?)<\\/script>/gi);
            for (const m of scripts) {
              const content = (m[1] || '').trim();
              if (!content.startsWith('{') || !content.includes('"chunk"')) continue;
              try {
                const parsed = JSON.parse(content);
                for (const ev of (parsed.events || [])) {
                  if (ev.kind === 'chunk') fullChunk += ev.chunk;
                }
              } catch (_) {}
            }
            if (fullChunk) {
              try {
                const arr = JSON.parse(fullChunk);
                const info = (Array.isArray(arr) ? arr : [])
                  .map(i => i && i.data && i.data.viewer && i.data.viewer.rpcs ? i.data.viewer.rpcs.getUsageInfo : null)
                  .find(Boolean);
                // Deferred chunks carry the AI credits balance card ("N AI credits") via getG1Interventions.
                const g1Interventions = (Array.isArray(arr) ? arr : [])
                  .filter(i => i && i.data && i.data.getG1Interventions);
                if (info) {
                  return JSON.stringify({ usageInfo: info, email, scrapedCredits, g1Interventions });
                }
                const isFree = (Array.isArray(arr) ? arr : []).some(i => i && i.data && i.data.viewer === null)
                  || html.includes('DATA_FETCHING_EXCEPTION')
                  || html.includes('gemini_out_of_quota_input_inline_upgrade_banner');
                if (isFree) {
                  return JSON.stringify({ usageInfo: { subscriptionTier: 'FREE', isFree: true, pools: [] }, email, scrapedCredits, g1Interventions });
                }
              } catch (_) {}
            }
            return JSON.stringify({ html, email, scrapedCredits });
            """

        case .grok:
            return """
            if (location.hostname.includes('accounts.x.ai') || location.pathname.includes('/sign-in')) {
              return JSON.stringify({ signedOut: true });
            }
            const cap = window.__aibarGrokCapture || {};
            if (cap.billingJSON) {
              return JSON.stringify({ billing: cap.billingJSON });
            }
            if (cap.grpcBase64) {
              return JSON.stringify({ grpcBase64: cap.grpcBase64 });
            }
            try {
              const grpcBody = new Uint8Array([0, 0, 0, 0, 2, 8, 0]);
              const res = await fetch('/grok_api_v2.GrokBuildBilling/GetGrokCreditsConfig', {
                method: 'POST',
                credentials: 'include',
                headers: {
                  'Content-Type': 'application/grpc-web+proto',
                  'X-Grpc-Web': '1'
                },
                body: grpcBody
              });
              if (res.status === 401 || res.status === 403) {
                return JSON.stringify({ signedOut: true });
              }
              if (res.ok) {
                const buf = new Uint8Array(await res.arrayBuffer());
                if (buf.length > 5) {
                  let bin = '';
                  for (let i = 0; i < buf.length; i++) bin += String.fromCharCode(buf[i]);
                  return JSON.stringify({ grpcBase64: btoa(bin) });
                }
              }
            } catch (_) {}
            const bodyText = document.body ? (document.body.innerText || '') : '';
            if (/sign\\s*in|log\\s*in/i.test(bodyText) && bodyText.length < 600) {
              return JSON.stringify({ signedOut: true });
            }
            const pctMatch = bodyText.match(/(\\d{1,3}(?:\\.\\d+)?)\\s*%\\s*(?:used|of\\s+credits)/i);
            if (pctMatch) {
              return JSON.stringify({ usedPercent: Number(pctMatch[1]) });
            }
            return JSON.stringify({ signedOut: false });
            """
        }
    }
}

@MainActor
private final class PageLoadAwaiter: NSObject, WKNavigationDelegate {
    private var continuation: CheckedContinuation<Void, Error>?
    private var timeoutTask: Task<Void, Never>?

    func load(url: URL, in webView: WKWebView, timeout: TimeInterval) async throws {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            self.continuation = cont
            webView.load(URLRequest(url: url))
            self.timeoutTask = Task { @MainActor [weak self] in
                try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                self?.finish(with: .success(()))
            }
        }
    }

    private func finish(with result: Result<Void, Error>) {
        guard let cont = continuation else { return }
        continuation = nil
        timeoutTask?.cancel()
        timeoutTask = nil
        cont.resume(with: result)
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        finish(with: .success(()))
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        let nsErr = error as NSError
        if nsErr.code == NSURLErrorCancelled { return }
        finish(with: .failure(error))
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        let nsErr = error as NSError
        if nsErr.code == NSURLErrorCancelled { return }
        finish(with: .failure(error))
    }
}
