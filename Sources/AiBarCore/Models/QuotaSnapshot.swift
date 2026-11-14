import Foundation

public enum QuotaSeverity: String, Codable, Sendable {
    case healthy
    case warning
    case critical

    public static func forUsedPercent(_ used: Int) -> QuotaSeverity {
        if used >= 90 {
            return .critical
        } else if used >= 80 {
            return .warning
        } else {
            return .healthy
        }
    }
}

public enum PercentageDisplayMode: String, Codable, CaseIterable, Sendable {
    case used
    case remaining

    public var title: String {
        switch self {
        case .used: return "Usage % (consumed)"
        case .remaining: return "Free % (remaining)"
        }
    }
}

public struct QuotaWindow: Codable, Equatable, Sendable, Identifiable {
    public var id: String
    public var title: String
    /// Consumed percentage (0.0 ... 100.0)
    public var usedPercent: Double
    /// Next reset timestamp if reported by the provider
    public var resetsAt: Date?
    /// Optional window duration in seconds (e.g. 18000 = 5h, 604800 = 7d)
    public var windowSeconds: Int?

    public init(
        id: String,
        title: String,
        usedPercent: Double,
        resetsAt: Date? = nil,
        windowSeconds: Int? = nil
    ) {
        self.id = id
        self.title = title
        self.usedPercent = min(100.0, max(0.0, usedPercent))
        self.resetsAt = resetsAt
        self.windowSeconds = windowSeconds
    }

    /// Remaining ("free") percentage rounded to 0...100
    public var remainingPercentInt: Int {
        let raw = (100.0 - usedPercent).rounded()
        return min(100, max(0, Int(raw)))
    }

    /// Used percentage rounded to 0...100
    public var usedPercentInt: Int {
        let raw = usedPercent.rounded()
        return min(100, max(0, Int(raw)))
    }

    public func displayNumber(mode: PercentageDisplayMode) -> Int {
        switch mode {
        case .used: return usedPercentInt
        case .remaining: return remainingPercentInt
        }
    }

    public var usedFraction: Double {
        min(1.0, max(0.0, usedPercent / 100.0))
    }

    public var remainingFraction: Double {
        min(1.0, max(0.0, (100.0 - usedPercent) / 100.0))
    }

    public var severity: QuotaSeverity {
        QuotaSeverity.forUsedPercent(usedPercentInt)
    }
}

public struct ExtraDetailItem: Codable, Equatable, Sendable, Identifiable {
    public var id: String
    public var label: String
    public var value: String

    public init(id: String, label: String, value: String) {
        self.id = id
        self.label = label
        self.value = value
    }
}

public enum AuthSourceKind: String, Codable, Sendable {
    case none
    case localOAuth = "Local OAuth"
    case localCLI = "Local CLI"
    case webSession = "Web Session"
    case manualToken = "Manual Token"
}

public enum ProviderStatusState: String, Codable, Sendable {
    case signedOut
    case loading
    case ready
    case freeDynamic
    case error
}

public struct MenubarNumberToken: Equatable, Sendable {
    public var value: Int
    public var severity: QuotaSeverity

    public init(value: Int, severity: QuotaSeverity) {
        self.value = value
        self.severity = severity
    }
}

public struct ProviderSnapshot: Codable, Equatable, Sendable {
    public var provider: ProviderID
    public var state: ProviderStatusState
    public var authSource: AuthSourceKind
    public var accountEmail: String?
    public var planName: String?
    /// Primary short-term rolling window (typically 5-hour session)
    public var shortWindow: QuotaWindow?
    /// Secondary long-term window (typically 7-day weekly or monthly cycle)
    public var longWindow: QuotaWindow?
    /// Additional model-specific windows (e.g. Sonnet, Opus, Spark)
    public var extraWindows: [QuotaWindow]
    /// Additional balance/reset notes
    public var details: [ExtraDetailItem]
    public var errorMessage: String?
    public var fetchedAt: Date?

    public init(
        provider: ProviderID,
        state: ProviderStatusState = .signedOut,
        authSource: AuthSourceKind = .none,
        accountEmail: String? = nil,
        planName: String? = nil,
        shortWindow: QuotaWindow? = nil,
        longWindow: QuotaWindow? = nil,
        extraWindows: [QuotaWindow] = [],
        details: [ExtraDetailItem] = [],
        errorMessage: String? = nil,
        fetchedAt: Date? = nil
    ) {
        self.provider = provider
        self.state = state
        self.authSource = authSource
        self.accountEmail = accountEmail
        self.planName = planName
        self.shortWindow = shortWindow
        self.longWindow = longWindow
        self.extraWindows = extraWindows
        self.details = details
        self.errorMessage = errorMessage
        self.fetchedAt = fetchedAt
    }

    public var allWindows: [QuotaWindow] {
        var list: [QuotaWindow] = []
        if let shortWindow { list.append(shortWindow) }
        if let longWindow { list.append(longWindow) }
        list.append(contentsOf: extraWindows)
        return list
    }

    /// Returns a single menu-bar number for this provider: the weekly (`longWindow`) limit
    /// (falling back to `shortWindow` only if no weekly window exists).
    /// Signed-out providers produce an empty array so they stay hidden from the menu bar.
    public func menubarNumbers(mode: PercentageDisplayMode = .used) -> [MenubarNumberToken] {
        switch state {
        case .signedOut, .freeDynamic:
            return []
        case .loading, .ready, .error:
            if let l = longWindow {
                // Surface warning/critical color if either the weekly OR the 5-hour window is near exhaustion
                let worstSeverity: QuotaSeverity
                if let s = shortWindow {
                    worstSeverity = Self.maxSeverity(l.severity, s.severity)
                } else {
                    worstSeverity = l.severity
                }
                return [MenubarNumberToken(value: l.displayNumber(mode: mode), severity: worstSeverity)]
            }
            if let s = shortWindow {
                return [MenubarNumberToken(value: s.displayNumber(mode: mode), severity: s.severity)]
            }
            return []
        }
    }

    private static func maxSeverity(_ a: QuotaSeverity, _ b: QuotaSeverity) -> QuotaSeverity {
        if a == .critical || b == .critical { return .critical }
        if a == .warning || b == .warning { return .warning }
        return .healthy
    }
}

public enum ResetFormatter {
    public static func countdownString(until resetDate: Date, now: Date = Date()) -> String {
        let seconds = Int(resetDate.timeIntervalSince(now))
        if seconds <= 0 {
            return "Resetting soon"
        }
        let minutes = (seconds + 30) / 60
        if minutes < 1 {
            return "Resets in <1m"
        }
        if minutes < 60 {
            return "Resets in \(minutes)m"
        }
        let hours = minutes / 60
        let remMin = minutes % 60
        if hours < 24 {
            return remMin > 0 ? "Resets in \(hours)h \(remMin)m" : "Resets in \(hours)h"
        }
        let days = hours / 24
        let remHours = hours % 24
        return remHours > 0 ? "Resets in \(days)d \(remHours)h" : "Resets in \(days)d"
    }

    public static func exactClockString(for resetDate: Date, now: Date = Date(), calendar: Calendar = .current) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = calendar.timeZone
        if calendar.isDate(resetDate, inSameDayAs: now) {
            formatter.dateFormat = "'Today' HH:mm"
        } else if let tomorrow = calendar.date(byAdding: .day, value: 1, to: now),
                  calendar.isDate(resetDate, inSameDayAs: tomorrow) {
            formatter.dateFormat = "'Tomorrow' HH:mm"
        } else {
            formatter.dateFormat = "EEE, MMM d, HH:mm"
        }
        return formatter.string(from: resetDate)
    }

    public static func relativeUpdatedString(since date: Date?, now: Date = Date()) -> String {
        guard let date else { return "Never updated" }
        let sec = max(0, Int(now.timeIntervalSince(date)))
        if sec < 15 { return "Updated just now" }
        if sec < 60 { return "Updated \(sec)s ago" }
        let min = sec / 60
        if min < 60 { return "Updated \(min)m ago" }
        let hr = min / 60
        return "Updated \(hr)h ago"
    }
}
