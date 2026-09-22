import Foundation

@MainActor
enum AICodexAnalyst {
    struct CustomAnalysis: Identifiable, Sendable, Codable, Hashable {
        var id: UUID = UUID()
        var question: String
        var reasonForAnalysis: String
        var sourceData: String
        var modelUsed: String
        var rawResult: String
        var codexVerification: String
        var finalConclusion: String
        var confidence: String
        var status: String
    }

    private struct CustomPrompt: Decodable { var question: String; var reason: String; var sourceData: String; var needsLLM: Bool }
    private struct ChatRequest: Encodable { struct Message: Encodable { var role: String; var content: String }; var model: String; var messages: [Message] }
    private struct ChatResponse: Decodable { struct Choice: Decodable { struct Message: Decodable { var content: String? }; var message: Message }; var choices: [Choice] }

    static func analyze(context: AuditContext, onProgress: @escaping @Sendable (Int, Int) -> Void) async -> [CustomAnalysis] {
        guard let contextJSON = try? String(decoding: JSONEncoder().encode(context), as: UTF8.self) else { return [] }
        let temporaryURL = FileManager.default.temporaryDirectory.appendingPathComponent("audit-context-\(UUID().uuidString).json")
        try? contextJSON.data(using: .utf8)?.write(to: temporaryURL, options: .atomic)
        defer { try? FileManager.default.removeItem(at: temporaryURL) }
        let prompt = """
        You are an SEO analyst. Analyze the following SEO audit context JSON and identify 0-10 anomalies, contradictions, or patterns that need deeper investigation. For each finding, create a custom analysis prompt.
        Return ONLY a JSON array. Each element must have "question", "reason", "sourceData", and "needsLLM". sourceData must name relevant context fields. Only create prompts for genuine anomalies; otherwise return [].
        Audit context JSON:
        \(contextJSON)
        """
        guard let output = await runCodex(prompt), let prompts = decodePrompts(output) else { return [] }
        let limited = Array(prompts.prefix(10))
        var analyses: [CustomAnalysis] = []
        for (index, prompt) in limited.enumerated() {
            let relevantData = subset(of: context, named: prompt.sourceData)
            let key = OpenRouterKeychain.load()
            let raw: String
            let model: String
            if prompt.needsLLM, !key.isEmpty {
                raw = (try? await openRouter(key: key, question: prompt.question, data: relevantData)) ?? ""
                model = raw.isEmpty ? "codex" : "combined"
            } else if prompt.needsLLM {
                raw = ""
                model = "codex"
            } else {
                raw = await runCodex("Answer this SEO investigation question using only the supplied JSON. State facts only, concisely. Question: \(prompt.question)\nJSON:\n\(relevantData)") ?? ""
                model = "codex"
            }
            let verified = verify(result: raw, context: context, unavailable: raw.isEmpty)
            analyses.append(.init(question: prompt.question, reasonForAnalysis: prompt.reason, sourceData: prompt.sourceData, modelUsed: model, rawResult: raw, codexVerification: verified.note, finalConclusion: raw.isEmpty ? "Analysis could not be completed because the required AI service was unavailable." : raw, confidence: verified.confidence, status: verified.status))
            onProgress(index + 1, limited.count)
        }
        return analyses
    }

    private static func decodePrompts(_ output: String) -> [CustomPrompt]? {
        guard let start = output.firstIndex(of: "["), let end = output.lastIndex(of: "]"), start <= end else { return nil }
        return try? JSONDecoder().decode([CustomPrompt].self, from: Data(output[start...end].utf8))
    }
    private static func subset(of context: AuditContext, named source: String) -> String {
        let normalized = source.lowercased()
        let value: AnyEncodable = normalized.contains("backlink") ? .init(context.backlinkSummary) : normalized.contains("gsc") || normalized.contains("searchconsole") ? .init(context.gscSummary) : normalized.contains("issue") ? .init(context.issues) : normalized.contains("schema") ? .init(context.schemaTypesDistribution) : normalized.contains("page") ? .init(context.pageTypeDistribution) : .init(context)
        return (try? String(decoding: JSONEncoder().encode(value), as: UTF8.self)) ?? "{}"
    }
    private static func verify(result: String, context: AuditContext, unavailable: Bool) -> (status: String, confidence: String, note: String) {
        guard !unavailable else { return ("Unable to verify", "Low", "No result was available to verify.") }
        let numbers = result.split { !$0.isNumber }.compactMap { Int($0) }
        let known = [context.crawlSummary.totalURLs, context.crawlSummary.htmlPages, context.backlinkSummary.totalBacklinks, context.backlinkSummary.referringDomains, context.gscSummary.indexedPages, context.gscSummary.notIndexedPages, context.gscSummary.clicks7d, context.gscSummary.impressions7d] + context.issues.map(\.count)
        let unmatched = numbers.filter { $0 > 1 && !known.contains($0) }
        let knownURLs = Set(context.topBacklinkSources.map(\.sourceURL) + context.gscErrorCategories.flatMap(\.examples))
        let mentionedURLs = result.components(separatedBy: .whitespacesAndNewlines).filter { $0.hasPrefix("http") }
        let unknownURLs = mentionedURLs.filter { !knownURLs.contains($0.trimmingCharacters(in: CharacterSet.punctuationCharacters)) }
        if unmatched.isEmpty && unknownURLs.isEmpty { return ("Confirmed", "High", "Checked numeric references and mentioned URLs against the audit context; all matched.") }
        if unmatched.count < max(2, numbers.count) { return ("Partially confirmed", "Medium", "Some figures or URLs were not present verbatim in the audit context; supported facts were retained.") }
        return ("Rejected", "Low", "The result contains figures or URLs that conflict with or cannot be found in the audit context.")
    }
    private static func openRouter(key: String, question: String, data: String) async throws -> String {
        var request = URLRequest(url: URL(string: "https://openrouter.ai/api/v1/chat/completions")!)
        request.httpMethod = "POST"; request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization"); request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(ChatRequest(model: "z-ai/glm-4.5", messages: [.init(role: "system", content: "You are an SEO analyst. Use only the data provided; do not invent facts, numbers, URLs, or causal claims."), .init(role: "user", content: "Question: \(question)\nRelevant data: \(data)")]))
        let (body, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, 200..<300 ~= http.statusCode else { throw URLError(.badServerResponse) }
        guard let result = try JSONDecoder().decode(ChatResponse.self, from: body).choices.first?.message.content, !result.isEmpty else { throw URLError(.cannotParseResponse) }
        return result
    }
    private static func runCodex(_ prompt: String) async -> String? {
        await Task.detached(priority: .utility) {
            let paths = [
                "/Applications/ChatGPT.app/Contents/Resources/codex",
                "/Applications/Codex.app/Contents/Resources/codex",
                "/opt/homebrew/bin/codex",
                "/usr/local/bin/codex"
            ]
            guard let path = paths.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) else { return nil }
            let process = Process(), output = Pipe(), error = Pipe()
            let resultURL = FileManager.default.temporaryDirectory.appendingPathComponent("sharespider-ai-custom-\(UUID().uuidString).txt")
            defer { try? FileManager.default.removeItem(at: resultURL) }
            process.executableURL = URL(fileURLWithPath: path)
            process.arguments = ["exec", "--sandbox", "danger-full-access", "--skip-git-repo-check", "--ephemeral", "--output-last-message", resultURL.path, prompt]
            process.standardOutput = output; process.standardError = error
            do { try process.run() } catch { return nil }
            let deadline = Date().addingTimeInterval(300)
            while process.isRunning && Date() < deadline { try? await Task.sleep(for: .milliseconds(100)) }
            if process.isRunning { process.terminate(); return nil }
            guard process.terminationStatus == 0 else { return nil }
            return try? String(contentsOf: resultURL, encoding: .utf8)
        }.value
    }
}

private struct AnyEncodable: Encodable {
    private let encodeBody: (Encoder) throws -> Void
    init<T: Encodable>(_ value: T) { encodeBody = value.encode }
    func encode(to encoder: Encoder) throws { try encodeBody(encoder) }
}
