import Foundation

actor CrawlCoordinator {
    private var queue: [(URL, Int)] = []
    private var visited: Set<String> = []
    private var stopped = false
    private var paused = false
    private var inlinks: [String: Int] = [:]
    private var sources: [String: Set<URL>] = [:]
    private let limit: Int

    init(limit: Int) { self.limit = limit }

    func seed(_ urls: [URL]) { for url in urls { enqueue(url, depth: 0, source: nil) } }
    func enqueue(_ url: URL, depth: Int, source: URL?) {
        let key = url.absoluteString
        if let source { sources[key, default: []].insert(source) }
        guard visited.count < limit, !visited.contains(key) else { return }
        visited.insert(key); queue.append((url, depth))
    }
    func sources(for url: URL) -> [URL] { Array(sources[url.absoluteString, default: []]).sorted { $0.absoluteString < $1.absoluteString } }
    func next() -> (URL, Int)? { guard !stopped, !paused, !queue.isEmpty else { return nil }; return queue.removeFirst() }
    func addInlinks(_ urls: [URL]) { for url in urls { inlinks[url.absoluteString, default: 0] += 1 } }
    func inlinkCount(_ url: URL) -> Int { inlinks[url.absoluteString, default: 0] }
    func queuedCount() -> Int { queue.count }
    func pause(_ value: Bool) { paused = value }
    func stop() { stopped = true; queue.removeAll() }
    func canContinue() -> Bool { !stopped }
}

actor CrawlerControl {
    private var active: CrawlCoordinator?
    func set(_ coordinator: CrawlCoordinator?) { active = coordinator }
    func clear(_ coordinator: CrawlCoordinator) { if active === coordinator { active = nil } }
    func pause(_ value: Bool) async { await active?.pause(value) }
    func stop() async { await active?.stop(); active = nil }
}

final class SpiderCrawler: @unchecked Sendable {
    private let control = CrawlerControl()

    func pause(_ value: Bool) async { await control.pause(value) }
    func stop() async { await control.stop() }

    func crawl(seeds: [URL], mode: CrawlMode, settings: CrawlSettings, onRecord: @escaping @Sendable (CrawlRecord) async -> Void, onQueue: @escaping @Sendable (Int) async -> Void) async {
        guard let rootHost = seeds.first?.host?.lowercased() else { return }
        let coordinator = CrawlCoordinator(limit: settings.maxURLs)
        await control.set(coordinator)
        defer { Task { await self.control.clear(coordinator) } }
        await coordinator.seed(seeds)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = settings.timeout
        configuration.httpAdditionalHeaders = [
            "User-Agent": settings.userAgent,
            "Accept": "text/html,application/xhtml+xml,application/xml;q=0.9,image/avif,image/webp,image/apng,image/svg+xml,image/*;q=0.8,*/*;q=0.7",
            "Accept-Language": "en-US,en;q=0.9"
        ]
        let session = URLSession(configuration: configuration)
        // Sitemap discovery is independent from the "respect robots" crawling policy:
        // sitemap declarations remain useful even when testing a site with robots ignored.
        let discoveredRobots = await RobotsRules.load(for: seeds[0], session: session)
        let sitemapURLs: Set<String> = mode == .spider ? await SitemapLoader.discover(for: seeds[0], session: session).urls : []
        if mode == .spider { for value in sitemapURLs.compactMap(URL.init(string:)) { await coordinator.enqueue(value, depth: 0, source: nil) } }
        let workerCount = max(1, settings.concurrency)
        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<workerCount {
                group.addTask {
                    while await coordinator.canContinue() {
                        guard let (url, depth) = await coordinator.next() else {
                            try? await Task.sleep(for: .milliseconds(120))
                            if await coordinator.queuedCount() == 0 { return }
                            continue
                        }
                        let blockedBy = discoveredRobots.blockingRule(for: url)
                        if settings.respectRobots, let blockedBy {
                            var blocked = CrawlRecord(url: url, kind: HTMLAnalyzer.isInternal(url, rootHost: rootHost, subdomains: settings.crawlSubdomains) ? .internalURL : .external, depth: depth)
                            blocked.robotsBlockedBy = blockedBy
                            blocked.indexability = "Blocked by robots.txt"
                            blocked.foundOnURLs = await coordinator.sources(for: url)
                            blocked.inSitemap = sitemapURLs.contains(url.absoluteString)
                            await onRecord(blocked)
                            await onQueue(coordinator.queuedCount())
                            continue
                        }
                        if settings.respectRobots && discoveredRobots.crawlDelay > 0 { try? await Task.sleep(for: .seconds(discoveredRobots.crawlDelay)) }
                        var record = await self.fetch(url: url, depth: depth, rootHost: rootHost, settings: settings, session: session)
                        record.robotsBlockedBy = blockedBy ?? ""
                        record.foundOnURLs = await coordinator.sources(for: url)
                        record.inSitemap = sitemapURLs.contains(record.url.absoluteString) || sitemapURLs.contains(url.absoluteString)
                        await onRecord(record)
                        if mode == .spider, record.isHTML, depth < settings.maxDepth, record.statusCode.map({ (200...299).contains($0) }) == true {
                            let analysis = HTMLAnalyzer.analyze(self.recordPayload(record), baseURL: url, rootHost: rootHost, settings: settings)
                            let links = analysis.internalLinks
                            await coordinator.addInlinks(links)
                            for link in links { await coordinator.enqueue(link, depth: depth + 1, source: record.url) }
                            // Crawl embedded internal images as resources as well. This allows
                            // broken-image findings to name the HTML page that uses the image.
                            for image in analysis.images {
                                guard let imageURL = URL(string: image.url), HTMLAnalyzer.isInternal(imageURL, rootHost: rootHost, subdomains: settings.crawlSubdomains) else { continue }
                                await coordinator.enqueue(imageURL, depth: depth + 1, source: record.url)
                            }
                        }
                        await onQueue(coordinator.queuedCount())
                    }
                }
            }
        }
    }

    // Payloads are kept only for the active fetch; this avoids retaining thousands of HTML documents in memory.
    private var payloadLock = NSLock()
    private var payloads: [UUID: String] = [:]
    private func storePayload(_ text: String, for id: UUID) { payloadLock.lock(); payloads[id] = text; payloadLock.unlock() }
    private func recordPayload(_ record: CrawlRecord) -> String { payloadLock.lock(); defer { payloadLock.unlock() }; return payloads.removeValue(forKey: record.id) ?? "" }

    private func fetch(url: URL, depth: Int, rootHost: String, settings: CrawlSettings, session: URLSession) async -> CrawlRecord {
        let start = Date()
        var result = CrawlRecord(url: url, kind: HTMLAnalyzer.isInternal(url, rootHost: rootHost, subdomains: settings.crawlSubdomains) ? .internalURL : .external, depth: depth)
        do {
            let observer = CrawlRedirectObserver()
            let fetched: (Data, URLResponse)
            var usedImageHeadProbe = false
            if Self.isLikelyImageURL(url) {
                // Do not download thousands of potentially multi-megabyte files
                // just to establish their status and byte size. A successful
                // HEAD response is sufficient; a normal browser-like GET remains
                // a fallback for CDNs that do not implement HEAD correctly.
                var imageResponse: (Data, URLResponse)?
                var lastError: Error?
                for delay in [0, 250] {
                    if delay > 0 { try? await Task.sleep(for: .milliseconds(delay)) }
                    do {
                        var request = URLRequest(url: url)
                        request.httpMethod = "HEAD"
                        request.timeoutInterval = min(8, settings.timeout)
                        let candidate = try await session.data(for: request)
                        imageResponse = candidate
                        if let http = candidate.1 as? HTTPURLResponse, (200...399).contains(http.statusCode) {
                            usedImageHeadProbe = true
                            break
                        }
                    } catch { lastError = error }
                }
                if let imageResponse, usedImageHeadProbe {
                    fetched = imageResponse
                } else {
                    // HEAD may return 403/405 while the same resource is fine
                    // in a browser, so confirm it with one GET before reporting
                    // a broken image.
                    do {
                        fetched = try await session.data(from: url)
                    } catch {
                        if let imageResponse { fetched = imageResponse }
                        else { throw lastError ?? error }
                    }
                }
            } else {
                let redirectSession = URLSession(configuration: session.configuration, delegate: observer, delegateQueue: nil)
                defer { redirectSession.invalidateAndCancel() }
                fetched = try await redirectSession.data(from: url)
            }
            let (data, response) = fetched
            result.responseTime = Date().timeIntervalSince(start)
            result.size = data.count
            var responseHeaders: [String: String] = [:]
            if let http = response as? HTTPURLResponse {
                result.statusCode = http.statusCode
                result.contentType = http.value(forHTTPHeaderField: "Content-Type") ?? "Unknown"
                if usedImageHeadProbe, let value = http.value(forHTTPHeaderField: "Content-Length"), let length = Int(value) {
                    result.size = length
                }
                responseHeaders = Dictionary(uniqueKeysWithValues: http.allHeaderFields.compactMap { key, value in
                    guard let key = key as? String else { return nil }
                    return (key, String(describing: value))
                })
                if let finalURL = response.url, finalURL != url {
                    result.redirectSources = [url]
                    result.redirectURL = finalURL
                    result.redirectChain = [url] + observer.chain
                    result.url = finalURL
                }
                for header in ["Strict-Transport-Security", "Content-Security-Policy", "X-Frame-Options", "X-Content-Type-Options"] { if let value = http.value(forHTTPHeaderField: header) { result.securityHeaders[header] = value } }
            }
            // Error responses for image URLs are often HTML error templates. They are resources, not SEO pages.
            guard result.isSEOPage, let html = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .windowsCP1251) else { return result }
            let page = HTMLAnalyzer.analyze(html, baseURL: url, rootHost: rootHost, settings: settings)
            result.title = page.title; result.metaDescription = page.description; result.metaKeywords = page.keywords; result.h1 = page.h1; result.h2 = page.h2; result.h1Count = page.h1Count; result.h2Count = page.h2Count; result.canonical = page.canonical; result.canonicalRaw = page.canonicalRaw; result.canonicalCount = page.canonicalCount; result.robots = page.robots; result.language = page.language; result.hreflang = page.hreflang; result.hreflangCodes = page.hreflangCodes; result.hreflangTargets = page.hreflangTargets; result.hasXDefault = page.hasXDefault; result.paginationURLs = page.paginationURLs; result.contentFingerprint = page.contentFingerprint; result.schemaTypes = page.schemaTypes; result.wordCount = page.wordCount; result.images = await imageSizes(page.images, session: session); result.analyticsIDs = page.analyticsIDs; result.analyticsSignals = page.analyticsSignals; result.wordPressHeadFindings = page.wordPressHeadFindings; result.internalLinks = page.internalLinks.count; result.internalLinkTargets = page.internalLinks.map(\.absoluteString); result.outgoingLinks = page.internalLinkDetails; result.externalLinks = page.externalLinks.count
            result.indexability = page.robots.lowercased().contains("noindex") ? "Noindex" : "Indexable"
            let classification = PageClassifier.classify(PageSignals(url: result.url, title: page.title, h1: page.h1, schemaTypes: Set(page.schemaTypes), ogType: page.ogType, hasPrice: page.hasPrice, hasAddToCart: page.hasAddToCart, hasBookingForm: page.hasBookingForm, hasAuthor: page.hasAuthor, hasPublishedDate: page.hasPublishedDate, hasPagination: !page.paginationURLs.isEmpty, repeatedCardCount: page.repeatedCardCount, hasContactDetails: page.hasContactDetails))
            result.pageType = classification.type; result.classificationConfidence = classification.confidence; result.classificationEvidence = classification.evidence
            let cms = CMSDetector.detect(html: html, headers: responseHeaders)
            result.cmsName = cms.name; result.cmsConfidence = cms.confidence; result.cmsEvidence = cms.evidence
            let schema = result.isSchemaEligible ? SchemaIntelligence.analyze(jsonLD: page.schemaJSON, pageType: classification.type) : SchemaInsight(entities: [], primaryType: "", compatibility: "Not applicable", completeness: 0)
            result.primarySchemaType = schema.primaryType; result.schemaCompatibility = schema.compatibility; result.schemaCompleteness = schema.completeness
            result.schemaValidationErrors = result.isSchemaEligible ? SchemaIntelligence.validations(jsonLD: page.schemaJSON).map { "\($0.type): missing \($0.missing.joined(separator: ", "))" } : []
            storePayload(html, for: result.id)
        } catch { result.responseTime = Date().timeIntervalSince(start); result.error = error.localizedDescription }
        return result
    }
    private static func isLikelyImageURL(_ url: URL) -> Bool {
        ["png", "jpg", "jpeg", "gif", "webp", "svg", "avif", "ico", "bmp", "tif", "tiff"].contains(url.pathExtension.lowercased())
    }
    private func imageSizes(_ images: [CrawledImage], session: URLSession) async -> [CrawledImage] {
        // Keep probes bounded. The crawler also downloads image resources
        // separately, so probing every <img> on image-heavy pages can hold a
        // whole worker for many minutes when a CDN stalls HEAD requests.
        // Twelve representative probes still provide useful page-level data;
        // the resource records remain the source of truth for image issues.
        var result: [CrawledImage] = []
        for batch in stride(from: 0, to: min(images.count, 12), by: 3) {
            let slice = images.dropFirst(batch).prefix(3)
            await withTaskGroup(of: CrawledImage.self) { group in
                for image in slice { group.addTask {
                    var copy = image
                    guard let url = URL(string: image.url) else { return copy }
                    var request = URLRequest(url: url)
                    request.httpMethod = "HEAD"
                    request.timeoutInterval = min(6, session.configuration.timeoutIntervalForRequest)
                    if let (_, response) = try? await session.data(for: request), let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode), let length = http.value(forHTTPHeaderField: "Content-Length") { copy.size = Int(length) ?? 0 }
                    return copy
                } }
                for await image in group { result.append(image) }
            }
        }
        return result
    }
}
