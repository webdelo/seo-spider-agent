import Foundation

/// A compact, source-agnostic summary shown while donor datasets are loaded.
/// DataForSEO can classify individual donor pages; Ahrefs, Ubersuggest and GSC
/// sometimes expose domains only, so their category counts are explicitly
/// domain-level heuristics rather than claims about a particular page.
struct BacklinkSourceStats: Sendable, Hashable {
    var links = 0
    var donors = 0
    var profiles = 0
    var catalogs = 0
    var articles = 0
    /// Donors that appear to be part of an international / language network
    /// (hreflang-linked same-name domains on another TLD). Only DataForSEO
    /// supplies page-level facts, so domain-only sources report 0.
    var hreflang = 0
    /// Donors whose target link is currently unreachable (HTTP error,
    /// 4xx/5xx, disappeared donor page). Page-level fact from DataForSEO only.
    var broken = 0
    var spam = 0
    /// A domain-only provider does not expose the actual linking page. Keep
    /// this count visible so zero category matches are not mistaken for a
    /// missing or stalled classification.
    var unclassified = 0

    init(
        links: Int = 0,
        donors: Int = 0,
        profiles: Int = 0,
        catalogs: Int = 0,
        articles: Int = 0,
        hreflang: Int = 0,
        broken: Int = 0,
        spam: Int = 0,
        unclassified: Int = 0
    ) {
        self.links = links
        self.donors = donors
        self.profiles = profiles
        self.catalogs = catalogs
        self.articles = articles
        self.hreflang = hreflang
        self.broken = broken
        self.spam = spam
        self.unclassified = unclassified
    }

    @MainActor static func dataForSEO(_ records: [BacklinkSourceDetail]) -> BacklinkSourceStats {
        BacklinkSourceStats(
            links: records.count,
            donors: Set(records.map { GSCBacklinkImportService.normalizedDomain($0.sourceDomain) }.filter { !$0.isEmpty }).count,
            profiles: records.filter { BacklinkClassifier.donorType(for: $0) == .profile }.count,
            catalogs: records.filter { BacklinkClassifier.donorType(for: $0) == .catalog }.count,
            articles: records.filter { BacklinkClassifier.donorType(for: $0) == .article }.count,
            hreflang: records.filter { $0.relatedDomainZone }.count,
            broken: records.filter { $0.broken }.count,
            spam: records.filter { BacklinkClassifier.donorType(for: $0) == .spam }.count,
            unclassified: records.filter { BacklinkClassifier.donorType(for: $0) == .unknown }.count
        )
    }

    static func domains(_ rawDomains: [String], links: Int? = nil, knownSpam: Set<String> = []) -> BacklinkSourceStats {
        let domains = Array(Set(rawDomains.map(GSCBacklinkImportService.normalizedDomain).filter { !$0.isEmpty }))
        return BacklinkSourceStats(
            links: links ?? domains.count,
            donors: domains.count,
            profiles: domains.filter { looksProfileLike($0) }.count,
            catalogs: domains.filter { looksCatalogLike($0) }.count,
            articles: domains.filter { looksArticleLike($0) }.count,
            hreflang: 0,
            broken: 0,
            spam: domains.filter { knownSpam.contains(GSCBacklinkImportService.normalizedDomain($0)) || looksSpamLike($0) }.count,
            unclassified: domains.filter {
                !looksProfileLike($0) &&
                !looksCatalogLike($0) &&
                !looksArticleLike($0) &&
                !knownSpam.contains(GSCBacklinkImportService.normalizedDomain($0)) &&
                !looksSpamLike($0)
            }.count
        )
    }

    private static func looksProfileLike(_ domain: String) -> Bool {
        let value = domain.lowercased()
        return ["profile", "member", "user", "people", "social"].contains { value.contains($0) }
    }
    private static func looksCatalogLike(_ domain: String) -> Bool {
        let value = domain.lowercased()
        return ["directory", "catalog", "listing", "business", "company", "firmen", "companies"].contains { value.contains($0) }
    }
    private static func looksArticleLike(_ domain: String) -> Bool {
        let value = domain.lowercased()
        return ["blog", "magazine", "journal", "news", "article", "medium", "prnewswire", "press", "review", "editorial"].contains { value.contains($0) }
    }
    private static func looksSpamLike(_ domain: String) -> Bool {
        let value = domain.lowercased()
        return ["casino", "pills", "loan", "viagra", "adult", "porn"].contains { value.contains($0) }
    }
}
