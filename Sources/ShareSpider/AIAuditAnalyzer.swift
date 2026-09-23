import Foundation

@MainActor
enum AIAuditAnalyzer {
    static func analyze(data: AIAuditReportData, startURL: String, records: [CrawlRecord], overview: [OverviewItem], issues: [Issue], referringDomainDetails: [ReferringDomainDetail], backlinkSourceDetails: [BacklinkSourceDetail], userBrief: AIAuditBrief = .init(), onStage: ((AIAuditStage) -> Void)? = nil) async -> AIAuditReport {
        let provider = AIProviderSettings.load().provider
        let key = OpenRouterKeychain.load()
        guard provider != .openRouter || !key.isEmpty else { onStage?(.complete); return fallback(data: data, startURL: startURL, reason: "AI-анализ недоступен: выбран OpenRouter, но API-ключ не настроен. Добавьте его в Settings → OpenRouter.") }
        onStage?(.linkAnalysis)
        let backlink = await analysis(for: data.backlinkProfile, provider: provider, key: key, instruction: "Проанализируй ссылочный профиль сайта: сильные стороны, риски и приоритеты. Используй только переданные цифры и URL.", fallback: "AI-анализ ссылочного профиля не выполнен; используйте структурированные данные отчёта.")
        onStage?(.technicalAnalysis)
        let technical = await analysis(for: data.technicalErrors, provider: provider, key: key, instruction: "Проанализируй технические SEO-проблемы краула и приоритизируй их. Опирайся только на переданные цифры, типы страниц и URL.", fallback: "Технический AI-анализ не выполнен; используйте структурированные данные отчёта.")
        onStage?(.gscAnalysis)
        let gsc = await analysis(for: data.searchConsoleErrors, provider: provider, key: key, instruction: "Проанализируй ошибки Google Search Console и связанные сведения краула. Опирайся только на переданные данные.", fallback: "AI-анализ Search Console не выполнен; используйте структурированные данные отчёта.")
        onStage?(.executiveSummary)
        let summary = await executiveSummary(backlink: backlink, technical: technical, gsc: gsc, provider: provider, key: key)
        onStage?(.agentAnalysis)
        let context = AuditContext.form(siteURL: startURL, records: records, overview: overview, issues: issues, backlinkSummary: data.backlinkSummary, referringDomainDetails: referringDomainDetails, backlinkSourceDetails: backlinkSourceDetails, gscSummary: data.searchConsoleSummary, gscErrorCategories: data.searchConsoleErrors.errors, pageMetrics: data.technicalErrors.pageMetrics, backlinkAnalysis: backlink, technicalAnalysis: technical, searchConsoleAnalysis: gsc, crawlSummary: data.crawlSummary, userBrief: userBrief)
        if let encoded = try? JSONEncoder().encode(context) { AutomationBridge.writeAIAuditContext(encoded) }
        let holistic = await holisticOpinion(context: context, provider: provider, key: key)
        let developerBrief = userBrief.scenarios.contains(where: { $0.localizedCaseInsensitiveContains("минималистичный текст для разработчика") })
            ? await developerTaskBrief(context: context, provider: provider, key: key)
            : ""
        let custom: [AICodexAnalyst.CustomAnalysis]
        switch AIProviderSettings.load().agent {
        case .codex:
            custom = await AICodexAnalyst.analyze(context: context, holisticOpinion: holistic) { _, _ in }
        case .hermes:
            custom = await HermesConnector.shared.analyze(context: context, records: records)
        }
        onStage?(.verification)
        onStage?(.executiveSummary)
        let verified = await verifiedSummary(backlink: backlink, technical: technical, gsc: gsc, analyses: custom, provider: provider, key: key)
        onStage?(.complete)
        return makeReport(data: data, startURL: startURL, backlink: backlink, technical: technical, gsc: gsc, summary: summary, holisticOpinion: holistic, developerBrief: developerBrief, customAnalyses: custom, verifiedSummary: verified)
    }

    private static func analysis<T: Encodable>(for block: T, provider: AIProvider, key: String, instruction: String, fallback: String) async -> String {
        do { return try await request(provider: provider, key: key, system: "Ты эксперт по SEO-аудитам. Отвечай только по-русски, обычным текстом, без JSON. Не придумывай факты, цифры или URL. \(instruction)", user: String(decoding: try JSONEncoder().encode(block), as: UTF8.self)) } catch { return fallback }
    }
    private static func executiveSummary(backlink: String, technical: String, gsc: String, provider: AIProvider, key: String) async -> String {
        do { return try await request(provider: provider, key: key, system: "Ты эксперт по SEO-аудитам. Напиши один краткий абзац на русском с executive summary, объединяющий три переданных анализа. Не добавляй фактов, которых в них нет.", user: "Ссылочный профиль:\n\(backlink)\n\nТехнический анализ:\n\(technical)\n\nSearch Console:\n\(gsc)") } catch { return "AI-итог не сформирован. Приоритеты определены по данным ссылочного профиля, технического краула и Search Console." }
    }
    private static func holisticOpinion(context: AuditContext, provider: AIProvider, key: String) async -> String {
        guard let json = try? String(decoding: JSONEncoder().encode(context), as: UTF8.self) else { return "" }
        let system = "Ты ведущий SEO-стратег. Дай цельное мнение о сайте по ПОЛНОМУ контексту аудита и пользовательскому брифу. Ответь по-русски: 1) что видно в данных, 2) наиболее вероятные причины/риски с пометкой, где это гипотеза, 3) приоритет следующих действий. Не выдумывай фактов, цифр или URL. Если приложен файл позиций, используй его только как дополнительный контекст."
        return (try? await request(provider: provider, key: key, system: system, user: json)) ?? "Цельное мнение не сформировано: используйте структурированные разделы аудита и добавьте доступный AI-провайдер в Settings."
    }
    private static func developerTaskBrief(context: AuditContext, provider: AIProvider, key: String) async -> String {
        guard let json = try? String(decoding: JSONEncoder().encode(context), as: UTF8.self) else { return "" }
        let system = "Ты технический SEO-лид. По полному контексту составь минималистичный текст для разработчика: только подтверждённые технические ошибки, 3–12 коротких пунктов. Для каждого: что исправить, где (примеры URL/тип страниц, только если есть в данных), критерий готовности. Не включай гипотезы, маркетинговые советы, ссылки или цифры, которых нет в данных. Ответь по-русски."
        return (try? await request(provider: provider, key: key, system: system, user: json)) ?? "Текст для разработчика не сформирован: AI-провайдер недоступен. Используйте раздел технических ошибок аудита."
    }
    private static func verifiedSummary(backlink: String, technical: String, gsc: String, analyses: [AICodexAnalyst.CustomAnalysis], provider: AIProvider, key: String) async -> String {
        let confirmed = analyses.filter { $0.status == "Confirmed" || $0.status == "Partially confirmed" }
        let rejected = analyses.filter { $0.status == "Rejected" }
        let user = "Fixed analyses:\n\(backlink)\n\n\(technical)\n\n\(gsc)\n\nConfirmed findings:\n\(confirmed.map { "• \($0.question): \($0.finalConclusion)" }.joined(separator: "\n"))\n\nRejected findings (do not state as facts):\n\(rejected.map(\.question).joined(separator: "\n"))"
        do { return try await request(provider: provider, key: key, system: "You are an SEO analyst. Based on the verified findings below, provide a 3-5 point verified summary with key findings, systemic problems, likely causes, fix priorities, and what is confirmed by facts versus probable interpretation. Respond in Russian. Do not present rejected findings as facts.", user: user) } catch { return "Проверенный итог не сформирован. Используйте подтверждённые выводы AI вместе с базовыми разделами аудита." }
    }
    private static func request(provider: AIProvider, key: String, system: String, user: String) async throws -> String {
        switch provider {
        case .openRouter: return try await openRouterRequest(key: key, system: system, user: user)
        case .codex: return try await codexRequest(system: system, user: user)
        case .ollama: return try await ollamaRequest(system: system, user: user)
        }
    }
    private static func openRouterRequest(key: String, system: String, user: String) async throws -> String {
        var request = URLRequest(url: URL(string: "https://openrouter.ai/api/v1/chat/completions")!)
        request.httpMethod = "POST"
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization"); request.setValue("application/json", forHTTPHeaderField: "Content-Type"); request.setValue("https://sharespider.app", forHTTPHeaderField: "HTTP-Referer"); request.setValue("ShareSpider AI Audit", forHTTPHeaderField: "X-Title")
        request.httpBody = try JSONEncoder().encode(ChatRequest(model: "z-ai/glm-4.5", messages: [.init(role: "system", content: system), .init(role: "user", content: user)]))
        let (body, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, 200..<300 ~= http.statusCode else { throw AnalysisError.requestFailed }
        guard let content = try JSONDecoder().decode(ChatResponse.self, from: body).choices.first?.message.content?.trimmingCharacters(in: .whitespacesAndNewlines), !content.isEmpty else { throw AnalysisError.emptyResponse }
        return content
    }
    private static func ollamaRequest(system: String, user: String) async throws -> String {
        let settings = LocalVisionSettings.load()
        guard let endpoint = URL(string: settings.endpoint.trimmingCharacters(in: CharacterSet(charactersIn: "/")) + "/api/generate") else { throw AnalysisError.requestFailed }
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"; request.timeoutInterval = 180
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(OllamaTextRequest(model: settings.model, prompt: "\(system)\n\n\(user)"))
        let (body, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, 200..<300 ~= http.statusCode else { throw AnalysisError.requestFailed }
        let content = try JSONDecoder().decode(OllamaTextResponse.self, from: body).response.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !content.isEmpty else { throw AnalysisError.emptyResponse }
        return content
    }
    private static func codexRequest(system: String, user: String) async throws -> String {
        let prompt = "\(system)\n\n\(user)"
        guard let answer = await Task.detached(priority: .utility, operation: {
            guard let executable = codexExecutableURL() else { return nil as String? }
            let process = Process(), output = Pipe()
            let resultURL = FileManager.default.temporaryDirectory.appendingPathComponent("sharespider-ai-\(UUID().uuidString).txt")
            defer { try? FileManager.default.removeItem(at: resultURL) }
            process.executableURL = executable
            // Finder-launched applications do not inherit a shell PATH.  Run the
            // installed Codex binary directly and ask it to write only its final
            // message, rather than the CLI session log, to the audit.
            process.arguments = ["exec", "--sandbox", "danger-full-access", "--skip-git-repo-check", "--ephemeral", "--output-last-message", resultURL.path, prompt]
            process.standardOutput = output
            do { try process.run() } catch { return nil }
            let deadline = Date().addingTimeInterval(300)
            while process.isRunning && Date() < deadline { try? await Task.sleep(for: .milliseconds(100)) }
            if process.isRunning { process.terminate(); return nil as String? }
            guard process.terminationStatus == 0 else { return nil }
            return try? String(contentsOf: resultURL, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
        }).value, !answer.isEmpty else { throw AnalysisError.requestFailed }
        return answer
    }
    private nonisolated static func codexExecutableURL() -> URL? {
        let paths = [
            "/Applications/ChatGPT.app/Contents/Resources/codex",
            "/Applications/Codex.app/Contents/Resources/codex",
            "/opt/homebrew/bin/codex",
            "/usr/local/bin/codex"
        ]
        return paths.first(where: { FileManager.default.isExecutableFile(atPath: $0) }).map(URL.init(fileURLWithPath:))
    }
    private static func makeReport(data: AIAuditReportData, startURL: String, backlink: String, technical: String, gsc: String, summary: String, holisticOpinion: String = "", developerBrief: String = "", customAnalyses: [AICodexAnalyst.CustomAnalysis] = [], verifiedSummary: String = "") -> AIAuditReport {
        AIAuditReport(siteURL: startURL, generatedAt: Date(), backlinkAnalysis: backlink, technicalAnalysis: technical, searchConsoleAnalysis: gsc, executiveSummary: summary, holisticOpinion: holisticOpinion, developerBrief: developerBrief, findings: fixedFindings(data), crawlSummary: data.crawlSummary, backlinkSummary: data.backlinkSummary, searchConsoleSummary: data.searchConsoleSummary, backlinkProfileDetail: data.backlinkProfile, technicalIssuesDetail: data.technicalErrors, searchConsoleErrorsDetail: data.searchConsoleErrors, customAnalyses: customAnalyses, verifiedSummary: verifiedSummary)
    }
    private static func fixedFindings(_ data: AIAuditReportData) -> [AIAuditFinding] {
        var findings = data.technicalErrors.issues.prefix(8).map { AIAuditFinding(title: $0.name, severity: severity($0.priority), category: $0.type, summary: "Затронуто URL: \($0.count) (\(String(format: "%.1f", $0.percentage))%).", affectedURLs: $0.examples, recommendation: "Проверьте примеры URL и устраните указанную техническую проблему.") }
        if data.backlinkSummary.pagesWithoutBacklinks > 0 { findings.append(.init(title: "Страницы без внешних ссылок", severity: "Medium", category: "Backlinks", summary: "Без обратных ссылок: \(data.backlinkSummary.pagesWithoutBacklinks) из \(data.backlinkSummary.totalEligiblePages) страниц.", affectedURLs: Array(data.backlinkProfile.pagesWithoutBacklinks.prefix(5)), recommendation: "Приоритизируйте важные страницы для аутрича и цифрового PR.")) }
        if data.searchConsoleSummary.notIndexedPages > 0 { findings.append(.init(title: "Неиндексируемые страницы", severity: "High", category: "Search Console", summary: "GSC сообщает о \(data.searchConsoleSummary.notIndexedPages) неиндексируемых страницах.", affectedURLs: data.searchConsoleErrors.errors.first(where: { $0.type.hasPrefix("Не проиндексировано") })?.examples ?? [], recommendation: "Проверьте причины исключения, canonical и возможность обхода, затем запросите валидацию в GSC.")) }
        return findings
    }
    private static func fallback(data: AIAuditReportData, startURL: String, reason: String) -> AIAuditReport {
        let backlink = "Профиль: \(data.backlinkSummary.totalBacklinks) активных ссылок с \(data.backlinkSummary.referringDomains) доменов; dofollow — \(data.backlinkSummary.dofollowBacklinks), nofollow — \(data.backlinkSummary.nofollowBacklinks), битых — \(data.backlinkSummary.brokenBacklinks), максимальный spam score — \(data.backlinkSummary.spamScore)."
        let technical = data.technicalErrors.issues.isEmpty ? "Технические ошибки в доступных данных не обнаружены." : "В крауле обнаружено \(data.technicalErrors.issues.count) типов проблем; наиболее заметные: \(data.technicalErrors.issues.prefix(3).map { "\($0.name) (\($0.count))" }.joined(separator: ", "))."
        let gsc = data.searchConsoleSummary.available ? "Проверено страниц: индексировано \(data.searchConsoleSummary.indexedPages), не индексировано \(data.searchConsoleSummary.notIndexedPages), ошибок покрытия/fetch — \(data.searchConsoleSummary.coverageErrors), мобильных проблем — \(data.searchConsoleSummary.mobileUsabilityIssues)." : data.searchConsoleSummary.unavailableReason
        return makeReport(data: data, startURL: startURL, backlink: backlink, technical: technical, gsc: gsc, summary: "\(reason) Приоритеты определены по данным ссылочного профиля, технического краула и Search Console.")
    }
    private static func severity(_ value: String) -> String { ["High", "Medium", "Low"].contains(value.capitalized) ? value.capitalized : "Medium" }
}

private extension AIAuditAnalyzer {
    struct ChatRequest: Encodable { struct Message: Encodable { var role: String; var content: String }; var model: String; var messages: [Message] }
    struct ChatResponse: Decodable { struct Choice: Decodable { struct Message: Decodable { var content: String? }; var message: Message }; var choices: [Choice] }
    struct OllamaTextRequest: Encodable { let model: String; let prompt: String; let stream = false; let options = ["temperature": 0] }
    struct OllamaTextResponse: Decodable { let response: String }
    enum AnalysisError: Error { case requestFailed, emptyResponse }
}
