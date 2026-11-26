import Foundation

public enum GrokProvider {

    // MARK: - 1. Grok CLI-Proxy REST Fetch (`~/.grok/auth.json` or manual SuperGrok Bearer)

    public static func fetchViaCLIProxy(
        bearerToken: String,
        fallbackEmail: String? = nil,
        fallbackPlan: String? = nil,
        source: AuthSourceKind = .localOAuth
    ) async throws -> ProviderSnapshot {
        var req = URLRequest(url: URL(string: "https://cli-chat-proxy.grok.com/v1/billing?format=credits")!)
        req.timeoutInterval = 12
        req.setValue("Bearer \(bearerToken)", forHTTPHeaderField: "Authorization")
        req.setValue("xai-grok-cli", forHTTPHeaderField: "x-xai-token-auth")
        req.setValue("application/json", forHTTPHeaderField: "Accept")

        let (data, resp) = try await URLSession.shared.data(for: req)
        guard let http = resp as? HTTPURLResponse else {
            throw ProviderFetchError.networkError("Invalid HTTP response from Grok")
        }
        if http.statusCode == 401 || http.statusCode == 403 {
            throw ProviderFetchError.unauthorized("Grok token expired — run 'grok login' or sign in via Web")
        }
        guard (200...299).contains(http.statusCode) else {
            throw ProviderFetchError.networkError("Grok HTTP \(http.statusCode)")
        }

        let tierDisplay = await fetchSettingsTier(bearerToken: bearerToken)
        return try parseBillingJSON(
            data: data,
            authSource: source,
            email: fallbackEmail,
            planOverride: tierDisplay ?? fallbackPlan
        )
    }

    private static func fetchSettingsTier(bearerToken: String) async -> String? {
        var req = URLRequest(url: URL(string: "https://cli-chat-proxy.grok.com/v1/settings")!)
        req.timeoutInterval = 2.5
        req.setValue("Bearer \(bearerToken)", forHTTPHeaderField: "Authorization")
        req.setValue("xai-grok-cli", forHTTPHeaderField: "x-xai-token-auth")
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        guard let (data, resp) = try? await URLSession.shared.data(for: req),
              let http = resp as? HTTPURLResponse, (200...299).contains(http.statusCode),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tier = json["subscription_tier_display"] as? String, !tier.isEmpty else {
            return nil
        }
        return tier
    }

    // MARK: - 2. `grok agent stdio` ACP JSON-RPC (`_x.ai/billing`)

    public static func fetchViaGrokCLIStdio(
        executablePath: String,
        fallbackEmail: String? = nil,
        fallbackPlan: String? = nil
    ) async throws -> ProviderSnapshot {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let proc = Process()
                proc.executableURL = URL(fileURLWithPath: executablePath)
                proc.arguments = ["agent", "stdio"]

                let stdinPipe = Pipe()
                let stdoutPipe = Pipe()
                let stderrPipe = Pipe()
                proc.standardInput = stdinPipe
                proc.standardOutput = stdoutPipe
                proc.standardError = stderrPipe

                do {
                    try proc.run()
                } catch {
                    continuation.resume(throwing: ProviderFetchError.networkError("Could not launch grok CLI"))
                    return
                }

                let initMsg = #"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"1","clientCapabilities":{"fs":{"readTextFile":false,"writeTextFile":false},"terminal":false}}}"# + "\n"
                let billMsg = #"{"jsonrpc":"2.0","id":2,"method":"_x.ai/billing","params":{}}"# + "\n"

                if let d1 = initMsg.data(using: .utf8) {
                    try? stdinPipe.fileHandleForWriting.write(contentsOf: d1)
                }
                if let d2 = billMsg.data(using: .utf8) {
                    try? stdinPipe.fileHandleForWriting.write(contentsOf: d2)
                }
                try? stdinPipe.fileHandleForWriting.close()

                let deadline = Date().addingTimeInterval(6.0)
                var buffer = Data()

                // `availableData` blocks while the CLI is alive but silent; terminating the process at the
                // deadline closes stdout so the read loop below always returns.
                DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 6.5) {
                    if proc.isRunning { proc.terminate() }
                }

                while Date() < deadline {
                    let available = stdoutPipe.fileHandleForReading.availableData
                    if available.isEmpty {
                        if !proc.isRunning { break }
                        Thread.sleep(forTimeInterval: 0.05)
                        continue
                    }
                    buffer.append(available)
                    if let text = String(data: buffer, encoding: .utf8) {
                        for line in text.split(separator: "\n") {
                            guard let lineData = String(line).data(using: .utf8),
                                  let rpc = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any],
                                  (rpc["id"] as? Int) == 2 else {
                                continue
                            }
                            if proc.isRunning { proc.terminate() }
                            if let errObj = rpc["error"] as? [String: Any] {
                                let msg = (errObj["message"] as? String) ?? "Grok CLI billing error"
                                if msg.lowercased().contains("authentication") || msg.lowercased().contains("login") {
                                    continuation.resume(throwing: ProviderFetchError.unauthorized(msg))
                                } else {
                                    continuation.resume(throwing: ProviderFetchError.networkError(msg))
                                }
                                return
                            }
                            if let result = rpc["result"] as? [String: Any],
                               let resultData = try? JSONSerialization.data(withJSONObject: result) {
                                do {
                                    let snap = try parseBillingJSON(
                                        data: resultData,
                                        authSource: .localCLI,
                                        email: fallbackEmail,
                                        planOverride: (result["subscription_tier"] as? String) ?? fallbackPlan
                                    )
                                    continuation.resume(returning: snap)
                                } catch {
                                    continuation.resume(throwing: error)
                                }
                                return
                            }
                        }
                    }
                }

                if proc.isRunning { proc.terminate() }
                continuation.resume(throwing: ProviderFetchError.networkError("Timed out reading Grok CLI billing"))
            }
        }
    }

    // MARK: - 3. Billing JSON & Web Bundle Parsing

    public static func parseWebBundleJSON(_ jsonData: Data) throws -> ProviderSnapshot {
        guard let root = try JSONSerialization.jsonObject(with: jsonData) as? [String: Any] else {
            throw ProviderFetchError.parseError("Invalid Grok web bundle")
        }
        if (root["signedOut"] as? Bool) == true {
            throw ProviderFetchError.unauthorized("Not signed in to Grok")
        }
        let email = root["email"] as? String
        let plan = root["plan"] as? String

        // 1. Captured JSON billing payload if present
        if let billingObj = root["billing"] as? [String: Any],
           let bData = try? JSONSerialization.data(withJSONObject: billingObj) {
            return try parseBillingJSON(data: bData, authSource: .webSession, email: email, planOverride: plan)
        }

        // 2. Captured gRPC-Web base64 binary frame from GetGrokCreditsConfig
        if let grpcBase64 = root["grpcBase64"] as? String,
           let rawBytes = Data(base64Encoded: grpcBase64),
           let protoSnap = parseGrokGrpcProtobuf(rawBytes, email: email, plan: plan) {
            return protoSnap
        }

        // 3. Direct scraped percent + reset from grok.com/?_s=billing modal DOM
        if let usedPct = numericDouble(root["usedPercent"]) {
            let resetDate = ISO8601Parser.parse(root["resetsAt"] as? String)
            return ProviderSnapshot(
                provider: .grok,
                state: .ready,
                authSource: .webSession,
                accountEmail: email,
                planName: plan ?? "SuperGrok",
                shortWindow: nil,
                longWindow: QuotaWindow(
                    id: "grok-credits",
                    title: "Weekly Credits",
                    usedPercent: usedPct,
                    resetsAt: resetDate,
                    windowSeconds: 7 * 86400
                ),
                fetchedAt: Date()
            )
        }

        throw ProviderFetchError.parseError("Open Billing in Grok or run 'grok login' to read credits")
    }

    public static func parseBillingJSON(
        data: Data,
        authSource: AuthSourceKind,
        email: String? = nil,
        planOverride: String? = nil
    ) throws -> ProviderSnapshot {
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ProviderFetchError.parseError("Invalid Grok billing JSON")
        }

        let config = (root["config"] as? [String: Any]) ?? root
        var details: [ExtraDetailItem] = []
        var longWindow: QuotaWindow?
        var extraWindows: [QuotaWindow] = []

        // Parse period start & end
        let currentPeriod = config["currentPeriod"] as? [String: Any]
        let billingCycle = root["billingCycle"] as? [String: Any]
        let startStr = (currentPeriod?["start"] as? String)
            ?? (config["billingPeriodStart"] as? String)
            ?? (billingCycle?["billingPeriodStart"] as? String)
        let endStr = (currentPeriod?["end"] as? String)
            ?? (config["billingPeriodEnd"] as? String)
            ?? (billingCycle?["billingPeriodEnd"] as? String)

        let startDate = ISO8601Parser.parse(startStr)
        let resetDate = ISO8601Parser.parse(endStr)

        var windowSeconds: Int?
        var periodLabel = "Credits"
        if let s = startDate, let e = resetDate, e > s {
            let diff = Int(e.timeIntervalSince(s))
            windowSeconds = diff
            if diff <= 9 * 86400 {
                periodLabel = "7-Day"
            } else if diff >= 25 * 86400 {
                periodLabel = "Monthly"
            }
        }

        let products = (config["productUsage"] as? [[String: Any]]) ?? []
        var grokBuildPercent: Double?
        for p in products {
            if (p["product"] as? String) == "GrokBuild",
               let share = numericDouble(p["usagePercent"]) {
                grokBuildPercent = share
            }
        }

        let totalCreditPct = numericDouble(config["creditUsagePercent"])

        // Prioritize Grok Build usage for the menu bar & primary row
        if let buildPct = grokBuildPercent {
            longWindow = QuotaWindow(
                id: "grok-build",
                title: "Grok Build (\(periodLabel))",
                usedPercent: buildPct,
                resetsAt: resetDate,
                windowSeconds: windowSeconds
            )
            if let totalPct = totalCreditPct, abs(totalPct - buildPct) >= 0.5 {
                extraWindows.append(QuotaWindow(
                    id: "grok-credits",
                    title: "Total Grok Pool (\(periodLabel))",
                    usedPercent: totalPct,
                    resetsAt: resetDate,
                    windowSeconds: windowSeconds
                ))
            }
        } else if let creditPct = totalCreditPct {
            longWindow = QuotaWindow(
                id: "grok-credits",
                title: "\(periodLabel) Credits",
                usedPercent: creditPct,
                resetsAt: resetDate,
                windowSeconds: windowSeconds
            )
        } else if let usageObj = root["usage"] as? [String: Any],
                  let totalUsed = centVal(usageObj["totalUsed"]),
                  let monthlyLimit = centVal(root["monthlyLimit"]),
                  monthlyLimit > 0 {
            let pct = (Double(totalUsed) / Double(monthlyLimit)) * 100.0
            longWindow = QuotaWindow(
                id: "grok-credits",
                title: "\(periodLabel) Credits",
                usedPercent: pct,
                resetsAt: resetDate,
                windowSeconds: windowSeconds
            )
        }

        // On-demand cap (either fallback primary or secondary extra window)
        if let onDemandUsed = centVal(config["onDemandUsed"]),
           let onDemandCap = centVal(config["onDemandCap"]),
           onDemandCap > 0 {
            let pct = (Double(onDemandUsed) / Double(onDemandCap)) * 100.0
            let odWin = QuotaWindow(
                id: "grok-ondemand",
                title: "On-Demand Cap",
                usedPercent: pct,
                resetsAt: resetDate,
                windowSeconds: windowSeconds
            )
            if longWindow == nil {
                longWindow = odWin
            } else {
                extraWindows.append(odWin)
            }
        }

        // Prepaid / available credit balance (USD cents)
        var availableCredit: String?
        if let prepaidObj = config["prepaidBalance"] as? [String: Any] {
            let cents = centVal(prepaidObj) ?? 0
            if cents >= 0 {
                availableCredit = String(format: "$%.2f", Double(cents) / 100.0)
            }
        } else if let onDemandUsed = centVal(config["onDemandUsed"]),
                  let onDemandCap = centVal(config["onDemandCap"]),
                  onDemandCap > 0 {
            let remainingCents = max(0, onDemandCap - onDemandUsed)
            availableCredit = String(format: "$%.2f", Double(remainingCents) / 100.0)
        }

        // Product breakdown (other Grok products when present alongside GrokBuild)
        for p in products {
            guard let name = p["product"] as? String,
                  name != "GrokBuild",
                  let share = numericDouble(p["usagePercent"]),
                  share > 0 else { continue }
            details.append(ExtraDetailItem(
                id: "grok-prod-\(name)",
                label: formatProductName(name),
                value: String(format: "%.1f%% used", share)
            ))
        }

        let rawTier = planOverride
            ?? (config["subscriptionTier"] as? String)
            ?? (root["subscription_tier"] as? String)

        if longWindow == nil && availableCredit == nil && details.isEmpty {
            throw ProviderFetchError.parseError("No Grok credit usage returned for this account")
        }

        return ProviderSnapshot(
            provider: .grok,
            state: longWindow != nil ? .ready : .freeDynamic,
            authSource: authSource,
            accountEmail: email,
            planName: formatGrokPlan(rawTier),
            shortWindow: nil,
            longWindow: longWindow,
            extraWindows: extraWindows,
            availableCredit: availableCredit,
            details: details,
            fetchedAt: Date()
        )
    }

    // MARK: - Minimal gRPC-Web Protobuf Reader (`GetGrokCreditsConfigResponse`)

    public static func parseGrokGrpcProtobuf(_ raw: Data, email: String?, plan: String?) -> ProviderSnapshot? {
        var payload = raw
        // Unwrap 5-byte gRPC-Web uncompressed data frame header (0x00 + 4-byte big-endian length)
        if payload.count >= 5 && payload[payload.startIndex] == 0x00 {
            let len = Int(payload[payload.startIndex + 1]) << 24
                | Int(payload[payload.startIndex + 2]) << 16
                | Int(payload[payload.startIndex + 3]) << 8
                | Int(payload[payload.startIndex + 4])
            if len > 0 && payload.count >= 5 + len {
                payload = payload.subdata(in: (payload.startIndex + 5)..<(payload.startIndex + 5 + len))
            }
        }

        // Scan outer message field 1 (config message) or direct fields for float percent + timestamps
        let inner = extractLengthDelimitedField(payload, fieldNumber: 1) ?? payload
        var foundPercent: Double?
        var timestamps: [TimeInterval] = []

        scanProtobufScalars(inner, foundPercent: &foundPercent, timestamps: &timestamps)
        let validFuture = timestamps.filter { $0 > 1_700_000_000 && $0 < 2_500_000_000 }.sorted()
        let resetDate = validFuture.last.map { Date(timeIntervalSince1970: $0) }

        guard foundPercent != nil || resetDate != nil else { return nil }
        return ProviderSnapshot(
            provider: .grok,
            state: .ready,
            authSource: .webSession,
            accountEmail: email,
            planName: formatGrokPlan(plan) ?? "SuperGrok",
            shortWindow: nil,
            longWindow: QuotaWindow(
                id: "grok-credits",
                title: "Weekly Credits",
                usedPercent: foundPercent ?? 0.0,
                resetsAt: resetDate,
                windowSeconds: 7 * 86400
            ),
            fetchedAt: Date()
        )
    }

    private static func extractLengthDelimitedField(_ data: Data, fieldNumber: Int) -> Data? {
        var idx = data.startIndex
        while idx < data.endIndex {
            guard let tag = readVarint(data, index: &idx) else { return nil }
            let wire = Int(tag & 0x07)
            let field = Int(tag >> 3)
            switch wire {
            case 0:
                guard readVarint(data, index: &idx) != nil else { return nil }
            case 1:
                guard data.distance(from: idx, to: data.endIndex) >= 8 else { return nil }
                idx = data.index(idx, offsetBy: 8)
            case 2:
                guard let lenU = readVarint(data, index: &idx) else { return nil }
                let len = Int(lenU)
                guard len >= 0, data.distance(from: idx, to: data.endIndex) >= len else { return nil }
                let end = data.index(idx, offsetBy: len)
                if field == fieldNumber {
                    return data.subdata(in: idx..<end)
                }
                idx = end
            case 5:
                guard data.distance(from: idx, to: data.endIndex) >= 4 else { return nil }
                idx = data.index(idx, offsetBy: 4)
            default:
                return nil
            }
        }
        return nil
    }

    private static func scanProtobufScalars(_ data: Data, foundPercent: inout Double?, timestamps: inout [TimeInterval], depth: Int = 0) {
        guard depth <= 3 else { return }
        var idx = data.startIndex
        while idx < data.endIndex {
            guard let tag = readVarint(data, index: &idx) else { return }
            let wire = Int(tag & 0x07)
            switch wire {
            case 0:
                if let val = readVarint(data, index: &idx) {
                    let secs = Double(val)
                    if secs > 1_700_000_000 && secs < 2_500_000_000 {
                        timestamps.append(secs)
                    }
                }
            case 1:
                guard data.distance(from: idx, to: data.endIndex) >= 8 else { return }
                var bits: UInt64 = 0
                for b in 0..<8 {
                    bits |= UInt64(data[data.index(idx, offsetBy: b)]) << (b * 8)
                }
                idx = data.index(idx, offsetBy: 8)
                let dbl = Double(bitPattern: bits)
                if dbl.isFinite && dbl >= 0.0 && dbl <= 100.0 && foundPercent == nil {
                    foundPercent = dbl
                }
            case 2:
                guard let lenU = readVarint(data, index: &idx) else { return }
                let len = Int(lenU)
                guard len >= 0, data.distance(from: idx, to: data.endIndex) >= len else { return }
                let sub = data.subdata(in: idx..<data.index(idx, offsetBy: len))
                idx = data.index(idx, offsetBy: len)
                if let str = String(data: sub, encoding: .utf8), let iso = ISO8601Parser.parse(str) {
                    timestamps.append(iso.timeIntervalSince1970)
                } else {
                    scanProtobufScalars(sub, foundPercent: &foundPercent, timestamps: &timestamps, depth: depth + 1)
                }
            case 5:
                guard data.distance(from: idx, to: data.endIndex) >= 4 else { return }
                var bits: UInt32 = 0
                for b in 0..<4 {
                    bits |= UInt32(data[data.index(idx, offsetBy: b)]) << (b * 8)
                }
                idx = data.index(idx, offsetBy: 4)
                let flt = Double(Float(bitPattern: bits))
                if flt.isFinite && flt >= 0.0 && flt <= 100.0 && foundPercent == nil {
                    foundPercent = flt
                }
            default:
                return
            }
        }
    }

    private static func readVarint(_ data: Data, index: inout Data.Index) -> UInt64? {
        var result: UInt64 = 0
        var shift: UInt64 = 0
        for _ in 0..<10 {
            guard index < data.endIndex else { return nil }
            let byte = data[index]
            index = data.index(after: index)
            result |= UInt64(byte & 0x7F) << shift
            if (byte & 0x80) == 0 {
                return result
            }
            shift += 7
        }
        return nil
    }

    private static func centVal(_ raw: Any?) -> Int? {
        if let dict = raw as? [String: Any] {
            if let v = dict["val"] as? Int { return v }
            if let d = dict["val"] as? Double { return Int(d) }
            if let s = dict["val"] as? String, let v = Int(s) { return v }
            if dict.isEmpty { return 0 }
        }
        return nil
    }

    private static func formatProductName(_ raw: String) -> String {
        switch raw {
        case "GrokBuild": return "Grok Build"
        case "GrokChat": return "Grok Chat"
        case "GrokImagine": return "Grok Imagine"
        case "GrokAppBuilder": return "Grok App Builder"
        default: return raw
        }
    }

    private static func formatGrokPlan(_ raw: String?) -> String? {
        guard let raw = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else {
            return nil
        }
        let lower = raw.lowercased()
        if lower.contains("heavy") { return "SuperGrok Heavy" }
        if lower.contains("super") { return "SuperGrok" }
        return raw
    }

    private static func numericDouble(_ value: Any?) -> Double? {
        if value is Bool { return nil }
        if let d = value as? Double { return d }
        if let i = value as? Int { return Double(i) }
        if let n = value as? NSNumber { return n.doubleValue }
        return nil
    }
}
