import Foundation

struct RobotsDirective: Sendable { var agent: String; var directive: String; var value: String }

struct RobotsRules: Sendable {
    var directives: [RobotsDirective] = []
    var crawlDelay: TimeInterval = 0
    var sitemaps: [URL] = []

    /// Googlebot-specific groups have priority. If no Googlebot group exists,
    /// the crawler falls back to `User-agent: *`, mirroring Google's robots
    /// group selection instead of merging the two rule sets.
    func blockingRule(for url: URL) -> String? {
        let preferredAgent = directives.contains { $0.agent == "googlebot" } ? "googlebot" : "*"
        let matches = directives.filter { $0.agent == preferredAgent && ruleMatches(path: url.path, pattern: $0.value) }
        guard let winner = matches.sorted(by: { lhs, rhs in
            if lhs.value.count == rhs.value.count { return lhs.directive == "allow" && rhs.directive == "disallow" }
            return lhs.value.count > rhs.value.count
        }).first, winner.directive == "disallow" else { return nil }
        return "Disallow: \(winner.value)"
    }

    func allows(_ url: URL) -> Bool { blockingRule(for: url) == nil }

    private func ruleMatches(path: String, pattern raw: String) -> Bool {
        guard !raw.isEmpty else { return false }
        let endAnchored = raw.hasSuffix("$")
        let pattern = endAnchored ? String(raw.dropLast()) : raw
        let escaped = NSRegularExpression.escapedPattern(for: pattern).replacingOccurrences(of: "\\*", with: ".*")
        return path.range(of: "^\(escaped)\(endAnchored ? "$" : "")", options: .regularExpression) != nil
    }

    static func load(for start: URL, session: URLSession) async -> RobotsRules {
        guard var c = URLComponents(url: start, resolvingAgainstBaseURL: false) else { return RobotsRules() }; c.path = "/robots.txt"; c.query = nil
        guard let u = c.url, let (data, _) = try? await session.data(from: u), let text = String(data: data, encoding: .utf8) else { return RobotsRules() }
        var result = RobotsRules(); var agents: [String] = []; var sectionHasDirective = false
        for raw in text.components(separatedBy: .newlines) {
            let line = raw.split(separator: "#", maxSplits: 1).first?.trimmingCharacters(in: .whitespaces) ?? ""
            let parts = line.split(separator: ":", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }; guard parts.count == 2 else { continue }
            switch parts[0].lowercased() {
            case "user-agent":
                if sectionHasDirective { agents = []; sectionHasDirective = false }
                agents.append(parts[1].lowercased())
            case "disallow", "allow":
                sectionHasDirective = true
                guard !parts[1].isEmpty else { continue }
                for agent in agents { result.directives.append(RobotsDirective(agent: agent, directive: String(parts[0]).lowercased(), value: parts[1])) }
            case "crawl-delay" where agents.contains("googlebot") || agents.contains("*"): result.crawlDelay = TimeInterval(parts[1]) ?? 0
            case "sitemap": if let url = URL(string: parts[1]) { result.sitemaps.append(url) }
            default: break
            }
        }
        return result
    }
}

private final class SitemapXMLDelegate: NSObject, XMLParserDelegate {
    var root = ""; var locations: [String] = []; private var capturing = false; private var value = ""; private var stack: [String] = []
    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName qName: String?, attributes: [String : String] = [:]) {
        let name = elementName.lowercased(); if root.isEmpty && (name == "urlset" || name == "sitemapindex") { root = name }
        // A sitemap can contain image/video extensions with their own <loc>.
        // Only the direct URL or sitemap entry location belongs to the page map.
        if name == "loc", let parent = stack.last, parent == "url" || parent == "sitemap" { capturing = true; value = "" }
        stack.append(name)
    }
    func parser(_ parser: XMLParser, foundCharacters string: String) { if capturing { value += string } }
    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) { if elementName.lowercased() == "loc", capturing { locations.append(value.trimmingCharacters(in: .whitespacesAndNewlines)); capturing = false }; _ = stack.popLast() }
}

/// Discovers sitemap locations from robots.txt, then falls back to /sitemap.xml.
/// Every sitemap-index is recursively parsed, including multi-level indexes.
enum SitemapLoader {
    static func discover(for start: URL, session: URLSession) async -> SitemapAudit {
        let robots = await RobotsRules.load(for: start, session: session)
        let roots: [URL]
        if robots.sitemaps.isEmpty, var parts = URLComponents(url: start, resolvingAgainstBaseURL: false) {
            parts.path = "/sitemap.xml"; parts.query = nil; roots = parts.url.map { [$0] } ?? []
        } else { roots = Array(Set(robots.sitemaps)).sorted { $0.absoluteString < $1.absoluteString } }
        guard !roots.isEmpty else { return SitemapAudit(roots: roots, error: "No sitemap URL could be constructed.") }
        var audit = await scan(roots, session: session)
        // A robots declaration can be stale. In that case attempt the standard
        // address as a final discovery fallback.
        if audit.documents.isEmpty, var parts = URLComponents(url: start, resolvingAgainstBaseURL: false) {
            parts.path = "/sitemap.xml"; parts.query = nil
            if let fallback = parts.url, !roots.contains(fallback) {
                audit = await scan([fallback], session: session)
                audit.roots = roots + [fallback]
            }
        }
        if audit.documents.isEmpty && audit.error.isEmpty { audit.error = "No readable sitemap was found." }
        return audit
    }

    static func load(_ roots: [URL], session: URLSession) async -> Set<String> {
        await scan(roots, session: session).urls
    }

    private static func scan(_ roots: [URL], session: URLSession) async -> SitemapAudit {
        var audit = SitemapAudit(roots: roots); var pending = roots; var seen = Set<String>()
        while !pending.isEmpty {
            let sitemap = pending.removeFirst()
            guard !seen.contains(sitemap.absoluteString) else { continue }
            seen.insert(sitemap.absoluteString)
            do {
                let (data, response) = try await session.data(from: sitemap)
                let status = (response as? HTTPURLResponse)?.statusCode ?? 0
                guard (200..<300).contains(status) else { audit.documents.append(SitemapDocument(url: sitemap, byteSize: data.count, error: "HTTP \(status)")); continue }
                let parser = XMLParser(data: data); let delegate = SitemapXMLDelegate(); parser.delegate = delegate
                guard parser.parse(), !delegate.root.isEmpty else { audit.documents.append(SitemapDocument(url: sitemap, byteSize: data.count, error: "Invalid XML sitemap")); continue }
                audit.documents.append(SitemapDocument(url: sitemap, type: delegate.root, urlCount: delegate.locations.count, byteSize: data.count))
                if delegate.root == "sitemapindex" { pending.append(contentsOf: delegate.locations.compactMap(URL.init(string:))) }
                else { for value in delegate.locations where !value.isEmpty { audit.urlSources[value, default: []].insert(sitemap.absoluteString) } }
            } catch { audit.documents.append(SitemapDocument(url: sitemap, error: error.localizedDescription)) }
        }
        return audit
    }
}

final class CrawlRedirectObserver: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    var chain: [URL] = []; var codes: [Int] = []
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void) { codes.append(response.statusCode); if let u = request.url { chain.append(u) }; completionHandler(request) }
}
