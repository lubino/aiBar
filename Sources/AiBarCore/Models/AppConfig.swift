import Foundation

public struct AppConfig: Codable, Equatable, Sendable {
    public var enabledProviders: [ProviderID]
    public var refreshIntervalMinutes: Int
    public var percentageMode: PercentageDisplayMode
    /// Tracks providers where the user completed an in-app WKWebView login
    public var webSignedInProviders: Set<ProviderID>

    public init(
        enabledProviders: [ProviderID] = ProviderID.allCases,
        refreshIntervalMinutes: Int = 5,
        percentageMode: PercentageDisplayMode = .used,
        webSignedInProviders: Set<ProviderID> = []
    ) {
        self.enabledProviders = enabledProviders
        self.refreshIntervalMinutes = refreshIntervalMinutes
        self.percentageMode = percentageMode
        self.webSignedInProviders = webSignedInProviders
    }

    enum CodingKeys: String, CodingKey {
        case enabledProviders
        case refreshIntervalMinutes
        case percentageMode
        case webSignedInProviders
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.enabledProviders = (try? c.decode([ProviderID].self, forKey: .enabledProviders)) ?? ProviderID.allCases
        self.refreshIntervalMinutes = (try? c.decode(Int.self, forKey: .refreshIntervalMinutes)) ?? 5
        self.percentageMode = (try? c.decode(PercentageDisplayMode.self, forKey: .percentageMode)) ?? .used
        self.webSignedInProviders = (try? c.decode(Set<ProviderID>.self, forKey: .webSignedInProviders)) ?? []
    }

    public func isEnabled(_ provider: ProviderID) -> Bool {
        enabledProviders.contains(provider)
    }

    public mutating func setEnabled(_ provider: ProviderID, enabled: Bool) {
        if enabled {
            if !enabledProviders.contains(provider) {
                enabledProviders = ProviderID.allCases.filter { $0 == provider || enabledProviders.contains($0) }
            }
        } else {
            let remaining = enabledProviders.filter { $0 != provider }
            if !remaining.isEmpty {
                enabledProviders = remaining
            }
        }
    }

    public static var defaultConfigURL: URL {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return home
            .appendingPathComponent(".config", isDirectory: true)
            .appendingPathComponent("aibar", isDirectory: true)
            .appendingPathComponent("config.json")
    }

    public static var snapshotCacheURL: URL {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return home
            .appendingPathComponent(".config", isDirectory: true)
            .appendingPathComponent("aibar", isDirectory: true)
            .appendingPathComponent("snapshots.json")
    }

    public static func load(from url: URL = defaultConfigURL) -> AppConfig {
        guard let data = try? Data(contentsOf: url),
              let decoded = try? JSONDecoder().decode(AppConfig.self, from: data) else {
            return AppConfig()
        }
        return decoded
    }

    public func save(to url: URL = defaultConfigURL) {
        let dir = url.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true, attributes: [
            .posixPermissions: 0o700
        ])
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(self) else { return }
        try? data.write(to: url, options: .atomic)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
}
