import Foundation

enum AIAuditAnalyzer {
    static func analyze(data: AIAuditReportData, startURL: String) async -> AIAuditReport {
        guard let key = ProcessInfo.processInfo.environment["OPENAI_API_KEY"], !key.isEmpty else {
            return fallback(data: data, startURL: startURL, assessment: "AI analysis was unavailable because OPENAI_API_KEY is not configured. This report uses the crawl, backlink, and Search Console data collected by ShareSpider.")
        }
        do {
            let sourceData = try JSONEncoder().encode(Payload(data: data))
            let userContent = String(decoding: sourceData, as: UTF8.self)
            var request = URLRequest(url: URL(string: "https://api.openai.com/v1/chat/completions")!)
            request.httpMethod = "POST"
            request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONEncoder().encode(ChatRequest(model: "gpt-4o-mini", messages: [
                .init(role: "system", content: "You are an expert SEO auditor. Analyze the provided structured data from a website crawl, backlink analysis (DataForSEO), and Google Search Console. Produce a concise, fact-based audit report. For each finding, cite the actual data (counts, URLs, metrics). Do not invent issues not supported by the data. Focus on High and Medium severity issues. Provide specific, actionable recommendations. Return only valid JSON: {\\\"overallAssessment\\\": string, \\\"findings\\\": [{\\\"title\\\": string, \\\"severity\\\": \\\"High|Medium|Low\\\", \\\"category\\\": string, \\\"summary\\\": string, \\\"affectedURLs\\\": [string], \\\"recommendation\\\": string}]}."),
                .init(role: "user", content: userContent)
            ]))
            let (responseData, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse, 200..<300 ~= http.statusCode else { throw AnalysisError.requestFailed }
            let completion = try JSONDecoder().decode(ChatResponse.self, from: responseData)
            guard let content = completion.choices.first?.message.content else { throw AnalysisError.emptyResponse }
            let clean = content.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: "```json", with: "").replacingOccurrences(of: "```", with: "").trimmingCharacters(in: .whitespacesAndNewlines)
            let result = try JSONDecoder().decode(LLMReport.self, from: Data(clean.utf8))
            let findings = result.findings.prefix(12).map { item in
                AIAuditFinding(title: item.title, severity: normalizedSeverity(item.severity), category: item.category, summary: item.summary, affectedURLs: Array(item.affectedURLs.prefix(5)), recommendation: item.recommendation)
            }
            guard !findings.isEmpty || result.overallAssessment.isEmpty == false else { throw AnalysisError.emptyResponse }
            return AIAuditReport(siteURL: startURL, generatedAt: Date(), crawlSummary: data.crawlSummary, backlinkSummary: data.backlinkSummary, searchConsoleSummary: data.searchConsoleSummary, findings: findings, overallAssessment: result.overallAssessment)
        } catch {
            return fallback(data: data, startURL: startURL, assessment: "AI analysis could not be completed, so this report uses a fact-based fallback generated from the available crawl, backlink, and Search Console data.")
        }
    }

    private static func fallback(data: AIAuditReportData, startURL: String, assessment: String) -> AIAuditReport {
        var findings = data.topCrawlIssues.prefix(8).map { issue in
            AIAuditFinding(title: issue.name, severity: fallbackSeverity(for: issue.name), category: category(for: issue.name), summary: "\(issue.count) affected URL\(issue.count == 1 ? "" : "s") found in the crawl.", affectedURLs: Array(issue.examples.prefix(5)), recommendation: recommendation(for: issue.name))
        }
        findings += data.topAuditFindings.prefix(4).map { finding in
            AIAuditFinding(title: finding.title, severity: normalizedSeverity(finding.severity), category: "Technical SEO", summary: finding.detail, affectedURLs: [], recommendation: "Review the affected pages and apply the technical correction described in this finding.")
        }
        if data.backlinkSummary.pagesWithoutBacklinks > 0 {
            findings.append(AIAuditFinding(title: "Indexable pages without backlinks", severity: "Medium", category: "Backlinks", summary: "\(data.backlinkSummary.pagesWithoutBacklinks) of \(data.backlinkSummary.totalEligiblePages) eligible pages have no detected external backlinks.", affectedURLs: Array(data.backlinkPagesWithoutLinks.prefix(5)), recommendation: "Prioritize important unlinked pages in digital PR, partner outreach, and internal content promotion."))
        }
        if data.searchConsoleSummary.notIndexedPages > 0 {
            findings.append(AIAuditFinding(title: "Pages not indexed by Google", severity: "High", category: "Indexing", summary: "Google Search Console reports \(data.searchConsoleSummary.notIndexedPages) inspected pages as not indexed, with \(data.searchConsoleSummary.coverageErrors) coverage or fetch issues.", affectedURLs: Array(data.searchConsolePagesNotIndexed.prefix(5)), recommendation: "Review each exclusion reason, fix crawlability or canonical signals, then request validation in Google Search Console."))
        }
        let fullAssessment = findings.isEmpty ? "No material high- or medium-priority issues were identified in the available data. \(assessment)" : "The audit found \(findings.count) prioritized issues across the available sources. \(assessment)"
        return AIAuditReport(siteURL: startURL, generatedAt: Date(), crawlSummary: data.crawlSummary, backlinkSummary: data.backlinkSummary, searchConsoleSummary: data.searchConsoleSummary, findings: Array(findings.prefix(12)), overallAssessment: fullAssessment)
    }

    private static func normalizedSeverity(_ value: String) -> String { ["High", "Medium", "Low"].contains(value.capitalized) ? value.capitalized : "Medium" }
    private static func fallbackSeverity(for name: String) -> String { name.contains("error") || name.contains("canonical") ? "High" : "Medium" }
    private static func category(for name: String) -> String { name.contains("alt") ? "Content" : name.contains("inlinks") ? "Technical SEO" : "Technical SEO" }
    private static func recommendation(for name: String) -> String {
        switch name {
        case "Internal server/client errors": "Restore the page, correct its internal links, or add a relevant 301 redirect."
        case "Internal redirects": "Update internal links to point directly to the final 200-status URL."
        case "Missing page title": "Add a unique, descriptive title tag to every affected indexable page."
        case "Missing meta description": "Write a unique, useful meta description for each affected page."
        case "Missing H1": "Add one descriptive H1 that accurately states the page’s primary topic."
        case "Missing canonical": "Add an absolute self-referencing canonical tag to the preferred version of each page."
        case "Images without alt text": "Add concise, meaningful alt text to informative images; leave decorative images empty."
        default: "Add relevant internal links from navigational or contextual pages to improve discovery."
        }
    }
}

private extension AIAuditAnalyzer {
    struct Payload: Encodable {
        struct CrawlIssue: Encodable { var name: String; var count: Int; var examples: [String] }
        struct AuditFindingPayload: Encodable { var title: String; var severity: String; var detail: String }
        var crawlSummary: AIAuditCrawlSummary; var backlinkSummary: AIAuditBacklinkSummary; var searchConsoleSummary: AIAuditSearchConsoleSummary
        var topCrawlIssues: [CrawlIssue]; var topAuditFindings: [AuditFindingPayload]; var backlinkPagesWithoutLinks: [String]; var searchConsolePagesNotIndexed: [String]
        init(data: AIAuditReportData) { crawlSummary = data.crawlSummary; backlinkSummary = data.backlinkSummary; searchConsoleSummary = data.searchConsoleSummary; topCrawlIssues = data.topCrawlIssues.map { .init(name: $0.name, count: $0.count, examples: $0.examples) }; topAuditFindings = data.topAuditFindings.map { .init(title: $0.title, severity: $0.severity, detail: $0.detail) }; backlinkPagesWithoutLinks = data.backlinkPagesWithoutLinks; searchConsolePagesNotIndexed = data.searchConsolePagesNotIndexed }
    }
    struct ChatRequest: Encodable { struct Message: Encodable { var role: String; var content: String }; var model: String; var messages: [Message] }
    struct ChatResponse: Decodable { struct Choice: Decodable { struct Message: Decodable { var content: String? }; var message: Message }; var choices: [Choice] }
    struct LLMReport: Decodable { struct Finding: Decodable { var title: String; var severity: String; var category: String; var summary: String; var affectedURLs: [String]; var recommendation: String }; var overallAssessment: String; var findings: [Finding] }
    enum AnalysisError: Error { case requestFailed, emptyResponse }
}
