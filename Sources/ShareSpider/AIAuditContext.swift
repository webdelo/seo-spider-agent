import Foundation

/// Optional business context supplied by the person commissioning an audit.
/// It travels with the complete audit snapshot, so the AI can distinguish a
/// routine technical review from (for example) a visibility-loss investigation.
struct AIAuditBrief: Codable, Sendable {
    var scenarios: [String] = []
    var customQuestion: String = ""
    var positionsFileName: String = ""
    /// Plain-text CSV/TSV extract, intentionally capped at import time.
    var positionsFileContent: String = ""

    var isEmpty: Bool {
        scenarios.isEmpty && customQuestion.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && positionsFileContent.isEmpty
    }
}

struct AuditContext: Codable, Sendable {
    var siteURL: String
    var crawlSummary: AIAuditCrawlSummary
    var overview: [OverviewItemSnapshot]
    var issues: [IssueSnapshot]
    var pageTypeDistribution: [CountBreakdown]
    var schemaTypesDistribution: [CountBreakdown]
    var schemaCompatibilityDistribution: [CountBreakdown]
    /// Compact Page Weight and AI Parsability summary. Individual URLs remain
    /// available to an agent through the ShareSpider MCP tools.
    var pageMetrics: AIAuditPageMetrics
    var backlinkSummary: AIAuditBacklinkSummary
    var topReferringDomains: [AIAuditReferringDomain]
    var topBacklinkSources: [AIAuditBacklinkSource]
    var donorTypeBreakdown: [AIAuditCountBreakdown]
    var anchorTypeBreakdown: [AIAuditCountBreakdown]
    var gscSummary: AIAuditSearchConsoleSummary
    var gscErrorCategories: [AIAuditSearchConsoleError]
    var backlinkAnalysis: String
    var technicalAnalysis: String
    var searchConsoleAnalysis: String
    var userBrief: AIAuditBrief

    struct OverviewItemSnapshot: Codable, Sendable { var name: String; var count: Int; var denominator: Int }
    struct IssueSnapshot: Codable, Sendable { var name: String; var type: String; var priority: String; var count: Int }
    struct CountBreakdown: Codable, Sendable { var type: String; var count: Int }
}

extension AuditContext {
    @MainActor
    static func form(siteURL: String, records: [CrawlRecord], overview: [OverviewItem], issues: [Issue], backlinkSummary: AIAuditBacklinkSummary, referringDomainDetails: [ReferringDomainDetail], backlinkSourceDetails: [BacklinkSourceDetail], gscSummary: AIAuditSearchConsoleSummary, gscErrorCategories: [AIAuditSearchConsoleError], pageMetrics: AIAuditPageMetrics, backlinkAnalysis: String, technicalAnalysis: String, searchConsoleAnalysis: String, crawlSummary: AIAuditCrawlSummary, userBrief: AIAuditBrief = .init()) -> AuditContext {
        let pages = records.filter(\.isSEOPage)
        let sources = backlinkSourceDetails.sorted { $0.pageRank == $1.pageRank ? $0.domainRank > $1.domainRank : $0.pageRank > $1.pageRank }.prefix(50).map { source in
            AIAuditBacklinkSource(sourceURL: source.sourceURL, sourceDomain: source.sourceDomain, domainRank: source.domainRank, pageRank: source.pageRank, anchor: source.anchor, dofollow: source.dofollow, spamScore: source.spamScore, donorType: BacklinkClassifier.donorType(for: source).rawValue, anchorType: BacklinkClassifier.anchorType(for: source, target: source.targetURL).rawValue)
        }
        func breakdown(_ values: [String]) -> [AIAuditCountBreakdown] {
            Dictionary(grouping: values, by: { $0 }).map { .init(type: $0.key, count: $0.value.count) }.sorted { $0.count > $1.count }
        }
        func counts(_ values: [String]) -> [CountBreakdown] {
            Dictionary(grouping: values, by: { $0 }).map { .init(type: $0.key, count: $0.value.count) }.sorted { $0.count > $1.count }
        }
        return AuditContext(siteURL: siteURL, crawlSummary: crawlSummary, overview: overview.map { .init(name: $0.name, count: $0.count, denominator: $0.denominator) }, issues: issues.map { .init(name: $0.name, type: $0.type, priority: $0.priority, count: $0.count) }, pageTypeDistribution: counts(pages.map(\.displayPageType)), schemaTypesDistribution: counts(pages.flatMap(\.schemaTypes)), schemaCompatibilityDistribution: counts(pages.map(\.schemaCompatibility)), pageMetrics: pageMetrics, backlinkSummary: backlinkSummary, topReferringDomains: referringDomainDetails.sorted { $0.rank > $1.rank }.prefix(50).map { .init(domain: $0.domain, rank: $0.rank, backlinks: $0.backlinks, spamScore: $0.spamScore, referringPages: $0.referringPages) }, topBacklinkSources: sources, donorTypeBreakdown: breakdown(sources.map(\.donorType)), anchorTypeBreakdown: breakdown(sources.map(\.anchorType)), gscSummary: gscSummary, gscErrorCategories: gscErrorCategories, backlinkAnalysis: backlinkAnalysis, technicalAnalysis: technicalAnalysis, searchConsoleAnalysis: searchConsoleAnalysis, userBrief: userBrief)
    }
}
