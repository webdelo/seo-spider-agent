import Foundation

struct AIAuditCountBreakdown: Codable, Sendable { var type: String; var count: Int }
struct AIAuditReferringDomain: Codable, Sendable { var domain: String; var rank: Int; var backlinks: Int; var spamScore: Int; var referringPages: Int }
struct AIAuditBacklinkSource: Codable, Sendable { var sourceURL: String; var sourceDomain: String; var domainRank: Int; var pageRank: Int; var anchor: String; var dofollow: Bool; var spamScore: Int; var donorType: String; var anchorType: String }
struct AIAuditTechnicalIssue: Codable, Sendable { var name: String; var type: String; var priority: String; var count: Int; var percentage: Double; var pageTypesAffected: [String]; var examples: [String] }
struct AIAuditTechnicalFinding: Codable, Sendable { var title: String; var severity: String; var detail: String; var examples: [String] }
struct AIAuditGSCURLDetail: Codable, Sendable { var url: String; var httpStatus: Int?; var indexability: String; var canonical: String; var pageType: String }
struct AIAuditSearchConsoleError: Codable, Sendable { var type: String; var count: Int; var examples: [String]; var exampleDetails: [AIAuditGSCURLDetail] }
struct AIAuditBacklinkBlock: Codable, Sendable { var summary: AIAuditBacklinkSummary; var topReferringDomains: [AIAuditReferringDomain]; var topBacklinkSources: [AIAuditBacklinkSource]; var donorTypeBreakdown: [AIAuditCountBreakdown]; var anchorTypeBreakdown: [AIAuditCountBreakdown]; var domainRankDistribution: [AIAuditCountBreakdown]; var pagesWithoutBacklinks: [String] }
struct AIAuditTechnicalBlock: Codable, Sendable { var crawlSummary: AIAuditCrawlSummary; var issues: [AIAuditTechnicalIssue]; var auditFindings: [AIAuditTechnicalFinding] }
struct AIAuditSearchConsoleBlock: Codable, Sendable { var summary: AIAuditSearchConsoleSummary; var errors: [AIAuditSearchConsoleError] }
struct AIAuditReportData: Sendable { var crawlSummary: AIAuditCrawlSummary; var backlinkSummary: AIAuditBacklinkSummary; var searchConsoleSummary: AIAuditSearchConsoleSummary; var backlinkProfile: AIAuditBacklinkBlock; var technicalErrors: AIAuditTechnicalBlock; var searchConsoleErrors: AIAuditSearchConsoleBlock }

@MainActor
enum AIAuditCollector {
    static func collect(records: [CrawlRecord], issues: [Issue], auditReport: AuditReport?, backlinkReport: BacklinkReport?, referringDomainDetails: [ReferringDomainDetail], backlinkSourceDetails: [BacklinkSourceDetail]) -> AIAuditReportData {
        let html = records.filter(\.isSEOPage), indexable = html.filter { $0.indexability == "Indexable" }
        let errors = records.filter { !$0.error.isEmpty || ($0.statusCode ?? 0) >= 400 }, redirects = records.filter { $0.hasRedirect || ($0.statusCode ?? 0) / 100 == 3 }
        let missingAltPages = html.filter { $0.images.contains { $0.alt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty } }
        let crawl = AIAuditCrawlSummary(totalURLs: records.count, htmlPages: html.count, errorCount: errors.count, redirectCount: redirects.count, missingTitles: indexable.filter { $0.title.isEmpty }.count, missingDescriptions: indexable.filter { $0.metaDescription.isEmpty }.count, missingH1: indexable.filter { $0.h1.isEmpty }.count, missingCanonical: indexable.filter { $0.canonical.isEmpty }.count, missingAltText: missingAltPages.count, averageResponseTime: records.isEmpty ? 0 : records.reduce(0) { $0 + $1.responseTime } / Double(records.count), pagesWithoutInlinks: html.filter { $0.depth > 0 && $0.inlinks == 0 }.count)

        let eligible = records.filter(\.isGSCEligible), pagesWithoutBacklinks = eligible.filter { $0.backlinkChecked && $0.backlinks == 0 }
        let domain = backlinkReport?.domain ?? BacklinkDomainProfile()
        let backlinks = AIAuditBacklinkSummary(domainRank: domain.rank, totalBacklinks: domain.backlinks, referringDomains: domain.referringDomains, dofollowBacklinks: domain.dofollowBacklinks, nofollowBacklinks: domain.nofollowBacklinks, brokenBacklinks: domain.brokenBacklinks, spamScore: domain.spamScore, pagesWithoutBacklinks: pagesWithoutBacklinks.count, totalEligiblePages: eligible.count)
        let rankedSources = backlinkSourceDetails.sorted { $0.pageRank == $1.pageRank ? $0.domainRank > $1.domainRank : $0.pageRank > $1.pageRank }.prefix(50)
        let sources = rankedSources.map { source in AIAuditBacklinkSource(sourceURL: source.sourceURL, sourceDomain: source.sourceDomain, domainRank: source.domainRank, pageRank: source.pageRank, anchor: source.anchor, dofollow: source.dofollow, spamScore: source.spamScore, donorType: BacklinkClassifier.donorType(for: source).rawValue, anchorType: BacklinkClassifier.anchorType(for: source, target: source.targetURL).rawValue) }
        let rankedDomains = referringDomainDetails.sorted { $0.rank > $1.rank }.prefix(50)
        let backlinkBlock = AIAuditBacklinkBlock(summary: backlinks, topReferringDomains: rankedDomains.map { .init(domain: $0.domain, rank: $0.rank, backlinks: $0.backlinks, spamScore: $0.spamScore, referringPages: $0.referringPages) }, topBacklinkSources: sources, donorTypeBreakdown: breakdown(sources.map(\.donorType)), anchorTypeBreakdown: breakdown(sources.map(\.anchorType)), domainRankDistribution: rankDistribution(referringDomainDetails.map(\.rank)), pagesWithoutBacklinks: pagesWithoutBacklinks.prefix(20).map { $0.url.absoluteString })

        let technicalIssues = issues.map { issue in
            let affected = records.filter { issue.urlIDs.contains($0.id) }
            return AIAuditTechnicalIssue(name: issue.name, type: issue.type, priority: issue.priority, count: issue.count, percentage: records.isEmpty ? 0 : Double(issue.count) / Double(records.count) * 100, pageTypesAffected: Array(Set(affected.map(\.pageType))).sorted(), examples: examples(for: issue, records: records))
        }
        let auditFindings = (auditReport?.findings ?? []).map { finding in AIAuditTechnicalFinding(title: finding.title, severity: finding.severity, detail: finding.detail, examples: records.filter { finding.urlIDs.contains($0.id) }.prefix(10).map { $0.url.absoluteString }) }
        let technicalBlock = AIAuditTechnicalBlock(crawlSummary: crawl, issues: technicalIssues, auditFindings: auditFindings)

        let inspected = records.filter { $0.searchConsoleIndexStatus != "Not checked" && $0.searchConsoleIndexStatus != "Unavailable" }, unavailable = records.first { $0.searchConsoleIndexStatus == "Unavailable" }
        let gsc = AIAuditSearchConsoleSummary(indexedPages: inspected.filter { $0.searchConsoleIndexStatus == "Indexed" }.count, notIndexedPages: inspected.filter { $0.searchConsoleIndexStatus == "Not indexed" }.count, clicks7d: records.filter(\.searchConsolePerformanceChecked).reduce(0) { $0 + $1.searchConsoleClicks7d }, impressions7d: records.filter(\.searchConsolePerformanceChecked).reduce(0) { $0 + $1.searchConsoleImpressions7d }, coverageErrors: inspected.filter { !$0.searchConsoleCoverage.isEmpty || isFetchError($0.searchConsoleFetchStatus) }.count, mobileUsabilityIssues: inspected.filter { !$0.searchConsoleMobileIssues.isEmpty }.count, available: !inspected.isEmpty || records.contains(where: \.searchConsolePerformanceChecked), unavailableReason: unavailable?.searchConsoleFetchStatus ?? (inspected.isEmpty ? "Search Console data has not been fetched." : ""))
        let gscErrors = grouped("Не проиндексировано", records: inspected.filter { $0.searchConsoleIndexStatus == "Not indexed" }) { _ in "not-indexed" } + grouped("Ошибка покрытия", records: inspected.filter { !$0.searchConsoleCoverage.isEmpty }) { $0.searchConsoleCoverage } + grouped("Ошибка fetch", records: inspected.filter { isFetchError($0.searchConsoleFetchStatus) }) { $0.searchConsoleFetchStatus } + grouped("Проблема мобильной версии", records: inspected.filter { !$0.searchConsoleMobileIssues.isEmpty }) { $0.searchConsoleMobileIssues.joined(separator: "; ") } + grouped("Ошибка rich results", records: inspected.filter { !$0.searchConsoleRichResultErrors.isEmpty }) { $0.searchConsoleRichResultErrors.joined(separator: "; ") }
        return .init(crawlSummary: crawl, backlinkSummary: backlinks, searchConsoleSummary: gsc, backlinkProfile: backlinkBlock, technicalErrors: technicalBlock, searchConsoleErrors: .init(summary: gsc, errors: gscErrors))
    }
    private static func breakdown(_ values: [String]) -> [AIAuditCountBreakdown] { Dictionary(grouping: values, by: { $0 }).map { .init(type: $0.key, count: $0.value.count) }.sorted { $0.count > $1.count } }
    private static func examples(for issue: Issue, records: [CrawlRecord]) -> [String] { !issue.externalURLs.isEmpty ? Array(issue.externalURLs.prefix(10)) : records.filter { issue.urlIDs.contains($0.id) }.prefix(10).map { $0.url.absoluteString } }
    private static func isFetchError(_ value: String) -> Bool { !value.isEmpty && value != "No error" && value != "—" && value != "Not checked" }
    private static func rankDistribution(_ ranks: [Int]) -> [AIAuditCountBreakdown] {
        let tiers: [(String, (Int) -> Bool)] = [("0-10", { $0 <= 10 }), ("11-20", { (11...20).contains($0) }), ("21-30", { (21...30).contains($0) }), ("31-50", { (31...50).contains($0) }), ("51-100", { (51...100).contains($0) }), ("100+", { $0 > 100 })]
        return tiers.map { .init(type: $0.0, count: ranks.filter($0.1).count) }
    }
    private static func grouped(_ prefix: String, records: [CrawlRecord], key: (CrawlRecord) -> String) -> [AIAuditSearchConsoleError] {
        Dictionary(grouping: records, by: key).filter { !$0.key.isEmpty }.map { group in
            let examples = Array(group.value.prefix(30))
            return .init(type: "\(prefix): \(group.key)", count: group.value.count, examples: examples.map { $0.url.absoluteString }, exampleDetails: examples.map { .init(url: $0.url.absoluteString, httpStatus: $0.statusCode, indexability: $0.indexability, canonical: $0.canonical, pageType: $0.pageType) })
        }.sorted { $0.count > $1.count }
    }
}
