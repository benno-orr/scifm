import Foundation
import UIKit
import os

let agentLog = Logger(subsystem: "com.borr.scifm", category: "agents")

/// The app's first LLM "agent": a focused, single-purpose Claude vision call
/// that identifies the panel-label letters (a, b, c, …) present in a scientific
/// figure image, returning a typed result.
actor PanelLetterAgent {
    static let shared = PanelLetterAgent()

    struct Result {
        let panels: [String]   // detected letters, reading order, lowercased
        let raw: String        // raw model text, for debugging
    }

    /// Vision model. Opus reads small panel labels most reliably; change to
    /// "claude-haiku-4-5" for cheaper/faster runs.
    private let model = "claude-opus-4-8"
    private var costProvider: LLMProviderType { model.contains("haiku") ? .haiku : .opus }

    private static let prompt = """
    This image is a figure from a scientific paper, made up of multiple sub-panels. \
    Each sub-panel is usually marked with a small letter label (typically a lowercase \
    a, b, c, … at the panel's top-left corner). Identify the panel-label letters that \
    actually appear in the image. Respond with ONLY a JSON object of the form \
    {"panels": ["a", "b", "c"]} listing the letters in reading order (left to right, \
    top to bottom), lowercased. If the figure has no panel labels, return {"panels": []}. \
    Output nothing except the JSON.
    """

    /// Runs the agent on a figure image. Returns nil if the Anthropic key is
    /// missing or the request fails.
    func identifyPanels(in image: UIImage) async -> Result? {
        guard let apiKey = Keychain.get("anthropicAPIKey"), !apiKey.isEmpty else {
            agentLog.log("panel-letter agent: no anthropic key")
            return nil
        }
        guard let b64 = Self.jpegBase64(image, maxEdge: 1536) else { return nil }

        let body: [String: Any] = [
            "model": model,
            "max_tokens": 300,
            "messages": [[
                "role": "user",
                "content": [
                    ["type": "image",
                     "source": ["type": "base64", "media_type": "image/jpeg", "data": b64]],
                    ["type": "text", "text": Self.prompt],
                ],
            ]],
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
            agentLog.log("panel-letter agent error: \(String(describing: err), privacy: .public)")
            return nil
        }
        if let usage = json["usage"] as? [String: Any] {
            let inT = usage["input_tokens"] as? Int ?? 0
            let outT = usage["output_tokens"] as? Int ?? 0
            CostTracker.shared.recordAsync(
                Pricing.llmCost(provider: costProvider, inputTokens: inT, outputTokens: outT))
        }
        let text = (json["content"] as? [[String: Any]])?
            .compactMap { $0["text"] as? String }.joined() ?? ""
        return Result(panels: Self.parseLetters(text), raw: text)
    }

    /// Resizes (long edge ≤ maxEdge) and JPEG-encodes to base64, to keep image
    /// tokens reasonable while staying legible.
    private static func jpegBase64(_ image: UIImage, maxEdge: CGFloat) -> String? {
        let w = image.size.width, h = image.size.height
        guard w > 0, h > 0 else { return nil }
        let scale = min(1, maxEdge / max(w, h))
        let target = CGSize(width: w * scale, height: h * scale)
        let resized = UIGraphicsImageRenderer(size: target).image { _ in
            image.draw(in: CGRect(origin: .zero, size: target))
        }
        return resized.jpegData(compressionQuality: 0.8)?.base64EncodedString()
    }

    /// Pulls the letters out of the model's JSON, tolerant of code fences or
    /// stray prose around it.
    private static func parseLetters(_ text: String) -> [String] {
        if let start = text.firstIndex(of: "{"), let end = text.lastIndex(of: "}") {
            let slice = String(text[start...end])
            if let data = slice.data(using: .utf8),
               let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let arr = obj["panels"] as? [String] {
                return arr.map { $0.lowercased() }.filter { $0.count == 1 }
            }
        }
        // Fallback: any quoted single letters.
        let ns = text as NSString
        let re = try? NSRegularExpression(pattern: "\"([A-Za-z])\"")
        return (re?.matches(in: text, range: NSRange(location: 0, length: ns.length)) ?? [])
            .map { ns.substring(with: $0.range(at: 1)).lowercased() }
    }
}
