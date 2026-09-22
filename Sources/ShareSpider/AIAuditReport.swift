import Foundation

enum AIAuditStage: String, Sendable {
    case notStarted, collectingData, linkAnalysis, technicalAnalysis, gscAnalysis, agentAnalysis, verification, executiveSummary, complete
}

struct AIAuditFinding: Identifiable, Hashable, Sendable, Codable {
    var id: UUID = UUID()
    var title: String
    var severity: String
    var category: String
    var summary: String
    var affectedURLs: [String]
    var recommendation: String
}

struct AIAuditReport: Sendable {
    var siteURL: String
    var generatedAt: Date
    var backlinkAnalysis: String
    var technicalAnalysis: String
    var searchConsoleAnalysis: String
    var executiveSummary: String
    var findings: [AIAuditFinding]
    var crawlSummary: AIAuditCrawlSummary
    var backlinkSummary: AIAuditBacklinkSummary
    var searchConsoleSummary: AIAuditSearchConsoleSummary
    var backlinkProfileDetail: AIAuditBacklinkBlock
    var technicalIssuesDetail: AIAuditTechnicalBlock
    var searchConsoleErrorsDetail: AIAuditSearchConsoleBlock
    var customAnalyses: [AICodexAnalyst.CustomAnalysis] = []
    var verifiedSummary: String = ""
    var rejectedFindings: [AICodexAnalyst.CustomAnalysis] { customAnalyses.filter { $0.status == "Rejected" } }
    var confirmedFindings: [AICodexAnalyst.CustomAnalysis] { customAnalyses.filter { $0.status == "Confirmed" || $0.status == "Partially confirmed" } }
    var probableFindings: [AICodexAnalyst.CustomAnalysis] { customAnalyses.filter { $0.status == "Probable" || $0.status == "Likely" } }
}

struct AIAuditCrawlSummary: Sendable, Codable {
    var totalURLs: Int; var htmlPages: Int; var errorCount: Int; var redirectCount: Int
    var missingTitles: Int; var missingDescriptions: Int; var missingH1: Int; var missingCanonical: Int
    var missingAltText: Int; var averageResponseTime: Double; var pagesWithoutInlinks: Int
    var sitemapURLs: Int; var sitemapAvailable: Bool; var successfulTitledPages: Int
}

struct AIAuditBacklinkSummary: Sendable, Codable {
    var domainRank: Int; var totalBacklinks: Int; var referringDomains: Int; var dofollowBacklinks: Int
    var nofollowBacklinks: Int; var brokenBacklinks: Int; var spamScore: Int; var pagesWithoutBacklinks: Int
    var totalEligiblePages: Int
}

struct AIAuditSearchConsoleSummary: Sendable, Codable {
    var indexedPages: Int; var notIndexedPages: Int; var clicks7d: Int; var impressions7d: Int
    var coverageErrors: Int; var mobileUsabilityIssues: Int; var available: Bool; var unavailableReason: String
}
