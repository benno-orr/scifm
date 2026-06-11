import Foundation
import Combine

// MARK: - Pricing

/// Central price list for the paid APIs. Rates are USD; adjust here if a
/// provider changes pricing.
enum Pricing {

    // ── TTS: USD per character ──
    static func ttsPerChar(_ provider: TTSProviderType) -> Double {
        switch provider {
        case .deepgram: return 0.015 / 1_000      // Deepgram Aura ≈ $0.015 / 1K chars
        case .openai:   return 15.0 / 1_000_000   // OpenAI tts-1 = $15 / 1M chars
        }
    }

    static func ttsCost(chars: Int, provider: TTSProviderType) -> Double {
        Double(max(0, chars)) * ttsPerChar(provider)
    }

    // ── LLM: USD per 1M tokens (input, output) ──
    static func llmRates(_ provider: LLMProviderType) -> (input: Double, output: Double)? {
        switch provider {
        case .none:      return nil
        case .haiku:     return (1.00, 5.00)     // Claude Haiku 4.5
        case .sonnet:    return (3.00, 15.00)    // Claude Sonnet 4.6
        case .opus:      return (15.00, 75.00)   // Claude Opus
        case .gpt4oMini: return (0.15, 0.60)     // GPT-4o mini
        }
    }

    static func llmCost(provider: LLMProviderType, inputTokens: Int, outputTokens: Int) -> Double {
        guard let r = llmRates(provider) else { return 0 }
        return Double(inputTokens) / 1_000_000 * r.input
             + Double(outputTokens) / 1_000_000 * r.output
    }
}

// MARK: - Cost tracker

/// Persistent running tally of API spend, bucketed by calendar day so we can
/// show both today's spend and an all-time total. Stored in UserDefaults.
@MainActor
final class CostTracker: ObservableObject {
    static let shared = CostTracker()

    /// "yyyy-MM-dd" → USD spent that day.
    @Published private(set) var dailyTotals: [String: Double] = [:]

    private let storageKey = "apiCostDailyTotals"
    private let dayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    private init() {
        if let data = UserDefaults.standard.data(forKey: storageKey),
           let decoded = try? JSONDecoder().decode([String: Double].self, from: data) {
            dailyTotals = decoded
        }
    }

    func record(_ amount: Double) {
        guard amount > 0, amount.isFinite else { return }
        let key = dayFormatter.string(from: Date())
        dailyTotals[key, default: 0] += amount
        persist()
    }

    /// Convenience for off-main callers (actors); hops to the main actor.
    nonisolated func recordAsync(_ amount: Double) {
        Task { @MainActor in CostTracker.shared.record(amount) }
    }

    var todayTotal: Double { dailyTotals[dayFormatter.string(from: Date())] ?? 0 }
    var allTimeTotal: Double { dailyTotals.values.reduce(0, +) }

    private func persist() {
        if let data = try? JSONEncoder().encode(dailyTotals) {
            UserDefaults.standard.set(data, forKey: storageKey)
        }
    }
}
