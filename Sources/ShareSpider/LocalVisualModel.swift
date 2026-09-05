import Foundation
import AppKit

/// Configuration for an optional local Ollama vision model. No screenshots leave the Mac.
struct LocalVisionSettings: Sendable {
    var enabled: Bool = true
    var endpoint = "http://127.0.0.1:11434"
    var model = "qwen2.5vl:7b"

    static func load() -> LocalVisionSettings {
        let defaults = UserDefaults.standard
        return LocalVisionSettings(
            enabled: defaults.object(forKey: "localVisionEnabled") as? Bool ?? true,
            endpoint: defaults.string(forKey: "localVisionEndpoint") ?? "http://127.0.0.1:11434",
            model: defaults.string(forKey: "localVisionModel") ?? "qwen2.5vl:7b"
        )
    }

    func save() {
        let defaults = UserDefaults.standard
        defaults.set(enabled, forKey: "localVisionEnabled")
        defaults.set(endpoint, forKey: "localVisionEndpoint")
        defaults.set(model, forKey: "localVisionModel")
    }
}

private struct OllamaGenerateRequest: Encodable {
    let model: String
    let prompt: String
    let images: [String]
    let stream = false
    let format = "json"
    let options = ["temperature": 0]
}

private struct OllamaGenerateResponse: Decodable { let response: String }
private struct VisionModelReply: Decodable {
    struct Finding: Decodable {
        let type: String
        let severity: String
        let detail: String
        let x: Double
        let y: Double
        let width: Double
        let height: Double
    }
    let issues: [Finding]
}

struct LocalVisualAnalysis: Sendable {
    var issues: [VisualIssue]
    var status: String
    var usedModel: Bool
}

enum LocalVisualModel {
    static func compare(desktop: String, mobile: String, settings: LocalVisionSettings) async -> String {
        guard settings.enabled, let endpoint = URL(string: settings.endpoint.trimmingCharacters(in: CharacterSet(charactersIn: "/")) + "/api/generate"), let desktopImage = compressedScreenshot(at: desktop), let mobileImage = compressedScreenshot(at: mobile) else { return "Comparison unavailable: local AI is disabled or screenshots could not be prepared." }
        let prompt = """
        Compare these two complete renders of the same page: image 1 is Desktop and image 2 is Mobile.
        Return JSON only: {"summary":"one concise sentence about whether the main content blocks correspond, and name any clearly missing, duplicated or extra major block"}.
        Do not flag normal responsive rearrangement.
        """
        var request = URLRequest(url: endpoint); request.httpMethod = "POST"; request.timeoutInterval = 90; request.setValue("application/json", forHTTPHeaderField: "Content-Type"); request.httpBody = try? JSONEncoder().encode(OllamaGenerateRequest(model: settings.model, prompt: prompt, images: [desktopImage, mobileImage]))
        guard let (data, response) = try? await URLSession.shared.data(for: request), let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode), let answer = try? JSONDecoder().decode(OllamaGenerateResponse.self, from: data), let object = try? JSONSerialization.jsonObject(with: Data(answer.response.utf8)) as? [String: Any], let summary = object["summary"] as? String else { return "Comparison unavailable: the local model did not return a usable conclusion." }
        return summary
    }

    static func inspect(screenshotPath: String, viewport: String, settings: LocalVisionSettings, pageWidth: Double, pageHeight: Double) async -> LocalVisualAnalysis {
        guard settings.enabled else { return LocalVisualAnalysis(issues: [], status: "AI analysis is disabled in Settings.", usedModel: false) }
        guard let endpoint = URL(string: settings.endpoint.trimmingCharacters(in: CharacterSet(charactersIn: "/")) + "/api/generate") else { return LocalVisualAnalysis(issues: [], status: "AI endpoint URL is invalid.", usedModel: false) }
        guard let image = compressedScreenshot(at: screenshotPath) else { return LocalVisualAnalysis(issues: [], status: "The screenshot could not be prepared for local AI analysis.", usedModel: false) }

        let prompt = """
        You are a strict senior QA and conversion auditor. Analyse this COMPLETE page screenshot for (viewport) only.
        Report only clearly visible, high-impact defects: blank/broken content, a blocked or unusable CTA/form/navigation,
        major overlap, text that cannot be read, a layout section clipped or cut off, horizontal mobile overflow, or a modal/overlay blocking essential content.
        Do not report normal whitespace, visual style preferences, tiny alignment differences, repeated items, or anything not clearly visible.
        Return JSON only: {"issues":[{"type":"short label","severity":"Critical|High","detail":"concrete visible impact","x":0-1000,"y":0-1000,"width":0-1000,"height":0-1000}]}.
        Coordinates must be normalized to the complete image: x/y are the top-left point, width/height define the affected rectangle.
        If there is no critical visible defect, return {"issues":[]}.
        """
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.timeoutInterval = 90
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try? JSONEncoder().encode(OllamaGenerateRequest(model: settings.model, prompt: prompt, images: [image]))
        guard let (data, response) = try? await URLSession.shared.data(for: request) else {
            return LocalVisualAnalysis(issues: [], status: "AI unavailable: Ollama is not responding at \(settings.endpoint). Start Ollama and install \(settings.model).", usedModel: false)
        }
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            let text = String(data: data, encoding: .utf8) ?? "unknown error"
            return LocalVisualAnalysis(issues: [], status: "AI unavailable: Ollama returned HTTP \((response as? HTTPURLResponse)?.statusCode ?? 0) (\(text.prefix(140))).", usedModel: false)
        }
        guard let answer = try? JSONDecoder().decode(OllamaGenerateResponse.self, from: data), let reply = decodeReply(answer.response) else {
            return LocalVisualAnalysis(issues: [], status: "AI response could not be decoded as the required visual-audit JSON.", usedModel: false)
        }
        let issues = reply.issues.prefix(12).map { finding in
            VisualIssue(
                type: finding.type,
                detail: "\(finding.severity): \(finding.detail)",
                viewport: viewport,
                selector: "Local vision model",
                x: clamp(finding.x) / 1000 * pageWidth,
                y: clamp(finding.y) / 1000 * pageHeight,
                width: max(20, clamp(finding.width) / 1000 * pageWidth),
                height: max(20, clamp(finding.height) / 1000 * pageHeight),
                source: "Local model"
            )
        }
        return LocalVisualAnalysis(issues: issues, status: "AI analysed this full-page \(viewport) render with \(settings.model). \(issues.count) critical finding(s).", usedModel: true)
    }

    private static func decodeReply(_ raw: String) -> VisionModelReply? {
        if let data = raw.data(using: .utf8), let reply = try? JSONDecoder().decode(VisionModelReply.self, from: data) { return reply }
        guard let start = raw.firstIndex(of: "{"), let end = raw.lastIndex(of: "}") else { return nil }
        return try? JSONDecoder().decode(VisionModelReply.self, from: Data(raw[start...end].utf8))
    }

    private static func clamp(_ value: Double) -> Double { min(1000, max(0, value)) }

    /// Downscale only the AI input. Report evidence keeps the original WebKit resolution.
    /// qwen2.5vl:7b defaults to a 4096-token context; a Retina desktop viewport at 1440×900
    /// otherwise exceeds that budget before the prompt is added.
    private static func compressedScreenshot(at path: String) -> String? {
        guard let source = NSImage(contentsOfFile: path) else { return nil }
        let ratio = min(1, 960 / max(source.size.width, source.size.height))
        let target = CGSize(width: max(1, source.size.width * ratio), height: max(1, source.size.height * ratio))
        let output = NSImage(size: target)
        output.lockFocus()
        source.draw(in: CGRect(origin: .zero, size: target), from: .zero, operation: .copy, fraction: 1)
        output.unlockFocus()
        guard let data = output.tiffRepresentation,
              let jpeg = NSBitmapImageRep(data: data)?.representation(using: .jpeg, properties: [.compressionFactor: 0.62]) else { return nil }
        return jpeg.base64EncodedString()
    }
}
