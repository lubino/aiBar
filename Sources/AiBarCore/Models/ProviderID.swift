import Foundation

public enum ProviderID: String, CaseIterable, Codable, Identifiable, Sendable {
    case google
    case anthropic
    case openai
    case grok

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .google: return "Google"
        case .anthropic: return "Anthropic"
        case .openai: return "OpenAI"
        case .grok: return "Grok"
        }
    }

    public var productSubtitle: String {
        switch self {
        case .google: return "Gemini"
        case .anthropic: return "Claude"
        case .openai: return "ChatGPT & Codex"
        case .grok: return "xAI SuperGrok"
        }
    }

    public var loginURL: URL {
        switch self {
        case .google:
            return URL(string: "https://gemini.google.com/usage")!
        case .anthropic:
            return URL(string: "https://claude.ai/login")!
        case .openai:
            return URL(string: "https://chatgpt.com/auth/login")!
        case .grok:
            return URL(string: "https://grok.com/?_s=billing")!
        }
    }

    public var webOriginURL: URL {
        switch self {
        case .google:
            return URL(string: "https://gemini.google.com/usage")!
        case .anthropic:
            return URL(string: "https://claude.ai/settings/usage")!
        case .openai:
            return URL(string: "https://chatgpt.com/")!
        case .grok:
            return URL(string: "https://grok.com/?_s=billing")!
        }
    }

    public var usageWebURL: URL {
        switch self {
        case .google:
            return URL(string: "https://gemini.google.com/usage")!
        case .anthropic:
            return URL(string: "https://claude.ai/settings/usage")!
        case .openai:
            return URL(string: "https://chatgpt.com/codex/cloud/settings/analytics#usage")!
        case .grok:
            return URL(string: "https://grok.com/?_s=billing")!
        }
    }

    public var settingsWebURL: URL {
        switch self {
        case .google:
            return URL(string: "https://one.google.com/settings")!
        case .anthropic:
            return URL(string: "https://claude.ai/settings")!
        case .openai:
            return URL(string: "https://chatgpt.com/#settings")!
        case .grok:
            return URL(string: "https://accounts.x.ai")!
        }
    }

    public var manualTokenPlaceholder: String {
        switch self {
        case .google:
            return "Cookie header from gemini.google.com"
        case .anthropic:
            return "OAuth token (sk-ant-oat...) or sessionKey=..."
        case .openai:
            return "OAuth Bearer token from chatgpt.com"
        case .grok:
            return "SuperGrok Bearer token"
        }
    }
}
