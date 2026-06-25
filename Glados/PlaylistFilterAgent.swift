import Foundation

/// Classifies which feed articles fall within a scientific domain/field, so a
/// playlist can be filtered by topic. The topic is free text — broad ("biology")
/// or specific ("immunology", "CRISPR gene editing"). Uses Claude Haiku.
actor PlaylistFilterAgent {
    static let shared = PlaylistFilterAgent()

    private let model = "claude-haiku-4-5"

    /// Returns the indices of `articles` whose subject matches `topic`, or nil on
    /// failure / missing key (caller should then keep everything).
    func matchingIndices(_ articles: [FeedArticle], topic: String) async -> [Int]? {
        guard !articles.isEmpty else { return [] }
        guard let apiKey = Keychain.get("anthropicAPIKey"), !apiKey.isEmpty else { return nil }

        let list = articles.enumerated().map { i, a in
            let summary = a.summary.prefix(280)
            return "\(i). \(a.title)\(summary.isEmpty ? "" : " — \(summary)")"
        }.joined(separator: "\n")

        let prompt = """
        You are filtering science news/articles for a playlist about the field: "\(topic)".
        Below is a numbered list of items (index. title — summary). Return ONLY JSON of \
        the form {"match":[0,2,5]} listing the indices whose subject matter falls within \
        "\(topic)". Include closely related subfields; exclude items that are clearly about \
        a different field. If none match, return {"match":[]}. Output nothing but the JSON.

        \(list)
        """

        let body: [String: Any] = [
            "model": model,
            "max_tokens": 1024,
            "messages": [["role": "user", "content": prompt]],
        ]
        guard let httpBody = try? JSONSerialization.data(withJSONObject: body) else { return nil }

        var req = URLRequest(url: URL(string: "https://api.anthropic.com/v1/messages")!)
        req.httpMethod = "POST"
        req.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        req.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        req.setValue("application/json", forHTTPHeaderField: "content-type")
        req.httpBody = httpBody
        req.timeoutInterval = 60

        guard let (data, _) = try? await URLSession.shared.data(for: req),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }

        if let err = json["error"] as? [String: Any] {
            agentLog.log("playlist-filter agent error: \(String(describing: err), privacy: .public)")
            return nil
        }
        if let usage = json["usage"] as? [String: Any] {
            let inT = usage["input_tokens"] as? Int ?? 0
            let outT = usage["output_tokens"] as? Int ?? 0
            CostTracker.shared.recordAsync(Pricing.llmCost(provider: .haiku, inputTokens: inT, outputTokens: outT))
        }
        let text = (json["content"] as? [[String: Any]])?
            .compactMap { $0["text"] as? String }.joined() ?? ""
        return Self.parse(text, count: articles.count)
    }

    /// Pulls the {"match":[…]} index array out of the model's reply.
    private static func parse(_ text: String, count: Int) -> [Int]? {
        guard let start = text.firstIndex(of: "{"), let end = text.lastIndex(of: "}") else { return nil }
        let slice = String(text[start...end])
        guard let data = slice.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let arr = obj["match"] as? [Any] else { return nil }
        let idx = arr.compactMap { v -> Int? in
            if let i = v as? Int { return i }
            if let d = v as? Double { return Int(d) }
            if let s = v as? String { return Int(s) }
            return nil
        }.filter { $0 >= 0 && $0 < count }
        return Array(Set(idx)).sorted()
    }
}
