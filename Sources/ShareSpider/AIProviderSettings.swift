import Foundation

/// Selects the service used for ShareSpider's text-based AI checks.
/// Keys and OAuth credentials are deliberately kept in local Application
/// Support files so routine checks never trigger a Keychain dialog.
enum AIProvider: String, CaseIterable, Identifiable, Hashable, Sendable {
    case codex
    case openRouter
    case ollama

    var id: String { rawValue }

    var title: String {
        switch self {
        case .codex: "Codex"
        case .openRouter: "OpenRouter"
        case .ollama: "Ollama (local)"
        }
    }

    var help: String {
        switch self {
        case .codex: "ShareSpider sends AI audit prompts to the locally installed Codex CLI."
        case .openRouter: "ShareSpider sends AI audit prompts through your OpenRouter API key."
        case .ollama: "ShareSpider sends AI audit prompts to the local Ollama endpoint."
        }
    }
}

/// The fixed audit blocks can use any configured LLM provider.  The deeper,
/// agent-led investigation is deliberately a separate choice: Hermes receives
/// MCP tools and decides which project details it needs to inspect.
enum AuditAgent: String, CaseIterable, Identifiable, Hashable, Sendable {
    case codex
    case hermes

    var id: String { rawValue }
    var title: String { self == .codex ? "Codex" : "Hermes" }
    var help: String {
        switch self {
        case .codex: "Codex proposes and verifies up to 10 focused investigations."
        case .hermes: "Hermes receives a concise audit context and can request project details through the read-only ShareSpider MCP tools."
        }
    }
}

struct AIProviderSettings: Sendable {
    var provider: AIProvider = .codex
    var agent: AuditAgent = .codex

    static func load() -> AIProviderSettings {
        let raw = UserDefaults.standard.string(forKey: "aiProvider") ?? AIProvider.codex.rawValue
        let agent = UserDefaults.standard.string(forKey: "auditAgent") ?? AuditAgent.codex.rawValue
        return AIProviderSettings(provider: AIProvider(rawValue: raw) ?? .codex, agent: AuditAgent(rawValue: agent) ?? .codex)
    }

    func save() {
        UserDefaults.standard.set(provider.rawValue, forKey: "aiProvider")
        UserDefaults.standard.set(agent.rawValue, forKey: "auditAgent")
    }
}
