import Foundation
import SwiftSoup

struct PageAnalysis: Sendable {
    var title = ""; var description = ""; var keywords = ""; var h1 = ""; var h2 = ""; var h1Count = 0; var h2Count = 0; var canonical = ""; var canonicalRaw = ""; var canonicalCount = 0; var robots = ""; var language = ""; var hreflang = ""; var hreflangCodes: [String] = []; var hreflangTargets: [HreflangLink] = []; var hasXDefault = false; var paginationURLs: [String] = []; var contentFingerprint = ""; var schemaTypes: [String] = []; var schemaJSON = ""; var ogType = ""; var hasPrice = false; var hasAddToCart = false; var hasBookingForm = false; var hasAuthor = false; var hasPublishedDate = false; var repeatedCardCount = 0; var hasContactDetails = false
    var wordCount = 0; var currencyAmountCount = 0; var internalLinks: [URL] = []; var internalLinkDetails: [CrawledLink] = []; var externalLinks: [URL] = []; var images: [CrawledImage] = []; var analyticsIDs: [String] = []; var analyticsSignals: [String] = []; var wordPressHeadFindings: [String] = []
    var rawHTMLSize = 0; var cleanedHTMLSize = 0; var extractedTextSize = 0; var estimatedHTMLTokens = 0; var estimatedTextTokens = 0; var domNodeCount = 0; var inlineJavaScriptSize = 0; var inlineCSSSize = 0; var embeddedJSONSize = 0; var resourceRequestCount = 0; var resourceCandidates: [PageResource] = []
}

enum HTMLAnalyzer {
    static func analyze(_ html: String, baseURL: URL, rootHost: String, settings: CrawlSettings) -> PageAnalysis {
        guard let doc = try? SwiftSoup.parse(html, baseURL.absoluteString) else { return PageAnalysis() }
        func text(_ selector: String) -> String { (try? doc.select(selector).first()?.text()) ?? "" }
        var output = PageAnalysis()
        output.rawHTMLSize = html.lengthOfBytes(using: .utf8)
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
        func headHrefs(_ selector: String) -> [String] {
            (try? doc.select(selector).compactMap { try $0.absUrl("href") }.filter { !$0.isEmpty }) ?? []
        }
        let rssLinks = headHrefs("head link[rel=alternate][type*=rss]")
        if !rssLinks.isEmpty { output.wordPressHeadFindings.append("RSS/Comments feed discovery links: \(rssLinks.joined(separator: ", "))") }
        let rsdLinks = headHrefs("head link[type*=rsd], head link[rel=EditURI], head link[href*=xmlrpc.php]")
        if !rsdLinks.isEmpty { output.wordPressHeadFindings.append("RSD/XML-RPC discovery link: \(rsdLinks.joined(separator: ", "))") }
        let shortlinks = headHrefs("head link[rel=shortlink]")
        if !shortlinks.isEmpty { output.wordPressHeadFindings.append("WordPress shortlink: \(shortlinks.joined(separator: ", "))") }
        let generator = (try? doc.select("head meta[name=generator]").array().map { try $0.attr("content") }) ?? []
        let wordPressGenerator = generator.filter { $0.localizedCaseInsensitiveContains("wordpress") }
        if !wordPressGenerator.isEmpty { output.wordPressHeadFindings.append("WordPress version generator meta: \(wordPressGenerator.joined(separator: ", "))") }
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
        // Case-insensitive range searches are surprisingly expensive on large,
        // mixed-language catalogue documents: every individual signal scans the
        // entire string with Unicode case folding. Build one compact working
        // copy instead and use inexpensive literal lookups for all signals.
        let signalHTML = html.lowercased()
        func hasSignal(_ value: String) -> Bool { signalHTML.contains(value) }
        output.hasPrice = hasSignal("price") || html.contains("₽") || html.contains("$")
        output.hasAddToCart = hasSignal("add to cart") || hasSignal("в корзин")
        output.hasBookingForm = hasSignal("book") || hasSignal("записаться") || hasSignal("appointment")
        output.hasAuthor = hasSignal("author") || hasSignal("автор")
        output.hasPublishedDate = hasSignal("datepublished") || hasSignal("published_time")
        output.hasContactDetails = hasSignal("tel:") || (html.contains("@") && hasSignal("mail"))
        output.repeatedCardCount = (try? doc.select("article, .card, .product, .item").count) ?? 0
        // Use the tag selector rather than a body-descendant selector. Some
        // otherwise valid HTML documents omit an explicit <body> in source;
        // SwiftSoup then normalises it differently and the old selector could
        // falsely report an existing H1 as missing.
        output.h1 = text("h1")
        output.h2 = text("body h2")
        output.h1Count = (try? doc.select("h1").count) ?? 0
        output.h2Count = (try? doc.select("body h2").count) ?? 0
        let bodyText = (try? doc.body()?.text()) ?? ""
        // A price list has many independent monetary amounts.  One price is a
        // common supporting signal on product/service pages, so keep the count
        // separate for the classifier instead of turning every priced page
        // into a Price page.
        let currencyPattern = "\\b\\d{1,3}(?:\\s\\d{3})*(?:[.,]\\d{2})?\\s*(?:₽|руб\\.?|рублей|р\\.)"
        output.currencyAmountCount = (try? NSRegularExpression(pattern: currencyPattern).numberOfMatches(in: bodyText, range: NSRange(bodyText.startIndex..., in: bodyText))) ?? 0
        // `cleanedHTMLSize` is retained for backwards-compatible exports. The
        // expensive regex-created document copy was not consumed by any report;
        // raw HTML is the meaningful input for the AI parsing assessment.
        output.cleanedHTMLSize = output.rawHTMLSize
        output.extractedTextSize = bodyText.lengthOfBytes(using: .utf8)
        output.estimatedHTMLTokens = max(0, output.rawHTMLSize / 4)
        output.estimatedTextTokens = max(0, output.extractedTextSize / 4)
        output.domNodeCount = (try? doc.getAllElements().count) ?? 0
        output.inlineJavaScriptSize = (try? doc.select("script:not([src])").array().reduce(0) { $0 + ((try? $1.html()) ?? "").lengthOfBytes(using: .utf8) }) ?? 0
        output.inlineCSSSize = (try? doc.select("style").array().reduce(0) { $0 + ((try? $1.html()) ?? "").lengthOfBytes(using: .utf8) }) ?? 0
        // Do not fingerprint the opening of `body`: on most sites it is the
        // shared header/navigation and makes unrelated pages look identical.
        // Exact-duplicate checks use the full, page-specific main/article area.
        let contentSelectors = "main, article, [role=main], .entry-content, .post-content, .page-content, .article-content"
        let contentBlocks = (try? doc.select(contentSelectors).array()) ?? []
        let primaryHeading = try? doc.select("body h1").first()
        let preferredBlock = contentBlocks
            .filter { block in primaryHeading.map { heading in (try? block.getAllElements().contains(heading)) ?? false } ?? false }
            .compactMap { try? $0.text() }
            .max(by: { $0.count < $1.count })
            ?? contentBlocks.compactMap { try? $0.text() }.max(by: { $0.count < $1.count })

        // Not every CMS uses semantic landmarks. In that case, use the H1's
        // sibling section — all H2/H3 subsections remain part of the page;
        // only a following H1 starts a new independent section.
        func headingSectionText() -> String? {
            guard let heading = primaryHeading else { return nil }
            var parts: [String] = []
            var current = try? heading.nextElementSibling()
            while let element = current {
                if element.tagName().lowercased() == "h1" { break }
                if let text = try? element.text(), !text.isEmpty { parts.append(text) }
                current = try? element.nextElementSibling()
            }
            let text = parts.joined(separator: " ")
            return text.isEmpty ? nil : text
        }

        if let mainText = preferredBlock ?? headingSectionText() {
            let normalized = mainText
                .lowercased()
                .split(whereSeparator: { $0.isWhitespace })
                .joined(separator: " ")
            // Very short interface fragments are not meaningful content and
            // must not form a duplicate-content group.
            if normalized.split(separator: " ").count >= 80 {
                output.contentFingerprint = String(normalized.hashValue)
            }
        }
        let jsonLD = (try? doc.select("script[type=application/ld+json]").array().compactMap { try $0.html() }.joined(separator: "\n")) ?? ""
        output.schemaJSON = jsonLD
        output.embeddedJSONSize = jsonLD.lengthOfBytes(using: .utf8)
        let typePattern = "\\\"@type\\\"\\s*:\\s*(?:\\[\\s*)?\\\"([^\\\"]+)\\\""
        if let regex = try? NSRegularExpression(pattern: typePattern) { output.schemaTypes = Array(Set(regex.matches(in: jsonLD, range: NSRange(jsonLD.startIndex..., in: jsonLD)).compactMap { Range($0.range(at: 1), in: jsonLD).map { String(jsonLD[$0]) } })).sorted() }
        // Count words without allocating an array for every word in the page.
        var words = 0; var inWord = false
        for scalar in bodyText.unicodeScalars {
            if CharacterSet.whitespacesAndNewlines.contains(scalar) { inWord = false }
            else if !inWord { words += 1; inWord = true }
        }
        output.wordCount = words
        // GA4 IDs have a substantial identifier after G-; requiring 6+ characters prevents false positives such as `G-GO` in JavaScript text.
        let analyticsPatterns: [(prefix: String, expression: String)] = [
            ("gtm-", "GTM-[A-Z0-9]{6,}"),
            ("g-", "G-[A-Z0-9]{6,}"),
            ("gt-", "GT-[A-Z0-9]{6,}"),
            ("aw-", "AW-[0-9]{6,}"),
            ("ua-", "UA-[0-9]+-[0-9]+")
        ]
        output.analyticsIDs = analyticsPatterns.flatMap { candidate in
            guard hasSignal(candidate.prefix) else { return [String]() }
            return (try? NSRegularExpression(pattern: candidate.expression).matches(in: html, range: NSRange(html.startIndex..., in: html)).compactMap { Range($0.range, in: html).map { String(html[$0]) } }) ?? []
        }
        if hasSignal("googletagmanager.com") { output.analyticsSignals.append("Google Tag Manager") }
        if hasSignal("google-analytics.com") { output.analyticsSignals.append("Google Analytics script") }
        if hasSignal("gtag(") { output.analyticsSignals.append("gtag") }
        if hasSignal("datalayer") { output.analyticsSignals.append("dataLayer") }
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
        func resource(_ selector: String, kind: String) -> [PageResource] {
            ((try? doc.select(selector).array()) ?? []).compactMap { node in
                let value = (try? node.absUrl("src")) ?? ""
                let href = value.isEmpty ? ((try? node.absUrl("href")) ?? "") : value
                guard let resourceURL = URL(string: href), !href.isEmpty else { return nil }
                return PageResource(url: href, kind: kind, thirdParty: !isInternal(resourceURL, rootHost: rootHost, subdomains: settings.crawlSubdomains))
            }
        }
        output.resourceCandidates = output.images.compactMap { image in
            guard let imageURL = URL(string: image.url) else { return nil }
            return PageResource(url: image.url, kind: "Images", thirdParty: !isInternal(imageURL, rootHost: rootHost, subdomains: settings.crawlSubdomains))
        }
        output.resourceCandidates += resource("script[src]", kind: "JavaScript")
        output.resourceCandidates += resource("link[rel~=stylesheet]", kind: "CSS")
        output.resourceCandidates += resource("link[as=font], link[href$=.woff], link[href$=.woff2], link[href$=.ttf], link[href$=.otf]", kind: "Fonts")
        output.resourceCandidates += resource("link[rel=preload][as=image]", kind: "Images")
        var seen = Set<String>(); output.resourceCandidates = output.resourceCandidates.filter { seen.insert($0.url).inserted }
        output.resourceRequestCount = 1 + output.resourceCandidates.count
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
