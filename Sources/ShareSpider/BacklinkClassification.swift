import Foundation
import SwiftSoup

/// Business-level backlink classification. DataForSEO supplies the raw facts
/// (platform, rank, URL, anchor and spam score); this layer turns them into the
/// practical categories used by SEO specialists. Rules live in a bundled JSON
/// file so they can be extended without growing a nested Swift switch.
@MainActor
enum BacklinkClassifier {
    enum DonorType: String, CaseIterable, Hashable, Sendable {
        case web20 = "Web 2.0"
        case pbn = "PBN"
        case catalog = "Каталог"
        case profile = "Профиль"
        case crowd = "Крауд / форум"
        case article = "Статья"
        case spam = "Spam"
        case homepage = "Главная"
        case redirect = "Редирект"
        case internationalNetwork = "Международная / языковая сетка"
        case unknown = "Не определено"
    }

    enum AnchorType: String, CaseIterable, Hashable, Sendable {
        case navigation = "Навигационный"
        case url = "URL-анкор"
        case empty = "Безанкорный"
        case text = "Текстовый"
    }

    private static let supportedRuleKeys: Set<String> = [
        "web20", "pbn", "catalog", "profile", "crowd", "article", "spam", "navigation"
    ]

    private static var rules: [String: [String]] = loadRules()

    /// The supplied donor lists are bundled with the app. Additions made through
    /// the MCP bridge are kept separately in Application Support, which means a
    /// new app build never overwrites an SEO specialist's custom lists.
    private static var customRulesURL: URL {
        let root = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("ShareSpider", isDirectory: true)
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root.appendingPathComponent("backlink-classification-custom-rules.json")
    }

    private static func bundledRules() -> [String: [String]] {
        guard let url = AppResources.url(forResource: "backlink-classification-rules", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let result = try? JSONDecoder().decode([String: [String]].self, from: data) else { return [:] }
        return result
    }

    private static func loadRules() -> [String: [String]] {
        // Keep generic URL/title heuristics alongside the editor-maintained
        // donor lists. A donor may be an article or directory even when its
        // domain has not yet been added to a specialist's list.
        var result = fallbackRules
        for (key, values) in bundledRules() {
            result[key, default: []] = unique(result[key, default: []] + values)
        }
        guard let data = try? Data(contentsOf: customRulesURL),
              let custom = try? JSONDecoder().decode([String: [String]].self, from: data) else {
            return result
        }
        for (key, values) in custom where supportedRuleKeys.contains(key) {
            result[key, default: []] = unique(result[key, default: []] + values)
        }
        return result
    }

    private static let fallbackRules: [String: [String]] = [
        "catalog": ["business", "listing", "/directory/", "/firma/", "/company/", "/companies/", "/businesses/", "/details/", "/firmen/", "/employers/", "/unternehmen/", "company profile", "claim this listing", "add review", "create listing"],
        "profile": ["/user/", "/profile/", "user profile", "member since", "joined on", "view my account"],
        "crowd": ["/forum/", "forum", "viewtopic.php", "topic=", "/threads/", "login to reply", "post a reply", "register account"],
        "article": ["/blog/", "/post/", "/articles/", "/news/", "/article/", "/wiki/", "/artikel/", "/20", "-vs-", "when-to", "-tips-", "can-you-", "learn-about", "what ", "why ", "how ", "guide", "benefits", "pros ", "cons ", "choosing"],
        "web20": ["wordpress.com", "blogspot.", "tumblr.com", "medium.com", "livejournal.com", "weebly.com", "wixsite.com"],
        "pbn": [],
        "spam": [],
        "navigation": []
    ]

    /// Imports only additive custom phrases. The input is intentionally JSON so
    /// MCP can update the lists without touching source files or the app bundle.
    @discardableResult
    static func appendCustomRules(json: String) -> String {
        guard let data = json.data(using: .utf8),
              let incoming = try? JSONDecoder().decode([String: [String]].self, from: data) else {
            return "Backlink rule update ignored: invalid JSON."
        }
        let accepted = incoming.filter { supportedRuleKeys.contains($0.key) }
        guard !accepted.isEmpty else {
            return "Backlink rule update ignored: no supported categories."
        }
        var stored: [String: [String]] = [:]
        if let existing = try? Data(contentsOf: customRulesURL),
           let decoded = try? JSONDecoder().decode([String: [String]].self, from: existing) {
            stored = decoded
        }
        var added = 0
        for (key, values) in accepted {
            let before = stored[key, default: []]
            let merged = unique(before + values)
            added += max(0, merged.count - before.count)
            stored[key] = merged
        }
        guard let output = try? JSONEncoder().encode(stored) else {
            return "Backlink rule update could not be saved."
        }
        do {
            try output.write(to: customRulesURL, options: .atomic)
            rules = loadRules()
            return "Backlink rules updated: (added) new phrase(s) in (accepted.count) category(s)."
        } catch {
            return "Backlink rule update could not be saved: (error.localizedDescription)"
        }
    }

    static func donorType(for item: BacklinkSourceDetail) -> DonorType {
        let source = normalized(item.sourceURL + " " + item.sourceTitle + " " + item.sourceDomain)
        // A provider's explicit spam signal is authoritative for donor
        // classification. Heuristics are only a fallback when the provider did
        // not mark the record as spam.
        if item.spamScore >= 50 { return .spam }
        if item.relatedDomainZone && item.hreflangLinksToTarget { return .internationalNetwork }
        if item.broken || item.sourceStatusCode >= 300 { return .redirect }
        if matches(source, rules["spam"] ?? []) { return .spam }
        if matches(source, rules["pbn"] ?? []) { return .pbn }
        if matches(source, rules["web20"] ?? []) { return .web20 }
        if isHomepage(item.sourceURL) { return .homepage }
        if matches(source, rules["catalog"] ?? []) { return .catalog }
        if matches(source, rules["profile"] ?? []) { return .profile }
        if matches(source, rules["crowd"] ?? []) { return .crowd }
        if matches(source, rules["article"] ?? []) { return .article }
        return .unknown
    }

    static func anchorType(for item: BacklinkSourceDetail, target: String) -> AnchorType {
        let anchor = normalized(item.anchor)
        guard !anchor.isEmpty else { return .empty }
        let targetHosts = [host(target), host(item.targetURL)].filter { !$0.isEmpty }
        let compact = anchor.replacingOccurrences(of: " ", with: "")
        if matches(anchor, rules["navigation"] ?? []) || matches(compact, rules["navigation"] ?? []) {
            return .navigation
        }
        if targetHosts.contains(where: { targetHost in
            let withoutWWW = targetHost.replacingOccurrences(of: "www.", with: "")
            return anchor == targetHost || anchor == withoutWWW || compact == targetHost || compact == withoutWWW
        }) { return .navigation }
        if anchor.hasPrefix("http://") || anchor.hasPrefix("https://") || anchor.hasPrefix("www.") { return .url }
        return .text
    }

    static func evidence(for item: BacklinkSourceDetail) -> String {
        let type = donorType(for: item)
        switch type {
        case .spam: return "DataForSEO spam score \(item.spamScore)"
        case .redirect: return item.broken ? "broken backlink" : "source HTTP \(item.sourceStatusCode)"
        case .homepage: return "source URL is the domain homepage"
        case .internationalNetwork: return "same-name domain on another zone links to target via hreflang"
        default: return "URL/title/platform heuristic"
        }
    }

    private static func matches(_ text: String, _ phrases: [String]) -> Bool {
        phrases.contains { !($0.isEmpty) && text.contains(normalized($0)) }
    }
    private static func unique(_ values: [String]) -> [String] {
        var seen = Set<String>()
        return values.filter {
            let key = normalized($0)
            return !key.isEmpty && seen.insert(key).inserted
        }
    }
    private static func normalized(_ value: String) -> String { value.lowercased().trimmingCharacters(in: .whitespacesAndNewlines) }
    private static func host(_ value: String) -> String { URL(string: value)?.host?.lowercased() ?? "" }
    private static func isHomepage(_ value: String) -> Bool {
        guard let url = URL(string: value) else { return false }
        return url.path.isEmpty || url.path == "/"
    }
}

/// Donor pages are fetched only for likely same-brand, different-TLD domains.
/// A confirmed hreflang link to the target makes the classification evidence-
/// based instead of relying solely on a matching domain name.
enum HreflangDonorInspector {
    static func inspect(_ sources: [BacklinkSourceDetail], target: String) async -> [BacklinkSourceDetail] {
        guard let targetHost = URL(string: target)?.host?.lowercased() else { return sources }
        let candidateIDs = Set(sources.enumerated().compactMap { index, source in
            sameNameDifferentZone(source.sourceDomain, targetHost) ? index : nil
        })
        guard !candidateIDs.isEmpty else { return sources }
        let session = URLSession(configuration: .ephemeral)
        return await withTaskGroup(of: (Int, Bool).self, returning: [BacklinkSourceDetail].self) { group in
            for index in candidateIDs {
                let source = sources[index]
                group.addTask {
                    guard let url = URL(string: source.sourceURL) else { return (index, false) }
                    var request = URLRequest(url: url); request.timeoutInterval = 8
                    guard let (data, _) = try? await session.data(for: request), let html = String(data: data, encoding: .utf8), let doc = try? SwiftSoup.parse(html, url.absoluteString) else { return (index, false) }
                    let hrefs = (try? doc.select("link[hreflang][href]").array().map { try $0.absUrl("href") }) ?? []
                    return (index, hrefs.contains { URL(string: $0)?.host?.lowercased() == targetHost })
                }
            }
            var updated = sources
            for await (index, linked) in group {
                updated[index].relatedDomainZone = true
                updated[index].hreflangLinksToTarget = linked
            }
            return updated
        }
    }

    private static func sameNameDifferentZone(_ source: String, _ target: String) -> Bool {
        let clean: (String) -> String = { $0.lowercased().replacingOccurrences(of: "www.", with: "") }
        let sourceHost = clean(URL(string: source)?.host ?? source)
        let targetHost = clean(target)
        guard sourceHost != targetHost else { return false }
        return sourceHost.split(separator: ".").first == targetHost.split(separator: ".").first
    }
}
