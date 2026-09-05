import Foundation

enum CrawlMode: String, CaseIterable, Identifiable { case spider = "Spider", list = "List"; var id: String { rawValue } }
enum CrawlState: Equatable { case idle, crawling, paused, finished, stopped
    var label: String { switch self { case .idle: "Ready"; case .crawling: "Crawling"; case .paused: "Paused"; case .finished: "Complete"; case .stopped: "Stopped" } }
}
enum URLKind: String, Codable { case internalURL = "Internal", external = "External" }

struct CrawlSettings: Sendable {
    /// A normal browser signature avoids false asset failures on CDNs that
    /// selectively challenge unknown crawler user agents. ShareSpider remains
    /// identifiable through its local UI and request rate controls.
    var userAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 14_0) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.6 Safari/605.1.15"
    var concurrency = 6
    var timeout: TimeInterval = 20
    var maxDepth = 5
    var maxURLs = 10_000
    var respectRobots = false
    var crawlSubdomains = false
    var crawlParameters = false
    var followNofollowLinks = false
    /// Visual audit is deliberately conservative by default: one representative URL.
    var visualAuditPageLimit = 1
}

struct CrawlRecord: Identifiable, Hashable, Sendable {
    let id = UUID()
    var url: URL
    var kind: URLKind = .internalURL
    var contentType = "—"
    var statusCode: Int?
    var redirectURL: URL?
    var redirectChain: [URL] = []
    var redirectSources: [URL] = []
    /// Internal HTML pages that referenced this URL during the current crawl.
    /// This makes an error report actionable: it shows where to fix the link.
    var foundOnURLs: [URL] = []
    var responseTime: TimeInterval = 0
    var size = 0
    var depth = 0
    var indexability = "Unknown"
    var robots = ""
    /// Matching `Disallow` directive, retained even when the crawl mode ignores
    /// robots.txt so the report can still explain what the rule blocks.
    var robotsBlockedBy = ""
    var canonical = ""
    var canonicalRaw = ""
    var canonicalCount = 0
    var title = ""
    var metaDescription = ""
    var metaKeywords = ""
    var h1 = ""
    var h2 = ""
    var h1Count = 0
    var h2Count = 0
    var wordCount = 0
    var internalLinks = 0
    var externalLinks = 0
    var inlinks = 0
    var internalLinkTargets: [String] = []
    var outgoingLinks: [CrawledLink] = []
    var inSitemap = false
    var hreflang = ""
    var hreflangCodes: [String] = []
    var hreflangTargets: [HreflangLink] = []
    var hasXDefault = false
    var paginationURLs: [String] = []
    var contentFingerprint = ""
    var schemaTypes: [String] = []
    var pageType = "Unknown"
    var classificationConfidence: Double = 0
    var classificationEvidence: [String] = []
    var primarySchemaType = ""
    var schemaCompatibility = "Unknown"
    var schemaCompleteness: Double = 0
    var schemaValidationErrors: [String] = []
    var cmsName = "Unknown"
    var cmsConfidence: Double = 0
    var cmsEvidence: [String] = []
    var language = ""
    var images: [CrawledImage] = []
    var analyticsIDs: [String] = []
    var analyticsSignals: [String] = []
    /// URL Inspection API result from Google Search Console. This is deliberately
    /// separate from the live HTTP status collected by the spider: Google can
    /// report a different, historical fetch/indexing state.
    var searchConsoleIndexStatus = "Not checked"
    var searchConsoleFetchStatus = "—"
    var searchConsoleCoverage = ""
    var searchConsoleGoogleCanonical = ""
    var searchConsoleLastCrawl = ""
    var searchConsoleRobotsStatus = ""
    var searchConsoleNoindexStatus = ""
    var searchConsoleSitemaps: [String] = []
    var searchConsoleRichResultErrors: [String] = []
    var searchConsoleMobileIssues: [String] = []
    /// Search Analytics performance for the last seven complete days. Unlike
    /// URL Inspection, this is traffic/visibility data rather than index state.
    var searchConsoleClicks7d = 0
    var searchConsoleImpressions7d = 0
    var searchConsoleQueriesTop10 = 0
    var searchConsoleQueriesTop20 = 0
    var searchConsoleQueryCount = 0
    /// True only after Search Analytics returned a seven-day result for this
    /// canonical URL. It keeps an unrequested URL distinct from a genuine zero.
    var searchConsolePerformanceChecked = false
    /// Page-level backlink values are obtained in one paginated Domain Pages
    /// request, never through a separate API request for every crawled URL.
    var backlinkChecked = false
    var backlinks = 0
    var referringDomains = 0
    var referringMainDomains = 0
    var referringPages = 0
    var backlinkPageRank = 0
    var backlinkSpamScore = 0
    var brokenBacklinks = 0
    var dofollowBacklinks = 0
    var nofollowBacklinks = 0
    var referringIPs = 0
    var referringSubnets = 0
    /// WordPress head links which disclose technical endpoints or create avoidable
    /// duplicate feeds. These are only populated for HTML documents.
    var wordPressHeadFindings: [String] = []
    var error = ""
    var securityHeaders: [String: String] = [:]
    var isHTML: Bool { contentType.lowercased().contains("text/html") }
    var isImagePath: Bool { ["png", "jpg", "jpeg", "gif", "webp", "svg", "avif", "ico", "bmp", "tif", "tiff"].contains(url.pathExtension.lowercased()) }
    /// A binary image is a crawl resource, even when it returns HTTP 200.
    var isImageResource: Bool { contentType.lowercased().trimmingCharacters(in: .whitespaces).hasPrefix("image/") }
    /// An image-looking URL can still be a real HTML page (for example a CMS rewrite).
    /// Only then is it eligible for page-level SEO checks, and only when it is successful.
    /// Page-level SEO checks apply only to successful HTML documents. Error
    /// templates and PDFs may be reachable URLs, but do not need canonicals.
    var isSEOPage: Bool { isHTML && (statusCode ?? 0) / 100 == 2 }
    var isSchemaEligible: Bool { isSEOPage }
    var isCanonicalEligible: Bool { isSEOPage }
    /// Google APIs are queried only for successful, self-canonical HTML pages.
    /// PDFs, images, error pages and alternate canonical variants are excluded.
    var isGSCEligible: Bool {
        guard isSEOPage, !isImageCandidate else { return false }
        let declared = canonical.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        return !declared.isEmpty && declared == url.absoluteString.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    }
    var isImageCandidate: Bool { isImagePath || isImageResource }
    /// Shown in the URLs table. A binary image must never be presented as an unknown page type.
    var displayPageType: String { isImageCandidate && !isSEOPage ? "Image" : pageType }
    var statusText: String { statusCode.map(String.init) ?? (error.isEmpty ? "—" : "Error") }
    var hasRedirect: Bool { !redirectSources.isEmpty }
}

struct CrawledImage: Hashable, Sendable { var url: String; var alt: String; var width: String; var height: String; var size: Int = 0 }
/// A link as it appeared in the source HTML. The destination record keeps these
/// details available for developer-facing tasks: where the broken URL was found
/// and which anchor needs to be corrected.
struct CrawledLink: Hashable, Sendable { var url: String; var anchor: String }
struct HreflangLink: Hashable, Sendable { var code: String; var url: String }

struct Issue: Identifiable, Hashable, Sendable { let id = UUID(); let name: String; let type: String; let priority: String; let urlIDs: Set<UUID>; var externalURLs: [String] = []; var reportedCount: Int? = nil
    var count: Int { reportedCount ?? max(urlIDs.count, externalURLs.count) }
}

struct OverviewItem: Identifiable, Hashable, Sendable { let id = UUID(); let name: String; let urlIDs: Set<UUID>; var denominator: Int; var children: [OverviewItem] = []; var displayCount: Int? = nil
    var count: Int { displayCount ?? urlIDs.count }
    var outlineChildren: [OverviewItem]? { children.isEmpty ? nil : children }
}

struct MirrorResult: Identifiable, Sendable { let id = UUID(); var source: URL; var status: Int?; var finalURL: URL?; var redirects: Int; var redirectStatuses: [Int] = []; var error: String }
struct AuditFinding: Identifiable { let id = UUID(); var title: String; var severity: String; var detail: String; var urlIDs: Set<UUID> }
struct SiteProfile { var domainRating: Double? = nil; var domainRatingError = ""; var ipAddresses: [String] = []; var cmsName = "Unknown"; var cmsConfidence: Double = 0; var cmsEvidence: [String] = [] }
struct AuditReport { var mirrors: [MirrorResult] = []; var findings: [AuditFinding] = []; var analyticsIDs: Set<String> = []; var analyticsPages = 0; var totalHTMLPages = 0; var robots = RobotsAudit(); var sitemap = SitemapAudit(); var hreflang: [HreflangResult] = []; var siteProfile = SiteProfile() }
struct BacklinkDomainProfile: Codable, Hashable, Sendable {
    var target = ""
    var rank = 0
    var backlinks = 0
    var referringDomains = 0
    var referringMainDomains = 0
    var referringPages = 0
    var referringIPs = 0
    var referringSubnets = 0
    var dofollowBacklinks = 0
    var nofollowBacklinks = 0
    var brokenBacklinks = 0
    var spamScore = 0
}
struct BacklinkPageMetric: Codable, Hashable, Sendable {
    var url = ""
    var backlinks = 0
    var referringDomains = 0
    var referringMainDomains = 0
    var referringPages = 0
    var rank = 0
    var spamScore = 0
    var brokenBacklinks = 0
    var dofollowBacklinks = 0
    var nofollowBacklinks = 0
    var referringIPs = 0
    var referringSubnets = 0
}
struct BacklinkReport: Codable, Hashable, Sendable {
    var target = ""
    var fetchedAt = Date()
    var domain = BacklinkDomainProfile()
    var pages: [String: BacklinkPageMetric] = [:]
    var apiRequests = 0
    var error = ""
    var isFresh: Bool { Date().timeIntervalSince(fetchedAt) < 7 * 24 * 60 * 60 }
}
enum BacklinkDrilldownKind: String, Sendable {
    case referringDomains = "Referring Domains"
    case backlinks = "Backlinks"
    var title: String { rawValue }
}
struct ReferringDomainDetail: Identifiable, Codable, Hashable, Sendable {
    var domain = ""
    var rank = 0
    var backlinks = 0
    var spamScore = 0
    var referringPages = 0
    var firstSeen = ""
    var id: String { domain }
}
struct BacklinkSourceDetail: Identifiable, Codable, Hashable, Sendable {
    var sourceURL = ""
    var targetURL = ""
    var sourceDomain = ""
    var domainRank = 0
    var pageRank = 0
    var anchor = ""
    var dofollow = false
    var firstSeen = ""
    var previousSeen = ""
    var lastSeen = ""
    /// True only when DataForSEO reports that the link itself or the donor page
    /// has been removed. A stale `lastSeen` date alone never makes a link lost.
    var isLost = false
    var broken = false
    var sourceTitle = ""
    var sourceStatusCode = 0
    var spamScore = 0
    var platformTypes: [String] = []
    var semanticLocation = ""
    var linkType = ""
    var id: String { sourceURL + "|" + targetURL + "|" + anchor }
}
struct BacklinkHistoryPoint: Identifiable, Codable, Hashable, Sendable {
    var date = ""
    var backlinks = 0
    var newBacklinks = 0
    var lostBacklinks = 0
    var referringDomains = 0
    var newReferringDomains = 0
    var lostReferringDomains = 0
    var id: String { date }
}
struct RobotsBlockingRule: Identifiable, Sendable { let id = UUID(); var rule: String; var urlCount: Int }
struct RobotsAudit {
    var available = false
    var sections = 0
    var googleRules = 0
    var bingRules = 0
    var yandexRules = 0
    var googleRuleSource = "—"
    var bingRuleSource = "—"
    var yandexRuleSource = "—"
    /// Rules that actually restrict or target a crawl. `Allow: /` and an empty
    /// `Disallow:` merely permit everything and therefore do not count.
    var effectiveRules = 0
    var blocksSite = false
    var commentLines = 0
    var blockedURLCount = 0
    var blockingRules: [RobotsBlockingRule] = []
    var error = ""
    var isIneffective: Bool { available && !blocksSite && effectiveRules == 0 }
}
struct SitemapDocument: Identifiable, Sendable { let id = UUID(); var url: URL; var type = "urlset"; var urlCount = 0; var byteSize = 0; var error = "" }
struct SitemapAudit: Sendable {
    var roots: [URL] = []
    var documents: [SitemapDocument] = []
    var urlSources: [String: Set<String>] = [:]
    var error = ""
    var notCrawled: [String] = []
    var checks: [SitemapURLCheck] = []
    var summary = SitemapSummary()
    var urls: Set<String> { Set(urlSources.keys) }
    var nestedCount: Int { documents.filter { $0.type == "sitemapindex" }.count }
}
struct SitemapSummary: Sendable { var nonCanonical = 0; var broken = 0; var redirects = 0; var missingFromSitemap = 0; var isolated = 0 }
struct SitemapURLCheck: Identifiable, Sendable { let id = UUID(); var url: URL; var status: Int?; var finalURL: URL?; var error = "" }
struct SchemaValidation: Sendable { var type: String; var missing: [String] }
struct HreflangResult: Identifiable, Sendable {
    let id = UUID(); var source: URL; var code: String; var target: URL; var status: Int?; var finalURL: URL?
    var reciprocal = false; var validCode = true; var selfReference = false; var targetCanonical = ""; var targetNoindex = false
    var targetLanguage = ""; var languageMatches = true; var duplicateCode = false; var conflict = false; var returnLinkCheckable = false; var returnLinkTargets: Set<String> = []; var error = ""
}
