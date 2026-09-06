import Foundation

@MainActor
enum AIAuditAnalyzer {
    static func analyze(data: AIAuditReportData, startURL: String, records: [CrawlRecord], overview: [OverviewItem], issues: [Issue], referringDomainDetails: [ReferringDomainDetail], backlinkSourceDetails: [BacklinkSourceDetail], onStage: ((AIAuditStage) -> Void)? = nil) async -> AIAuditReport {
        guard let key = ProcessInfo.processInfo.environment["OPENROUTER_API_KEY"], !key.isEmpty else { onStage?(.complete); return fallback(data: data, startURL: startURL, reason: "AI-анализ недоступен: OPENROUTER_API_KEY не настроен.") }
        onStage?(.linkAnalysis)
        let backlink = await analysis(for: data.backlinkProfile, key: key, instruction: "Проанализируй ссылочный профиль сайта: сильные стороны, риски и приоритеты. Используй только переданные цифры и URL.", fallback: "Анализ ссылочного профиля через OpenRouter не выполнен; используйте структурированные данные отчёта.")
        onStage?(.technicalAnalysis)
        let technical = await analysis(for: data.technicalErrors, key: key, instruction: "Проанализируй технические SEO-проблемы краула и приоритизируй их. Опирайся только на переданные цифры, типы страниц и URL.", fallback: "Технический AI-анализ не выполнен; используйте структурированные данные отчёта.")
        onStage?(.gscAnalysis)
        let gsc = await analysis(for: data.searchConsoleErrors, key: key, instruction: "Проанализируй ошибки Google Search Console и связанные сведения краула. Опирайся только на переданные данные.", fallback: "AI-анализ Search Console не выполнен; используйте структурированные данные отчёта.")
        onStage?(.executiveSummary)
        let summary = await executiveSummary(backlink: backlink, technical: technical, gsc: gsc, key: key)
        onStage?(.codexAnalysis)
        let context = AuditContext.form(siteURL: startURL, records: records, overview: overview, issues: issues, backlinkSummary: data.backlinkSummary, referringDomainDetails: referringDomainDetails, backlinkSourceDetails: backlinkSourceDetails, gscSummary: data.searchConsoleSummary, gscErrorCategories: data.searchConsoleErrors.errors, backlinkAnalysis: backlink, technicalAnalysis: technical, searchConsoleAnalysis: gsc, crawlSummary: data.crawlSummary)
        if let encoded = try? JSONEncoder().encode(context) { AutomationBridge.writeAIAuditContext(encoded) }
        onStage?(.verification)
        let custom = await AICodexAnalyst.analyze(context: context) { _, _ in }
        onStage?(.executiveSummary)
        let verified = await verifiedSummary(backlink: backlink, technical: technical, gsc: gsc, analyses: custom, key: key)
        onStage?(.complete)
        return makeReport(data: data, startURL: startURL, backlink: backlink, technical: technical, gsc: gsc, summary: summary, customAnalyses: custom, verifiedSummary: verified)
    }

    private static func analysis<T: Encodable>(for block: T, key: String, instruction: String, fallback: String) async -> String {
        do { return try await request(key: key, system: "Ты эксперт по SEO-аудитам. Отвечай только по-русски, обычным текстом, без JSON. Не придумывай факты, цифры или URL. \(instruction)", user: String(decoding: try JSONEncoder().encode(block), as: UTF8.self)) } catch { return fallback }
    }
    private static func executiveSummary(backlink: String, technical: String, gsc: String, key: String) async -> String {
        do { return try await request(key: key, system: "Ты эксперт по SEO-аудитам. Напиши один краткий абзац на русском с executive summary, объединяющий три переданных анализа. Не добавляй фактов, которых в них нет.", user: "Ссылочный профиль:\n\(backlink)\n\nТехнический анализ:\n\(technical)\n\nSearch Console:\n\(gsc)") } catch { return "AI-итог не сформирован. Приоритеты определены по данным ссылочного профиля, технического краула и Search Console." }
    }
    private static func verifiedSummary(backlink: String, technical: String, gsc: String, analyses: [AICodexAnalyst.CustomAnalysis], key: String) async -> String {
        let confirmed = analyses.filter { $0.status == "Confirmed" || $0.status == "Partially confirmed" }
        let rejected = analyses.filter { $0.status == "Rejected" }
        let user = "Fixed analyses:\n\(backlink)\n\n\(technical)\n\n\(gsc)\n\nConfirmed findings:\n\(confirmed.map { "• \($0.question): \($0.finalConclusion)" }.joined(separator: "\n"))\n\nRejected findings (do not state as facts):\n\(rejected.map(\.question).joined(separator: "\n"))"
        do { return try await request(key: key, system: "You are an SEO analyst. Based on the verified findings below, provide a 3-5 point verified summary with key findings, systemic problems, likely causes, fix priorities, and what is confirmed by facts versus probable interpretation. Respond in Russian. Do not present rejected findings as facts.", user: user) } catch { return "Проверенный итог не сформирован. Используйте подтверждённые выводы Codex Deep Analysis вместе с базовыми разделами аудита." }
    }
    private static func request(key: String, system: String, user: String) async throws -> String {
        var request = URLRequest(url: URL(string: "https://openrouter.ai/api/v1/chat/completions")!)
        request.httpMethod = "POST"
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization"); request.setValue("application/json", forHTTPHeaderField: "Content-Type"); request.setValue("https://sharespider.app", forHTTPHeaderField: "HTTP-Referer"); request.setValue("ShareSpider AI Audit", forHTTPHeaderField: "X-Title")
        request.httpBody = try JSONEncoder().encode(ChatRequest(model: "z-ai/glm-4.5", messages: [.init(role: "system", content: system), .init(role: "user", content: user)]))
        let (body, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, 200..<300 ~= http.statusCode else { throw AnalysisError.requestFailed }
        guard let content = try JSONDecoder().decode(ChatResponse.self, from: body).choices.first?.message.content?.trimmingCharacters(in: .whitespacesAndNewlines), !content.isEmpty else { throw AnalysisError.emptyResponse }
        return content
    }
    private static func makeReport(data: AIAuditReportData, startURL: String, backlink: String, technical: String, gsc: String, summary: String, customAnalyses: [AICodexAnalyst.CustomAnalysis] = [], verifiedSummary: String = "") -> AIAuditReport {
        AIAuditReport(siteURL: startURL, generatedAt: Date(), backlinkAnalysis: backlink, technicalAnalysis: technical, searchConsoleAnalysis: gsc, executiveSummary: summary, findings: fixedFindings(data), crawlSummary: data.crawlSummary, backlinkSummary: data.backlinkSummary, searchConsoleSummary: data.searchConsoleSummary, backlinkProfileDetail: data.backlinkProfile, technicalIssuesDetail: data.technicalErrors, searchConsoleErrorsDetail: data.searchConsoleErrors, customAnalyses: customAnalyses, verifiedSummary: verifiedSummary)
    }
    private static func fixedFindings(_ data: AIAuditReportData) -> [AIAuditFinding] {
        var findings = data.technicalErrors.issues.prefix(8).map { AIAuditFinding(title: $0.name, severity: severity($0.priority), category: $0.type, summary: "Затронуто URL: \($0.count) (\(String(format: "%.1f", $0.percentage))%).", affectedURLs: $0.examples, recommendation: "Проверьте примеры URL и устраните указанную техническую проблему.") }
        if data.backlinkSummary.pagesWithoutBacklinks > 0 { findings.append(.init(title: "Страницы без внешних ссылок", severity: "Medium", category: "Backlinks", summary: "Без обратных ссылок: \(data.backlinkSummary.pagesWithoutBacklinks) из \(data.backlinkSummary.totalEligiblePages) страниц.", affectedURLs: Array(data.backlinkProfile.pagesWithoutBacklinks.prefix(5)), recommendation: "Приоритизируйте важные страницы для аутрича и цифрового PR.")) }
        if data.searchConsoleSummary.notIndexedPages > 0 { findings.append(.init(title: "Неиндексируемые страницы", severity: "High", category: "Search Console", summary: "GSC сообщает о \(data.searchConsoleSummary.notIndexedPages) неиндексируемых страницах.", affectedURLs: data.searchConsoleErrors.errors.first(where: { $0.type.hasPrefix("Не проиндексировано") })?.examples ?? [], recommendation: "Проверьте причины исключения, canonical и возможность обхода, затем запросите валидацию в GSC.")) }
        return findings
    }
    private static func fallback(data: AIAuditReportData, startURL: String, reason: String) -> AIAuditReport {
        let backlink = "Профиль: DR \(data.backlinkSummary.domainRank), \(data.backlinkSummary.totalBacklinks) ссылок с \(data.backlinkSummary.referringDomains) доменов; dofollow — \(data.backlinkSummary.dofollowBacklinks), nofollow — \(data.backlinkSummary.nofollowBacklinks), битых — \(data.backlinkSummary.brokenBacklinks), spam score — \(data.backlinkSummary.spamScore)."
        let technical = data.technicalErrors.issues.isEmpty ? "Технические ошибки в доступных данных не обнаружены." : "В крауле обнаружено \(data.technicalErrors.issues.count) типов проблем; наиболее заметные: \(data.technicalErrors.issues.prefix(3).map { "\($0.name) (\($0.count))" }.joined(separator: ", "))."
        let gsc = data.searchConsoleSummary.available ? "Проверено страниц: индексировано \(data.searchConsoleSummary.indexedPages), не индексировано \(data.searchConsoleSummary.notIndexedPages), ошибок покрытия/fetch — \(data.searchConsoleSummary.coverageErrors), мобильных проблем — \(data.searchConsoleSummary.mobileUsabilityIssues)." : data.searchConsoleSummary.unavailableReason
        return makeReport(data: data, startURL: startURL, backlink: backlink, technical: technical, gsc: gsc, summary: "\(reason) Приоритеты определены по данным ссылочного профиля, технического краула и Search Console.")
    }
    private static func severity(_ value: String) -> String { ["High", "Medium", "Low"].contains(value.capitalized) ? value.capitalized : "Medium" }
}

private extension AIAuditAnalyzer {
    struct ChatRequest: Encodable { struct Message: Encodable { var role: String; var content: String }; var model: String; var messages: [Message] }
    struct ChatResponse: Decodable { struct Choice: Decodable { struct Message: Decodable { var content: String? }; var message: Message }; var choices: [Choice] }
    enum AnalysisError: Error { case requestFailed, emptyResponse }
}
