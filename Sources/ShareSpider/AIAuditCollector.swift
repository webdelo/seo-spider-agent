import Foundation

struct AIAuditReportData: Sendable {
    var crawlSummary: AIAuditCrawlSummary
    var backlinkSummary: AIAuditBacklinkSummary
    var searchConsoleSummary: AIAuditSearchConsoleSummary
    var topCrawlIssues: [(name: String, count: Int, examples: [String])]
    var topAuditFindings: [(title: String, severity: String, detail: String)]
    var backlinkPagesWithoutLinks: [String]
    var searchConsolePagesNotIndexed: [String]
}

enum AIAuditCollector {
    static func collect(records: [CrawlRecord], auditReport: AuditReport?, backlinkReport: BacklinkReport?, startURL: String) -> AIAuditReportData {
        let html = records.filter(\.isSEOPage)
        let indexable = html.filter { $0.indexability == "Indexable" }
        let errors = records.filter { !$0.error.isEmpty || ($0.statusCode ?? 0) >= 400 }
        let redirects = records.filter { $0.hasRedirect || ($0.statusCode ?? 0) / 100 == 3 }
        let missingAltPages = html.filter { $0.images.contains { $0.alt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty } }
        let crawl = AIAuditCrawlSummary(
            totalURLs: records.count, htmlPages: html.count, errorCount: errors.count, redirectCount: redirects.count,
            missingTitles: indexable.filter { $0.title.isEmpty }.count, missingDescriptions: indexable.filter { $0.metaDescription.isEmpty }.count,
            missingH1: indexable.filter { $0.h1.isEmpty }.count, missingCanonical: indexable.filter { $0.canonical.isEmpty }.count,
            missingAltText: missingAltPages.count,
            averageResponseTime: records.isEmpty ? 0 : records.reduce(0) { $0 + $1.responseTime } / Double(records.count),
            pagesWithoutInlinks: html.filter { $0.depth > 0 && $0.inlinks == 0 }.count
        )

        let eligible = records.filter(\.isGSCEligible)
        let pagesWithoutBacklinks = eligible.filter { $0.backlinkChecked && $0.backlinks == 0 }
        let domain = backlinkReport?.domain ?? BacklinkDomainProfile()
        let backlinks = AIAuditBacklinkSummary(domainRank: domain.rank, totalBacklinks: domain.backlinks, referringDomains: domain.referringDomains, dofollowBacklinks: domain.dofollowBacklinks, nofollowBacklinks: domain.nofollowBacklinks, brokenBacklinks: domain.brokenBacklinks, spamScore: domain.spamScore, pagesWithoutBacklinks: pagesWithoutBacklinks.count, totalEligiblePages: eligible.count)

        let inspected = records.filter { $0.searchConsoleIndexStatus != "Not checked" && $0.searchConsoleIndexStatus != "Unavailable" }
        let unavailable = records.first { $0.searchConsoleIndexStatus == "Unavailable" }
        let coverageErrors = inspected.filter { !$0.searchConsoleCoverage.isEmpty || $0.searchConsoleFetchStatus.hasPrefix("HTTP 4") || $0.searchConsoleFetchStatus.hasPrefix("HTTP 5") || $0.searchConsoleFetchStatus == "Soft 404" }.count
        let searchConsole = AIAuditSearchConsoleSummary(indexedPages: inspected.filter { $0.searchConsoleIndexStatus == "Indexed" }.count, notIndexedPages: inspected.filter { $0.searchConsoleIndexStatus == "Not indexed" }.count, clicks7d: records.filter(\.searchConsolePerformanceChecked).reduce(0) { $0 + $1.searchConsoleClicks7d }, impressions7d: records.filter(\.searchConsolePerformanceChecked).reduce(0) { $0 + $1.searchConsoleImpressions7d }, coverageErrors: coverageErrors, mobileUsabilityIssues: inspected.filter { !$0.searchConsoleMobileIssues.isEmpty }.count, available: !inspected.isEmpty || records.contains(where: \.searchConsolePerformanceChecked), unavailableReason: unavailable?.searchConsoleFetchStatus ?? (inspected.isEmpty ? "Search Console data has not been fetched." : ""))

        let issueCandidates: [(String, [CrawlRecord])] = [
            ("Internal server/client errors", errors), ("Internal redirects", redirects),
            ("Missing page title", indexable.filter { $0.title.isEmpty }), ("Missing meta description", indexable.filter { $0.metaDescription.isEmpty }),
            ("Missing H1", indexable.filter { $0.h1.isEmpty }), ("Missing canonical", indexable.filter { $0.canonical.isEmpty }),
            ("Images without alt text", missingAltPages), ("Pages without internal inlinks", html.filter { $0.depth > 0 && $0.inlinks == 0 })
        ]
        let topCrawlIssues = issueCandidates.filter { !$0.1.isEmpty }.map { (name: $0.0, count: $0.1.count, examples: $0.1.prefix(5).map { $0.url.absoluteString }) }.sorted { $0.count > $1.count }.prefix(10).map { $0 }
        let auditFindings = (auditReport?.findings ?? []).sorted { weight($0.severity) > weight($1.severity) }.prefix(10).map { (title: $0.title, severity: $0.severity, detail: $0.detail) }
        return AIAuditReportData(crawlSummary: crawl, backlinkSummary: backlinks, searchConsoleSummary: searchConsole, topCrawlIssues: topCrawlIssues, topAuditFindings: auditFindings, backlinkPagesWithoutLinks: pagesWithoutBacklinks.prefix(20).map { $0.url.absoluteString }, searchConsolePagesNotIndexed: inspected.filter { $0.searchConsoleIndexStatus == "Not indexed" }.prefix(20).map { $0.url.absoluteString })
    }

    private static func weight(_ severity: String) -> Int { severity == "High" ? 3 : severity == "Medium" ? 2 : 1 }
}
