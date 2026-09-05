import Foundation
import SwiftSoup

struct PageAnalysis: Sendable {
    var title = ""; var description = ""; var keywords = ""; var h1 = ""; var h2 = ""; var h1Count = 0; var h2Count = 0; var canonical = ""; var canonicalRaw = ""; var canonicalCount = 0; var robots = ""; var language = ""; var hreflang = ""; var hreflangCodes: [String] = []; var hreflangTargets: [HreflangLink] = []; var hasXDefault = false; var paginationURLs: [String] = []; var contentFingerprint = ""; var schemaTypes: [String] = []; var schemaJSON = ""; var ogType = ""; var hasPrice = false; var hasAddToCart = false; var hasBookingForm = false; var hasAuthor = false; var hasPublishedDate = false; var repeatedCardCount = 0; var hasContactDetails = false
    var wordCount = 0; var internalLinks: [URL] = []; var internalLinkDetails: [CrawledLink] = []; var externalLinks: [URL] = []; var images: [CrawledImage] = []; var analyticsIDs: [String] = []; var analyticsSignals: [String] = []; var wordPressHeadFindings: [String] = []
}

enum HTMLAnalyzer {
    static func analyze(_ html: String, baseURL: URL, rootHost: String, settings: CrawlSettings) -> PageAnalysis {
        guard let doc = try? SwiftSoup.parse(html, baseURL.absoluteString) else { return PageAnalysis() }
        func text(_ selector: String) -> String { (try? doc.select(selector).first()?.text()) ?? "" }
        var output = PageAnalysis()
        output.title = text("head title")
        output.description = (try? doc.select("head meta[name=description]").first()?.attr("content")) ?? ""
        output.ogType = (try? doc.select("meta[property=og:type]").first()?.attr("content")) ?? ""
        output.keywords = (try? doc.select("head meta[name=keywords]").first()?.attr("content")) ?? ""
        output.canonical = (try? doc.select("head link[rel=canonical]").first()?.absUrl("href")) ?? ""
        output.canonicalRaw = (try? doc.select("head link[rel=canonical]").first()?.attr("href")) ?? ""
        output.canonicalCount = (try? doc.select("head link[rel=canonical]").count) ?? 0
        // These tags are injected by WordPress core or plugins. They are useful
        // during development, but normally expose avoidable feed/XML-RPC and
        // shortlink endpoints on a public production site.
        let rssLinks = (try? doc.select("head link[rel=alternate][type*=rss]").count) ?? 0
        if rssLinks > 0 { output.wordPressHeadFindings.append("RSS/Comments feed discovery links") }
        let rsdLinks = (try? doc.select("head link[type*=rsd], head link[rel=EditURI], head link[href*=xmlrpc.php]").count) ?? 0
        if rsdLinks > 0 { output.wordPressHeadFindings.append("RSD/XML-RPC discovery link") }
        let shortlinks = (try? doc.select("head link[rel=shortlink]").count) ?? 0
        if shortlinks > 0 { output.wordPressHeadFindings.append("WordPress shortlink") }
        let generator = (try? doc.select("head meta[name=generator]").array().map { try $0.attr("content") }) ?? []
        if generator.contains(where: { $0.localizedCaseInsensitiveContains("wordpress") }) { output.wordPressHeadFindings.append("WordPress version generator meta") }
        output.robots = (try? doc.select("meta[name=robots]").first()?.attr("content")) ?? ""
        output.language = (try? doc.select("html").first()?.attr("lang")) ?? ""
        output.hreflang = (try? doc.select("link[hreflang]").map { try $0.attr("hreflang") }.joined(separator: ", ")) ?? ""
        output.hreflangCodes = (try? doc.select("link[hreflang]").map { try $0.attr("hreflang") }) ?? []
        output.hreflangTargets = (try? doc.select("link[hreflang]").compactMap { node in
            let code = try node.attr("hreflang"); let url = try node.absUrl("href")
            return code.isEmpty || url.isEmpty ? nil : HreflangLink(code: code, url: url)
        }) ?? []
        output.hasXDefault = output.hreflangCodes.contains { $0.lowercased() == "x-default" }
        output.paginationURLs = (try? doc.select("link[rel=next], link[rel=prev]").map { try $0.absUrl("href") }.filter { !$0.isEmpty }) ?? []
        let pageHTML = html.lowercased(); output.hasPrice = pageHTML.contains("price") || pageHTML.contains("₽") || pageHTML.contains("$"); output.hasAddToCart = pageHTML.contains("add to cart") || pageHTML.contains("в корзин"); output.hasBookingForm = pageHTML.contains("book") || pageHTML.contains("записаться") || pageHTML.contains("appointment"); output.hasAuthor = pageHTML.contains("author") || pageHTML.contains("автор"); output.hasPublishedDate = pageHTML.contains("datepublished") || pageHTML.contains("published_time"); output.hasContactDetails = pageHTML.contains("tel:") || pageHTML.contains("@") && pageHTML.contains("mail")
        output.repeatedCardCount = (try? doc.select("article, .card, .product, .item").count) ?? 0
        output.h1 = text("body h1")
        output.h2 = text("body h2")
        output.h1Count = (try? doc.select("body h1").count) ?? 0
        output.h2Count = (try? doc.select("body h2").count) ?? 0
        let bodyText = (try? doc.body()?.text()) ?? ""
        output.contentFingerprint = String(bodyText.lowercased().split(whereSeparator: { $0.isWhitespace }).prefix(250).joined(separator: " ").hashValue)
        let jsonLD = (try? doc.select("script[type=application/ld+json]").array().compactMap { try $0.html() }.joined(separator: "\n")) ?? ""
        output.schemaJSON = jsonLD
        let typePattern = "\\\"@type\\\"\\s*:\\s*(?:\\[\\s*)?\\\"([^\\\"]+)\\\""
        if let regex = try? NSRegularExpression(pattern: typePattern) { output.schemaTypes = Array(Set(regex.matches(in: jsonLD, range: NSRange(jsonLD.startIndex..., in: jsonLD)).compactMap { Range($0.range(at: 1), in: jsonLD).map { String(jsonLD[$0]) } })).sorted() }
        output.wordCount = bodyText.split(whereSeparator: { $0.isWhitespace || $0.isNewline }).count
        // GA4 IDs have a substantial identifier after G-; requiring 6+ characters prevents false positives such as `G-GO` in JavaScript text.
        let patterns = ["GTM-[A-Z0-9]{6,}", "G-[A-Z0-9]{6,}", "GT-[A-Z0-9]{6,}", "AW-[0-9]{6,}", "UA-[0-9]+-[0-9]+"]
        output.analyticsIDs = patterns.flatMap { pattern in (try? NSRegularExpression(pattern: pattern).matches(in: html, range: NSRange(html.startIndex..., in: html)).compactMap { Range($0.range, in: html).map { String(html[$0]) } }) ?? [] }
        if html.localizedCaseInsensitiveContains("googletagmanager.com") { output.analyticsSignals.append("Google Tag Manager") }
        if html.localizedCaseInsensitiveContains("google-analytics.com") { output.analyticsSignals.append("Google Analytics script") }
        if html.contains("gtag(") { output.analyticsSignals.append("gtag") }
        if html.contains("dataLayer") { output.analyticsSignals.append("dataLayer") }
        let anchors = (try? doc.select("a[href]").array()) ?? []
        for a in anchors {
            let rel = (try? a.attr("rel"))?.lowercased() ?? ""
            if rel.split(separator: " ").contains("nofollow") && !settings.followNofollowLinks { continue }
            guard let raw = try? a.attr("href"), let url = normalize(raw, base: baseURL, settings: settings) else { continue }
            if isInternal(url, rootHost: rootHost, subdomains: settings.crawlSubdomains) {
                output.internalLinks.append(url)
                let anchor = ((try? a.text()) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                output.internalLinkDetails.append(CrawledLink(url: url.absoluteString, anchor: anchor.isEmpty ? "(no anchor text)" : anchor))
            } else { output.externalLinks.append(url) }
        }
        let imageNodes = (try? doc.select("img[src]").array()) ?? []
        output.images = imageNodes.compactMap { node in
            guard let src = try? node.absUrl("src"), !src.isEmpty else { return nil }
            return CrawledImage(url: src, alt: (try? node.attr("alt")) ?? "", width: (try? node.attr("width")) ?? "", height: (try? node.attr("height")) ?? "")
        }
        return output
    }

    static func normalize(_ raw: String, base: URL, settings: CrawlSettings) -> URL? {
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty, !value.hasPrefix("#"), !value.lowercased().hasPrefix("mailto:"), !value.lowercased().hasPrefix("tel:"), let resolved = URL(string: value, relativeTo: base)?.absoluteURL, var components = URLComponents(url: resolved, resolvingAgainstBaseURL: true), let scheme = components.scheme?.lowercased(), scheme == "http" || scheme == "https" else { return nil }
        components.fragment = nil
        if !settings.crawlParameters { components.query = nil }
        return components.url?.absoluteURL
    }

    static func isInternal(_ url: URL, rootHost: String, subdomains: Bool) -> Bool {
        guard let host = url.host?.lowercased() else { return false }
        return host == rootHost || (subdomains && host.hasSuffix("." + rootHost))
    }
}
