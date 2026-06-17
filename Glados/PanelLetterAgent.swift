import Foundation
import UIKit
import os

let agentLog = Logger(subsystem: "com.borr.scifm", category: "agents")

/// The app's first LLM "agent": a focused, single-purpose Claude vision call that
/// finds the panel-label letters (a, b, c, …) in a scientific figure and returns
/// each letter with its bounding box, so it can drive overlays and cropping.
actor PanelLetterAgent {
    static let shared = PanelLetterAgent()

    /// One located panel label. `box` is normalized to the image (0–1, top-left origin).
    struct Panel {
        let letter: String
        let box: CGRect
    }

    struct Result {
        let panels: [Panel]
        let raw: String          // raw model text, for debugging
        var letters: [String] { panels.map(\.letter) }
    }

    /// Vision model. Opus reads small panel labels (and locates them) most
    /// reliably; change to "claude-haiku-4-5" for cheaper/faster runs.
    private let model = "claude-opus-4-8"
    private var costProvider: LLMProviderType { model.contains("haiku") ? .haiku : .opus }

    private static let prompt = """
    This image is a figure from a scientific paper, made up of multiple sub-panels. \
    Each sub-panel is marked with a small letter label (usually a lowercase a, b, c, … \
    at the panel's top-left corner). Find those panel-label letters. Respond with ONLY \
    JSON of the form:
    {"panels":[{"letter":"a","x":0.01,"y":0.02,"w":0.03,"h":0.04}]}
    where, for each letter, x and y are the top-left corner of that letter's bounding \
    box and w and h are its width and height — all as fractions of the image's width and \
    height (0 to 1, with the origin at the top-left of the image). List them in reading \
    order, lowercased. If the figure has no panel labels, return {"panels":[]}. Output \
    nothing except the JSON.
    """

    /// Runs the agent on a figure image. nil if the Anthropic key is missing or
    /// the request fails.
    func identifyPanels(in image: UIImage) async -> Result? {
        guard let apiKey = Keychain.get("anthropicAPIKey"), !apiKey.isEmpty else {
            agentLog.log("panel-letter agent: no anthropic key")
            return nil
        }
        guard let b64 = Self.jpegBase64(image, maxEdge: 1536) else { return nil }

        let body: [String: Any] = [
            "model": model,
            "max_tokens": 600,
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
        return Result(panels: Self.parse(text), raw: text)
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

    /// Parses the model's JSON into located panels, tolerant of code fences,
    /// stray prose, and 0–1000 vs 0–1 coordinate scales.
    private static func parse(_ text: String) -> [Panel] {
        guard let start = text.firstIndex(of: "{"), let end = text.lastIndex(of: "}") else { return [] }
        let slice = String(text[start...end])
        guard let data = slice.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let arr = obj["panels"] as? [[String: Any]] else { return [] }
        return arr.compactMap { p in
            guard let letter = (p["letter"] as? String)?.lowercased(), letter.count == 1,
                  var x = num(p["x"]), var y = num(p["y"]),
                  var w = num(p["w"]), var h = num(p["h"]) else { return nil }
            // Some models answer in a 0–1000 scale; normalize to fractions.
            if max(x, y, max(w, h)) > 1.5 { x /= 1000; y /= 1000; w /= 1000; h /= 1000 }
            guard w > 0, h > 0 else { return nil }
            return Panel(letter: letter, box: CGRect(x: x, y: y, width: w, height: h))
        }
    }

    private static func num(_ v: Any?) -> CGFloat? {
        if let d = v as? Double { return CGFloat(d) }
        if let i = v as? Int { return CGFloat(i) }
        if let s = v as? String, let d = Double(s) { return CGFloat(d) }
        return nil
    }
}
