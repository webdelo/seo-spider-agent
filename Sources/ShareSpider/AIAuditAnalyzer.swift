import Foundation

enum AIAuditAnalyzer {
    static func analyze(data: AIAuditReportData, startURL: String) async -> AIAuditReport {
        guard let key = ProcessInfo.processInfo.environment["OPENROUTER_API_KEY"], !key.isEmpty else { return fallback(data: data, startURL: startURL, reason: "AI-анализ недоступен: OPENROUTER_API_KEY не настроен.") }
        do {
            let source = try JSONEncoder().encode(Payload(data: data))
            var request = URLRequest(url: URL(string: "https://openrouter.ai/api/v1/chat/completions")!)
            request.httpMethod = "POST"
            request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.setValue("https://sharespider.app", forHTTPHeaderField: "HTTP-Referer")
            request.setValue("ShareSpider AI Audit", forHTTPHeaderField: "X-Title")
            request.httpBody = try JSONEncoder().encode(ChatRequest(model: "z-ai/glm-4.5", messages: [
                .init(role: "system", content: "You are an expert SEO auditor. You will receive 3 blocks of structured data: (1) backlink profile, (2) technical crawl errors, (3) Google Search Console errors. For each block, write a concise analytical commentary in Russian, grounded in the actual numbers and examples. Then produce a final one-paragraph executive summary. Return ONLY valid JSON with this structure: {\"backlinkAnalysis\": string, \"technicalAnalysis\": string, \"searchConsoleAnalysis\": string, \"executiveSummary\": string, \"findings\": [{\"title\": string, \"severity\": \"High|Medium|Low\", \"category\": string, \"summary\": string, \"affectedURLs\": [string], \"recommendation\": string}]}. Do not invent facts or URLs."),
                .init(role: "user", content: String(decoding: source, as: UTF8.self))
            ]))
            let (body, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse, 200..<300 ~= http.statusCode else { throw AnalysisError.requestFailed }
            guard let content = try JSONDecoder().decode(ChatResponse.self, from: body).choices.first?.message.content else { throw AnalysisError.emptyResponse }
            let clean = content.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: "```json", with: "").replacingOccurrences(of: "```", with: "").trimmingCharacters(in: .whitespacesAndNewlines)
            let result = try JSONDecoder().decode(LLMReport.self, from: Data(clean.utf8))
            guard !result.backlinkAnalysis.isEmpty || !result.technicalAnalysis.isEmpty || !result.searchConsoleAnalysis.isEmpty || !result.executiveSummary.isEmpty else { throw AnalysisError.emptyResponse }
            return makeReport(data: data, startURL: startURL, backlink: result.backlinkAnalysis, technical: result.technicalAnalysis, gsc: result.searchConsoleAnalysis, summary: result.executiveSummary, findings: result.findings)
        } catch { return fallback(data: data, startURL: startURL, reason: "AI-анализ через OpenRouter не выполнен; показан отчёт на основе собранных данных.") }
    }

    private static func makeReport(data: AIAuditReportData, startURL: String, backlink: String, technical: String, gsc: String, summary: String, findings: [LLMReport.Finding]) -> AIAuditReport {
        AIAuditReport(siteURL: startURL, generatedAt: Date(), backlinkAnalysis: backlink, technicalAnalysis: technical, searchConsoleAnalysis: gsc, executiveSummary: summary, findings: findings.prefix(12).map { .init(title: $0.title, severity: severity($0.severity), category: $0.category, summary: $0.summary, affectedURLs: Array($0.affectedURLs.prefix(5)), recommendation: $0.recommendation) }, crawlSummary: data.crawlSummary, backlinkSummary: data.backlinkSummary, searchConsoleSummary: data.searchConsoleSummary)
    }
    private static func fallback(data: AIAuditReportData, startURL: String, reason: String) -> AIAuditReport {
        var findings = data.technicalErrors.issues.prefix(8).map { AIAuditFinding(title: $0.name, severity: severity($0.priority), category: $0.type, summary: "Затронуто URL: \($0.count).", affectedURLs: $0.examples, recommendation: "Проверьте примеры URL и устраните указанную техническую проблему.") }
        if data.backlinkSummary.pagesWithoutBacklinks > 0 { findings.append(.init(title: "Страницы без внешних ссылок", severity: "Medium", category: "Backlinks", summary: "Без обратных ссылок: \(data.backlinkSummary.pagesWithoutBacklinks) из \(data.backlinkSummary.totalEligiblePages) страниц.", affectedURLs: Array(data.backlinkProfile.pagesWithoutBacklinks.prefix(5)), recommendation: "Приоритизируйте важные страницы для аутрича и цифрового PR.")) }
        if data.searchConsoleSummary.notIndexedPages > 0 { findings.append(.init(title: "Неиндексируемые страницы", severity: "High", category: "Search Console", summary: "GSC сообщает о \(data.searchConsoleSummary.notIndexedPages) неиндексируемых страницах.", affectedURLs: data.searchConsoleErrors.errors.first(where: { $0.type.hasPrefix("Не проиндексировано") })?.examples ?? [], recommendation: "Проверьте причины исключения, canonical и возможность обхода, затем запросите валидацию в GSC.")) }
        let backlink = "Профиль: DR \(data.backlinkSummary.domainRank), \(data.backlinkSummary.totalBacklinks) ссылок с \(data.backlinkSummary.referringDomains) доменов; dofollow — \(data.backlinkSummary.dofollowBacklinks), nofollow — \(data.backlinkSummary.nofollowBacklinks), битых — \(data.backlinkSummary.brokenBacklinks), spam score — \(data.backlinkSummary.spamScore)."
        let technical = data.technicalErrors.issues.isEmpty ? "Технические ошибки в доступных данных не обнаружены." : "В крауле обнаружено \(data.technicalErrors.issues.count) типов проблем; наиболее заметные: \(data.technicalErrors.issues.prefix(3).map { "\($0.name) (\($0.count))" }.joined(separator: ", "))."
        let gsc = data.searchConsoleSummary.available ? "Проверено страниц: индексировано \(data.searchConsoleSummary.indexedPages), не индексировано \(data.searchConsoleSummary.notIndexedPages), ошибок покрытия/fetch — \(data.searchConsoleSummary.coverageErrors), мобильных проблем — \(data.searchConsoleSummary.mobileUsabilityIssues)." : data.searchConsoleSummary.unavailableReason
        let fallbackFindings = findings.map { LLMReport.Finding(title: $0.title, severity: $0.severity, category: $0.category, summary: $0.summary, affectedURLs: $0.affectedURLs, recommendation: $0.recommendation) }
        return makeReport(data: data, startURL: startURL, backlink: backlink, technical: technical, gsc: gsc, summary: "\(reason) Приоритеты определены по данным ссылочного профиля, технического краула и Search Console.", findings: fallbackFindings)
    }
    private static func severity(_ value: String) -> String { ["High", "Medium", "Low"].contains(value.capitalized) ? value.capitalized : "Medium" }
}

private extension AIAuditAnalyzer {
    struct Payload: Encodable { var backlinkProfile: AIAuditBacklinkBlock; var technicalErrors: AIAuditTechnicalBlock; var searchConsoleErrors: AIAuditSearchConsoleBlock; init(data: AIAuditReportData) { backlinkProfile = data.backlinkProfile; technicalErrors = data.technicalErrors; searchConsoleErrors = data.searchConsoleErrors } }
    struct ChatRequest: Encodable { struct Message: Encodable { var role: String; var content: String }; var model: String; var messages: [Message] }
    struct ChatResponse: Decodable { struct Choice: Decodable { struct Message: Decodable { var content: String? }; var message: Message }; var choices: [Choice] }
    struct LLMReport: Decodable { struct Finding: Decodable { var title: String; var severity: String; var category: String; var summary: String; var affectedURLs: [String]; var recommendation: String }; var backlinkAnalysis: String; var technicalAnalysis: String; var searchConsoleAnalysis: String; var executiveSummary: String; var findings: [Finding] }
    enum AnalysisError: Error { case requestFailed, emptyResponse }
}
