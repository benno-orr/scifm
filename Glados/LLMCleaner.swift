import Foundation

actor LLMCleaner {
    static let shared = LLMCleaner()

    private let session: URLSession

    init() {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 90
        self.session = URLSession(configuration: config)
    }

    // MARK: - Article polish

    /// Cleans article text for TTS. Falls back to original on failure or if provider is none.
    func clean(title: String, text: String) async -> String {
        let prompt = """
        You are preparing a scientific article for professional text-to-speech narration. \
        The text has already had inline citations removed and scientific abbreviations \
        spelled out phonetically. Your job:
        1. Remove any remaining inline citations, e.g. (Smith et al., 2023), [1], [1,2,3].
        2. Remove references to figures, tables, or supplements, e.g. "as shown in Figure 3A".
        3. Rewrite sentence fragments or abrupt transitions so they flow naturally when read aloud.
        4. Remove LaTeX artefacts, stray HTML tags, or formatting symbols.
        5. Keep all scientific content intact — do not summarise or add new content.
        6. Return ONLY the cleaned body text, no title, no commentary.
        """
        return await call(system: prompt, user: text) ?? text
    }

    // MARK: - Figure narration merge

    /// Merges a figure legend + body-text context sentences into a fluent TTS narration.
    /// Falls back to a simple join if LLM is unavailable.
    func mergeForFigure(figureRef: String, legendText: String, contextSentences: [String]) async -> String {
        guard !contextSentences.isEmpty else { return legendText }

        let contextBlock = contextSentences.joined(separator: " ")
        let prompt = """
        You are preparing a narration for a scientific figure panel for text-to-speech playback.

        You will receive:
        1. The figure legend (caption from the paper)
        2. Sentences from the paper body that discuss this figure panel

        Your task: synthesise these into a fluid 2–3 paragraph narration that:
        - Explains what is shown and what it means scientifically
        - Integrates the legend and body context naturally — do not repeat information
        - Removes figure callout notation like "(Figure 4F)" or "(Fig. 4A–C)"
        - Flows naturally when read aloud
        - Does NOT start with "Figure X" — the figure label will be prepended separately
        - Returns ONLY the narration text, no titles or metadata
        """
        let userContent = "Legend:\n\(legendText)\n\nBody context:\n\(contextBlock)"
        return await call(system: prompt, user: userContent) ?? "\(legendText) \(contextBlock)"
    }

    // MARK: - Summary generation

    /// Writes a short plain-language summary from article text, for items whose
    /// feed provides no real abstract. Returns nil if no LLM provider is set or
    /// the call fails.
    func summarize(title: String, text: String) async -> String? {
        guard AppSettings.llmProvider != .none else { return nil }
        let prompt = """
        You are writing a concise, plain-language summary of a scientific article for audio playback. \
        Using ONLY the article text provided, write 3 to 5 sentences explaining what the work found and \
        why it matters. Do not invent details, numbers, or claims that are not in the text. Do not mention \
        figures, tables, references, or the article's structure. Write flowing prose suitable for narration, \
        with no headings or lists. Return ONLY the summary text.
        """
        let body = String(text.prefix(12000))
        return await call(system: prompt, user: "Title: \(title)\n\nArticle text:\n\(body)")
    }

    // MARK: - Routing

    private func call(system: String, user: String) async -> String? {
        switch AppSettings.llmProvider {
        case .none:
            return nil
        case .haiku, .sonnet, .opus:
            return await callAnthropic(system: system, user: user)
        case .gpt4oMini:
            return await callOpenAI(system: system, user: user)
        }
    }

    // MARK: - Anthropic

    private func callAnthropic(system: String, user: String) async -> String? {
        guard let provider = AppSettings.llmProvider.anthropicModelID,
              let apiKey = Keychain.get("anthropicAPIKey"), !apiKey.isEmpty else { return nil }

        let body: [String: Any] = [
            "model": provider,
            "max_tokens": 16000,
            "system": system,
            "messages": [["role": "user", "content": user]],
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: body) else { return nil }

        var request = URLRequest(url: URL(string: "https://api.anthropic.com/v1/messages")!)
        request.httpMethod = "POST"
        request.setValue(apiKey,        forHTTPHeaderField: "x-api-key")
        request.setValue("2023-06-01",  forHTTPHeaderField: "anthropic-version")
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        request.httpBody = data

        guard let (responseData, _) = try? await session.data(for: request),
              let json = try? JSONSerialization.jsonObject(with: responseData) as? [String: Any],
              let content = (json["content"] as? [[String: Any]])?.first,
              let text = content["text"] as? String, !text.isEmpty
        else { return nil }

        if let usage = json["usage"] as? [String: Any] {
            let inT = usage["input_tokens"] as? Int ?? 0
            let outT = usage["output_tokens"] as? Int ?? 0
            CostTracker.shared.recordAsync(
                Pricing.llmCost(provider: AppSettings.llmProvider, inputTokens: inT, outputTokens: outT))
        }

        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - OpenAI

    private func callOpenAI(system: String, user: String) async -> String? {
        guard let apiKey = Keychain.get("openaiAPIKey"), !apiKey.isEmpty else { return nil }

        let body: [String: Any] = [
            "model": "gpt-4o-mini",
            "messages": [
                ["role": "system", "content": system],
                ["role": "user",   "content": user],
            ],
            "temperature": 0.2,
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: body) else { return nil }

        var request = URLRequest(url: URL(string: "https://api.openai.com/v1/chat/completions")!)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = data

        guard let (responseData, _) = try? await session.data(for: request),
              let json = try? JSONSerialization.jsonObject(with: responseData) as? [String: Any],
              let choices = json["choices"] as? [[String: Any]],
              let message = choices.first?["message"] as? [String: Any],
              let text = message["content"] as? String, !text.isEmpty
        else { return nil }

        if let usage = json["usage"] as? [String: Any] {
            let inT = usage["prompt_tokens"] as? Int ?? 0
            let outT = usage["completion_tokens"] as? Int ?? 0
            CostTracker.shared.recordAsync(
                Pricing.llmCost(provider: AppSettings.llmProvider, inputTokens: inT, outputTokens: outT))
        }

        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
