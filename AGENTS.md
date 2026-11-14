# AGENTS.md — Developer & Architecture Context for aiBar

Read this document before modifying `aiBar`. All code, comments, commit messages, and documentation on disk must remain in **English**.

---

## 1. Critical Toolchain Constraint (No Full Xcode Dependency)

`aiBar` is intentionally engineered to compile and test using **macOS Command Line Tools alone** (`swift build` / `swift run`), without requiring a 30+ GB `Xcode.app` installation.

### Hard Rules for Swift Code:
1. **Do NOT use SwiftUI / Observation macros (`@State`, `@Binding` macro, `@Observable`, `@Model`):**
   On macOS 26+ SDKs, `@State` and `@Observable` rely on external compiler plugins (`SwiftUIMacros`, `ObservationMacros`) that only ship inside `Xcode.app` or require macro plugins absent in standalone Command Line Tools.
   - **Use instead:** `ObservableObject` + `@Published` + `@ObservedObject` + explicit `Binding(get:set:)`.
2. **Do NOT import `XCTest` or use `@Test` / `#expect` macros:**
   `XCTest.framework` is not bundled with Command Line Tools.
   - **Use instead:** the standalone executable test target in `Tests/AiBarCoreTests/main.swift`, invoked via `swift run AiBarTests`.
3. **Strict Swift 6 Concurrency:**
   `Package.swift` uses `swift-tools-version: 6.0`. All models crossing isolation boundaries in `AiBarCore` must conform to `Sendable`, and UI controllers/stores in `AiBarApp` are `@MainActor`-isolated.

---

## 2. Project Structure

```text
aiBar/
├── Package.swift                      # Targets: AiBarCore (library), AiBarApp (executable "aiBar"), AiBarTests (executable)
├── scripts/
│   ├── build-app.sh                   # Release build + AppIcon.icns generation + Info.plist (LSUIElement=true) + ad-hoc codesign
│   └── generate-icon.swift            # Programmatic CoreGraphics generator for AppIcon.iconset
├── Sources/
│   ├── AiBarCore/                     # Pure Foundation + Security layer (no AppKit/WebKit; unit-tested)
│   │   ├── Models/
│   │   │   ├── ProviderID.swift       # .google, .anthropic, .openai, .grok + canonical login/usage/settings URLs
│   │   │   ├── QuotaSnapshot.swift    # QuotaWindow, ProviderSnapshot, PercentageDisplayMode, ResetFormatter
│   │   │   └── AppConfig.swift        # ~/.config/aibar/config.json + ~/.config/aibar/snapshots.json
│   │   ├── Storage/
│   │   │   └── KeychainStore.swift    # macOS Login Keychain wrapper (service: "sk.lubino.aiBar")
│   │   ├── Auth/
│   │   │   └── LocalCredentialReader.swift # Reads ~/.grok/auth.json, ~/.claude/.credentials.json, ~/.codex/auth.json, ~/.local/share/opencode/auth.json
│   │   └── Providers/
│   │       ├── GoogleProvider.swift
│   │       ├── AnthropicProvider.swift
│   │       ├── OpenAIProvider.swift
│   │       └── GrokProvider.swift
│   └── AiBarApp/                      # macOS GUI layer (AppKit + SwiftUI + WebKit + ServiceManagement)
│       ├── main.swift                 # App entry point + CLI flags (--json, --render-preview <png>)
│       ├── AppDelegate.swift          # Lifecycle, hidden Edit/File mainMenu (enables ⌘C/⌘V/⌘W/⌘Q in LSUIElement), wake refresh
│       ├── State/
│       │   └── UsageStore.swift       # @MainActor ObservableObject orchestrating Hybrid Auth, polling timer, snapshot persistence
│       ├── StatusBar/
│       │   ├── ProviderIcons.swift    # Vector CoreGraphics template marks (Google G, Anthropic A\, OpenAI knot, Grok slash)
│       │   └── StatusBarController.swift # Single unified NSStatusItem + pixel-tight Retina strip renderer + NSPopover anchor
│       ├── WebAuth/
│       │   ├── WebSessionManager.swift # Persistent WKWebsiteDataStore.default(), Safari UA, same-origin JS probes, Grok WKE capture
│       │   └── WebLoginWindowController.swift # In-app login window with OAuth popup support & post-login auto-verification
│       └── Views/
│           ├── PopoverRootView.swift  # Auto-sized popover (MaxHeightProposingLayout + ViewThatFits)
│           ├── SettingsWindowController.swift
│           └── WindowActivationCoordinator.swift # Promotes .accessory -> .regular while login/settings windows are open
└── Tests/
    └── AiBarCoreTests/
        └── main.swift                 # Deterministic parser & menu-bar formatting test suite
```

---

## 3. UI & UX Invariants

1. **Single Unified Menu Bar Strip (`StatusBarController.swift`):**
   - `aiBar` uses **one** `NSStatusItem` (`sk.lubino.aiBar.unified`) with `imagePosition = .imageOnly` and explicit tight `statusItem.length = ceil(strip.size.width) + 6` to avoid macOS's wide status item text margins.
   - Signed-out providers or missing windows **never** render dashes (`-`, `–`, `--`) or `%` symbols. Only signed-in providers with numeric values appear (`[Icon]<number>`).
   - If zero providers are signed in, `ProviderIcons.appFallbackIcon` renders a single 13pt icon so the user can click to sign in.
   - **Menu bar metric:** `ProviderSnapshot.menubarNumbers(mode:)` returns **1 number per provider**—specifically `longWindow` (the 7-day weekly / billing cycle limit), falling back to `shortWindow` only if `longWindow` is absent. Warning/critical color (`orange` >= 80% used, `red` >= 90% used) reflects `maxSeverity(longWindow, shortWindow)` so an exhausted 5-hour session still highlights the menu bar number.
2. **Screen-Fitted Auto-Sizing Popover (`PopoverRootView.swift`):**
   - Never hardcode a fixed popover height or force an unconditional `ScrollView`.
   - `NSHostingController` uses `sizingOptions = [.preferredContentSize]`.
   - `MaxHeightProposingLayout` proposes `NSScreen.visibleFrame.height - 48 - headerFooterHeight` down to `ViewThatFits(in: .vertical)`, which chooses the plain intrinsic `VStack` (no scrollbar) whenever it fits on screen and switches to `ScrollView` only when content exceeds the screen height.
3. **Keyboard & `⌘+Tab` Support in an `LSUIElement` App:**
   - `AppDelegate` installs a hidden `NSApp.mainMenu` with standard `Edit` (`Cut`/`Copy`/`Paste`/`Select All`) and `File` (`Close Window`) items; without this, `⌘V` does not work inside `WKWebView` or `NSTextField` in accessory apps.
   - `WindowActivationCoordinator` temporarily switches `NSApp.setActivationPolicy(.regular)` while `WebLoginWindowController` or `SettingsWindowController` is open so users can `⌘+Tab` to Mail / 1Password / Authenticator during 2FA and return cleanly, reverting to `.accessory` when the window closes.

---

## 4. Provider Auth & Wire Schemas

All 4 providers use undocumented web/CLI quota endpoints. Execute web-authenticated requests **inside** same-origin `WKWebView` (`WebSessionManager.swift`) rather than copying cookies into `URLSession`, because `claude.ai` and `chatgpt.com` enforce Cloudflare Turnstile (`cf_clearance`) and `grok.com` requires a browser-held Web Key Exchange (WKE) keypair in IndexedDB.

### Google (`GoogleProvider.swift` + `WebSessionManager.swift`)
- **Web Sign-In:** `https://gemini.google.com/usage`. Requires macOS Safari `customUserAgent` (otherwise `accounts.google.com` blocks with `403 disallowed_useragent`) and `WKUIDelegate.webView(_:createWebViewWith:...)` for SSO popups.
- **Data extraction:** Fetches `/usage` (or `/u/<n>/usage`) in-page and reassembles SSR streamed `<script>` JSON chunks (`events[].kind == "chunk"` -> `data.viewer.rpcs.getUsageInfo`). No hardcoded persisted GraphQL hash is needed.
- **Fields:** `subscriptionTier` (`TIER1`/`PRO`, `TIER2`/`ULTRA`, `FREE`), `pools[]` (`GXU_FIVE_HOURLY` and `GXU_WEEKLY`), where `percentageUsed` is a **`0.0...1.0` fraction** (multiply by 100) and `gxu.windowRefreshesAt` is ISO-8601.

### Anthropic (`AnthropicProvider.swift`)
- **Priority:** Manual Keychain (`sk-ant-oat...` or `sessionKey=...`) → Local OAuth (`~/.claude/.credentials.json` or `~/.local/share/opencode/auth.json`) → WebKit session on `https://claude.ai`.
- **OAuth endpoint:** `GET https://api.anthropic.com/api/oauth/usage` with headers `Authorization: Bearer <token>`, `anthropic-beta: oauth-2025-04-20`, and `User-Agent: claude-code/2.1.0` (omitting `claude-code` UA triggers aggressive 429s). Optional profile lookup: `GET https://api.anthropic.com/api/oauth/profile`.
- **WebKit endpoint:** `/api/organizations` → `/api/organizations/{uuid}/usage` + `/api/account`.
- **Fields:** `five_hour`, `seven_day`, `seven_day_sonnet`, `seven_day_opus` (`utilization` is **`0.0...100.0`**, `resets_at` is ISO-8601), plus fallback support for `limits[]` (`session`, `weekly_all`, `weekly_scoped`). Note: Claude Ultra omits `five_hour` (`null`).

### OpenAI (`OpenAIProvider.swift`)
- **Priority:** Manual Keychain → Local OAuth (`~/.codex/auth.json` or `~/.local/share/opencode/auth.json`) → WebKit session on `https://chatgpt.com`.
- **Token refresh:** Expired local OAuth tokens are refreshed via `POST https://auth.openai.com/oauth/token` (`client_id=app_EMoamEEZ73f0CkXaXp7hrann`) and cached in `aiBar`'s own Keychain entry (`oauth.cache.openai`)—**never** mutate external `~/.codex/auth.json` or OpenCode files.
- **WebKit flow:** `fetch('/api/auth/session')` → extracts `accessToken` + `account.id` → `fetch('/backend-api/wham/usage')`.
- **Window classification:** Always inspect `limit_window_seconds` (`<= 21600` = 5-hour `shortWindow`; `> 21600` = 7-day/30-day `longWindow`). Do **not** assume `primary_window` is 5-hour—ChatGPT Team plans return the 7-day (`604800`s) window in `primary_window` with `secondary_window: null`.

### Grok (`GrokProvider.swift`)
- **Priority:** Manual Keychain → `grok agent stdio` JSON-RPC (`initialize` + `_x.ai/billing`, 6s hard deadline) → `GET https://cli-chat-proxy.grok.com/v1/billing?format=credits` (`x-xai-token-auth: xai-grok-cli` + Bearer from `~/.grok/auth.json`) → WebKit on `https://grok.com/?_s=billing` (`WKUserScript` network hook + gRPC-Web `GetGrokCreditsConfig` protobuf reader).
- **Metric selection:** Grok has a single periodic credit pool (no 5-hour window). When `config.productUsage` includes `"GrokBuild"`, **prioritize `GrokBuild.usagePercent`** as `longWindow` (`Grok Build (7-Day)`) and place total pool usage in `extraWindows` if it differs.

---

## 5. Build, Test & Diagnostics

```bash
# Run unit tests (must pass before every commit)
swift run AiBarTests

# Build & ad-hoc sign release app bundle -> build/aiBar.app
./scripts/build-app.sh

# Dump live provider snapshots as JSON from CLI
./build/aiBar.app/Contents/MacOS/aiBar --json

# Render off-screen menu bar strip preview PNG
./build/aiBar.app/Contents/MacOS/aiBar --render-preview /tmp/preview.png
```

Never commit secrets, tokens, cookies, `~/.config/aibar/*`, `.DS_Store`, or build artifacts (`/.build`, `/build`, `*.app`).

---

## 6. Maintainer Push Protocol

When the user says **push**:

1. Run `swift run AiBarTests` and verify `git status` / `git diff` contain no secrets or build artifacts.
2. Patch-bump `VERSION="MAJOR.MINOR.PATCH"` in `scripts/build-app.sh`.
3. Stage all intended files (`git add`), commit in English explaining **what** and **why**, and `git push` to `origin` (`git@github.com:lubino/aiBar.git`, branch `main`).
