import Foundation
import AiBarCore

private var passedCount = 0
private var failedCount = 0

@MainActor
private func check(_ condition: @autoclosure () -> Bool, _ message: String, file: String = #fileID, line: Int = #line) {
    if condition() {
        passedCount += 1
    } else {
        failedCount += 1
        fputs("FAIL [\(file):\(line)] \(message)\n", stderr)
    }
}

@MainActor
private func runAnthropicTests() throws {
    let usageJSON = """
    {
      "five_hour": {
        "utilization": 22.0,
        "resets_at": "2026-11-14T19:30:00.000000+00:00"
      },
      "seven_day": {
        "utilization": 36.4,
        "resets_at": "2026-11-19T12:00:00.000000+00:00"
      },
      "seven_day_sonnet": {
        "utilization": 10.0,
        "resets_at": "2026-11-19T12:00:00.000000+00:00"
      }
    }
    """.data(using: .utf8)!

    let profileJSON = """
    {
      "account": { "email": "user@example.com", "has_claude_max": true },
      "organization": { "plan_display_name": "Max" }
    }
    """.data(using: .utf8)!

    let creditsJSON = """
    {
      "amount": 5597,
      "currency": "EUR",
      "balance": { "money": { "amount_minor": 5597, "currency": "EUR", "exponent": 2 } }
    }
    """.data(using: .utf8)!

    let snap = try AnthropicProvider.parseUsagePayload(
        usageData: usageJSON,
        profileData: profileJSON,
        prepaidCreditsData: creditsJSON,
        authSource: .localOAuth
    )

    check(snap.state == .ready, "Anthropic state should be ready")
    check(snap.availableCredit == "€55.97", "Anthropic prepaid credit €55.97 parsed")
    check(snap.menubarNumbers(mode: .used).map(\.value) == [36], "Anthropic menubar shows weekly [36] only")
    check(snap.menubarNumbers(mode: .remaining).map(\.value) == [64], "Anthropic remaining menubar shows weekly [64] only")
    check(snap.allWindows.count == 3, "Detail popup still retains 5h, 7d, and Sonnet windows")

    let signedOut = ProviderSnapshot(provider: .anthropic, state: .signedOut)
    check(signedOut.menubarNumbers().isEmpty, "Signed-out provider produces empty menubar numbers (hidden)")
}

@MainActor
private func runOpenAITests() throws {
    let plusJSON = """
    {
      "email": "dev@openai.example",
      "plan_type": "plus",
      "rate_limit": {
        "allowed": true,
        "primary_window": {
          "used_percent": 15,
          "limit_window_seconds": 18000,
          "reset_at": 1794680000
        },
        "secondary_window": {
          "used_percent": 41,
          "limit_window_seconds": 604800,
          "reset_at": 1795100000
        }
      },
      "credits": { "has_credits": true, "balance": "4.2" }
    }
    """.data(using: .utf8)!

    let plusSnap = try OpenAIProvider.parseWhamUsage(data: plusJSON, authSource: .localOAuth)
    check(plusSnap.menubarNumbers(mode: .used).map(\.value) == [41], "OpenAI Plus menubar shows weekly [41] only")
    check(plusSnap.availableCredit == "$4.20", "OpenAI available credit $4.20 parsed")

    let teamJSON = """
    {
      "plan_type": "team",
      "rate_limit": {
        "primary_window": {
          "used_percent": 9,
          "limit_window_seconds": 604800,
          "reset_at": 1795100000
        },
        "secondary_window": null
      }
    }
    """.data(using: .utf8)!

    let teamSnap = try OpenAIProvider.parseWhamUsage(data: teamJSON, authSource: .webSession)
    check(teamSnap.menubarNumbers(mode: .used).map(\.value) == [9], "Single-window Team plan shows only [9] with zero dashes")
}

@MainActor
private func runGoogleTests() throws {
    let chunkPayload = #"[{"data":{"viewer":{"rpcs":{"getUsageInfo":{"subscriptionTier":"TIER1","pools":[{"poolType":"GXU_FIVE_HOURLY","percentageUsed":0.12,"gxu":{"windowRefreshesAt":"2026-11-14T21:00:00Z"}},{"poolType":"GXU_WEEKLY","percentageUsed":0.35,"gxu":{"windowRefreshesAt":"2026-11-20T00:00:00Z"}},{"poolType":"OVERAGE_CREDITS","overageCreditPool":{"creditsRemaining":1000}}]}}}},"errors":[]}]"#
    let escapedChunk = try String(
        data: JSONSerialization.data(withJSONObject: ["events": [["kind": "chunk", "chunk": chunkPayload]]]),
        encoding: .utf8
    )!
    let fakeHTML = """
    <html><body>
    <a href="https://accounts.google.com/SignOutOptions" aria-label="Google Account: Test (gemini.user@gmail.com)"></a>
    <script>\(escapedChunk)</script>
    </body></html>
    """

    let snap = try GoogleProvider.parseUsageHTML(fakeHTML, authSource: .webSession)
    check(snap.menubarNumbers(mode: .used).map(\.value) == [35], "Google menubar shows weekly [35] only, while popup retains 5h [12] and weekly [35]")
    check(snap.shortWindow?.usedPercentInt == 12 && snap.longWindow?.usedPercentInt == 35, "Google popup retains both 5h and weekly windows")
    check(snap.availableCredit == "1,000 AI credits", "Google overage AI credits parsed")

    let topLevelBundle = #"{"usageInfo":{"subscriptionTier":"TIER2","aiCreditsRemaining":25000,"pools":[{"poolType":"GXU_WEEKLY","percentageUsed":0.5,"gxu":{"windowRefreshesAt":"2026-11-20T00:00:00Z"}}]},"email":"a@b.c","scrapedCredits":"999 AI credits"}"#
    let topSnap = try GoogleProvider.parseWebBundleJSON(Data(topLevelBundle.utf8))
    check(topSnap.availableCredit == "25,000 AI credits", "Google top-level aiCreditsRemaining wins over scraped text")

    let scrapedBundle = #"{"usageInfo":{"subscriptionTier":"TIER1","pools":[{"poolType":"GXU_WEEKLY","percentageUsed":0.1,"gxu":{"windowRefreshesAt":"2026-11-20T00:00:00Z"}}]},"email":"a@b.c","scrapedCredits":"1,200 AI credits"}"#
    let scrapedSnap = try GoogleProvider.parseWebBundleJSON(Data(scrapedBundle.utf8))
    check(scrapedSnap.availableCredit == "1,200 AI credits", "Google falls back to scraped AI credits text")
}

@MainActor
private func runGrokTests() throws {
    let billingJSON = """
    {
      "config": {
        "creditUsagePercent": 29.0,
        "currentPeriod": {
          "start": "2026-11-10T00:00:00Z",
          "end": "2026-11-17T00:00:00Z"
        },
        "prepaidBalance": { "val": 354 },
        "productUsage": [
          { "product": "GrokBuild", "usagePercent": 24.0 },
          { "product": "GrokChat", "usagePercent": 5.0 }
        ]
      }
    }
    """.data(using: .utf8)!

    let snap = try GrokProvider.parseBillingJSON(
        data: billingJSON,
        authSource: .localOAuth,
        email: "grok@x.example",
        planOverride: "SuperGrok"
    )
    check(snap.longWindow?.usedPercentInt == 24, "Grok prioritizes GrokBuild 24% as primary window")
    check(snap.menubarNumbers(mode: .used).map(\.value) == [24], "Grok menubar shows single number [24] from GrokBuild, no dashes")
    check(snap.availableCredit == "$3.54", "Grok available credit $3.54 parsed")
    check(snap.extraWindows.first?.usedPercentInt == 29, "Total Grok pool 29% kept in detail extraWindows")
    check(!snap.details.contains(where: { $0.label == "Grok Build" }), "Grok Build not duplicated in details")
    check(snap.details.contains(where: { $0.label == "Grok Chat" }), "Grok Chat breakdown preserved in details")

    check(QuotaSeverity.forUsedPercent(24) == .healthy, "24% used is healthy")
    check(QuotaSeverity.forUsedPercent(84) == .warning, "84% used is warning")
    check(QuotaSeverity.forUsedPercent(93) == .critical, "93% used is critical")
}

do {
    try runAnthropicTests()
    try runOpenAITests()
    try runGoogleTests()
    try runGrokTests()
    print("AiBarTests: \(passedCount) assertions passed, \(failedCount) failed.")
    exit(failedCount == 0 ? 0 : 1)
} catch {
    fputs("Unhandled test error: \(error)\n", stderr)
    exit(1)
}
