import Foundation

// MARK: - TTS Provider

enum TTSProviderType: String, CaseIterable {
    case deepgram = "deepgram"
    case openai   = "openai"

    var displayName: String {
        switch self {
        case .deepgram: return "Deepgram"
        case .openai:   return "OpenAI"
        }
    }
}

// MARK: - LLM Provider

enum LLMProviderType: String, CaseIterable {
    case none      = "none"
    case haiku     = "haiku"
    case sonnet    = "sonnet"
    case opus      = "opus"
    case gpt4oMini = "gpt4omini"

    var displayName: String {
        switch self {
        case .none:      return "None"
        case .haiku:     return "Claude Haiku"
        case .sonnet:    return "Claude Sonnet"
        case .opus:      return "Claude Opus"
        case .gpt4oMini: return "GPT-4o mini"
        }
    }

    var costLabel: String {
        switch self {
        case .none:      return ""
        case .haiku:     return "~$0.004/article"
        case .sonnet:    return "~$0.24/article"
        case .opus:      return "~$1.17/article"
        case .gpt4oMini: return "~$0.01/article"
        }
    }

    var needsAnthropicKey: Bool {
        self == .haiku || self == .sonnet || self == .opus
    }

    var needsOpenAIKey: Bool { self == .gpt4oMini }

    var anthropicModelID: String? {
        switch self {
        case .haiku:  return "claude-haiku-4-5-20251001"
        case .sonnet: return "claude-sonnet-4-6"
        case .opus:   return "claude-opus-4-8"
        default:      return nil
        }
    }
}

// MARK: - Settings

enum AppSettings {
    static var ttsProvider: TTSProviderType {
        get {
            let raw = UserDefaults.standard.string(forKey: "ttsProvider") ?? ""
            return TTSProviderType(rawValue: raw) ?? .deepgram
        }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: "ttsProvider") }
    }

    static var llmProvider: LLMProviderType {
        get {
            let raw = UserDefaults.standard.string(forKey: "llmProvider") ?? ""
            return LLMProviderType(rawValue: raw) ?? .haiku
        }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: "llmProvider") }
    }

    /// One-time switch of the polishing model to Claude Haiku, overriding any
    /// previously persisted choice once. The user remains free to change it in
    /// Settings afterward (this won't re-fire).
    static func migrateToHaikuPolishingIfNeeded() {
        let key = "didMigrateLLMToHaiku"
        guard !UserDefaults.standard.bool(forKey: key) else { return }
        llmProvider = .haiku
        UserDefaults.standard.set(true, forKey: key)
    }
}
