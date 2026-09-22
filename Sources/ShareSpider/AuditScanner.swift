import Foundation

final class RedirectObserver: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    var statuses: [Int] = []
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
        statuses.append(response.statusCode)
        completionHandler(request)
    }
}

enum AuditScanner {
    static func run(startURL: URL, records: [CrawlRecord]) async -> AuditReport {
        var report = AuditReport()
        guard let host = startURL.host else { return report }
        async let resolvedIPs = SiteDiagnostics.resolveIPs(host: host)
        async let ahrefsRating = SiteDiagnostics.domainRating(host: host)
        async let sitemap = SitemapLoader.discover(for: startURL, session: .shared)
        report.robots = await robotsAudit(startURL)
        let blocked = records.filter { !$0.robotsBlockedBy.isEmpty }
        report.robots.blockedURLCount = blocked.count
        report.robots.blockingRules = Dictionary(grouping: blocked, by: \.robotsBlockedBy)
            .map { RobotsBlockingRule(rule: $0.key, urlCount: $0.value.count) }
            .sorted { $0.rule < $1.rule }
        let bare = host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
        let variants = ["http://\(bare)", "http://www.\(bare)", "https://\(bare)", "https://www.\(bare)"] .compactMap(URL.init(string:))
        report.mirrors = await withTaskGroup(of: MirrorResult.self) { group in
            for url in variants { group.addTask { await check(url) } }
            return await group.reduce(into: []) { $0.append($1) }.sorted { $0.source.absoluteString < $1.source.absoluteString }
        }
        // Check common duplicate forms beyond the four domain mirrors: the
        // homepage's index files and one representative internal URL with the
        // opposite trailing-slash variant.
        let pageVariants = redirectVariants(startURL: startURL, records: records)
        let variantResults = await withTaskGroup(of: MirrorResult.self) { group in
            for url in pageVariants { group.addTask { await check(url) } }
            return await group.reduce(into: []) { $0.append($1) }
        }
        report.mirrors.append(contentsOf: variantResults)
        let main = report.mirrors.first(where: { $0.source.scheme == "https" && !$0.source.host!.hasPrefix("www.") })?.finalURL
        let conflicts = report.mirrors.filter { $0.status == 200 && $0.finalURL?.host != main?.host }
        let http200 = report.mirrors.filter { $0.source.scheme == "http" && $0.status == 200 && $0.finalURL?.scheme == "http" }
        if !conflicts.isEmpty { report.findings.append(AuditFinding(title: "Conflicting domain mirrors", severity: "High", detail: "Different domain variants resolve to different final hosts.", urlIDs: [])) }
        if !http200.isEmpty { report.findings.append(AuditFinding(title: "HTTP does not redirect to HTTPS", severity: "High", detail: "One or more HTTP variants remain available over HTTP.", urlIDs: [])) }
        if report.mirrors.contains(where: { $0.redirects > 1 }) { report.findings.append(AuditFinding(title: "Extra redirect hops", severity: "Medium", detail: "At least one mirror reaches its final URL through more than one redirect.", urlIDs: [])) }
        let directVariantDuplicates = variantResults.filter { ($0.status ?? 0) / 100 == 2 && $0.redirects == 0 }
        if !directVariantDuplicates.isEmpty {
            report.findings.append(AuditFinding(title: "Directly accessible URL variants", severity: "High", detail: "A slash, non-slash or index-file variant returns 200 without redirecting to the preferred URL: \(directVariantDuplicates.map { $0.source.absoluteString }.joined(separator: "; ")).", urlIDs: []))
        }
        // Binary image files are resources, not HTML pages for analytics or client SEO findings.
        let pages = records.filter(\.isSEOPage); report.totalHTMLPages = pages.count
        let tagged = pages.filter { !$0.analyticsIDs.isEmpty || !$0.analyticsSignals.isEmpty }; report.analyticsPages = tagged.count; report.analyticsIDs = Set(tagged.flatMap(\.analyticsIDs))
        let missing = Set(pages.filter { $0.analyticsIDs.isEmpty && $0.analyticsSignals.isEmpty }.map(\.id))
        if tagged.isEmpty { report.findings.append(AuditFinding(title: "Analytics code not detected", severity: "Medium", detail: "No GTM, GA4, Universal Analytics, gtag or dataLayer code was found. This does not verify tracking delivery.", urlIDs: missing)) }
        else if !missing.isEmpty { report.findings.append(AuditFinding(title: "Analytics missing on some pages", severity: "Medium", detail: "Analytics code was not detected on \(missing.count) HTML pages.", urlIDs: missing)) }
        if report.analyticsIDs.count > 1 { report.findings.append(AuditFinding(title: "Multiple analytics identifiers", severity: "High", detail: "Found: \(report.analyticsIDs.sorted().joined(separator: ", ")).", urlIDs: Set(tagged.map(\.id)))) }
        if report.analyticsIDs.contains(where: { $0.hasPrefix("UA-") }) && !report.analyticsIDs.contains(where: { $0.hasPrefix("G-") || $0.hasPrefix("GTM-") }) { report.findings.append(AuditFinding(title: "Universal Analytics only", severity: "Low", detail: "Only the deprecated UA identifier was found.", urlIDs: Set(tagged.map(\.id)))) }
        let wordPressPages = pages.filter { $0.cmsName == "WordPress" }
        let wpHeadExposure = wordPressPages.filter { !$0.wordPressHeadFindings.isEmpty }
        if !wpHeadExposure.isEmpty {
            let types = Array(Set(wpHeadExposure.flatMap(\.wordPressHeadFindings))).sorted().joined(separator: "; ")
            report.findings.append(AuditFinding(title: "WordPress technical head links", severity: "Medium", detail: "WordPress service links are exposed in the HTML head on \(wpHeadExposure.count) page(s): \(types). Remove unused RSS/comments feed discovery, RSD/XML-RPC discovery, shortlink and WordPress version generator tags from the public template. This reduces unnecessary technical endpoints and duplicate URL signals.", urlIDs: Set(wpHeadExposure.map(\.id))))
        }
        let technical = records.filter { r in let u = r.url.absoluteString.lowercased(); return u.contains("?p=") || u.contains("page_id=") || u.contains("author=") || u.contains("attachment_id=") || u.contains("/feed") || u.contains("trackback") || u.contains("wp-json") || u.contains("xmlrpc.php") || u.contains("wp-login") || u.contains("wp-admin") || u.contains("index.php") || u.contains("index.html") || u.contains("/amp") || u.contains("print") || r.url.path.contains("//") || (r.url.query?.isEmpty == true) }
        let dangerous = Set(technical.filter { ($0.statusCode ?? 0) == 200 && $0.indexability == "Indexable" }.map(\.id))
        if !dangerous.isEmpty {
            let examples = technical.filter { dangerous.contains($0.id) }.prefix(3).map(\.url.absoluteString).joined(separator: "; ")
            report.findings.append(AuditFinding(title: "Indexable technical duplicate URLs", severity: "High", detail: "What it means: a technical or parameter URL returns 200 and is allowed to be indexed, so it can compete with the main page and create duplicate content. Found \(dangerous.count) URL(s): \(examples). Fix: redirect the technical URL to the preferred human-readable page, set its canonical to that page, and remove it from internal links and the sitemap.", urlIDs: dangerous))
        }
        report.sitemap = await sitemap
        let sitemapRecords = records.filter { $0.inSitemap }
        let crawledKeys = Set(records.flatMap { [$0.url.absoluteString] + $0.redirectSources.map(\.absoluteString) }.map(sitemapKey))
        report.sitemap.notCrawled = report.sitemap.urls.filter { !crawledKeys.contains(sitemapKey($0)) }.sorted()
        // Check sitemap URLs that were not reached during the crawl. A finite cap
        // protects a client machine from an accidental million-URL sitemap.
        report.sitemap.checks = await sitemapChecks(report.sitemap.notCrawled.prefix(1_000).compactMap(URL.init(string:)))
        report.sitemap.summary.nonCanonical = sitemapRecords.filter { !$0.canonical.isEmpty && sitemapKey($0.canonical) != sitemapKey($0.url.absoluteString) }.count
        report.sitemap.summary.redirects = sitemapRecords.filter { $0.hasRedirect || !$0.redirectChain.isEmpty }.count
        report.sitemap.summary.broken = sitemapRecords.filter { !$0.error.isEmpty || (($0.statusCode ?? 0) / 100 != 2) }.count + report.sitemap.checks.filter { !$0.error.isEmpty || (($0.status ?? 0) / 100 != 2) }.count
        report.sitemap.summary.missingFromSitemap = records.filter { $0.isSEOPage && ($0.statusCode ?? 0) / 100 == 2 && !$0.inSitemap }.count
        report.sitemap.summary.isolated = sitemapRecords.filter { $0.isSEOPage && $0.depth > 0 && $0.inlinks == 0 }.count
        func sitemapFinding(_ title: String, _ severity: String, _ detail: String, _ test: (CrawlRecord) -> Bool) {
            let ids = Set(sitemapRecords.filter(test).map(\.id)); if !ids.isEmpty { report.findings.append(AuditFinding(title: title, severity: severity, detail: detail + " Affected URLs: \(ids.count).", urlIDs: ids)) }
        }
        sitemapFinding("Non-200 URLs in sitemap", "High", "A sitemap should contain only final, successful URLs.") { !$0.error.isEmpty || (($0.statusCode ?? 0) / 100 != 2) }
        sitemapFinding("Redirect URLs in sitemap", "Medium", "A sitemap should point directly to the final URL, not a 3xx redirect.") { $0.hasRedirect || !$0.redirectChain.isEmpty }
        sitemapFinding("Non-canonical URLs in sitemap", "Medium", "The sitemap contains URLs whose canonical points to another page.") { !$0.canonical.isEmpty && $0.canonical.trimmingCharacters(in: CharacterSet(charactersIn: "/")) != $0.url.absoluteString.trimmingCharacters(in: CharacterSet(charactersIn: "/")) }
        sitemapFinding("Noindex URLs in sitemap", "High", "Noindex pages should not be listed in an XML sitemap.") { $0.indexability == "Noindex" }
        sitemapFinding("Technical URLs in sitemap", "Medium", "Parameters and CMS/service endpoints should not be submitted in a sitemap.") { $0.url.query != nil || $0.url.path.contains("wp-") || $0.url.path.contains("index.") }
        let uncheckedBroken = report.sitemap.checks.filter { !$0.error.isEmpty || (($0.status ?? 0) / 100 != 2) }
        if !uncheckedBroken.isEmpty { report.findings.append(AuditFinding(title: "Broken URLs in sitemap", severity: "High", detail: "Sitemap URLs not reached in the crawl were checked directly; \(uncheckedBroken.count) return an error or non-2xx status.", urlIDs: [])) }
        if !report.sitemap.notCrawled.isEmpty { report.findings.append(AuditFinding(title: "URLs in sitemap not found by crawler", severity: "Medium", detail: "\(report.sitemap.notCrawled.count) sitemap URL(s) were absent from the completed crawl. This can indicate isolated pages, crawl limits, or unavailable URL variants.", urlIDs: [])) }
        let outsideSitemap = records.filter { $0.isSEOPage && ($0.statusCode ?? 0) / 100 == 2 && !$0.inSitemap }
        if !outsideSitemap.isEmpty { report.findings.append(AuditFinding(title: "Available pages outside sitemap", severity: "Medium", detail: "\(outsideSitemap.count) successful HTML page(s) discovered by crawl are not listed in the XML sitemap.", urlIDs: Set(outsideSitemap.map(\.id)))) }
        report.hreflang = await hreflangAudit(records)
        let badHreflang = report.hreflang.filter { ($0.status ?? 0) / 100 != 2 || !$0.resolvesToDeclaredTarget }
        let missingReturns = report.hreflang.filter { $0.returnLinkCheckable && !$0.reciprocal }
        let invalidCodes = report.hreflang.filter { !$0.validCode }
        let noSelf = report.hreflang.filter { !$0.selfReference }.map(\.source)
        let canonicalMismatch = report.hreflang.filter { !$0.targetCanonical.isEmpty && sitemapKey($0.targetCanonical) != sitemapKey($0.target.absoluteString) }
        let noindexTargets = report.hreflang.filter(\.targetNoindex)
        let duplicateCodes = report.hreflang.filter(\.duplicateCode)
        let hreflangConflicts = report.hreflang.filter(\.conflict)
        let languageMismatch = report.hreflang.filter { !$0.languageMatches }
        if !badHreflang.isEmpty { report.findings.append(AuditFinding(title: "Hreflang targets are not final 200 URLs", severity: "High", detail: "Some hreflang targets return an error or redirect instead of a final 200 response.", urlIDs: Set(records.filter { page in badHreflang.contains { $0.source == page.url } }.map(\.id)))) }
        if !missingReturns.isEmpty { report.findings.append(AuditFinding(title: "Hreflang return links missing", severity: "High", detail: "Some alternate pages do not link back to the source page.", urlIDs: Set(records.filter { page in missingReturns.contains { $0.source == page.url } }.map(\.id)))) }
        if !invalidCodes.isEmpty { report.findings.append(AuditFinding(title: "Invalid hreflang language or region codes", severity: "Medium", detail: "Use ISO language codes and optional ISO region codes, e.g. en or en-GB.", urlIDs: Set(records.filter { page in invalidCodes.contains { $0.source == page.url } }.map(\.id)))) }
        if !noSelf.isEmpty { report.findings.append(AuditFinding(title: "Hreflang self-reference missing", severity: "High", detail: "Each language page should include an hreflang link to its own canonical URL.", urlIDs: Set(records.filter { noSelf.contains($0.url) }.map(\.id)))) }
        if !canonicalMismatch.isEmpty { report.findings.append(AuditFinding(title: "Hreflang target is non-canonical", severity: "High", detail: "Some hreflang links target a URL whose canonical points elsewhere.", urlIDs: Set(records.filter { page in canonicalMismatch.contains { $0.source == page.url } }.map(\.id)))) }
        if !noindexTargets.isEmpty { report.findings.append(AuditFinding(title: "Hreflang target is noindex", severity: "High", detail: "Noindex pages should not be used as language alternates.", urlIDs: Set(records.filter { page in noindexTargets.contains { $0.source == page.url } }.map(\.id)))) }
        if !duplicateCodes.isEmpty { report.findings.append(AuditFinding(title: "Duplicate hreflang codes", severity: "Medium", detail: "A source page contains multiple entries for the same language or region.", urlIDs: Set(records.filter { page in duplicateCodes.contains { $0.source == page.url } }.map(\.id)))) }
        if !hreflangConflicts.isEmpty { report.findings.append(AuditFinding(title: "Conflicting hreflang language versions", severity: "High", detail: "The same language code points to different alternate URLs.", urlIDs: Set(records.filter { page in hreflangConflicts.contains { $0.source == page.url } }.map(\.id)))) }
        if !languageMismatch.isEmpty { report.findings.append(AuditFinding(title: "Hreflang does not match target language", severity: "Medium", detail: "The alternate hreflang code differs from the target page html lang value.", urlIDs: Set(records.filter { page in languageMismatch.contains { $0.source == page.url } }.map(\.id)))) }
        report.siteProfile.ipAddresses = await resolvedIPs
        let ahrefs = await ahrefsRating
        report.siteProfile.domainRating = ahrefs.value
        report.siteProfile.domainRatingError = ahrefs.error
        let cms = pages.filter { $0.cmsName != "Unknown" }.reduce(into: [String: (count: Int, confidence: Double, evidence: [String])]()) { values, page in
            var current = values[page.cmsName] ?? (0, 0, [])
            current.count += 1; current.confidence = max(current.confidence, page.cmsConfidence)
            current.evidence = Array(Set(current.evidence + page.cmsEvidence)).sorted()
            values[page.cmsName] = current
        }.max { $0.value.count < $1.value.count }
        if let cms { report.siteProfile.cmsName = cms.key; report.siteProfile.cmsConfidence = cms.value.confidence; report.siteProfile.cmsEvidence = cms.value.evidence }
        return report
    }
    private static func robotsAudit(_ start: URL) async -> RobotsAudit {
        guard var components = URLComponents(url: start, resolvingAgainstBaseURL: false) else { return RobotsAudit(error: "Invalid start URL") }; components.path = "/robots.txt"; components.query = nil
        guard let url = components.url else { return RobotsAudit(error: "Invalid robots URL") }
        do {
            let (data, response) = try await URLSession.shared.data(from: url)
            guard (response as? HTTPURLResponse)?.statusCode == 200, let text = String(data: data, encoding: .utf8) else { return RobotsAudit(error: "robots.txt is unavailable") }
            var audit = RobotsAudit(available: true); var agents: [String] = []; var sectionHasRules = false
            var groupDirectives: [String: [(key: String, value: String)]] = [:]
            func finishSection() { if !agents.isEmpty { audit.sections += 1; sectionHasRules = false } }
            for raw in text.components(separatedBy: .newlines) {
                if raw.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("#") { audit.commentLines += 1 }
                let line = raw.split(separator: "#", maxSplits: 1).first?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""; let parts = line.split(separator: ":", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }; guard parts.count == 2 else { continue }; let key = parts[0].lowercased(); let value = parts[1]
                if key == "user-agent" { if sectionHasRules { finishSection(); agents = [] }; agents.append(value.lowercased()); continue }
                guard key == "disallow" || key == "allow" else { continue }
                sectionHasRules = true
                for agent in agents { groupDirectives[agent.lowercased(), default: []].append((key, value)) }
            }
            if !agents.isEmpty { audit.sections += 1 }
            func effective(_ directives: [(key: String, value: String)]) -> [(key: String, value: String)] {
                directives.filter { !$0.value.isEmpty && !($0.key == "allow" && $0.value == "/") }
            }
            func selectRules(for crawler: String) -> (source: String, rules: [(key: String, value: String)]) {
                // A specific bot group wins over the wildcard group. Rules are
                // never combined, as this is how Google evaluates robots.txt.
                let specific = groupDirectives.filter { $0.key == crawler }
                if !specific.isEmpty { return (specific.keys.sorted().joined(separator: ", "), specific.values.flatMap { $0 }) }
                return (groupDirectives["*"] == nil ? "no matching group" : "User-agent: *", groupDirectives["*"] ?? [])
            }
            let google = selectRules(for: "googlebot")
            let bing = selectRules(for: "bingbot")
            let yandex = selectRules(for: "yandex")
            audit.googleRuleSource = google.source; audit.bingRuleSource = bing.source; audit.yandexRuleSource = yandex.source
            audit.googleRules = effective(google.rules).count; audit.bingRules = effective(bing.rules).count; audit.yandexRules = effective(yandex.rules).count
            audit.effectiveRules = Set(groupDirectives.values.flatMap(effective).map { "\($0.key):\($0.value)" }).count
            audit.blocksSite = [google, bing, yandex].contains { selection in effective(selection.rules).contains { $0.key == "disallow" && $0.value == "/" } }
            return audit
        } catch { return RobotsAudit(error: error.localizedDescription) }
    }
    private static func check(_ url: URL) async -> MirrorResult {
        var request = URLRequest(url: url); request.timeoutInterval = 15
        let observer = RedirectObserver()
        let session = URLSession(configuration: .ephemeral, delegate: observer, delegateQueue: nil)
        do { let (_, response) = try await session.data(for: request); let http = response as? HTTPURLResponse; let final = response.url; return MirrorResult(source: url, status: http?.statusCode, finalURL: final, redirects: observer.statuses.count, redirectStatuses: observer.statuses, error: "") }
        catch { return MirrorResult(source: url, status: nil, finalURL: nil, redirects: 0, error: error.localizedDescription) }
    }
    private static func redirectVariants(startURL: URL, records: [CrawlRecord]) -> [URL] {
        var values = Set<String>()
        func add(_ url: URL?) { if let url, url != startURL { values.insert(url.absoluteString) } }
        // Main-page aliases are always useful to test.
        if var root = URLComponents(url: startURL, resolvingAgainstBaseURL: false) {
            root.path = "/index.html"; root.query = nil; add(root.url)
            root.path = "/index.php"; add(root.url)
        }
        // One internal SEO page is enough for a lightweight audit probe.
        if let page = records.first(where: { $0.isSEOPage && $0.url.path != "/" && !$0.url.path.isEmpty }), var parts = URLComponents(url: page.url, resolvingAgainstBaseURL: false) {
            let path = parts.path
            parts.path = path.hasSuffix("/") ? String(path.dropLast()) : path + "/"
            add(parts.url)
        }
        return values.compactMap(URL.init(string:)).sorted { $0.absoluteString < $1.absoluteString }
    }
    private static func sitemapKey(_ value: String) -> String { value.trimmingCharacters(in: CharacterSet(charactersIn: "/")) }
    private static func sitemapChecks(_ urls: [URL]) async -> [SitemapURLCheck] {
        await withTaskGroup(of: SitemapURLCheck.self) { group in
            // These URLs are intentionally absent from the crawl and are the
            // only sitemap addresses that need a separate probe. Keep the
            // network work bounded; launching hundreds at once slows the Mac
            // and often causes server throttling/timeouts.
            var iterator = urls.makeIterator()
            for _ in 0..<min(8, urls.count) {
                if let url = iterator.next() {
                    group.addTask {
                        let result = await check(url)
                        return SitemapURLCheck(url: url, status: result.status, finalURL: result.finalURL, error: result.error)
                    }
                }
            }
            var values: [SitemapURLCheck] = []
            while let value = await group.next() {
                values.append(value)
                if let url = iterator.next() {
                    group.addTask {
                        let result = await check(url)
                        return SitemapURLCheck(url: url, status: result.status, finalURL: result.finalURL, error: result.error)
                    }
                }
            }
            return values.sorted { $0.url.absoluteString < $1.url.absoluteString }
        }
    }
    private static func hreflangAudit(_ records: [CrawlRecord]) async -> [HreflangResult] {
        // Overview already contains the crawler's response, final URL, canonical,
        // language and robots data. Reuse every crawled record here instead of
        // fetching an alternate URL a second time during the audit.
        let crawledRecords = records
        let pages = crawledRecords.filter { $0.isSEOPage && !$0.hreflangTargets.isEmpty }
        // A URL can be discovered from more than one source (for example a
        // sitemap and several internal links). Keep the first crawled record
        // instead of requiring unique dictionary keys and crashing the audit.
        let known = crawledRecords.reduce(into: [String: CrawlRecord]()) { result, page in
            let key = hreflangURLKey(page.url)
            if result[key] == nil { result[key] = page }
        }
        let pairs = pages.flatMap { page in page.hreflangTargets.compactMap { link in URL(string: link.url).map { (page, link, $0) } } }
        let uniqueTargets = Array(Dictionary(grouping: pairs.map { $0.2 }, by: hreflangURLKey).values.compactMap(\.first))
        let remoteTargets = uniqueTargets.filter { known[hreflangURLKey($0)] == nil }
        let probes = await hreflangProbes(remoteTargets)
        let probeByKey = Dictionary(uniqueKeysWithValues: probes.map { (hreflangURLKey($0.target), $0) })
        return pairs.map { page, link, target in
            let targetKey = hreflangURLKey(target)
            let localTarget = known[targetKey]
            let probe: HreflangProbe
            if let localTarget {
                probe = HreflangProbe(target: target, status: localTarget.statusCode, finalURL: localTarget.url, canonical: localTarget.canonical, noindex: localTarget.indexability == "Noindex", language: localTarget.language, alternateURLKeys: Set(localTarget.hreflangTargets.compactMap { URL(string: $0.url).map(hreflangURLKey) }), error: localTarget.error)
            } else {
                probe = probeByKey[targetKey] ?? HreflangProbe(target: target, status: nil, finalURL: nil, error: "Target was not checked")
            }
            // The alternate page can be outside the crawled host.  In that
            // case its hreflang declarations are collected by hreflangProbes.
            // Compare normalised URLs: / and an omitted root slash are the
            // same address for the purpose of a reciprocal hreflang link.
            let returnLinkCheckable = !probe.alternateURLKeys.isEmpty
            let reciprocal = probe.alternateURLKeys.contains(hreflangURLKey(page.url))
            let sameCodeEntries = page.hreflangTargets.filter { $0.code.caseInsensitiveCompare(link.code) == .orderedSame }
            let distinctTargets = Set(sameCodeEntries.map { sitemapKey($0.url) })
            let sourceKey = sitemapKey(page.url.absoluteString)
            let selfReference = page.hreflangTargets.contains { sitemapKey($0.url) == sourceKey }
            let codeLanguage = link.code.lowercased().split(separator: "-").first.map(String.init) ?? ""
            let pageLanguage = probe.language.lowercased().split(separator: "-").first.map(String.init) ?? ""
            return HreflangResult(source: page.url, code: link.code, target: target, status: probe.status, finalURL: probe.finalURL, reciprocal: reciprocal, validCode: validHreflangCode(link.code), selfReference: selfReference, targetCanonical: probe.canonical, targetNoindex: probe.noindex, targetLanguage: probe.language, languageMatches: pageLanguage.isEmpty || codeLanguage == "x" || codeLanguage == pageLanguage, duplicateCode: sameCodeEntries.count > 1, conflict: distinctTargets.count > 1, returnLinkCheckable: returnLinkCheckable, returnLinkTargets: probe.alternateURLKeys, error: probe.error)
        }.sorted { $0.source.absoluteString < $1.source.absoluteString }
    }
    private static func validHreflangCode(_ value: String) -> Bool {
        if value.lowercased() == "x-default" { return true }
        return value.range(of: "^[a-z]{2,3}(-[A-Z]{2}|-[0-9]{3})?$", options: .regularExpression) != nil
    }
    private static func hreflangURLKey(_ url: URL) -> String {
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            return url.absoluteString.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        }
        components.scheme = components.scheme?.lowercased()
        components.host = components.host?.lowercased()
        components.fragment = nil
        if (components.scheme == "https" && components.port == 443) || (components.scheme == "http" && components.port == 80) {
            components.port = nil
        }
        if components.path == "/" { components.path = "" }
        else if components.path.hasSuffix("/") { components.path.removeLast() }
        return components.string ?? url.absoluteString.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    }
    private struct HreflangProbe: Sendable { var target: URL; var status: Int?; var finalURL: URL?; var canonical = ""; var noindex = false; var language = ""; var alternateURLKeys: Set<String> = []; var error = "" }
    private static func hreflangProbes(_ targets: [URL]) async -> [HreflangProbe] {
        func probe(_ target: URL) async -> HreflangProbe {
            var request = URLRequest(url: target); request.timeoutInterval = 12
            // Some CDN/WAF configurations serve a reduced or challenge page to
            // URLSession's default user agent. Use the same browser-like headers
            // as the crawler so reciprocal hreflang is read from the actual page.
            let crawlSettings = CrawlSettings()
            request.setValue(crawlSettings.userAgent, forHTTPHeaderField: "User-Agent")
            request.setValue("text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8", forHTTPHeaderField: "Accept")
            request.setValue("en-US,en;q=0.9", forHTTPHeaderField: "Accept-Language")
            let observer = RedirectObserver(); let session = URLSession(configuration: .ephemeral, delegate: observer, delegateQueue: nil)
            do {
                let (data, response) = try await session.data(for: request)
                let status = (response as? HTTPURLResponse)?.statusCode
                let final = response.url
                guard let final, let html = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .windowsCP1251) else { return HreflangProbe(target: target, status: status, finalURL: final) }
                let page = HTMLAnalyzer.analyze(html, baseURL: final, rootHost: final.host ?? "", settings: CrawlSettings())
                // Keep the DOM parse as the primary source, then add a
                // deliberately small raw-tag fallback. A few production pages
                // contain malformed link markup that SwiftSoup repairs in a way
                // that loses an attribute; a valid reciprocal href must not be
                // reported as missing merely because of that repair.
                let parsedKeys = Set(page.hreflangTargets.compactMap { URL(string: $0.url).map(hreflangURLKey) })
                let alternateURLKeys = parsedKeys.union(rawHreflangURLKeys(in: html, baseURL: final))
                return HreflangProbe(target: target, status: status, finalURL: final, canonical: page.canonical, noindex: page.robots.localizedCaseInsensitiveContains("noindex"), language: page.language, alternateURLKeys: alternateURLKeys)
            } catch { return HreflangProbe(target: target, status: nil, finalURL: nil, error: error.localizedDescription) }
        }
        return await withTaskGroup(of: HreflangProbe.self) { group in
            var iterator = targets.makeIterator()
            for _ in 0..<min(8, targets.count) { if let target = iterator.next() { group.addTask { await probe(target) } } }
            var values: [HreflangProbe] = []
            while let result = await group.next() { values.append(result); if let target = iterator.next() { group.addTask { await probe(target) } } }
            return values
        }
    }
    private static func rawHreflangURLKeys(in html: String, baseURL: URL) -> Set<String> {
        guard let tagRegex = try? NSRegularExpression(pattern: "(?is)<link\\b[^>]*\\bhreflang\\s*=\\s*(?:\\\"[^\\\"]*\\\"|'[^']*'|[^\\s>]+)[^>]*>"),
              let hrefRegex = try? NSRegularExpression(pattern: "(?is)\\bhref\\s*=\\s*(?:\\\"([^\\\"]*)\\\"|'([^']*)'|([^\\s>]+))") else { return [] }
        let fullRange = NSRange(html.startIndex..., in: html)
        return Set(tagRegex.matches(in: html, range: fullRange).compactMap { match in
            guard let tagRange = Range(match.range, in: html) else { return nil }
            let tag = String(html[tagRange])
            guard let hrefMatch = hrefRegex.firstMatch(in: tag, range: NSRange(tag.startIndex..., in: tag)) else { return nil }
            let value = (1...3).compactMap { index in
                let range = hrefMatch.range(at: index)
                return range.location == NSNotFound ? nil : Range(range, in: tag).map { String(tag[$0]) }
            }.first
            guard let value, !value.isEmpty, let url = URL(string: value, relativeTo: baseURL)?.absoluteURL else { return nil }
            return hreflangURLKey(url)
        })
    }
}
