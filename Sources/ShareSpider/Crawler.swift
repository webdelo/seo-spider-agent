import Foundation

actor CrawlCoordinator {
    private var queue: [(URL, Int)] = []
    private var cursor = 0
    private var active = 0
    private var visited: Set<String> = []
    private var stopped = false
    private var paused = false
    private var inlinks: [String: Int] = [:]
    private var sources: [String: Set<URL>] = [:]
    /// Source-link lists are evidence for a finding, not an unbounded crawl
    /// graph kept forever. Keeping the first references is enough to explain a
    /// broken URL while preventing category pages from retaining thousands of
    /// duplicate source URLs in memory.
    private let retainedSourceLimit = 20
    /// Keep workers alive while robots.txt and sitemap discovery run in the
    /// background. Without this, a slow preflight either freezes the first
    /// request or lets workers exit before sitemap URLs can be enqueued.
    private var preflightPending = true
    private let limit: Int

    init(limit: Int) { self.limit = limit }

    func seed(_ urls: [URL]) { for url in urls { enqueue(url, depth: 0, source: nil) } }
    func enqueue(_ url: URL, depth: Int, source: URL?) {
        let key = url.absoluteString
        if let source {
            var sourceSet = sources[key, default: []]
            if sourceSet.contains(source) || sourceSet.count < retainedSourceLimit {
                sourceSet.insert(source)
                sources[key] = sourceSet
            }
        }
        guard visited.count < limit, !visited.contains(key) else { return }
        visited.insert(key); queue.append((url, depth))
    }
    func sources(for url: URL) -> [URL] { Array(sources[url.absoluteString, default: []]).sorted { $0.absoluteString < $1.absoluteString } }
    func next() -> (URL, Int)? {
        guard !stopped, !paused, cursor < queue.count else { return nil }
        let item = queue[cursor]; cursor += 1; active += 1
        return item
    }
    func completed() { active = max(0, active - 1) }
    func exhausted() -> Bool { !paused && !preflightPending && cursor == queue.count && active == 0 }
    func addInlinks(_ urls: [URL]) { for url in urls { inlinks[url.absoluteString, default: 0] += 1 } }
    func inlinkCount(_ url: URL) -> Int { inlinks[url.absoluteString, default: 0] }
    func queuedCount() -> Int { max(0, queue.count - cursor) }
    func pause(_ value: Bool) { paused = value }
    func stop() { stopped = true; queue.removeAll(); cursor = 0 }
    func finishPreflight() { preflightPending = false }
    func canContinue() -> Bool { !stopped }
}

/// Robots and sitemap discovery are metadata enrichment, not a prerequisite
/// for fetching the homepage. Workers read the latest snapshot without waiting
/// for a slow or blocked preflight request.
actor CrawlPreflight {
    private var robots = RobotsRules()
    private var sitemapURLs: Set<String> = []

    func update(robots: RobotsRules, sitemapURLs: Set<String>) {
        self.robots = robots
        self.sitemapURLs = sitemapURLs
    }
    func blockingRule(for url: URL, userAgent: String) -> String? { robots.blockingRule(for: url, userAgent: userAgent) }
    func crawlDelay(for userAgent: String) -> TimeInterval { robots.crawlDelay(for: userAgent) }
    func containsInSitemap(_ url: URL) -> Bool { sitemapURLs.contains(url.absoluteString) }
}

struct CrawlStageProgress: Sendable, Codable {
    var htmlCompleted = 0
    var htmlFinished = false
    var weightTotal = 0
    var weightCompleted = 0
    var weightPartial = 0
    var weightActive = 0
    var cdpQueued = 0
    var cdpCompleted = 0
    var cdpVerified = 0
    var cdpPrimary = 0
    var crawlerThrottle = 0
    var transportMode = "normal HTTP"
}

actor PageWeightQueue {
    // The audited record is already retained by the view model.  Holding the
    // same large value (resource list, links and image metadata) for the
    // lifetime of the crawl doubled memory use on catalogue sites.
    private var queue: [CrawlRecord?] = []
    private var cursor = 0
    private var closed = false
    private var progress = CrawlStageProgress()
    func append(_ record: CrawlRecord) { queue.append(record); progress.weightTotal += 1 }
    func next() -> CrawlRecord? {
        guard cursor < queue.count else { return nil }
        let record = queue[cursor]
        queue[cursor] = nil
        cursor += 1
        guard let record else { return nil }
        progress.weightActive += 1
        return record
    }
    func htmlCompleted() { progress.htmlCompleted += 1 }
    func complete(partial: Bool) { progress.weightCompleted += 1; progress.weightActive -= 1; if partial { progress.weightPartial += 1 } }
    func close() { closed = true; progress.htmlFinished = true }
    func fallbackQueued() { progress.cdpQueued += 1 }
    func fallbackCompleted(verified: Bool) { progress.cdpCompleted += 1; if verified { progress.cdpVerified += 1 } }
    func throttle(_ milliseconds: Int) { progress.crawlerThrottle = milliseconds }
    func transport(_ plan: CrawlTransportPlan) { progress.transportMode = plan.label; if plan.transport == .cdp { progress.cdpPrimary += 1 } }
    func finished() -> Bool { closed && cursor == queue.count }
    func snapshot() -> CrawlStageProgress { progress }
}

/// Downloading HTML is mostly I/O-bound; constructing a large SwiftSoup DOM is
/// CPU- and memory-bound. Keep those concerns separate so five HTTP workers do
/// not inflate five huge documents simultaneously and stall the whole crawl.
actor HTMLAnalysisGate {
    private let limit: Int
    private var active = 0
    private var waiters: [CheckedContinuation<Void, Never>] = []

    init(limit: Int) { self.limit = max(1, limit) }

    func acquire() async {
        if active < limit {
            active += 1
            return
        }
        await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
    }

    func release() {
        if let waiter = waiters.first {
            waiters.removeFirst()
            waiter.resume()
        } else {
            active = max(0, active - 1)
        }
    }
}

enum CrawlTransport: String, Sendable { case http, cdp }
enum AdaptiveCrawlMode: String, Sendable { case normal, cautious, cdp, recovery }
struct CrawlTransportPlan: Sendable {
    var transport: CrawlTransport
    var delayMilliseconds: Int
    var isHTTPProbe = false
    var mode: AdaptiveCrawlMode
    var label: String {
        switch mode {
        case .normal: "normal HTTP"
        case .cautious: "cautious HTTP"
        case .cdp: isHTTPProbe ? "CDP mode · HTTP probe" : "CDP mode"
        case .recovery: "recovery HTTP"
        }
    }
}

/// Per-domain adaptive circuit breaker. HTTP remains the primary transport;
/// CDP is selected only after sustained server/WAF/rate-limit signals.
actor AdaptiveCrawlGate {
    private let baseline: Int
    private var limit: Int
    private var inFlight = 0
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private var recentUnhealthy: [Bool] = []
    private var consecutiveUnhealthy = 0
    private var stableHTTPResponses = 0
    private var successfulProbes = 0
    private var cdpURLsSinceProbe = 0
    private var delayMilliseconds = 0
    private var mode: AdaptiveCrawlMode = .normal

    init(concurrency: Int) { baseline = max(1, concurrency); limit = max(1, concurrency) }
    func acquirePlan() async -> CrawlTransportPlan {
        if mode == .cdp {
            cdpURLsSinceProbe += 1
            if cdpURLsSinceProbe >= 20 {
                cdpURLsSinceProbe = 0
                while inFlight >= 1 { await withCheckedContinuation { waiters.append($0) } }
                inFlight += 1
                return CrawlTransportPlan(transport: .http, delayMilliseconds: max(1_000, delayMilliseconds), isHTTPProbe: true, mode: .cdp)
            }
            return CrawlTransportPlan(transport: .cdp, delayMilliseconds: 0, mode: .cdp)
        }
        while inFlight >= limit { await withCheckedContinuation { waiters.append($0) } }
        inFlight += 1
        return CrawlTransportPlan(transport: .http, delayMilliseconds: delayMilliseconds, mode: mode)
    }

    func releaseHTTP(_ record: CrawlRecord, wasProbe: Bool) -> Int {
        inFlight = max(0, inFlight - 1)
        let status = record.statusCode ?? 0
        let unhealthy = [403, 429].contains(status) || (500...599).contains(status) || record.suspectedWAF || !record.error.isEmpty
        let slow = record.responseTime >= 8
        recentUnhealthy.append(unhealthy || slow); if recentUnhealthy.count > 24 { recentUnhealthy.removeFirst() }
        consecutiveUnhealthy = unhealthy ? consecutiveUnhealthy + 1 : 0
        let errorShare = recentUnhealthy.isEmpty ? 0 : Double(recentUnhealthy.filter { $0 }.count) / Double(recentUnhealthy.count)
        stableHTTPResponses = unhealthy || slow ? 0 : stableHTTPResponses + 1

        switch mode {
        case .normal where consecutiveUnhealthy >= 2 || (recentUnhealthy.count >= 8 && errorShare >= 0.25):
            mode = .cautious
            limit = max(2, limit / 2)
            delayMilliseconds = min(3_000, max(250, delayMilliseconds == 0 ? 250 : delayMilliseconds * 2))
        case .cautious where consecutiveUnhealthy >= 4 || (recentUnhealthy.count >= 12 && errorShare >= 0.35):
            mode = .cdp
            limit = 1
            delayMilliseconds = min(5_000, max(1_000, delayMilliseconds * 2))
            successfulProbes = 0
        case .cautious where stableHTTPResponses >= 10:
            mode = .recovery
        case .recovery where unhealthy || slow:
            mode = .cdp
            limit = 1
            delayMilliseconds = min(5_000, max(1_000, delayMilliseconds))
            successfulProbes = 0
        case .recovery where stableHTTPResponses >= 12:
            mode = .normal
        case .cdp where wasProbe:
            if !unhealthy && !slow {
                successfulProbes += 1
                if successfulProbes >= 3 {
                    mode = .recovery
                    limit = max(2, baseline / 2)
                    delayMilliseconds = max(250, delayMilliseconds / 2)
                    stableHTTPResponses = 0
                }
            } else { successfulProbes = 0 }
        default: break
        }
        if mode == .recovery || mode == .normal, !unhealthy, !slow, recentUnhealthy.count >= 16, errorShare < 0.08 {
            limit = min(baseline, limit + 1)
            delayMilliseconds = max(0, delayMilliseconds - 100)
        }
        if inFlight < limit, let waiter = waiters.first { waiters.removeFirst(); waiter.resume() }
        return delayMilliseconds
    }

    /// A hung local browser must not hold every crawler worker forever. Return
    /// this host to a paced HTTP retry path; a later unhealthy series can open
    /// the circuit again if browser verification is still needed.
    func releaseCDP(timedOut: Bool) -> Int {
        guard timedOut else { return delayMilliseconds }
        mode = .cautious
        limit = max(1, min(2, baseline / 2))
        delayMilliseconds = min(3_000, max(500, delayMilliseconds))
        cdpURLsSinceProbe = 0
        successfulProbes = 0
        stableHTTPResponses = 0
        return delayMilliseconds
    }
}

/// Circuit state is retained per host. A shared local Chrome session can serve
/// any site, but an unhealthy host must never make another host leave HTTP.
actor AdaptiveDomainGates {
    private let concurrency: Int
    private var gates: [String: AdaptiveCrawlGate] = [:]
    init(concurrency: Int) { self.concurrency = concurrency }
    func gate(for host: String) -> AdaptiveCrawlGate {
        let key = host.lowercased()
        if let existing = gates[key] { return existing }
        let created = AdaptiveCrawlGate(concurrency: concurrency)
        gates[key] = created
        return created
    }
}

actor CrawlerControl {
    private var active: CrawlCoordinator?
    func set(_ coordinator: CrawlCoordinator?) { active = coordinator }
    func clear(_ coordinator: CrawlCoordinator) { if active === coordinator { active = nil } }
    func pause(_ value: Bool) async { await active?.pause(value) }
    func stop() async { await active?.stop(); active = nil }
}

/// A site can reference hundreds of static files on one HTML page. Keep their
/// metadata probes shared and bounded across every crawl worker: resource
/// measurement must never become an unbounded second crawler.
actor ResourceProbeGate {
    private var available: Int
    private var waiters: [CheckedContinuation<Void, Never>] = []
    init(limit: Int) { available = limit }
    func acquire() async {
        guard available == 0 else { available -= 1; return }
        await withCheckedContinuation { waiters.append($0) }
    }
    func release() {
        if let next = waiters.first {
            waiters.removeFirst(); next.resume()
        } else { available += 1 }
    }
}

/// Per-crawl single-flight cache: shared template assets are measured once,
/// including failures, and concurrent pages await the same request.
actor ResourceMeasurementCache {
    private var inFlight: [String: Task<Int, Never>] = [:]
    private var completed: [String: Int] = [:]
    // A site can have tens of thousands of one-off product images.  Caching
    // every completed probe permanently turns Page Weight into an unbounded
    // memory cache. Reused template resources still benefit from this cap.
    private let completedLimit = 16_000
    private let gate: ResourceProbeGate
    init(limit: Int = 4) { gate = ResourceProbeGate(limit: limit) }
    func size(url: URL, session: URLSession) async -> Int {
        let key = url.absoluteString
        if let value = completed[key] { return value }
        if let existing = inFlight[key] { return await existing.value }
        let task = Task { [gate] in
            await gate.acquire()
            var request = URLRequest(url: url)
            request.httpMethod = "HEAD"
            request.timeoutInterval = 3
            var size = 0
            if !Task.isCancelled,
               let (_, response) = try? await session.data(for: request),
               let http = response as? HTTPURLResponse,
               (200...299).contains(http.statusCode) {
                size = max(0, Int(http.value(forHTTPHeaderField: "Content-Length") ?? "") ?? 0)
            }
            await gate.release()
            return size
        }
        inFlight[key] = task
        let value = await task.value
        inFlight[key] = nil
        if completed.count < completedLimit { completed[key] = value }
        return value
    }
}

final class SpiderCrawler: @unchecked Sendable {
    private let control = CrawlerControl()

    func pause(_ value: Bool) async { await control.pause(value) }
    func stop() async { await control.stop() }

    func crawl(seeds: [URL], mode: CrawlMode, settings: CrawlSettings, onRecord: @escaping @Sendable (CrawlRecord) async -> Void, onQueue: @escaping @Sendable (Int) async -> Void, onStages: @escaping @Sendable (CrawlStageProgress) async -> Void = { _ in }, onDiagnostic: @escaping @Sendable (CrawlRecord, String) async -> Void = { _, _ in }) async {
        guard let rootHost = seeds.first?.host?.lowercased() else { return }
        let coordinator = CrawlCoordinator(limit: settings.maxURLs)
        await control.set(coordinator)
        defer { Task { await self.control.clear(coordinator) } }
        await coordinator.seed(seeds)
        let configuration = URLSessionConfiguration.ephemeral
        // A long per-request timeout makes the entire crawl look frozen when
        // an origin silently drops the TCP connection. Report the row and let
        // the bounded Chrome fallback verify it instead.
        configuration.timeoutIntervalForRequest = min(settings.timeout, 15)
        // URLSession otherwise defaults to six connections per host. Honour the
        // user-selected crawl parallelism for HTML documents, but retain a
        // conservative ceiling so a small origin is not overwhelmed.
        configuration.httpMaximumConnectionsPerHost = max(2, min(settings.concurrency, 16))
        configuration.httpAdditionalHeaders = [
            "User-Agent": settings.userAgent,
            "Accept": "text/html,application/xhtml+xml,application/xml;q=0.9,image/avif,image/webp,image/apng,image/svg+xml,image/*;q=0.8,*/*;q=0.7",
            "Accept-Language": "en-US,en;q=0.9"
        ]
        let session = URLSession(configuration: configuration)
        let preflightConfiguration = configuration.copy() as! URLSessionConfiguration
        preflightConfiguration.timeoutIntervalForRequest = min(settings.timeout, 5)
        preflightConfiguration.timeoutIntervalForResource = min(settings.timeout, 12)
        let preflightSession = URLSession(configuration: preflightConfiguration)
        // Page Weight is deliberately a separate, low-priority network pool.
        // Sharing the HTML session let a burst of image/CSS HEAD requests occupy
        // every host connection and reduce the crawler to a fraction of its rate.
        let resourceConfiguration = configuration.copy() as! URLSessionConfiguration
        resourceConfiguration.httpMaximumConnectionsPerHost = 4
        resourceConfiguration.timeoutIntervalForRequest = min(settings.timeout, 8)
        let resourceSession = URLSession(configuration: resourceConfiguration)
        let resourceCache = ResourceMeasurementCache(limit: 4)
        // Keep HTTP at the configured rate, but cap expensive DOM construction
        // independently. Two concurrent parses are enough to keep CPU busy on
        // large catalogue templates without the multi-gigabyte memory spikes
        // caused by five simultaneous SwiftSoup documents.
        let htmlAnalysisGate = HTMLAnalysisGate(limit: min(2, settings.concurrency))
        let weights = PageWeightQueue()
        let requestGates = AdaptiveDomainGates(concurrency: settings.concurrency)
        let fallbackQueue = ChromeFallbackQueue()
        let fallbackTask = Task {
            await fallbackQueue.run(onRecord: { [weak self] record, check in
                var verified = record
                if let self, check.hasParseableHTML {
                    await self.enrichCDPHTML(check.html, into: &verified, rootHost: rootHost, settings: settings, htmlAnalysisGate: htmlAnalysisGate)
                }
                await onRecord(verified)
                await onDiagnostic(verified, "chrome-fallback-result")
            }, onProgress: { verified in
                await weights.fallbackCompleted(verified: verified)
                await onStages(weights.snapshot())
            })
        }
        let weightTask = Task {
            await withTaskGroup(of: Void.self) { group in
                for _ in 0..<4 { group.addTask {
                    while await coordinator.canContinue() {
                        guard let record = await weights.next() else {
                            if await weights.finished() { return }
                            try? await Task.sleep(for: .milliseconds(100)); continue
                        }
                        let updated = await self.measureWeight(record, session: resourceSession, cache: resourceCache)
                        await onRecord(updated)
                        await weights.complete(partial: updated.weightStatus == "Partial")
                        await onStages(weights.snapshot())
                    }
                } }
            }
        }
        let preflight = CrawlPreflight()
        // Sitemap discovery is independent from the "respect robots" crawl
        // policy. It intentionally runs concurrently with the homepage fetch.
        let preflightTask = Task {
            let robots = await RobotsRules.load(for: seeds[0], session: preflightSession)
            let sitemapURLs: Set<String> = mode == .spider
                ? await SitemapLoader.discover(for: seeds[0], session: preflightSession, robots: robots).urls
                : []
            await preflight.update(robots: robots, sitemapURLs: sitemapURLs)
            if mode == .spider {
                for value in sitemapURLs.compactMap(URL.init(string:)) {
                    await coordinator.enqueue(value, depth: 0, source: nil)
                }
            }
            await coordinator.finishPreflight()
        }
        let workerCount = max(1, settings.concurrency)
        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<workerCount {
                group.addTask {
                    while await coordinator.canContinue() {
                        guard let (url, depth) = await coordinator.next() else {
                            try? await Task.sleep(for: .milliseconds(120))
                            if await coordinator.exhausted() { return }
                            continue
                        }
                        let blockedBy = await preflight.blockingRule(for: url, userAgent: settings.userAgent)
                        if settings.respectRobots, let blockedBy {
                            var blocked = CrawlRecord(url: url, kind: HTMLAnalyzer.isInternal(url, rootHost: rootHost, subdomains: settings.crawlSubdomains) ? .internalURL : .external, depth: depth)
                            blocked.robotsBlockedBy = blockedBy
                            blocked.indexability = "Blocked by robots.txt"
                            blocked.foundOnURLs = await coordinator.sources(for: url)
                            blocked.inSitemap = await preflight.containsInSitemap(url)
                            await onRecord(blocked)
                            await coordinator.completed()
                            await weights.htmlCompleted()
                            await onQueue(coordinator.queuedCount())
                            continue
                        }
                        let requestGate = await requestGates.gate(for: url.host?.lowercased() ?? rootHost)
                        let plan = await requestGate.acquirePlan()
                        // Static images are never useful CDP candidates. They
                        // have no DOM to inspect and were previously consuming
                        // the two Chrome tabs after a site's circuit opened.
                        let forceHTTPResource = Self.isLikelyImageURL(url)
                        let reportedPlan = forceHTTPResource && plan.transport == .cdp
                            ? CrawlTransportPlan(transport: .http, delayMilliseconds: 0, mode: plan.mode)
                            : plan
                        await weights.transport(reportedPlan)
                        var record: CrawlRecord
                        if plan.transport == .http || forceHTTPResource {
                            let robotsDelay = await preflight.crawlDelay(for: settings.userAgent)
                            if settings.respectRobots && robotsDelay > 0 { try? await Task.sleep(for: .seconds(robotsDelay)) }
                            if !forceHTTPResource && plan.delayMilliseconds > 0 { try? await Task.sleep(for: .milliseconds(plan.delayMilliseconds)) }
                            record = await self.fetch(url: url, depth: depth, rootHost: rootHost, settings: settings, session: session, resourceCache: resourceCache, htmlAnalysisGate: htmlAnalysisGate)
                            let currentThrottle = plan.transport == .http
                                ? await requestGate.releaseHTTP(record, wasProbe: plan.isHTTPProbe)
                                : await requestGate.releaseCDP(timedOut: false)
                            await weights.throttle(currentThrottle)
                        } else {
                            await onDiagnostic(CrawlRecord(url: url), "chrome-primary-selected")
                            record = await self.fetchViaCDP(url: url, depth: depth, rootHost: rootHost, settings: settings, htmlAnalysisGate: htmlAnalysisGate)
                            let currentThrottle = await requestGate.releaseCDP(timedOut: record.verificationResult == "Chrome CDP timed out")
                            await weights.throttle(currentThrottle)
                        }
                        record.robotsBlockedBy = blockedBy ?? ""
                        record.foundOnURLs = await coordinator.sources(for: url)
                        let finalURLInSitemap = await preflight.containsInSitemap(record.url)
                        let requestedURLInSitemap = await preflight.containsInSitemap(url)
                        record.inSitemap = finalURLInSitemap || requestedURLInSitemap
                        if plan.transport == .http, !record.error.isEmpty || (record.statusCode ?? 0) >= 400 {
                            await onDiagnostic(record, "http-response-anomaly")
                        }
                        if plan.transport == .http, !forceHTTPResource, Self.needsChromeVerification(record) {
                            await onDiagnostic(record, "http-anomaly-before-chrome-fallback")
                            record.originalStatus = record.statusCode
                            record.verificationResult = "Chrome verification queued"
                            await fallbackQueue.enqueue(record)
                            await weights.fallbackQueued()
                        }
                        await onRecord(record)
                        if record.isSEOPage { await weights.append(record) }
                        await weights.htmlCompleted()
                        await onStages(weights.snapshot())
                        if mode == .spider, record.isHTML, depth < settings.maxDepth, record.statusCode.map({ (200...299).contains($0) }) == true {
                            let links = record.internalLinkTargets.compactMap(URL.init(string:))
                            await coordinator.addInlinks(links)
                            for link in links { await coordinator.enqueue(link, depth: depth + 1, source: record.url) }
                            // Crawl embedded internal images as resources as well. This allows
                            // broken-image findings to name the HTML page that uses the image.
                            for image in record.images {
                                guard let imageURL = URL(string: image.url), HTMLAnalyzer.isInternal(imageURL, rootHost: rootHost, subdomains: settings.crawlSubdomains) else { continue }
                                await coordinator.enqueue(imageURL, depth: depth + 1, source: record.url)
                            }
                        }
                        await onQueue(coordinator.queuedCount())
                        await coordinator.completed()
                    }
                }
            }
        }
        await preflightTask.value
        await fallbackQueue.close()
        // Verification continues in a bounded background queue. It updates the
        // existing row when Chrome returns, without holding HTTP workers or the UI.
        _ = fallbackTask
        await weights.close()
        await onStages(weights.snapshot())
        await weightTask.value
        await onStages(weights.snapshot())
    }

    private func fetch(url: URL, depth: Int, rootHost: String, settings: CrawlSettings, session: URLSession, resourceCache: ResourceMeasurementCache, htmlAnalysisGate: HTMLAnalysisGate) async -> CrawlRecord {
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
            // `data.count` is decoded HTML. For an ordinary HTML GET, task
            // metrics provide the separately useful compressed transfer size.
            result.transferredSize = observer.responseBodyBytesReceived
            var responseHeaders: [String: String] = [:]
            if let http = response as? HTTPURLResponse {
                result.statusCode = http.statusCode
                result.contentType = http.value(forHTTPHeaderField: "Content-Type") ?? "Unknown"
                result.contentEncoding = http.value(forHTTPHeaderField: "Content-Encoding") ?? ""
                if result.transferredSize == 0, let value = http.value(forHTTPHeaderField: "Content-Length"), let length = Int(value) {
                    result.transferredSize = length
                }
                if usedImageHeadProbe, let value = http.value(forHTTPHeaderField: "Content-Length"), let length = Int(value) {
                    result.size = length
                    result.transferredSize = length
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
            // A normal form often contains strings such as `recaptcha` or
            // `input_phone_recaptcha`; they are not evidence of a block. Only
            // mark a successful document as WAF when the page itself has the
            // narrow shape of a provider challenge.
            if (200...299).contains(result.statusCode ?? 0), let body = String(data: data.prefix(512_000), encoding: .utf8), Self.looksLikeWAF(body) {
                result.suspectedWAF = true
            }
            // Error responses for image URLs are often HTML error templates. They are resources, not SEO pages.
            guard result.isSEOPage, let html = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .windowsCP1251) else { return result }
            await htmlAnalysisGate.acquire()
            let page = HTMLAnalyzer.analyze(html, baseURL: url, rootHost: rootHost, settings: settings)
            await htmlAnalysisGate.release()
            result.title = page.title; result.metaDescription = page.description; result.metaKeywords = page.keywords; result.h1 = page.h1; result.h2 = page.h2; result.h1Count = page.h1Count; result.h2Count = page.h2Count; result.canonical = page.canonical; result.canonicalRaw = page.canonicalRaw; result.canonicalCount = page.canonicalCount; result.robots = page.robots; result.language = page.language; result.hreflang = page.hreflang; result.hreflangCodes = page.hreflangCodes; result.hreflangTargets = page.hreflangTargets; result.hasXDefault = page.hasXDefault; result.paginationURLs = page.paginationURLs; result.contentFingerprint = page.contentFingerprint; result.schemaTypes = page.schemaTypes; result.wordCount = page.wordCount; result.images = page.images; result.analyticsIDs = page.analyticsIDs; result.analyticsSignals = page.analyticsSignals; result.wordPressHeadFindings = page.wordPressHeadFindings; result.internalLinks = page.internalLinks.count; result.internalLinkTargets = page.internalLinks.map(\.absoluteString); result.outgoingLinks = page.internalLinkDetails; result.externalLinks = page.externalLinks.count
            let measuredResources = page.resourceCandidates
            result.weightStatus = "Queued"
            let imageSizesByURL = Dictionary(uniqueKeysWithValues: measuredResources.filter { $0.kind == "Images" }.map { ($0.url, $0.size) })
            result.images = result.images.map { image in var copy = image; copy.size = imageSizesByURL[image.url] ?? 0; return copy }
            result.pageResources = measuredResources
            result.htmlSize = page.rawHTMLSize; result.cleanedHTMLSize = page.cleanedHTMLSize; result.extractedTextSize = page.extractedTextSize; result.estimatedHTMLTokens = page.estimatedHTMLTokens; result.estimatedTextTokens = page.estimatedTextTokens; result.domNodeCount = page.domNodeCount; result.inlineJavaScriptSize = page.inlineJavaScriptSize; result.inlineCSSSize = page.inlineCSSSize; result.embeddedJSONSize = page.embeddedJSONSize; result.resourceRequestCount = page.resourceRequestCount
            result.imageResourceSize = measuredResources.filter { $0.kind == "Images" }.reduce(0) { $0 + $1.size }
            result.javascriptResourceSize = page.inlineJavaScriptSize + measuredResources.filter { $0.kind == "JavaScript" }.reduce(0) { $0 + $1.size }
            result.cssResourceSize = page.inlineCSSSize + measuredResources.filter { $0.kind == "CSS" }.reduce(0) { $0 + $1.size }
            result.fontResourceSize = measuredResources.filter { $0.kind == "Fonts" }.reduce(0) { $0 + $1.size }
            result.otherResourceSize = measuredResources.filter { !["Images", "JavaScript", "CSS", "Fonts"].contains($0.kind) }.reduce(0) { $0 + $1.size }
            result.thirdPartyResourceSize = measuredResources.filter(\.thirdParty).reduce(0) { $0 + $1.size }
            result.pageWeight = result.htmlSize + result.imageResourceSize + result.javascriptResourceSize + result.cssResourceSize + result.fontResourceSize + result.otherResourceSize
            result.contentToHTMLRatio = result.htmlSize == 0 ? 0 : Double(result.extractedTextSize) / Double(result.htmlSize); result.primaryWeightCause = PageMetricsAnalyzer.primaryCause(for: result); result.aiParsability = PageMetricsAnalyzer.aiAssessment(for: result)
            result.indexability = page.robots.lowercased().contains("noindex") ? "Noindex" : "Indexable"
            let classification = PageClassifier.classify(PageSignals(url: result.url, title: page.title, h1: page.h1, schemaTypes: Set(page.schemaTypes), ogType: page.ogType, hasPrice: page.hasPrice, hasAddToCart: page.hasAddToCart, hasBookingForm: page.hasBookingForm, hasAuthor: page.hasAuthor, hasPublishedDate: page.hasPublishedDate, hasPagination: !page.paginationURLs.isEmpty, repeatedCardCount: page.repeatedCardCount, h2Count: page.h2Count, wordCount: page.wordCount, currencyAmountCount: page.currencyAmountCount, hasContactDetails: page.hasContactDetails))
            result.pageType = classification.type; result.aiBustCategory = classification.aiBustCategory; result.classificationConfidence = classification.confidence; result.classificationEvidence = classification.evidence
            let cms = CMSDetector.detect(html: html, headers: responseHeaders)
            result.cmsName = cms.name; result.cmsConfidence = cms.confidence; result.cmsEvidence = cms.evidence
            let schema = result.isSchemaEligible ? SchemaIntelligence.analyze(jsonLD: page.schemaJSON, pageType: classification.type) : SchemaInsight(entities: [], primaryType: "", compatibility: "Not applicable", completeness: 0)
            result.primarySchemaType = schema.primaryType; result.schemaCompatibility = schema.compatibility; result.schemaCompleteness = schema.completeness
            result.schemaValidationErrors = result.isSchemaEligible ? SchemaIntelligence.validations(jsonLD: page.schemaJSON).map { "\($0.type): missing \($0.missing.joined(separator: ", "))" } : []
        } catch { result.responseTime = Date().timeIntervalSince(start); result.error = error.localizedDescription }
        return result
    }
    private static func needsChromeVerification(_ record: CrawlRecord) -> Bool {
        let status = record.statusCode ?? 0
        return [403, 429].contains(status) || (500...599).contains(status) || record.suspectedWAF || !record.error.isEmpty
    }
    private static func looksLikeWAF(_ html: String) -> Bool {
        // Challenge pages identify themselves at the beginning of the HTML.
        // Do not treat isolated words such as `captcha`, `recaptcha`, `access
        // denied` or `security check` as a block: production forms, FAQ text
        // and legal content routinely contain them.
        let sample = String(html.prefix(128_000))
        let value = sample.lowercased()
        func tagText(_ tag: String) -> String {
            let pattern = "(?is)<\(tag)\\b[^>]*>(.*?)</\(tag)>"
            guard let regex = try? NSRegularExpression(pattern: pattern),
                  let match = regex.firstMatch(in: sample, range: NSRange(sample.startIndex..., in: sample)),
                  let range = Range(match.range(at: 1), in: sample) else { return "" }
            return String(sample[range]).lowercased()
        }
        let titleAndH1 = tagText("title") + " " + tagText("h1")
        let blockerHeading = ["just a moment", "attention required", "access denied", "security check", "bot verification", "checking your browser", "verify you are human"].contains { titleAndH1.contains($0) }
        let challengeCopy = ["checking your browser", "verify you are human", "verify that you are human", "unusual traffic", "enable javascript and cookies", "temporarily blocked", "request blocked"].contains { value.contains($0) }
        let cloudflareChallenge = value.contains("cf-chl-") || value.contains("challenge-platform") || value.contains("/cdn-cgi/challenge")
        // Error/challenge documents are normally very small after markup is
        // removed. A long article or service page containing a form cannot
        // satisfy this condition merely because it uses reCAPTCHA.
        let visible = sample.replacingOccurrences(of: "(?is)<script\\b[^>]*>.*?</script>|<style\\b[^>]*>.*?</style>|<[^>]+>", with: " ", options: .regularExpression)
        let sparseVisibleContent = visible.trimmingCharacters(in: .whitespacesAndNewlines).count < 1_500
        return (cloudflareChallenge && (blockerHeading || challengeCopy)) ||
            (sparseVisibleContent && blockerHeading && challengeCopy)
    }
    private func fetchViaCDP(url: URL, depth: Int, rootHost: String, settings: CrawlSettings, htmlAnalysisGate: HTMLAnalysisGate) async -> CrawlRecord {
        let start = Date()
        let check = await ChromeCDPSession.shared.verify(url)
        var result = CrawlRecord(url: url, kind: HTMLAnalyzer.isInternal(url, rootHost: rootHost, subdomains: settings.crawlSubdomains) ? .internalURL : .external, depth: depth)
        result.responseTime = Date().timeIntervalSince(start)
        result.statusCode = check.status; result.cdpStatus = check.status
        result.size = check.contentLength; result.transportUsed = "cdp"
        result.contentType = check.contentType.isEmpty ? "Unknown" : check.contentType
        if let finalURL = URL(string: check.finalURL), finalURL != url {
            result.redirectSources = [url]
            result.redirectURL = finalURL
            result.redirectChain = [url, finalURL]
            result.url = finalURL
        }
        if check.succeeded, check.hasParseableHTML {
            result.verificationResult = "Fetched via Chrome CDP"
            await enrichCDPHTML(check.html, into: &result, rootHost: rootHost, settings: settings, htmlAnalysisGate: htmlAnalysisGate)
        } else if check.succeeded {
            result.verificationResult = "Chrome content unavailable"
            result.error = check.error.isEmpty ? "Chrome returned a successful response without a captured HTML document." : check.error
        } else {
            result.verificationResult = check.error.localizedCaseInsensitiveContains("timed out") ? "Chrome CDP timed out" : (check.status == nil ? "Chrome CDP unavailable" : "Chrome confirmed server error")
            result.error = check.error
        }
        return result
    }

    /// A CDP response is not merely a status check: when Chrome supplied a
    /// document, run exactly the same extraction and classification pipeline
    /// as an HTTP response. Without this, a browser-derived 200 was displayed
    /// as an empty/Unknown page and could not discover its internal links.
    private func enrichCDPHTML(_ html: String, into result: inout CrawlRecord, rootHost: String, settings: CrawlSettings, htmlAnalysisGate: HTMLAnalysisGate) async {
        guard result.isHTML, (result.statusCode ?? 0) / 100 == 2 else { return }
        await htmlAnalysisGate.acquire()
        let page = HTMLAnalyzer.analyze(html, baseURL: result.url, rootHost: rootHost, settings: settings)
        await htmlAnalysisGate.release()
        result.title = page.title; result.metaDescription = page.description; result.metaKeywords = page.keywords; result.h1 = page.h1; result.h2 = page.h2; result.h1Count = page.h1Count; result.h2Count = page.h2Count; result.canonical = page.canonical; result.canonicalRaw = page.canonicalRaw; result.canonicalCount = page.canonicalCount; result.robots = page.robots; result.language = page.language; result.hreflang = page.hreflang; result.hreflangCodes = page.hreflangCodes; result.hreflangTargets = page.hreflangTargets; result.hasXDefault = page.hasXDefault; result.paginationURLs = page.paginationURLs; result.contentFingerprint = page.contentFingerprint; result.schemaTypes = page.schemaTypes; result.wordCount = page.wordCount; result.images = page.images; result.analyticsIDs = page.analyticsIDs; result.analyticsSignals = page.analyticsSignals; result.wordPressHeadFindings = page.wordPressHeadFindings; result.internalLinks = page.internalLinks.count; result.internalLinkTargets = page.internalLinks.map(\.absoluteString); result.outgoingLinks = page.internalLinkDetails; result.externalLinks = page.externalLinks.count
        let resources = page.resourceCandidates
        result.weightStatus = "Queued"
        result.pageResources = resources
        result.htmlSize = page.rawHTMLSize; result.cleanedHTMLSize = page.cleanedHTMLSize; result.extractedTextSize = page.extractedTextSize; result.estimatedHTMLTokens = page.estimatedHTMLTokens; result.estimatedTextTokens = page.estimatedTextTokens; result.domNodeCount = page.domNodeCount; result.inlineJavaScriptSize = page.inlineJavaScriptSize; result.inlineCSSSize = page.inlineCSSSize; result.embeddedJSONSize = page.embeddedJSONSize; result.resourceRequestCount = page.resourceRequestCount
        result.imageResourceSize = resources.filter { $0.kind == "Images" }.reduce(0) { $0 + $1.size }
        result.javascriptResourceSize = page.inlineJavaScriptSize + resources.filter { $0.kind == "JavaScript" }.reduce(0) { $0 + $1.size }
        result.cssResourceSize = page.inlineCSSSize + resources.filter { $0.kind == "CSS" }.reduce(0) { $0 + $1.size }
        result.fontResourceSize = resources.filter { $0.kind == "Fonts" }.reduce(0) { $0 + $1.size }
        result.otherResourceSize = resources.filter { !["Images", "JavaScript", "CSS", "Fonts"].contains($0.kind) }.reduce(0) { $0 + $1.size }
        result.thirdPartyResourceSize = resources.filter(\.thirdParty).reduce(0) { $0 + $1.size }
        result.pageWeight = result.htmlSize + result.imageResourceSize + result.javascriptResourceSize + result.cssResourceSize + result.fontResourceSize + result.otherResourceSize
        result.contentToHTMLRatio = result.htmlSize == 0 ? 0 : Double(result.extractedTextSize) / Double(result.htmlSize); result.primaryWeightCause = PageMetricsAnalyzer.primaryCause(for: result); result.aiParsability = PageMetricsAnalyzer.aiAssessment(for: result)
        result.indexability = page.robots.lowercased().contains("noindex") ? "Noindex" : "Indexable"
        let classification = PageClassifier.classify(PageSignals(url: result.url, title: page.title, h1: page.h1, schemaTypes: Set(page.schemaTypes), ogType: page.ogType, hasPrice: page.hasPrice, hasAddToCart: page.hasAddToCart, hasBookingForm: page.hasBookingForm, hasAuthor: page.hasAuthor, hasPublishedDate: page.hasPublishedDate, hasPagination: !page.paginationURLs.isEmpty, repeatedCardCount: page.repeatedCardCount, h2Count: page.h2Count, wordCount: page.wordCount, currencyAmountCount: page.currencyAmountCount, hasContactDetails: page.hasContactDetails))
        result.pageType = classification.type; result.aiBustCategory = classification.aiBustCategory; result.classificationConfidence = classification.confidence; result.classificationEvidence = classification.evidence
        let cms = CMSDetector.detect(html: html, headers: [:])
        result.cmsName = cms.name; result.cmsConfidence = cms.confidence; result.cmsEvidence = cms.evidence
        let schema = SchemaIntelligence.analyze(jsonLD: page.schemaJSON, pageType: classification.type)
        result.primarySchemaType = schema.primaryType; result.schemaCompatibility = schema.compatibility; result.schemaCompleteness = schema.completeness
        result.schemaValidationErrors = SchemaIntelligence.validations(jsonLD: page.schemaJSON).map { "\($0.type): missing \($0.missing.joined(separator: ", "))" }
    }
    private static func isLikelyImageURL(_ url: URL) -> Bool {
        ["png", "jpg", "jpeg", "gif", "webp", "svg", "avif", "ico", "bmp", "tif", "tiff"].contains(url.pathExtension.lowercased())
    }
    private func measureWeight(_ input: CrawlRecord, session: URLSession, cache: ResourceMeasurementCache) async -> CrawlRecord {
        var result = input
        let resources = await resourceSizes(input.pageResources, session: session, cache: cache)
        result.pageResources = resources
        func total(_ kind: String) -> Int { resources.filter { $0.kind == kind }.reduce(0) { $0 + $1.size } }
        result.imageResourceSize = total("Images")
        result.javascriptResourceSize = total("JavaScript")
        result.cssResourceSize = total("CSS")
        result.fontResourceSize = total("Fonts")
        result.thirdPartyResourceSize = resources.filter(\.thirdParty).reduce(0) { $0 + $1.size }
        // Inline data is already included in HTML and must not be counted twice.
        result.pageWeight = result.htmlSize + resources.reduce(0) { $0 + $1.size }
        result.weightStatus = resources.contains { $0.size == 0 } ? "Partial" : "Measured"
        result.primaryWeightCause = PageMetricsAnalyzer.primaryCause(for: result)
        let sizes = Dictionary(uniqueKeysWithValues: resources.map { ($0.url, $0.size) })
        result.images = result.images.map { var image = $0; image.size = sizes[image.url] ?? 0; return image }
        return result
    }
    /// Page Weight uses the headers of every static resource referenced in the
    /// document. HEAD avoids downloading megabytes of assets; a response with
    /// no length stays visible in the resource list with an unknown (zero) size.
    private func resourceSizes(_ resources: [PageResource], session: URLSession, cache: ResourceMeasurementCache) async -> [PageResource] {
        // There are already four Page Weight workers and a global four-request
        // probe gate. A task group with one child for every asset can create
        // thousands of suspended tasks for a single category page, even though
        // only four requests can run. Process each page serially; the workers
        // preserve the intended global parallelism without the task explosion.
        var result: [PageResource] = []
        result.reserveCapacity(resources.count)
        for resource in resources {
            var value = resource
            if let url = URL(string: resource.url) {
                value.size = await cache.size(url: url, session: session)
            }
            result.append(value)
        }
        return result.sorted { $0.size > $1.size }
    }
}
