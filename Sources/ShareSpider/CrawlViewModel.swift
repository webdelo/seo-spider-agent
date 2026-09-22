import Foundation
import AppKit
import SwiftUI

private actor BatchSiteTracker {
    private var processed = 0
    private var queued = 0
    func record() -> Double { processed += 1; return progress }
    func queue(_ value: Int) -> Double { queued = value; return progress }
    private var progress: Double { let total = processed + queued; return total == 0 ? 0 : min(1, Double(processed) / Double(total)) }
}

@MainActor
final class CrawlViewModel: ObservableObject {
    @Published var mode: CrawlMode = .spider
    @Published var startText = "https://example.com"
    @Published var listText = ""
    @Published var settings = CrawlSettingsStore.load()
    @Published var localVision = LocalVisionSettings.load()
    @Published private(set) var records: [CrawlRecord] = []
    /// These reports are intentionally cached. Rebuilding every metric after every
    /// HTTP response makes a large crawl spend more time redrawing than crawling.
    @Published private(set) var issues: [Issue] = []
    @Published private(set) var overview: [OverviewItem] = []
    @Published private(set) var state: CrawlState = .idle
    @Published private(set) var queued = 0
    @Published private(set) var stageProgress = CrawlStageProgress()
    @Published private(set) var startedAt: Date?
    @Published var selectedIssue: Issue?
    @Published private(set) var overviewSelectionName: String?
    @Published private(set) var overviewSelectionIDs: Set<UUID> = []
    /// URLs supplied by a property-wide GSC report.  They can be absent from
    /// the crawl, so keep them separately from local record identifiers.
    @Published private(set) var overviewSelectionExternalURLs: [String] = []
    @Published private(set) var issueSelection: Issue?
    @Published private(set) var auditReport: AuditReport?
    @Published private(set) var auditRunning = false
    @Published private(set) var aiAuditRunning = false
    @Published private(set) var aiAuditStage: AIAuditStage = .notStarted
    @Published private(set) var aiAuditReport: AIAuditReport?
    @Published private(set) var customAnalyses: [AICodexAnalyst.CustomAnalysis] = []
    @Published private(set) var pageSpeedResults: [PageSpeedResult] = []
    @Published private(set) var pageSpeedRunning = false
    @Published private(set) var visualAuditResults: [VisualAuditResult] = []
    @Published private(set) var visualAuditRunning = false
    @Published private(set) var visualAuditProgress: VisualAuditProgress?
    @Published private(set) var searchConsoleRunning = false
    @Published private(set) var searchConsoleProgress = 0
    @Published private(set) var searchConsoleTotal = 0
    @Published private(set) var searchConsoleMessage = ""
    @Published private(set) var backlinkReport: BacklinkReport?
    @Published private(set) var backlinkRunning = false
    @Published private(set) var backlinkProgress = 0
    @Published private(set) var backlinkTotal = 0
    @Published private(set) var backlinkMessage = ""
    @Published private(set) var dataForSEOProfileMessage = "Not started"
    @Published private(set) var dataForSEOProfileClassifying = false
    @Published private(set) var backlinkDrilldownKind: BacklinkDrilldownKind?
    @Published private(set) var backlinkDrilldownRunning = false
    @Published private(set) var referringDomainDetails: [ReferringDomainDetail] = []
    @Published private(set) var backlinkSourceDetails: [BacklinkSourceDetail] = []
    @Published private(set) var backlinkHistory: [BacklinkHistoryPoint] = []
    @Published private(set) var gscBacklinkImport: GSCBacklinkImport?
    @Published private(set) var ahrefsBacklinkImport: AhrefsBacklinkImport?
    @Published private(set) var ubersuggestBacklinkImport: UbersuggestBacklinkImport?
    @Published private(set) var ahrefsComparisonRunning = false
    @Published private(set) var ubersuggestComparisonRunning = false
    @Published private(set) var ahrefsComparisonProgress = 0
    @Published private(set) var ahrefsComparisonTotal = 1
    @Published private(set) var ahrefsComparisonMessage = "Not started"
    @Published private(set) var ubersuggestComparisonProgress = 0
    @Published private(set) var ubersuggestComparisonTotal = 1
    @Published private(set) var ubersuggestComparisonMessage = "Not started"
    /// Domain-only providers are profiled after their download finishes.  The
    /// results are deliberately kept separate from DataForSEO's page-level
    /// classifications so the UI never pretends a donor homepage is the exact
    /// page carrying the backlink.
    @Published private(set) var ahrefsSourceStats = BacklinkSourceStats()
    @Published private(set) var ubersuggestSourceStats = BacklinkSourceStats()
    @Published private(set) var gscSourceStats = BacklinkSourceStats()
    @Published private(set) var ahrefsProfileClassifying = false
    @Published private(set) var ubersuggestProfileClassifying = false
    @Published private(set) var gscProfileClassifying = false
    @Published private(set) var gscBacklinkProgress = 0
    @Published private(set) var gscBacklinkTotal = 3
    @Published private(set) var gscBacklinkStage = "Not started"
    var backlinkComparisonRunning: Bool { ahrefsComparisonRunning || ubersuggestComparisonRunning }
    var backlinkProfileAnalysisRunning: Bool {
        backlinkDrilldownRunning || ahrefsComparisonRunning || ubersuggestComparisonRunning || gscChromeLinkSyncRunning ||
        ahrefsProfileClassifying || ubersuggestProfileClassifying || gscProfileClassifying
    }
    @Published private(set) var gscSiteReport: GSCSiteReport?
    @Published private(set) var gscCoreWebVitalsReport: GSCCoreWebVitalsReport?
    @Published private(set) var gscChromeLinkSyncRunning = false
    @Published private(set) var gscChromePageIndexingSyncRunning = false
    @Published private(set) var gscChromeCoreWebVitalsSyncRunning = false
    /// Progress for Chrome-based GSC reports. This is intentionally separate
    /// from the crawl and URL Inspection counters: Page Indexing and Links
    /// are site-wide reports, not a row-by-row crawl operation.
    @Published private(set) var gscChromeProgress = 0
    @Published private(set) var gscChromeTotal = 3
    @Published private(set) var gscChromeStage = ""
    var gscChromeSyncRunning: Bool { gscChromeLinkSyncRunning || gscChromePageIndexingSyncRunning || gscChromeCoreWebVitalsSyncRunning }
    @Published var approvedVisualIssueIDs: Set<UUID> = []
    @Published private(set) var batchProgress: BatchScenarioProgress?
    @Published private(set) var batchRunning = false
    @Published var activeProjectID: UUID?
    private var task: Task<Void, Never>?
    /// Keep post-crawl network measurements alive independently of the crawl
    /// task. An unretained Task could be dropped during a UI state transition,
    /// leaving a journal column permanently marked as not checked.
    private var searchConsoleTask: Task<Void, Never>?
    private var pageSpeedTask: Task<Void, Never>?
    private var backlinkTask: Task<Void, Never>?
    private var backlinkDetailTask: Task<Void, Never>?
    private var donorProfileTasks: [DonorProfileSource: Task<Void, Never>] = [:]
    private var donorProfileTarget = ""
    /// The journal entry that belongs to the currently running GSC job.  A new
    /// crawl must never silently inherit an inspection still running for the
    /// previous site.
    private var searchConsoleJobStartURL: String?
    private var pendingRecordFlush: Task<Void, Never>?
    private var pendingSummaryRefresh: Task<Void, Never>?
    private var pendingRecords: [CrawlRecord] = []
    private var recordIndexByURL: [String: Int] = [:]
    private var inlinkCounts: [String: Int] = [:]
    private var cachedErrors = 0
    private var lastDiagnosticWrite = Date.distantPast
    private var speedSamples: [(TimeInterval, Int)] = []
    /// Set only for an MCP-launched scan. It is consumed when that crawl ends so
    /// a subsequent manual Start does not unexpectedly spend Search Console quota.
    private var inspectSearchConsoleAfterCrawl = false
    /// An access denial is a property-level fact, not a transient request
    /// failure.  Keep it for the lifetime of this project run so that the
    /// other GSC entry points cannot reopen Chrome or retry the same property.
    private var gscAccessDeniedTarget = ""
    /// Used by MCP for an atomic crawl → audit workflow.  It prevents an audit
    /// from being started against a SQLite-restored URL list, which deliberately
    /// does not retain parsed hreflang markup.
    private var runAuditAfterCrawl = false
    /// Keeps WebKit and its callbacks alive for the complete visual-audit session.
    private var visualAuditor: WebKitVisualAudit?
    private let crawler = SpiderCrawler()
    /// Injected by the root view. A crawl can never begin without an online
    /// licence confirmation from the Worker.
    weak var licenseManager: LicenseManager?
    @Published private(set) var licenseCheckRunning = false

    private enum DonorProfileSource: Hashable {
        case ahrefs
        case ubersuggest
        case searchConsole
    }

    /// Google returns an ordinary-looking error response for a property the
    /// signed-in account cannot read. Continuing URL by URL only wastes the
    /// daily inspection quota and leaves the journal stuck in "Checking…".
    private func isGSCPropertyAccessDenied(_ error: Error) -> Bool {
        let text = error.localizedDescription.lowercased()
        return text.contains("access denied") ||
            text.contains("don't have access to this property") ||
            text.contains("do not have access to this property") ||
            text.contains("access to this property") ||
            text.contains("insufficient permission") ||
            text.contains("permission denied") ||
            text.contains("not authorized") ||
            text.contains("not authorised")
    }

    private func gscTargetKey(_ value: String) -> String {
        let qualified = value.contains("://") ? value : "https://\(value)"
        return URL(string: qualified)?.host?.lowercased() ?? value.lowercased()
    }

    private func isGSCBlocked(for target: String) -> Bool {
        !gscAccessDeniedTarget.isEmpty && gscAccessDeniedTarget == gscTargetKey(target)
    }

    private func blockGSCForCurrentTarget(reason: String) {
        let target = gscTargetKey(startText)
        guard !target.isEmpty else { return }
        let isFirstAccessDenial = gscAccessDeniedTarget != target
        gscAccessDeniedTarget = target
        if isFirstAccessDenial {
            // Links, Page Indexing and Core Web Vitals share this dedicated
            // profile. Closing it ends any already-open helper as well.
            ChromeGSCLinkSync.shared.closeDedicatedChromeAfterAccessDenied()
        }
        searchConsoleTask?.cancel()
        searchConsoleTask = nil
        searchConsoleRunning = false
        searchConsoleJobStartURL = nil
        let message = "Остановлено: нет доступа к свойству Google Search Console. Повторные обращения и новые окна Chrome для \(target) отключены до следующего запуска проверки."
        searchConsoleMessage = message
        gscChromeStage = "Google Search Console: stopped — no access to this property"
        gscBacklinkStage = "Stopped: no access to this Search Console property"
        backlinkMessage = message
        ProjectJournalStore.shared.updateSearchConsole(startURL: startText, records: records, unavailableReason: reason)
    }

    var errors: Int { cachedErrors }
    var speed: String {
        guard let first = speedSamples.first, let last = speedSamples.last, last.0 - first.0 >= 1 else { return "Measuring speed…" }
        return String(format: "%.1f URL/s · last 60s", Double(last.1 - first.1) / (last.0 - first.0))
    }
    var progress: Double { settings.maxURLs == 0 ? 0 : min(1, Double(records.count) / Double(settings.maxURLs)) }
    /// The queue grows and shrinks while links are discovered. This is an honest
    /// estimate rather than a false percentage based on the configured URL limit.
    var crawlProgress: Double {
        let totalKnown = records.count + queued
        guard totalKnown > 0 else { return state == .finished ? 1 : 0 }
        return Double(records.count) / Double(totalKnown)
    }
    var crawlProgressLabel: String {
        if state == .finished { return "Crawl complete: \(records.count) URLs processed" }
        return "Processed \(records.count) · queued \(queued) · \(speed)"
    }

    func start() {
        guard !licenseCheckRunning else { return }
        guard let licenseManager else { state = .idle; return }
        licenseCheckRunning = true
        Task { [weak self, weak licenseManager] in
            defer { self?.licenseCheckRunning = false }
            guard let self, let licenseManager, await licenseManager.validateForNewCrawl() else { return }
            if self.state == .paused {
                await self.crawler.pause(false)
                self.state = .crawling
            } else {
                self.startLicensedCrawl()
            }
        }
    }

    private func startLicensedCrawl() {
        let raw = mode == .spider ? [startText] : listText.components(separatedBy: .newlines)
        let urls = raw.compactMap { value -> URL? in
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            let qualified = trimmed.contains("://") ? trimmed : "https://" + trimmed
            return URL(string: qualified)
        }
        guard !urls.isEmpty else { return }
        // Use one canonical project key regardless of whether a user typed a
        // bare host or a complete URL. This keeps PageSpeed and GSC updates in
        // the existing project history instead of creating a second project.
        if mode == .spider, let first = urls.first { startText = first.absoluteString }
        // A new crawl is a new explicit request. It may be for a different
        // property, so do not carry a previous run's access refusal into it.
        gscAccessDeniedTarget = ""
        loadBacklinkImportsForCurrentTarget()
        gscSiteReport = GSCSiteReportImport.load(target: startText)
        gscCoreWebVitalsReport = GSCCoreWebVitalsImport.load(target: startText)
        cancelPostCrawlChecksForNewCrawl()
        resetCrawlResults(); queued = urls.count; startedAt = Date(); state = .crawling
        // The crawl has a durable home before the first request.  This keeps a
        // large project recoverable even if the application is stopped while
        // secondary queues (Page Weight, GSC, Chrome) are still running.
        _ = SessionStore.shared.beginRun(startURL: startText, date: startedAt ?? Date())
        let diagnosticsLog = CrawlDiagnosticsLog(startURL: startText, date: startedAt ?? Date())
        stageProgress = CrawlStageProgress()
        speedSamples = [(ProcessInfo.processInfo.systemUptime, 0)]
        let selectedMode = mode; let selectedSettings = settings
        Task { await diagnosticsLog.configuration(settings: selectedSettings) }
        launchConfiguredIntegrationsAtCrawlStart()
        task = Task { [weak self, crawler] in
            await crawler.crawl(seeds: urls, mode: selectedMode, settings: selectedSettings, onRecord: { record in
                await MainActor.run {
                    self?.enqueue(record, maximum: selectedSettings.maxURLs)
                }
            }, onQueue: { count in await MainActor.run { self?.queued = count } }, onStages: { progress in
                await MainActor.run {
                    self?.stageProgress = progress
                    self?.writeCrawlDiagnostics()
                }
            }, onDiagnostic: { record, event in
                await diagnosticsLog.record(record, event: event)
            })
            await MainActor.run {
                guard let self, self.state != .stopped else { return }
                self.flushPendingRecords()
                // Localised variants are the same logical page. Normalise their
                // classification once the full crawl graph is available, rather
                // than letting translated titles produce conflicting page types.
                self.synchronizeHreflangPageTypes()
                SessionStore.shared.persist(self.records)
                let finalRecords = self.records
                let crawlStartURL = self.startText
                SessionStore.shared.finishRun()
                AutomationBridge.logPerformance(site: crawlStartURL, stage: "crawl", duration: Date().timeIntervalSince(self.startedAt ?? Date()), urlCount: finalRecords.count)
                // Keep a run in the journal immediately. This lets PageSpeed
                // and Search Console write their independent results while the
                // CPU-heavy issue aggregation runs in the background.
                if let projectID = self.activeProjectID { ProjectJournalStore.shared.record(projectID: projectID, records: finalRecords, issues: self.issues) }
                else { ProjectJournalStore.shared.record(startURL: crawlStartURL, records: finalRecords, issues: self.issues) }
                // URL Inspection is a quota-bound per-URL API, unlike Chrome
                // Page Indexing / Links exports. It is explicitly opt-in.
                let shouldInspectSearchConsole = self.inspectSearchConsoleAfterCrawl || self.settings.enableGSCURLInspection
                self.inspectSearchConsoleAfterCrawl = false
                let shouldRunAudit = self.runAuditAfterCrawl
                self.runAuditAfterCrawl = false
                self.state = .finished; self.queued = 0
                if shouldInspectSearchConsole {
                    self.inspectSearchConsole(urlIDs: Set(finalRecords.map(\.id)))
                }
                // Per-page DataForSEO enrichment uses the final canonical URL
                // set. The optional donor-domain profile is deliberately a
                // separate job, so this only fills page metrics.
                if self.settings.enableDataForSEO { self.refreshBacklinkData(force: false) }
                self.runPageSpeed()
                self.finishSummariesInBackground(records: finalRecords, startURL: crawlStartURL)
                if shouldRunAudit { self.runAudit() }
            }
        }
    }

    /// Site-wide integrations do not need the finished crawl result. Starting
    private func writeCrawlDiagnostics() {
        guard Date().timeIntervalSince(lastDiagnosticWrite) >= 2 else { return }
        lastDiagnosticWrite = Date()
        let url = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("ShareSpider/crawl-progress.json")
        let payload: [String: Any] = ["site": startText, "updatedAt": Date().timeIntervalSince1970, "elapsed": Date().timeIntervalSince(startedAt ?? Date()), "records": records.count, "queued": queued, "httpCompleted": stageProgress.htmlCompleted, "httpFinished": stageProgress.htmlFinished, "weightCompleted": stageProgress.weightCompleted, "weightTotal": stageProgress.weightTotal, "weightPartial": stageProgress.weightPartial, "weightActive": stageProgress.weightActive]
        if let data = try? JSONSerialization.data(withJSONObject: payload, options: .prettyPrinted) {
            try? data.write(to: url, options: .atomic)
            // The application-support copy is kept for local automation;
            // the run-folder copy is the user-visible durable progress file.
            SessionStore.shared.writeProgress(data)
        }
    }

    /// Site-wide Search Console reports do not need the finished crawl result.
    /// Full donor-profile work is intentionally excluded: it starts only from
    /// the Backlinks tab and never overlaps a crawl.
    private func launchConfiguredIntegrationsAtCrawlStart() {
        if settings.enableGSCChromeReports { syncGSCPageIndexingThroughChrome() }
    }

    /// A second crawl can be started while PageSpeed/GSC is still finishing the
    /// first one.  Keep the two measurements from blocking each other and make
    /// the interrupted journal entry explicit rather than leaving "Not checked".
    private func cancelPostCrawlChecksForNewCrawl() {
        if searchConsoleRunning {
            searchConsoleTask?.cancel()
            if let previousURL = searchConsoleJobStartURL {
                ProjectJournalStore.shared.updateSearchConsole(
                    startURL: previousURL,
                    records: [],
                    unavailableReason: "Superseded by a newer crawl."
                )
            }
            searchConsoleTask = nil
            searchConsoleJobStartURL = nil
            searchConsoleRunning = false
            searchConsoleMessage = "Previous Search Console check was stopped for the new crawl."
        }
        if pageSpeedRunning {
            pageSpeedTask?.cancel()
            pageSpeedTask = nil
            pageSpeedRunning = false
        }
        if backlinkRunning {
            backlinkTask?.cancel()
            backlinkTask = nil
            backlinkRunning = false
            backlinkMessage = "Previous backlink analysis was stopped for the new crawl."
        }
        // The donor profile is a standalone Backlinks-tab task. Do not leave
        // one running when a new crawl begins.
        if backlinkDrilldownRunning {
            backlinkDetailTask?.cancel()
            backlinkDetailTask = nil
            backlinkDrilldownRunning = false
            dataForSEOProfileClassifying = false
            dataForSEOProfileMessage = "Stopped for the new crawl."
        }
        donorProfileTasks.values.forEach { $0.cancel() }
        donorProfileTasks.removeAll()
        ahrefsProfileClassifying = false
        ubersuggestProfileClassifying = false
        gscProfileClassifying = false
    }
    func start(project: SEOProject) {
        mode = .spider
        startText = project.startURL
        activeProjectID = project.id
        start()
    }
    func pause() { Task { await crawler.pause(true) }; state = .paused }
    func stop() { Task { await crawler.stop() }; task?.cancel(); state = .stopped; queued = 0 }
    func clear() { stop(); resetCrawlResults(); state = .idle; selectedIssue = nil; startedAt = nil; activeProjectID = nil }
    /// Clears all crawl, audit and visual-audit state so the next Start begins
    /// with a clean client report instead of mixing results from two sites.
    func resetAuditAndCrawl() {
        stop()
        resetCrawlResults()
        auditReport = nil; aiAuditReport = nil; customAnalyses = []; aiAuditStage = .notStarted; pageSpeedResults = []; visualAuditResults = []
        approvedVisualIssueIDs = []; auditRunning = false; aiAuditRunning = false; pageSpeedRunning = false
        visualAuditRunning = false; visualAuditProgress = nil; visualAuditor = nil
        state = .idle; startedAt = nil; queued = 0
    }
    func selectOverview(_ item: OverviewItem) {
        overviewSelectionName = item.name; overviewSelectionIDs = item.urlIDs
        overviewSelectionExternalURLs = gscSiteReport?.metrics.first(where: { $0.label == item.name })?.examples
            ?? gscCoreWebVitalsReport?.metrics.first(where: { $0.label == item.name })?.examples ?? []
        switch item.name {
        case BacklinkDrilldownKind.referringDomains.rawValue, "Referring Main Domains": loadBacklinkDrilldown(.referringDomains)
        case BacklinkDrilldownKind.backlinks.rawValue, "Referring Pages", "Dofollow Backlinks", "Nofollow Backlinks", "Broken Backlinks": loadBacklinkDrilldown(.backlinks)
        default: backlinkDrilldownKind = nil
        }
    }
    func clearOverviewSelection() { overviewSelectionName = nil; overviewSelectionIDs = []; overviewSelectionExternalURLs = []; backlinkDrilldownKind = nil }
    /// Network workers deliver records independently. Publishing each one forces
    /// SwiftUI to redraw large tables hundreds of times per second, so records are
    /// committed in short batches while preserving their crawl order.
    private func enqueue(_ record: CrawlRecord, maximum: Int) {
        pendingRecords.append(record)
        guard pendingRecordFlush == nil else { return }
        pendingRecordFlush = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(250))
            guard !Task.isCancelled else { return }
            self?.flushPendingRecords(maximum: maximum)
        }
    }

    private func flushPendingRecords(maximum: Int = .max) {
        pendingRecordFlush?.cancel(); pendingRecordFlush = nil
        let batch = pendingRecords; pendingRecords.removeAll(keepingCapacity: true)
        guard !batch.isEmpty else { return }
        var updated = records
        for record in batch { merge(record, into: &updated, maximum: maximum) }
        records = updated
        // Store the completed HTTP row or subsequent Page Weight/CDP update as
        // it arrives.  Do not wait until the entire crawl is finished.
        let persisted = Set(batch.map { $0.url.absoluteString }).compactMap { key in
            recordIndexByURL[key].map { records[$0] }
        }
        SessionStore.shared.persist(persisted)
        let tick = ProcessInfo.processInfo.systemUptime
        if let previous = speedSamples.last, tick - previous.0 > 120 { speedSamples.removeAll() }
        speedSamples.append((tick, stageProgress.htmlCompleted))
        while speedSamples.count > 2 && tick - speedSamples[1].0 > 60 { speedSamples.removeFirst() }
        cachedErrors = records.reduce(into: 0) { count, record in
            if !record.hasUnconfirmedCDPFailure && (!record.error.isEmpty || (record.statusCode ?? 0) >= 400) { count += 1 }
        }
        scheduleSummaryRefresh()
    }

    /// Inlinks are updated only for the source URL's targets. This replaces the
    /// previous full scan of every page and every link after every HTTP response.
    private func merge(_ incoming: CrawlRecord, into records: inout [CrawlRecord], maximum: Int) {
        let key = incoming.url.absoluteString
        if let existing = recordIndexByURL[key] ?? records.firstIndex(where: { $0.id == incoming.id }) {
            // Redirect normalisation can change a URL string between the first
            // response and Page Weight/CDP follow-up. The record UUID remains
            // stable, so never append a duplicate row for that follow-up.
            recordIndexByURL[key] = existing
            if incoming.weightStatus == "Measured" || incoming.weightStatus == "Partial" {
                // Aggregate Page Weight metrics retain the full measurement.
                // The UI only ever renders the top resources, so retaining the
                // heaviest 50 prevents a large catalogue page from permanently
                // carrying thousands of asset rows in RAM.
                records[existing].pageResources = Array(incoming.pageResources.sorted { $0.size > $1.size }.prefix(50))
                records[existing].pageWeight = incoming.pageWeight
                records[existing].weightStatus = incoming.weightStatus
                records[existing].imageResourceSize = incoming.imageResourceSize
                records[existing].javascriptResourceSize = incoming.javascriptResourceSize
                records[existing].cssResourceSize = incoming.cssResourceSize
                records[existing].fontResourceSize = incoming.fontResourceSize
                records[existing].thirdPartyResourceSize = incoming.thirdPartyResourceSize
                records[existing].primaryWeightCause = incoming.primaryWeightCause
                records[existing].images = incoming.images
            }
            if incoming.originalStatus != nil || incoming.cdpStatus != nil || incoming.verificationResult != "Not required" {
                records[existing].originalStatus = incoming.originalStatus
                records[existing].cdpStatus = incoming.cdpStatus
                records[existing].verificationResult = incoming.verificationResult
                records[existing].statusCode = incoming.statusCode
                records[existing].contentType = incoming.contentType
                records[existing].error = incoming.error
                records[existing].transportUsed = incoming.transportUsed
                records[existing].suspectedWAF = incoming.suspectedWAF
            }
            for source in incoming.redirectSources where !records[existing].redirectSources.contains(source) { records[existing].redirectSources.append(source) }
            for source in incoming.foundOnURLs where !records[existing].foundOnURLs.contains(source) && records[existing].foundOnURLs.count < 20 { records[existing].foundOnURLs.append(source) }
            if records[existing].redirectURL == nil { records[existing].redirectURL = incoming.redirectURL; records[existing].redirectChain = incoming.redirectChain }
            return
        }
        guard records.count < maximum else { return }
        var record = incoming
        record.inlinks = inlinkCounts[key, default: 0]
        // Targets have already been used to populate the crawl queue below;
        // they are not needed by the post-crawl audit. Keep a bounded anchor
        // sample for technical exports rather than every navigation link.
        if record.outgoingLinks.count > 250 { record.outgoingLinks = Array(record.outgoingLinks.prefix(250)) }
        let index = records.count
        records.append(record)
        recordIndexByURL[key] = index
        for target in record.internalLinkTargets {
            inlinkCounts[target, default: 0] += 1
            if let targetIndex = recordIndexByURL[target] {
                records[targetIndex].inlinks = inlinkCounts[target, default: 0]
            }
        }
        records[index].internalLinkTargets.removeAll(keepingCapacity: false)
    }

    /// Hreflang alternates are language/region variants of one logical page.
    /// The strongest non-unknown classification in each connected group wins.
    private func synchronizeHreflangPageTypes() {
        func urlKey(_ url: URL) -> String {
            var components = URLComponents(url: url, resolvingAgainstBaseURL: false)
            components?.fragment = nil
            let raw = (components?.url ?? url).absoluteString
            return raw.trimmingCharacters(in: CharacterSet(charactersIn: "/")).lowercased()
        }

        var indexes: [String: Int] = [:]
        for (index, record) in records.enumerated() { indexes[urlKey(record.url)] = index }
        var neighbours = Array(repeating: Set<Int>(), count: records.count)
        for (index, record) in records.enumerated() {
            for link in record.hreflangTargets {
                guard let target = URL(string: link.url), let other = indexes[urlKey(target)], other != index else { continue }
                neighbours[index].insert(other)
                neighbours[other].insert(index)
            }
        }

        var visited = Set<Int>()
        for start in records.indices where !visited.contains(start) && !neighbours[start].isEmpty {
            var group: [Int] = []
            var pending = [start]
            visited.insert(start)
            while let index = pending.popLast() {
                group.append(index)
                for next in neighbours[index] where !visited.contains(next) {
                    visited.insert(next)
                    pending.append(next)
                }
            }
            guard let source = group
                .map({ records[$0] })
                .filter({ $0.pageType != "Unknown" })
                .max(by: { $0.classificationConfidence < $1.classificationConfidence }) else { continue }
            for index in group {
                guard records[index].pageType != source.pageType || records[index].aiBustCategory != source.aiBustCategory else { continue }
                records[index].pageType = source.pageType
                records[index].aiBustCategory = source.aiBustCategory
                records[index].classificationConfidence = source.classificationConfidence
                records[index].classificationEvidence = ["Inherited from hreflang group: \(source.url.absoluteString)"]
            }
        }
    }

    private func scheduleSummaryRefresh() {
        // Throttle rather than debounce: a continuous crawl must still refresh
        // its counters periodically, but never more than once per short interval.
        guard pendingSummaryRefresh == nil else { return }
        let snapshot = records
        let siteReport = gscSiteReport
        let vitals = gscCoreWebVitalsReport
        let backlinks = backlinkReport
        pendingSummaryRefresh = Task { [weak self] in
            try? await Task.sleep(for: .seconds(5))
            guard !Task.isCancelled else { return }
            let summaries = await Task.detached(priority: .utility) {
                (IssueBuilder.make(snapshot, gscSiteReport: siteReport, gscCoreWebVitalsReport: vitals), OverviewBuilder.make(snapshot, gscSiteReport: siteReport, gscCoreWebVitalsReport: vitals) + BacklinkOverviewBuilder.make(snapshot, report: backlinks))
            }.value
            guard !Task.isCancelled else { return }
            self?.issues = summaries.0
            self?.overview = summaries.1
            self?.pendingSummaryRefresh = nil
        }
    }

    private func refreshSummariesNow() {
        pendingSummaryRefresh?.cancel(); pendingSummaryRefresh = nil
        issues = IssueBuilder.make(records, gscSiteReport: gscSiteReport, gscCoreWebVitalsReport: gscCoreWebVitalsReport)
        overview = OverviewBuilder.make(records, gscSiteReport: gscSiteReport, gscCoreWebVitalsReport: gscCoreWebVitalsReport) + BacklinkOverviewBuilder.make(records, report: backlinkReport)
    }

    /// Issue building scans the complete result set and can be expensive on
    /// large websites. Running it outside the main actor means the two remote
    /// post-crawl checks can begin immediately instead of waiting for it.
    private func finishSummariesInBackground(records snapshot: [CrawlRecord], startURL: String) {
        Task { [weak self, snapshot, startURL] in
            let started = Date()
            let siteReport = self?.gscSiteReport
            let coreWebVitalsReport = self?.gscCoreWebVitalsReport
            let summaries = await Task.detached(priority: .utility) {
                (IssueBuilder.make(snapshot, gscSiteReport: siteReport, gscCoreWebVitalsReport: coreWebVitalsReport), OverviewBuilder.make(snapshot, gscSiteReport: siteReport, gscCoreWebVitalsReport: coreWebVitalsReport))
            }.value
            guard let self,
                  self.state == .finished,
                  self.startText == startURL else { return }
            self.issues = summaries.0
            // URL Inspection can complete while the expensive issue pass is
            // still running. Use the latest records here so GSC counters are
            // not overwritten with the old all-zero snapshot.
            let latestRecords = self.records
            self.overview = OverviewBuilder.make(latestRecords, gscSiteReport: self.gscSiteReport, gscCoreWebVitalsReport: self.gscCoreWebVitalsReport) + BacklinkOverviewBuilder.make(latestRecords, report: self.backlinkReport)
            ProjectJournalStore.shared.updateIssueCounters(startURL: startURL, issues: summaries.0)
            AutomationBridge.logPerformance(site: startURL, stage: "final-issue-aggregation", duration: Date().timeIntervalSince(started), urlCount: snapshot.count)
        }
    }

    private func resetCrawlResults() {
        pendingRecordFlush?.cancel(); pendingRecordFlush = nil
        pendingSummaryRefresh?.cancel(); pendingSummaryRefresh = nil
        pendingRecords.removeAll(keepingCapacity: false)
        recordIndexByURL.removeAll(keepingCapacity: false)
        inlinkCounts.removeAll(keepingCapacity: false)
        records = []; issues = []; overview = []; cachedErrors = 0
        aiAuditReport = nil; customAnalyses = []; aiAuditRunning = false; aiAuditStage = .notStarted
        backlinkReport = nil; backlinkProgress = 0; backlinkTotal = 0; backlinkMessage = ""
        backlinkSourceDetails = []; backlinkHistory = []; referringDomainDetails = []
        overviewSelectionName = nil; overviewSelectionIDs = []; issueSelection = nil
    }
    func selectIssue(_ issue: Issue) { issueSelection = issue }
    func clearIssueSelection() { issueSelection = nil }
    func refreshBacklinkData(force: Bool = true) {
        guard !records.isEmpty, !backlinkRunning else { return }
        let canonicalPages = records.filter { $0.isGSCEligible }.map { $0.url.absoluteString }
        guard !canonicalPages.isEmpty else { backlinkMessage = "No canonical HTML pages are available for backlink enrichment."; return }
        let startURL = startText
        backlinkRunning = true; backlinkProgress = 0; backlinkTotal = canonicalPages.count
        backlinkMessage = "Backlink analysis started"
        backlinkTask = Task { [weak self, canonicalPages, startURL] in
            let started = Date()
            do {
                let result = try await DataForSEOBacklinks.enrich(target: startURL, expectedURLs: canonicalPages, force: force) { progress in
                    await MainActor.run {
                        guard let self else { return }
                        self.backlinkProgress = progress.completed
                        self.backlinkTotal = progress.total
                        self.backlinkMessage = progress.message
                    }
                }
                guard !Task.isCancelled else { return }
                await MainActor.run {
                    guard let self, self.startText == startURL else { return }
                    self.applyBacklinkReport(result)
                    self.backlinkReport = result
                    self.backlinkRunning = false
                    self.backlinkProgress = result.pages.count
                    self.backlinkTotal = max(canonicalPages.count, result.pages.count)
                    self.backlinkMessage = "Backlink analysis completed · \(result.pages.count) pages enriched · \(result.apiRequests) API requests"
                    self.refreshSummariesNow()
                    ProjectJournalStore.shared.updateBacklinks(startURL: startURL, report: result, enrichedURLs: result.pages.count, totalURLs: canonicalPages.count)
                    AutomationBridge.logPerformance(site: startURL, stage: "backlink-analysis", duration: Date().timeIntervalSince(started), urlCount: result.pages.count)
                }
            } catch is CancellationError {
                await MainActor.run { self?.backlinkRunning = false; self?.backlinkMessage = "Backlink analysis stopped." }
            } catch {
                await MainActor.run { self?.backlinkRunning = false; self?.backlinkMessage = "Backlink analysis unavailable: \(error.localizedDescription)" }
            }
        }
    }
    func stopBacklinkAnalysis() {
        backlinkTask?.cancel(); backlinkTask = nil
        backlinkDetailTask?.cancel(); backlinkDetailTask = nil
        backlinkRunning = false; backlinkDrilldownRunning = false
        backlinkMessage = "Backlink analysis stopped."
        dataForSEOProfileMessage = "Stopped"
        dataForSEOProfileClassifying = false
    }
    /// Runs the complete donor-domain comparison as a standalone job. It does
    /// not require crawl records, so it can be used from the Backlinks tab for
    /// an existing project or a newly entered domain.
    func runBacklinkProfileAnalysis() {
        guard state != .crawling, state != .paused,
              !startText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        loadBacklinkSourceAnalysis()
        if AhrefsKeychain.isConfigured { loadAhrefsReferringDomains() }
        if UbersuggestMCPAuth.shared.isConnected { loadUbersuggestReferringDomains() }
        syncGSCBacklinksThroughChrome()
    }

    /// Cached source imports are useful without starting a new site crawl.
    /// The Backlinks screen calls this when the target field changes, so a
    /// reopened project immediately regains its already downloaded datasets.
    func loadBacklinkImportsForCurrentTarget() {
        let target = startText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !target.isEmpty else { return }
        if target != donorProfileTarget {
            donorProfileTasks.values.forEach { $0.cancel() }
            donorProfileTasks.removeAll()
            donorProfileTarget = target
            ahrefsSourceStats = BacklinkSourceStats()
            ubersuggestSourceStats = BacklinkSourceStats()
            gscSourceStats = BacklinkSourceStats()
            ahrefsProfileClassifying = false
            ubersuggestProfileClassifying = false
            gscProfileClassifying = false
        }
        gscBacklinkImport = GSCBacklinkImportService.load(target: target)
        ahrefsBacklinkImport = AhrefsBacklinkService.load(target: target)
        ubersuggestBacklinkImport = UbersuggestBacklinkService.load(target: target)
    }

    /// Starts the lightweight, domain-level classification for every available
    /// source. Search Console, Ahrefs and Ubersuggest do not expose the exact
    /// linking page in these datasets, so the result is labelled as a donor
    /// domain signal rather than a fact about an individual backlink.
    func ensureDonorProfileClassification() {
        loadBacklinkImportsForCurrentTarget()
        if let report = ahrefsBacklinkImport {
            beginDonorProfile(
                .ahrefs,
                domains: report.domains,
                links: report.linkCount,
                knownSpam: Set(report.spamDomains)
            )
        }
        if let report = ubersuggestBacklinkImport {
            beginDonorProfile(
                .ubersuggest,
                domains: report.domains,
                links: report.linkCount,
                knownSpam: Set(report.spamDomains)
            )
        }
        if let report = gscBacklinkImport {
            beginDonorProfile(
                .searchConsole,
                domains: report.donors.map(\.sourceDomain),
                links: report.donors.reduce(0) { $0 + max(1, $1.links) }
            )
        }
    }

    private func beginDonorProfile(
        _ source: DonorProfileSource,
        domains: [String],
        links: Int,
        knownSpam: Set<String> = []
    ) {
        let normalizedDomains = Array(Set(domains.map(GSCBacklinkImportService.normalizedDomain).filter { !$0.isEmpty }))
        guard !normalizedDomains.isEmpty, !isProfileClassifying(source) else { return }
        if stats(for: source).donors == normalizedDomains.count { return }

        donorProfileTasks[source]?.cancel()
        setProfileClassifying(source, true)
        updateProfileProgress(source, completed: 0, total: normalizedDomains.count, message: "Classifying donor domains…")
        let expectedStartURL = startText
        donorProfileTasks[source] = Task { [weak self] in
            let result = await DonorDomainProfiler.profile(
                domains: normalizedDomains,
                links: links,
                knownSpam: knownSpam
            ) { [weak self] completed, total in
                guard !Task.isCancelled else { return }
                await MainActor.run {
                    guard let self, self.startText == expectedStartURL else { return }
                    self.updateProfileProgress(
                        source,
                        completed: completed,
                        total: total,
                        message: "Classifying donor domains: \(completed) / \(total)"
                    )
                }
            }
            guard !Task.isCancelled else { return }
            await MainActor.run {
                guard let self, self.startText == expectedStartURL else { return }
                self.setStats(result, for: source)
                self.setProfileClassifying(source, false)
                self.updateProfileProgress(
                    source,
                    completed: result.donors,
                    total: result.donors,
                    message: "Loaded \(result.donors) donor domains · domain-level classification complete"
                )
                self.donorProfileTasks[source] = nil
            }
        }
    }

    private func stats(for source: DonorProfileSource) -> BacklinkSourceStats {
        switch source {
        case .ahrefs: ahrefsSourceStats
        case .ubersuggest: ubersuggestSourceStats
        case .searchConsole: gscSourceStats
        }
    }

    private func setStats(_ stats: BacklinkSourceStats, for source: DonorProfileSource) {
        switch source {
        case .ahrefs: ahrefsSourceStats = stats
        case .ubersuggest: ubersuggestSourceStats = stats
        case .searchConsole: gscSourceStats = stats
        }
    }

    private func isProfileClassifying(_ source: DonorProfileSource) -> Bool {
        switch source {
        case .ahrefs: ahrefsProfileClassifying
        case .ubersuggest: ubersuggestProfileClassifying
        case .searchConsole: gscProfileClassifying
        }
    }

    private func setProfileClassifying(_ source: DonorProfileSource, _ value: Bool) {
        switch source {
        case .ahrefs: ahrefsProfileClassifying = value
        case .ubersuggest: ubersuggestProfileClassifying = value
        case .searchConsole: gscProfileClassifying = value
        }
    }

    private func updateProfileProgress(_ source: DonorProfileSource, completed: Int, total: Int, message: String) {
        switch source {
        case .ahrefs:
            ahrefsComparisonProgress = completed
            ahrefsComparisonTotal = max(total, 1)
            ahrefsComparisonMessage = message
        case .ubersuggest:
            ubersuggestComparisonProgress = completed
            ubersuggestComparisonTotal = max(total, 1)
            ubersuggestComparisonMessage = message
        case .searchConsole:
            gscBacklinkProgress = completed
            gscBacklinkTotal = max(total, 1)
            gscBacklinkStage = message
        }
    }
    /// Explicit actions only: Ahrefs and Ubersuggest API/MCP queries can
    /// consume the user's provider quota, so a routine site crawl never fires
    /// them implicitly. Their cached snapshots remain available for charts.
    func loadAhrefsReferringDomains() {
        guard state != .crawling, state != .paused,
              !ahrefsComparisonRunning, !startText.isEmpty else { return }
        ahrefsComparisonRunning = true
        ahrefsComparisonProgress = 0; ahrefsComparisonTotal = 1
        ahrefsComparisonMessage = "Requesting referring domains…"
        backlinkMessage = "Loading referring domains from Ahrefs…"
        let target = startText
        Task { [weak self] in
            do {
                let result = try await AhrefsBacklinkService.referringDomains(target: target) { progress in
                    await MainActor.run {
                        self?.ahrefsComparisonProgress = progress.completed
                        self?.ahrefsComparisonTotal = max(progress.total, progress.completed, 1)
                        self?.ahrefsComparisonMessage = progress.message
                    }
                }
                await MainActor.run {
                    guard let self, self.startText == target else { return }
                    self.ahrefsBacklinkImport = result
                    self.ahrefsComparisonRunning = false
                    self.ahrefsComparisonProgress = 1
                    self.ahrefsComparisonMessage = "Loaded \(result.domains.count) donor domains"
                    self.backlinkMessage = "Loaded \(result.domains.count) Ahrefs referring domains for comparison."
                    self.beginDonorProfile(
                        .ahrefs,
                        domains: result.domains,
                        links: result.linkCount,
                        knownSpam: Set(result.spamDomains)
                    )
                }
            } catch {
                await MainActor.run { self?.ahrefsComparisonRunning = false; self?.ahrefsComparisonMessage = "Failed: \(error.localizedDescription)"; self?.backlinkMessage = "Ahrefs comparison data unavailable: \(error.localizedDescription)" }
            }
        }
    }
    func loadUbersuggestReferringDomains() {
        guard state != .crawling, state != .paused,
              !ubersuggestComparisonRunning, !startText.isEmpty else { return }
        ubersuggestComparisonRunning = true
        ubersuggestComparisonProgress = 0; ubersuggestComparisonTotal = 1
        ubersuggestComparisonMessage = "Requesting referring domains…"
        backlinkMessage = "Loading referring domains from Ubersuggest MCP…"
        let target = startText
        Task { [weak self] in
            do {
                let result = try await UbersuggestBacklinkService.referringDomains(target: target) { progress in
                    await MainActor.run {
                        self?.ubersuggestComparisonProgress = progress.completed
                        self?.ubersuggestComparisonTotal = max(progress.total, progress.completed, 1)
                        self?.ubersuggestComparisonMessage = progress.message
                    }
                }
                await MainActor.run {
                    guard let self, self.startText == target else { return }
                    self.ubersuggestBacklinkImport = result
                    self.ubersuggestComparisonRunning = false
                    self.ubersuggestComparisonProgress = 1
                    self.ubersuggestComparisonMessage = "Loaded \(result.domains.count) donor domains"
                    self.backlinkMessage = "Loaded \(result.domains.count) Ubersuggest referring domains for comparison."
                    self.beginDonorProfile(
                        .ubersuggest,
                        domains: result.domains,
                        links: result.linkCount,
                        knownSpam: Set(result.spamDomains)
                    )
                }
            } catch {
                await MainActor.run { self?.ubersuggestComparisonRunning = false; self?.ubersuggestComparisonMessage = "Failed: \(error.localizedDescription)"; self?.backlinkMessage = "Ubersuggest comparison data unavailable: \(error.localizedDescription)" }
            }
        }
    }
    private func loadBacklinkDrilldown(_ kind: BacklinkDrilldownKind) {
        guard !backlinkDrilldownRunning else { return }
        backlinkDrilldownKind = kind; backlinkDrilldownRunning = true
        let target = startText
        backlinkDetailTask = Task { [weak self] in
            do {
                switch kind {
                case .referringDomains:
                    let result = try await DataForSEOBacklinks.referringDomains(target: target)
                    await MainActor.run { self?.referringDomainDetails = result; self?.backlinkDrilldownRunning = false; self?.backlinkDetailTask = nil }
                case .backlinks:
                    let result = try await DataForSEOBacklinks.backlinks(target: target)
                    await MainActor.run { self?.backlinkSourceDetails = result; self?.backlinkDrilldownRunning = false; self?.backlinkDetailTask = nil }
                }
            } catch is CancellationError {
                await MainActor.run { self?.backlinkDrilldownRunning = false; self?.backlinkMessage = "Backlink details stopped."; self?.backlinkDetailTask = nil }
            } catch {
                await MainActor.run { self?.backlinkDrilldownRunning = false; self?.backlinkMessage = "Backlink details unavailable: \(error.localizedDescription)"; self?.backlinkDetailTask = nil }
            }
        }
    }

    /// Loads the donor-page and anchor rows used by the dedicated Backlinks
    /// tab. It intentionally runs only on request: source-level data is much
    /// larger than the compact domain summary used during a regular crawl.
    func loadBacklinkSourceAnalysis() {
        guard state != .crawling, state != .paused,
              !backlinkDrilldownRunning, !startText.isEmpty else { return }
        backlinkDrilldownKind = .backlinks
        backlinkDrilldownRunning = true
        backlinkSourceDetails = []; backlinkHistory = []; backlinkProgress = 0; backlinkTotal = 0
        backlinkMessage = "Loading active, lost and historical links from DataForSEO…"
        dataForSEOProfileMessage = backlinkMessage
        let target = startText
        backlinkDetailTask = Task { [weak self] in
            do {
                let result = try await DataForSEOBacklinks.backlinks(target: target) { progress in
                    await MainActor.run {
                        self?.backlinkProgress = progress.completed
                        self?.backlinkTotal = progress.total
                        self?.backlinkMessage = progress.message
                        self?.dataForSEOProfileMessage = progress.message
                    }
                }
                // History availability depends on the DataForSEO plan.  It is
                // supplementary, so active-link data remains useful if it is
                // unavailable for this account.
                let history = (try? await DataForSEOBacklinks.history(target: target)) ?? []
                await MainActor.run {
                    self?.dataForSEOProfileClassifying = true
                    self?.dataForSEOProfileMessage = "Classifying donor pages and checking probable language networks…"
                }
                let classified = await HreflangDonorInspector.inspect(result, target: target)
                await MainActor.run {
                    self?.backlinkSourceDetails = classified
                    self?.backlinkHistory = history
                    self?.backlinkDrilldownRunning = false
                    self?.dataForSEOProfileClassifying = false
                    let active = result.filter { !$0.isLost }.count
                    let lost = result.count - active
                    let message = history.isEmpty
                        ? "Loaded \(active) active and \(lost) lost donor links. Historical trend is unavailable for this DataForSEO account."
                        : "Loaded \(active) active and \(lost) lost donor links with historical trend."
                    self?.backlinkMessage = message
                    self?.dataForSEOProfileMessage = message
                    self?.backlinkDetailTask = nil
                }
            } catch is CancellationError {
                await MainActor.run {
                    self?.backlinkDrilldownRunning = false
                    self?.dataForSEOProfileClassifying = false
                    self?.backlinkMessage = "Backlink source analysis stopped."
                    self?.dataForSEOProfileMessage = "Stopped"
                    self?.backlinkDetailTask = nil
                }
            } catch {
                await MainActor.run {
                    self?.backlinkDrilldownRunning = false
                    self?.dataForSEOProfileClassifying = false
                    self?.backlinkMessage = "Backlink source analysis unavailable: \(error.localizedDescription)"
                    self?.dataForSEOProfileMessage = "Failed: \(error.localizedDescription)"
                    self?.backlinkDetailTask = nil
                }
            }
        }
    }

    func importGSCBacklinkCSV() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.commaSeparatedText, .plainText]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.prompt = "Import GSC links"
        guard panel.runModal() == .OK, let url = panel.url,
              let csv = try? String(contentsOf: url, encoding: .utf8) else { return }
        applyGSCBacklinkCSV(csv)
    }
    /// The GSC Links report is not exposed by Google's public API.  This uses
    /// a dedicated local Chrome profile plus Playwright to export the report,
    /// then feeds that CSV into the same importer as a manual export.
    func syncGSCBacklinksThroughChrome() {
        // All Chrome-based GSC reports use the same dedicated profile and CDP
        // port. Running two at once makes one helper close the other's page.
        guard state != .crawling, state != .paused, !gscChromeSyncRunning else { return }
        guard !isGSCBlocked(for: startText) else {
            blockGSCForCurrentTarget(reason: "Google Search Console access was already denied during this check.")
            return
        }
        gscChromeLinkSyncRunning = true
        gscChromeProgress = 0
        gscChromeTotal = 3
        gscBacklinkProgress = 0
        gscBacklinkTotal = 3
        gscBacklinkStage = "Opening Chrome"
        gscChromeStage = "Google Search Console · links: opening Chrome"
        backlinkMessage = "Opening the local ShareSpider Chrome profile and exporting the Google Search Console Links report…"
        ChromeGSCLinkSync.shared.start(target: startText, progress: { [weak self] message, completed, total in
            guard let self else { return }
            self.gscChromeProgress = completed
            self.gscChromeTotal = total
            self.gscBacklinkProgress = completed
            self.gscBacklinkTotal = total
            self.gscBacklinkStage = message
            self.gscChromeStage = "Google Search Console · links: \(message)"
        }) { [weak self] result in
            guard let self else { return }
            self.gscChromeLinkSyncRunning = false
            switch result {
            case .success(let csv):
                self.applyGSCBacklinkCSV(csv)
            case .failure(let error):
                if self.isGSCPropertyAccessDenied(error) {
                    self.blockGSCForCurrentTarget(reason: error.localizedDescription)
                } else {
                    self.gscBacklinkStage = "Failed: \(error.localizedDescription)"
                    self.backlinkMessage = "Chrome GSC link sync failed: \(error.localizedDescription)"
                }
            }
        }
    }
    func importGSCSiteReportCSV() {
        let panel = NSOpenPanel(); panel.allowedContentTypes = [.commaSeparatedText, .plainText]; panel.allowsMultipleSelection = false; panel.canChooseDirectories = false; panel.prompt = "Import GSC site report"
        guard panel.runModal() == .OK, let url = panel.url, let csv = try? String(contentsOf: url, encoding: .utf8) else { return }
        applyGSCSiteReportCSV(csv)
    }
    /// Page Indexing is intentionally not folded into URL Inspection. The
    /// report represents Google's site-wide view, including URLs absent from
    /// this crawl, so it is imported as a separate GSC coverage dataset.
    func syncGSCPageIndexingThroughChrome() {
        guard !gscChromeSyncRunning else { return }
        guard !isGSCBlocked(for: startText) else {
            blockGSCForCurrentTarget(reason: "Google Search Console access was already denied during this check.")
            return
        }
        gscChromePageIndexingSyncRunning = true
        gscChromeProgress = 0
        gscChromeTotal = 3
        gscChromeStage = "Google Search Console · Page Indexing: opening Chrome"
        searchConsoleMessage = "Opening the local ShareSpider Chrome profile and exporting Google Search Console Page Indexing…"
        ChromeGSCPageIndexingSync.shared.start(target: startText, progress: { [weak self] message, completed, total in
            guard let self else { return }
            self.gscChromeProgress = completed
            self.gscChromeTotal = total
            self.gscChromeStage = "Google Search Console · Page Indexing (indexed, excluded, 404, soft 404, redirects, 5xx, canonical, robots): \(message)"
        }) { [weak self] result in
            guard let self else { return }
            self.gscChromePageIndexingSyncRunning = false
            switch result {
            case .success(let csv): self.applyGSCSiteReportCSV(csv)
            case .failure(let error):
                // Deliberately retain gscSiteReport and its journal snapshot.
                let message = error.localizedDescription
                if self.isGSCPropertyAccessDenied(error) {
                    self.blockGSCForCurrentTarget(reason: message)
                } else {
                    self.searchConsoleMessage = "Chrome Page Indexing sync is waiting: \(message)"
                }
            }
        }
    }
    private func applyGSCSiteReportCSV(_ csv: String) {
        do {
            let report = try GSCSiteReportImport.importCSV(csv, target: startText)
            gscSiteReport = report
            ProjectJournalStore.shared.updateSearchConsoleSiteReport(startURL: startText, report: report)
            refreshSummariesNow()
            searchConsoleMessage = "Imported GSC site-wide Page indexing report: \(report.total) reported URLs."
        } catch { searchConsoleMessage = "GSC site report import unavailable: \(error.localizedDescription)" }
    }
    /// Imports mobile-only field-data groups from the Core Web Vitals report.
    func syncGSCCoreWebVitalsThroughChrome() {
        guard !gscChromeSyncRunning else { return }
        guard !isGSCBlocked(for: startText) else {
            blockGSCForCurrentTarget(reason: "Google Search Console access was already denied during this check.")
            return
        }
        gscChromeCoreWebVitalsSyncRunning = true; gscChromeProgress = 0; gscChromeTotal = 3
        gscChromeStage = "Google Search Console · mobile Core Web Vitals: opening Chrome"
        ChromeGSCCoreWebVitalsSync.shared.start(target: startText, progress: { [weak self] message, completed, total in
            self?.gscChromeProgress = completed; self?.gscChromeTotal = total
            self?.gscChromeStage = "Google Search Console · mobile Core Web Vitals: \(message)"
        }) { [weak self] result in
            guard let self else { return }; self.gscChromeCoreWebVitalsSyncRunning = false
            switch result {
            case .success(let csv):
                do {
                    let report = try GSCCoreWebVitalsImport.importCSV(csv, target: self.startText)
                    self.gscCoreWebVitalsReport = report
                    ProjectJournalStore.shared.updateGSCCoreWebVitals(startURL: self.startText, report: report)
                    self.refreshSummariesNow()
                    self.searchConsoleMessage = "Imported Google mobile Core Web Vitals: \(report.total) reported URL group(s)."
                } catch { self.searchConsoleMessage = "Core Web Vitals import unavailable: \(error.localizedDescription)" }
            case .failure(let error):
                let message = error.localizedDescription
                if self.isGSCPropertyAccessDenied(error) {
                    self.blockGSCForCurrentTarget(reason: message)
                } else {
                    self.searchConsoleMessage = "Chrome Core Web Vitals sync is waiting: \(message)"
                }
            }
        }
    }
    func coreWebVitalIssues(for url: URL) -> String {
        let key = url.absoluteString.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let values = gscCoreWebVitalsReport?.metrics.filter { metric in metric.examples.contains { $0.trimmingCharacters(in: CharacterSet(charactersIn: "/")) == key } }.map { "\($0.group): \($0.label)" } ?? []
        return values.isEmpty ? "—" : values.joined(separator: "; ")
    }

    private func applyGSCBacklinkCSV(_ csv: String) {
        do {
            let imported = try GSCBacklinkImportService.importCSV(csv, target: startText)
            gscBacklinkImport = imported
            gscBacklinkProgress = gscBacklinkTotal
            gscBacklinkStage = "Imported \(imported.donors.count) donor records"
            backlinkMessage = "Imported \(imported.donors.count) Google Search Console donor records. DataForSEO remains the active/lost source."
            beginDonorProfile(
                .searchConsole,
                domains: imported.donors.map(\.sourceDomain),
                links: imported.donors.reduce(0) { $0 + max(1, $1.links) }
            )
        } catch {
            gscBacklinkStage = "Import failed: \(error.localizedDescription)"
            backlinkMessage = "Google Search Console link import unavailable: \(error.localizedDescription)"
        }
    }
    private func applyBacklinkReport(_ report: BacklinkReport) {
        for index in records.indices {
            let key = DataForSEOBacklinks.urlKey(records[index].url.absoluteString)
            guard let metric = report.pages[key] else { continue }
            records[index].backlinkChecked = true
            records[index].backlinks = metric.backlinks
            records[index].referringDomains = metric.referringDomains
            records[index].referringMainDomains = metric.referringMainDomains
            records[index].referringPages = metric.referringPages
            records[index].backlinkPageRank = metric.rank
            records[index].backlinkSpamScore = metric.spamScore
            records[index].brokenBacklinks = metric.brokenBacklinks
            records[index].dofollowBacklinks = metric.dofollowBacklinks
            records[index].nofollowBacklinks = metric.nofollowBacklinks
            records[index].referringIPs = metric.referringIPs
            records[index].referringSubnets = metric.referringSubnets
        }
    }
    func runAudit() {
        guard let start = URL(string: startText), !auditRunning else { return }; auditRunning = true
        AutomationBridge.writeAuditStatus(.init(site: start.absoluteString, state: "running", checked: 0, problems: 0, missingReturnLinks: 0, examples: [], updatedAt: Date()))
        Task {
            let started = Date()
            let report = await AuditScanner.run(startURL: start, records: records)
            AutomationBridge.logPerformance(site: start.absoluteString, stage: "audit", duration: Date().timeIntervalSince(started), urlCount: records.count)
            let missingReturns = report.hreflang.filter { $0.returnLinkCheckable && !$0.reciprocal }
            AutomationBridge.writeAuditStatus(.init(site: start.absoluteString, state: "complete", checked: report.hreflang.count, problems: report.hreflang.filter { ($0.returnLinkCheckable && !$0.reciprocal) || ($0.status ?? 0) / 100 != 2 }.count, missingReturnLinks: missingReturns.count, examples: missingReturns.prefix(10).map { result in
                let returned = result.returnLinkTargets.sorted().prefix(3).joined(separator: ", ")
                return "\(result.source.absoluteString) → \(result.target.absoluteString) | return set: \(returned)"
            }, updatedAt: Date()))
            await MainActor.run { self.auditReport = report; self.auditRunning = false }
        }
    }
    func runAIAudit() {
        guard !aiAuditRunning, !records.isEmpty else { return }
        aiAuditRunning = true
        aiAuditStage = .collectingData
        let startURL = startText
        let data = AIAuditCollector.collect(records: records, issues: issues, auditReport: auditReport, backlinkReport: backlinkReport, referringDomainDetails: referringDomainDetails, backlinkSourceDetails: backlinkSourceDetails)
        let auditRecords = records, auditOverview = overview, auditIssues = issues
        let auditDomains = referringDomainDetails, auditSources = backlinkSourceDetails
        Task { [weak self] in
            let report = await AIAuditAnalyzer.analyze(data: data, startURL: startURL, records: auditRecords, overview: auditOverview, issues: auditIssues, referringDomainDetails: auditDomains, backlinkSourceDetails: auditSources) { stage in
                self?.aiAuditStage = stage
            }
            guard !Task.isCancelled else { return }
            self?.aiAuditReport = report
            self?.customAnalyses = report.customAnalyses
            ProjectJournalStore.shared.updateAIAudit(startURL: startURL, report: report, agent: AIProviderSettings.load().agent)
            self?.aiAuditRunning = false
        }
    }
    func exportAIAuditPDF() {
        guard let report = aiAuditReport else { return }
        if let url = AIAuditPDFReport.export(report: report, startURL: startText) {
            // Make a successful automatic export visible immediately; otherwise
            // Finder-created PDF files are easy to mistake for a failed export.
            NSWorkspace.shared.activateFileViewerSelecting([url])
        }
    }
    func exportTechnicalTasks(severity: TechnicalTaskPDFReport.Severity = .highMedium) {
        guard !records.isEmpty else { return }
        // The task brief includes both crawl issues and technical findings that
        // were calculated in Audit (for example non-reciprocal hreflang).
        // No extra URL requests are made during export.
        let auditIssues = auditReport?.findings.map {
            Issue(name: $0.title, type: "Audit", priority: $0.severity, urlIDs: $0.urlIDs)
        } ?? []
        let allTasks = issues + auditIssues
        if let url = TechnicalTaskPDFReport.export(records: records, issues: allTasks, startURL: startText, severity: severity) {
            NSWorkspace.shared.activateFileViewerSelecting([url])
        }
    }
    /// Each domain is crawled independently. A batch never shares a crawl queue,
    /// sitemap, robots policy or URL limit between client sites.
    /// Batch/scenario runs include Search Console coverage whenever the user has
    /// connected it.  This happens before both the PDFs and the journal entry
    /// are created, so the date column always describes one coherent check.
    /// All batch, scheduled and deep-link launches converge here.  A batch is
    /// one user-requested analysis, so it performs one online confirmation
    /// before the first site starts rather than spending a request per URL.
    func runBatch(urlStrings: [String], kind: ScenarioReportKind, severity: TechnicalTaskPDFReport.Severity, outputDirectory: URL, includeSearchConsole: Bool? = nil) {
        guard !batchRunning, !licenseCheckRunning, let licenseManager else { return }
        licenseCheckRunning = true
        Task { [weak self, weak licenseManager] in
            defer { self?.licenseCheckRunning = false }
            guard let self, let licenseManager, await licenseManager.validateForNewCrawl() else { return }
            self.runLicensedBatch(urlStrings: urlStrings, kind: kind, severity: severity, outputDirectory: outputDirectory, includeSearchConsole: includeSearchConsole)
        }
    }

    private func runLicensedBatch(urlStrings: [String], kind: ScenarioReportKind, severity: TechnicalTaskPDFReport.Severity, outputDirectory: URL, includeSearchConsole: Bool? = nil) {
        let urls = urlStrings.compactMap { raw -> URL? in
            let clean = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            return URL(string: clean.contains("://") ? clean : "https://" + clean)
        }
        guard !urls.isEmpty, !batchRunning else { return }
        let selectedSettings = settings
        let useSearchConsole = includeSearchConsole ?? SearchConsoleAuth.shared.isConnected
        let reportsDirectory = ReportFileNaming.downloadsDirectory
        batchRunning = true
        let siteNames = urls.map { $0.host ?? $0.absoluteString }
        let initialProgress = BatchScenarioProgress(completed: 0, total: urls.count, currentSite: siteNames[0], pendingSites: siteNames, outputDirectory: reportsDirectory.path)
        batchProgress = initialProgress
        AutomationBridge.writeBatchStatus(initialProgress)
        Task { [weak self] in
            var completed = 0
            var batchSummary: [BatchSiteCriticalSummary] = []
            var reportPaths: [String] = []
            for (index, start) in urls.enumerated() {
                guard !Task.isCancelled else { break }
                let completedBeforeSite = completed
                let activeProgress = BatchScenarioProgress(completed: completedBeforeSite, total: urls.count, currentSite: siteNames[index], currentSiteProgress: 0, pendingSites: Array(siteNames[index...]), outputDirectory: reportsDirectory.path)
                AutomationBridge.writeBatchStatus(activeProgress)
                await MainActor.run { self?.batchProgress = activeProgress }
                var siteRecords: [CrawlRecord] = []
                let siteCrawler = SpiderCrawler()
                let tracker = BatchSiteTracker()
                let crawlStarted = Date()
                await siteCrawler.crawl(seeds: [start], mode: .spider, settings: selectedSettings, onRecord: { record in
                    let siteProgress = await tracker.record()
                    await MainActor.run {
                        if let index = siteRecords.firstIndex(where: { $0.id == record.id }) { siteRecords[index] = record }
                        else { siteRecords.append(record) }
                    }
                    let progress = BatchScenarioProgress(completed: completedBeforeSite, total: urls.count, currentSite: siteNames[index], currentSiteProgress: siteProgress, pendingSites: Array(siteNames[index...]), outputDirectory: reportsDirectory.path)
                    AutomationBridge.writeBatchStatus(progress)
                    await MainActor.run { self?.batchProgress = progress }
                }, onQueue: { count in
                    let siteProgress = await tracker.queue(count)
                    let progress = BatchScenarioProgress(completed: completedBeforeSite, total: urls.count, currentSite: siteNames[index], currentSiteProgress: siteProgress, pendingSites: Array(siteNames[index...]), outputDirectory: reportsDirectory.path)
                    AutomationBridge.writeBatchStatus(progress)
                    await MainActor.run { self?.batchProgress = progress }
                })
                AutomationBridge.logPerformance(site: start.absoluteString, stage: "crawl", duration: Date().timeIntervalSince(crawlStarted), urlCount: siteRecords.count)
                let issuesStarted = Date()
                let siteIssues = IssueBuilder.make(siteRecords)
                AutomationBridge.logPerformance(site: start.absoluteString, stage: "issue-build", duration: Date().timeIntervalSince(issuesStarted), urlCount: siteRecords.count)
                let auditStarted = Date()
                let audit = await AuditScanner.run(startURL: start, records: siteRecords)
                AutomationBridge.logPerformance(site: start.absoluteString, stage: "audit", duration: Date().timeIntervalSince(auditStarted), urlCount: siteRecords.count)
                var gscCountries: [SearchConsoleTrafficCountry] = []
                if useSearchConsole {
                    let searchConsoleStarted = Date()
                    do {
                        let result = try await self?.inspectedSearchConsoleRecords(siteRecords)
                        if let result { siteRecords = result.records; gscCountries = result.countries }
                        AutomationBridge.logPerformance(site: start.absoluteString, stage: "search-console", duration: Date().timeIntervalSince(searchConsoleStarted), urlCount: result?.checked ?? 0)
                    } catch {
                        // Keep the crawl and client PDFs useful if Google rejects
                        // a token or quota request. Persist the reason so the
                        // journal never remains stuck at “Checking…”.
                        siteRecords = self?.markSearchConsoleUnavailable(siteRecords, targetIDs: Set(siteRecords.map(\.id)), reason: error.localizedDescription) ?? siteRecords
                        AutomationBridge.logPerformance(site: start.absoluteString, stage: "search-console-unavailable", duration: Date().timeIntervalSince(searchConsoleStarted), urlCount: 0)
                    }
                }
                let speedStarted = Date()
                let pageSpeed = await PageSpeedService.checkHomepage(start)
                AutomationBridge.logPerformance(site: start.absoluteString, stage: "pagespeed-home", duration: Date().timeIntervalSince(speedStarted), urlCount: 2)
                let auditIssues = audit.findings.map { Issue(name: $0.title, type: "Audit", priority: $0.severity, urlIDs: $0.urlIDs) }
                batchSummary.append(Self.criticalSummary(name: start.host ?? start.absoluteString, startURL: start, records: siteRecords, issues: siteIssues + auditIssues))
                let siteName = (start.host ?? "site").replacingOccurrences(of: "/", with: "-")
                let directory = reportsDirectory.appendingPathComponent(siteName, isDirectory: true)
                try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                let auditName = ReportFileNaming.stem(for: start.absoluteString, report: "Audit") + ".pdf"
                let tasksName = ReportFileNaming.stem(for: start.absoluteString, report: "Technical-Tasks") + ".pdf"
                if kind == .clientAudit || kind == .both {
                    let output = directory.appendingPathComponent(auditName); let started = Date()
                    if ClientPDFReport.write(to: output, report: audit, records: siteRecords, issues: siteIssues, startURL: start.absoluteString) { reportPaths.append(output.path) }
                    AutomationBridge.logPerformance(site: start.absoluteString, stage: "pdf-client-audit", duration: Date().timeIntervalSince(started), urlCount: siteRecords.count)
                }
                if kind == .technicalTasks || kind == .both {
                    let output = directory.appendingPathComponent(tasksName); let started = Date()
                    if TechnicalTaskPDFReport.write(to: output, records: siteRecords, issues: siteIssues + auditIssues, startURL: start.absoluteString, severity: severity) { reportPaths.append(output.path) }
                    AutomationBridge.logPerformance(site: start.absoluteString, stage: "pdf-technical-tasks", duration: Date().timeIntervalSince(started), urlCount: siteRecords.count)
                }
                await MainActor.run {
                    ProjectJournalStore.shared.record(startURL: start.absoluteString, records: siteRecords, issues: siteIssues + auditIssues)
                    ProjectJournalStore.shared.updatePageSpeed(startURL: start.absoluteString, results: pageSpeed)
                    if useSearchConsole {
                        let gscReason = siteRecords.first(where: { $0.searchConsoleIndexStatus == "Unavailable" })?.searchConsoleFetchStatus
                        ProjectJournalStore.shared.updateSearchConsole(startURL: start.absoluteString, records: siteRecords, unavailableReason: gscReason)
                        ProjectJournalStore.shared.updateSearchConsoleTraffic(startURL: start.absoluteString, records: siteRecords, countries: gscCountries)
                    }
                }
                completed += 1
                let progress = BatchScenarioProgress(completed: completed, total: urls.count, currentSite: siteNames[index], currentSiteProgress: 1, pendingSites: index + 1 < siteNames.count ? Array(siteNames[(index + 1)...]) : [], outputDirectory: reportsDirectory.path, reportPaths: reportPaths)
                AutomationBridge.writeBatchStatus(progress)
                await MainActor.run { self?.batchProgress = progress }
            }
            let summaryURL = reportsDirectory.appendingPathComponent(ReportFileNaming.stem(for: "https://batch.local", report: "Critical-Issues-Summary") + ".pdf")
            let savedSummary = !batchSummary.isEmpty && BatchCriticalPDFReport.write(to: summaryURL, summaries: batchSummary)
            if savedSummary { reportPaths.insert(summaryURL.path, at: 0) }
            let finalProgress = BatchScenarioProgress(completed: completed, total: urls.count, currentSite: "Batch complete", currentSiteProgress: 1, pendingSites: [], outputDirectory: reportsDirectory.path, summaryReportPath: savedSummary ? summaryURL.path : "", reportPaths: reportPaths)
            AutomationBridge.writeBatchStatus(finalProgress)
            await MainActor.run {
                self?.batchRunning = false
                self?.batchProgress = finalProgress
            }
        }
    }
    private static func criticalSummary(name: String, startURL: URL, records: [CrawlRecord], issues: [Issue]) -> BatchSiteCriticalSummary {
        var seen = Set<String>()
        let critical = issues.filter { $0.priority == "High" }.sorted { $0.count > $1.count }.compactMap { issue -> BatchCriticalIssue? in
            // The same issue may appear both in crawl findings and the audit.
            guard seen.insert(issue.name).inserted else { return nil }
            let examples = records.filter { issue.urlIDs.contains($0.id) }.prefix(3).map { $0.url.absoluteString }
            return BatchCriticalIssue(title: issue.name, count: max(issue.count, examples.count), examples: examples)
        }.prefix(8).map { $0 }
        return BatchSiteCriticalSummary(name: name, url: startURL.absoluteString, issues: critical)
    }
    func runPageSpeed() {
        guard !pageSpeedRunning, let home = URL(string: startText) else { return }
        pageSpeedRunning = true
        pageSpeedTask = Task { [weak self] in
            let results = await PageSpeedService.checkHomepage(home)
            await MainActor.run {
                guard let self else { return }
                self.pageSpeedResults = results
                self.pageSpeedRunning = false
                ProjectJournalStore.shared.updatePageSpeed(startURL: self.startText, results: results)
                self.pageSpeedTask = nil
            }
        }
    }
    /// Runs the Search Console URL Inspection API only for rows currently shown
    /// in the table. This prevents an accidental multi-thousand-URL API job and
    /// respects Google's per-property inspection quota.
    func inspectSearchConsole(urlIDs: Set<UUID>) {
        guard !searchConsoleRunning else { return }
        guard !isGSCBlocked(for: startText) else {
            blockGSCForCurrentTarget(reason: "Google Search Console access was already denied during this check.")
            return
        }
        let targetIDs = urlIDs.isEmpty ? Set(records.map(\.id)) : urlIDs
        let targets = records.filter { targetIDs.contains($0.id) && $0.kind == .internalURL && $0.isGSCEligible }
        AutomationBridge.logPerformance(site: startText, stage: "search-console-command targets=\(targets.count)", duration: 0, urlCount: records.count)
        guard !targets.isEmpty else {
            let reason = "No canonical HTML page URLs are eligible for Google inspection."
            searchConsoleMessage = reason
            ProjectJournalStore.shared.updateSearchConsole(startURL: startText, records: records, unavailableReason: reason)
            return
        }
        searchConsoleRunning = true; searchConsoleProgress = 0; searchConsoleTotal = targets.count
        searchConsoleMessage = "Preparing Search Console inspection…"
        let jobStartURL = startText
        searchConsoleJobStartURL = jobStartURL
        // Persist the state before making the first network call.  Inspection
        // quotas can make a response slow; the Projects journal must show that
        // it is running, not incorrectly say that nothing was checked.
        ProjectJournalStore.shared.updateSearchConsole(
            startURL: jobStartURL,
            records: [],
            unavailableReason: "Checking…"
        )
        searchConsoleTask = Task { [weak self, jobStartURL] in
            guard let self else { return }
            do {
                let started = Date()
                let result = try await self.inspectedSearchConsoleRecords(self.records, targetIDs: targetIDs) { completed, total in
                    self.searchConsoleProgress = completed
                    self.searchConsoleMessage = "Search Console: \(completed) of \(total) URLs checked"
                }
                guard !Task.isCancelled else { return }
                self.records = result.records
                // GSC fields are part of Overview metrics. Rebuild the small
                // summary after the inspection finishes so its counts are not
                // left at the pre-Google zero values while the journal already
                // contains the completed result.
                self.scheduleSummaryRefresh()
                self.searchConsoleRunning = false
                if result.checked == result.total {
                    self.searchConsoleMessage = "Search Console inspection complete: \(targets.count) URLs"
                    ProjectJournalStore.shared.updateSearchConsole(startURL: jobStartURL, records: self.records)
                    ProjectJournalStore.shared.updateSearchConsoleTraffic(startURL: jobStartURL, records: self.records, countries: result.countries)
                } else {
                    ProjectJournalStore.shared.updateSearchConsole(
                        startURL: jobStartURL,
                        records: self.records,
                        unavailableReason: "Inspection was interrupted before completion."
                    )
                }
                AutomationBridge.logPerformance(site: jobStartURL, stage: "search-console-complete", duration: Date().timeIntervalSince(started), urlCount: result.checked)
                self.searchConsoleTask = nil
                self.searchConsoleJobStartURL = nil
            } catch {
                guard !Task.isCancelled else { return }
                let reason = error.localizedDescription
                if self.isGSCPropertyAccessDenied(error) {
                    self.blockGSCForCurrentTarget(reason: reason)
                    return
                }
                self.records = self.markSearchConsoleUnavailable(self.records, targetIDs: targetIDs, reason: reason)
                self.scheduleSummaryRefresh()
                self.searchConsoleRunning = false
                self.searchConsoleMessage = "Search Console unavailable: \(reason)"
                ProjectJournalStore.shared.updateSearchConsole(startURL: jobStartURL, records: self.records, unavailableReason: reason)
                AutomationBridge.logPerformance(site: jobStartURL, stage: "search-console-error", duration: 0, urlCount: targets.count)
                self.searchConsoleTask = nil
                self.searchConsoleJobStartURL = nil
            }
        }
    }

    private func markSearchConsoleUnavailable(_ sourceRecords: [CrawlRecord], targetIDs: Set<UUID>, reason: String) -> [CrawlRecord] {
        sourceRecords.map { record in
            guard targetIDs.contains(record.id), record.kind == .internalURL, record.isGSCEligible else { return record }
            var unavailable = record
            unavailable.searchConsoleIndexStatus = "Unavailable"
            unavailable.searchConsoleFetchStatus = reason
            unavailable.searchConsoleCoverage = ""
            unavailable.searchConsolePerformanceChecked = false
            return unavailable
        }
    }
    /// Shared, one-at-a-time URL Inspection runner for the URLs tab and batch
    /// scenarios.  The service is deliberately sequential because the Google
    /// endpoint has strict quotas; callers can still show their own progress.
    private func inspectedSearchConsoleRecords(_ sourceRecords: [CrawlRecord], targetIDs: Set<UUID>? = nil, onProgress: ((Int, Int) -> Void)? = nil) async throws -> (records: [CrawlRecord], checked: Int, total: Int, countries: [SearchConsoleTrafficCountry]) {
        var records = sourceRecords
        let targets = records.filter {
            (targetIDs == nil || targetIDs!.contains($0.id)) && $0.kind == .internalURL && $0.isGSCEligible
        }
        guard !targets.isEmpty else { return (records, 0, 0, []) }
        let token = try await SearchConsoleAuth.shared.accessToken()
        let accessibleProperties = try await SearchConsoleInspectionService.accessibleProperties(accessToken: token)
        guard !accessibleProperties.isEmpty else {
            throw SearchConsoleError.request("The connected Google account has no accessible Search Console properties.")
        }
        let resolvedProperties = Dictionary(uniqueKeysWithValues: targets.compactMap { target in
            SearchConsoleInspectionService.siteProperty(for: target.url, accessibleProperties: accessibleProperties).map { (target.id, $0) }
        })
        let unmatchedHosts = Set(targets.filter { resolvedProperties[$0.id] == nil }.compactMap { $0.url.host?.lowercased() })
        let unavailableReason = unmatchedHosts.isEmpty ? "" : "No accessible Google Search Console property matches: \(unmatchedHosts.sorted().joined(separator: ", "))."
        var checked = 0
        for target in targets {
            guard !Task.isCancelled else { break }
            defer {
                checked += 1
                onProgress?(checked, targets.count)
            }
            if let index = records.firstIndex(where: { $0.id == target.id }) {
                guard let property = resolvedProperties[target.id] else {
                    records[index].searchConsoleIndexStatus = "Unavailable"
                    records[index].searchConsoleFetchStatus = unavailableReason
                    records[index].searchConsoleCoverage = ""
                    continue
                }
                do {
                    let result = try await SearchConsoleInspectionService.inspect(url: target.url, siteURL: property, accessToken: token)
                    records[index].searchConsoleIndexStatus = result.indexStatus
                    records[index].searchConsoleFetchStatus = result.fetchStatus
                    records[index].searchConsoleCoverage = result.coverage
                    records[index].searchConsoleGoogleCanonical = result.googleCanonical
                    records[index].searchConsoleLastCrawl = result.lastCrawl
                    records[index].searchConsoleRobotsStatus = result.robotsStatus
                    records[index].searchConsoleNoindexStatus = result.noindexStatus
                    records[index].searchConsoleSitemaps = result.sitemaps
                    records[index].searchConsoleRichResultErrors = result.richResultErrors
                    records[index].searchConsoleMobileIssues = result.mobileIssues
                } catch {
                    // This is property-wide, not a URL-specific failure.
                    // Abort immediately so no further API quota is spent.
                    if isGSCPropertyAccessDenied(error) { throw error }
                    records[index].searchConsoleIndexStatus = "Unavailable"
                    records[index].searchConsoleFetchStatus = error.localizedDescription
                    records[index].searchConsoleCoverage = ""
                    records[index].searchConsoleGoogleCanonical = ""
                    records[index].searchConsoleLastCrawl = ""
                    records[index].searchConsoleRobotsStatus = ""
                    records[index].searchConsoleNoindexStatus = ""
                    records[index].searchConsoleSitemaps = []
                    records[index].searchConsoleRichResultErrors = []
                    records[index].searchConsoleMobileIssues = []
                }
            }
            // The inspection endpoint has a strict daily quota; avoid bursts.
            try? await Task.sleep(for: .milliseconds(350))
        }
        var allCountries: [SearchConsoleTrafficCountry] = []
        let byProperty = Dictionary(grouping: targets.filter { resolvedProperties[$0.id] != nil }, by: { resolvedProperties[$0.id]! })
        for (property, propertyTargets) in byProperty {
            do {
                let performance = try await SearchConsolePerformanceService.fetch(siteURL: property, pageURLs: propertyTargets.map(\.url), accessToken: token)
                allCountries.append(contentsOf: performance.countries)
                for target in propertyTargets {
                    guard let index = records.firstIndex(where: { $0.id == target.id }) else { continue }
                    let key = target.url.absoluteString.trimmingCharacters(in: CharacterSet(charactersIn: "/")).lowercased()
                    let value = performance.pages[key] ?? SearchConsolePagePerformance()
                    records[index].searchConsoleClicks7d = value.clicks
                    records[index].searchConsoleImpressions7d = value.impressions
                    records[index].searchConsoleQueryCount = value.queryCount
                    records[index].searchConsoleQueriesTop10 = value.queriesTop10
                    records[index].searchConsoleQueriesTop20 = value.queriesTop20
                    records[index].searchConsolePerformanceChecked = true
                }
            } catch {
                // URL Inspection stays useful even if Search Analytics is not
                // available for the property or is temporarily rate-limited.
            }
        }
        return (records, checked, targets.count, allCountries.sorted { $0.clicks > $1.clicks }.prefix(5).map { $0 })
    }
    func runVisualAudit() {
        guard !visualAuditRunning else { return }
        visualAuditRunning = true
        visualAuditProgress = nil
        let auditor = WebKitVisualAudit(localVision: localVision, pageLimit: settings.visualAuditPageLimit) { [weak self] progress in
            self?.visualAuditProgress = progress
        }
        visualAuditor = auditor
        let pages = records
        Task { [weak self, auditor] in
            let results = await auditor.run(pages)
            guard let self else { return }
            self.visualAuditResults = results
            self.approvedVisualIssueIDs = []
            self.visualAuditRunning = false
            self.visualAuditProgress = nil
            self.visualAuditor = nil
        }
    }
    func setVisualIssueApproved(_ id: UUID, _ approved: Bool) { if approved { approvedVisualIssueIDs.insert(id) } else { approvedVisualIssueIDs.remove(id) } }
    private func restoreLatestSessionForInspection() {
        guard records.isEmpty, let session = SessionStore.shared.latestSession() else { return }
        startText = session.startURL
        records = session.records
        recordIndexByURL = Dictionary(uniqueKeysWithValues: records.enumerated().map { ($0.element.url.absoluteString, $0.offset) })
        refreshSummariesNow()
        state = .finished
    }
    func handleLaunchURL(_ url: URL) {
        guard url.scheme == "sharespider", let command = url.host, let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return }
        let values = Dictionary(uniqueKeysWithValues: (components.queryItems ?? []).map { ($0.name, $0.value ?? "") })
        // Chrome-based GSC commands may be launched without a completed local
        // crawl. Honour their explicit property URL instead of falling back to
        // the last session.
        if let target = values["url"], !target.isEmpty { startText = target }
        if command == "batch" {
            let urls = (values["urls"] ?? "").components(separatedBy: CharacterSet(charactersIn: ",;\n\r")).map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
            guard !urls.isEmpty else { return }
            if let concurrency = Int(values["concurrency"] ?? "") { settings.concurrency = min(32, max(1, concurrency)) }
            if let limit = Int(values["maxURLs"] ?? "") { settings.maxURLs = min(50_000, max(1, limit)) }
            let kind = ScenarioReportKind(rawValue: values["report"] ?? "") ?? .both
            let severity = TechnicalTaskPDFReport.Severity(rawValue: values["severity"] ?? "") ?? .highMedium
            // `searchConsole=0` is an explicit opt-out.  A connected account is
            // otherwise used for batch/scenario reports so the journal's GSC
            // rows are populated alongside crawl and PageSpeed data.
            runBatch(urlStrings: urls, kind: kind, severity: severity, outputDirectory: ReportFileNaming.downloadsDirectory, includeSearchConsole: values["searchConsole"] == "0" ? false : nil)
            return
        }
        if command == "search-console" {
            restoreLatestSessionForInspection()
            if state == .crawling || state == .paused {
                inspectSearchConsoleAfterCrawl = true
                searchConsoleMessage = "Search Console inspection queued for when the crawl completes."
            } else {
                inspectSearchConsole(urlIDs: Set(records.map(\.id)))
            }
            return
        }
        if command == "connect-search-console" {
            Task { await SearchConsoleAuth.shared.authorize() }
            return
        }
        if command == "audit" {
            restoreLatestSessionForInspection()
            if state != .crawling && state != .paused { runAudit() }
            return
        }
        if command == "backlinks" {
            restoreLatestSessionForInspection()
            if state == .crawling || state == .paused {
                backlinkMessage = "Backlink analysis is available after the crawl completes."
            } else {
                refreshBacklinkData(force: values["refresh"] != "0")
            }
            return
        }
        if command == "backlink-rules" {
            if let payload = AutomationBridge.consumePendingBacklinkRules() {
                backlinkMessage = BacklinkClassifier.appendCustomRules(json: payload)
                objectWillChange.send()
            } else {
                backlinkMessage = "No backlink rule update was received."
            }
            return
        }
        if command == "gsc-backlinks-import" {
            if let payload = AutomationBridge.consumePendingGSCBacklinkExport() {
                applyGSCBacklinkCSV(payload)
            } else {
                backlinkMessage = "No Google Search Console link export was received."
            }
            return
        }
        if command == "gsc-chrome-links-sync" {
            restoreLatestSessionForInspection()
            syncGSCBacklinksThroughChrome()
            return
        }
        if command == "gsc-chrome-page-indexing-sync" {
            restoreLatestSessionForInspection()
            syncGSCPageIndexingThroughChrome()
            return
        }
        if command == "gsc-chrome-core-web-vitals-sync" {
            restoreLatestSessionForInspection()
            syncGSCCoreWebVitalsThroughChrome()
            return
        }
        if command == "gsc-site-report-import" {
            if let payload = AutomationBridge.consumePendingGSCSiteReport() { applyGSCSiteReportCSV(payload) }
            else { searchConsoleMessage = "No GSC site report export was received." }
            return
        }
        guard command == "scan" else { return }
        if let target = values["url"], !target.isEmpty { startText = target }
        if let concurrency = Int(values["concurrency"] ?? "") { settings.concurrency = min(32, max(1, concurrency)) }
        if let depth = Int(values["depth"] ?? "") { settings.maxDepth = min(30, max(0, depth)) }
        if values["testMode"] == "1" || values["ignoreRobots"] == "1" { settings.respectRobots = false; settings.followNofollowLinks = true }
        inspectSearchConsoleAfterCrawl = values["searchConsole"] == "1"
        runAuditAfterCrawl = values["audit"] == "1"
        if values["start"] == "1" { start() }
    }
    func importList() {
        let panel = NSOpenPanel(); panel.allowedContentTypes = [.plainText, .commaSeparatedText]; panel.allowsMultipleSelection = false
        // Keep the optional list import outside Documents by default. PDF reports
        // never use a panel and are always written directly to Downloads.
        panel.directoryURL = ReportFileNaming.downloadsDirectory
        guard panel.runModal() == .OK, let url = panel.url, let content = try? String(contentsOf: url) else { return }
        listText = content.components(separatedBy: CharacterSet(charactersIn: ",;\n\r")).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }.joined(separator: "\n")
    }
    func export(_ scope: ExportScope) {
        let rows: [String]
        switch scope {
        case .urls: rows = CSV.urls(records)
        case .issues: rows = CSV.issues(issues, total: records.count)
        case .overview: rows = CSV.overview(overview, total: records.count)
        case .broken: rows = CSV.urls(records.filter { !$0.error.isEmpty || ($0.statusCode ?? 0) >= 400 })
        case .redirects: rows = CSV.urls(records.filter { $0.redirectURL != nil || ($0.statusCode ?? 0) / 100 == 3 })
        case .imagesWithoutAlt: rows = CSV.images(records)
        }
        let panel = NSSavePanel(); panel.allowedContentTypes = [.commaSeparatedText]; panel.nameFieldStringValue = "ShareSpider-\(scope.rawValue).csv"; panel.directoryURL = ReportFileNaming.downloadsDirectory
        guard panel.runModal() == .OK, let destination = panel.url else { return }
        try? rows.joined(separator: "\n").write(to: destination, atomically: true, encoding: .utf8)
    }
}

enum ExportScope: String, CaseIterable, Identifiable { case urls = "URLs", issues = "Issues", overview = "Overview", broken = "Broken links", redirects = "Redirects", imagesWithoutAlt = "Images without alt"; var id: String { rawValue } }

enum IssueBuilder {
    /// WordPress technical paths must be matched as path components. A simple
    /// `contains("wp-")` misclassifies legitimate product slugs such as
    /// `maybach-mb-the-majesty-ii-g-wp-z25` as crawler artefacts.
    private static func isTechnicalSitemapURL(_ record: CrawlRecord) -> Bool {
        if record.url.query != nil { return true }
        let path = record.url.path.lowercased()
        let components = path.split(separator: "/").map(String.init)
        if components.contains(where: { ["wp-admin", "wp-content", "wp-includes"].contains($0) }) { return true }
        return path == "/xmlrpc.php" || path.hasSuffix("/index.php")
    }

    static func make(_ records: [CrawlRecord], gscSiteReport: GSCSiteReport? = nil, gscCoreWebVitalsReport: GSCCoreWebVitalsReport? = nil) -> [Issue] {
        func issue(_ name: String, _ type: String, _ priority: String, _ test: (CrawlRecord) -> Bool) -> Issue? { let ids = Set(records.filter(test).map(\.id)); return ids.isEmpty ? nil : Issue(name: name, type: type, priority: priority, urlIDs: ids) }
        func indexable(_ record: CrawlRecord) -> Bool { record.indexability == "Indexable" }
        func finalHTTPFailure(_ record: CrawlRecord) -> Bool {
            // A browser-side timeout/unavailability has no origin status to
            // confirm. Surface it in the URL diagnostics, but never report it
            // as a broken page merely because the local CDP transport failed.
            if record.hasUnconfirmedCDPFailure { return false }
            let status = record.statusCode ?? 0
            if [403, 429].contains(status) || (500...599).contains(status) || record.suspectedWAF {
                return !record.isPendingChromeVerification && !record.isVerifiedViaChrome
            }
            return !record.error.isEmpty || status >= 400
        }
        let pageWeightMedians = PageMetricsAnalyzer.typeMedians(records)
        let fingerprintCounts = Dictionary(grouping: records.filter { indexable($0) && !$0.contentFingerprint.isEmpty }, by: \.contentFingerprint).mapValues(\.count)
        var result = [
            issue("Internal server/client errors", "Issue", "High") { $0.kind == .internalURL && !$0.isImageCandidate && finalHTTPFailure($0) },
            issue("Broken image resources", "Issue", "High") { $0.kind == .internalURL && $0.isImageCandidate && finalHTTPFailure($0) },
            issue("Heavy image resources", "Warning", "Medium") { $0.kind == .internalURL && $0.isImageResource && ($0.statusCode ?? 0) / 100 == 2 && $0.size > 100_000 },
            issue("Internal redirects (3xx)", "Warning", "Medium") { $0.kind == .internalURL && $0.hasRedirect },
            issue("Missing page title", "Issue", "High") { indexable($0) && $0.isSEOPage && $0.title.isEmpty },
            issue("Missing meta description", "Warning", "Medium") { indexable($0) && $0.isSEOPage && $0.metaDescription.isEmpty },
            issue("Missing H1", "Issue", "High") { indexable($0) && $0.isSEOPage && $0.h1Count == 0 },
            issue("Missing canonical", "Issue", "High") { indexable($0) && $0.isCanonicalEligible && $0.canonical.isEmpty },
            issue("Multiple canonical tags", "Issue", "High") { indexable($0) && $0.isCanonicalEligible && $0.canonicalCount > 1 },
            issue("Relative canonical URL", "Warning", "Medium") { indexable($0) && $0.isCanonicalEligible && !$0.canonicalRaw.isEmpty && !$0.canonicalRaw.contains("://") },
            issue("Canonical points to another URL", "Warning", "Medium") { indexable($0) && $0.isCanonicalEligible && !$0.canonical.isEmpty && $0.canonical.trimmingCharacters(in: CharacterSet(charactersIn: "/")) != $0.url.absoluteString.trimmingCharacters(in: CharacterSet(charactersIn: "/")) },
            issue("Title too long", "Warning", "Medium") { indexable($0) && $0.title.count > 60 },
            issue("Title too short", "Warning", "Medium") { indexable($0) && !$0.title.isEmpty && $0.title.count < 20 },
            issue("Low content", "Opportunity", "Medium") { indexable($0) && $0.isSEOPage && $0.wordCount > 0 && $0.wordCount < 200 },
            issue("HTTP URL", "Warning", "Low") { $0.url.scheme == "http" },
            issue("URL with parameters", "Warning", "Low") { $0.url.query != nil },
            issue("Images without alt text", "Warning", "Medium") { indexable($0) && $0.images.contains(where: { $0.alt.trimmingCharacters(in: .whitespaces).isEmpty }) },
            issue("Images over 100 KB", "Warning", "Medium") { indexable($0) && $0.images.contains(where: { $0.size > 100_000 }) },
            issue("Noindex pages", "Warning", "Medium") { $0.robots.lowercased().contains("noindex") },
            issue("URLs blocked by robots.txt", "Warning", "Medium") { !$0.robotsBlockedBy.isEmpty },
            issue("Nofollow pages", "Warning", "Low") { $0.robots.lowercased().contains("nofollow") },
            // Orphans are navigationally isolated HTML pages. Image files and
            // other fetched resources can naturally have no HTML inlinks and
            // must never be reported as orphan pages.
            issue("Orphan pages", "Warning", "Medium") { $0.isSEOPage && $0.depth > 0 && $0.inlinks == 0 },
            issue("Pages without internal outlinks", "Opportunity", "Low") { $0.isSEOPage && $0.internalLinks == 0 },
            issue("Pages without internal inlinks", "Opportunity", "Low") { $0.isSEOPage && $0.depth > 0 && $0.inlinks == 0 },
            issue("Noindex URLs in sitemap", "Warning", "Medium") { $0.inSitemap && $0.indexability == "Noindex" },
            issue("Technical URLs in sitemap", "Warning", "Medium") { $0.inSitemap && isTechnicalSitemapURL($0) },
            issue("Duplicate content", "Warning", "Medium") { r in indexable(r) && (fingerprintCounts[r.contentFingerprint] ?? 0) > 1 },
            issue("Missing x-default hreflang", "Warning", "Low") { !$0.hreflangCodes.isEmpty && !$0.hasXDefault },
            issue("Hreflang self-reference missing", "Issue", "High") { record in !record.hreflangTargets.isEmpty && !record.hreflangTargets.contains { $0.url.trimmingCharacters(in: CharacterSet(charactersIn: "/")) == record.url.absoluteString.trimmingCharacters(in: CharacterSet(charactersIn: "/")) } },
            issue("Duplicate hreflang codes", "Warning", "Medium") { Set($0.hreflangCodes.map { $0.lowercased() }).count < $0.hreflangCodes.count },
            issue("Invalid hreflang language or region codes", "Warning", "Medium") { record in record.hreflangCodes.contains { code in code.lowercased() != "x-default" && code.range(of: "^[a-z]{2,3}(-[A-Z]{2}|-[0-9]{3})?$", options: .regularExpression) == nil } },
            issue("Missing security headers", "Warning", "Low") { $0.url.scheme == "https" && $0.securityHeaders.count < 4 }
            ,issue("WordPress technical head links", "Warning", "Medium") { !$0.wordPressHeadFindings.isEmpty }
            ,issue("Pages without JSON-LD structured data", "Opportunity", "Medium") { $0.isSchemaEligible && $0.schemaTypes.isEmpty }
            ,issue("Missing Organization / Business schema", "Warning", "Medium") { record in record.isSchemaEligible && !records.contains { $0.isSchemaEligible && $0.schemaTypes.contains { ["Organization", "LocalBusiness", "Corporation", "ProfessionalService"].contains($0) } } }
            ,issue("Missing BreadcrumbList schema", "Warning", "Medium") { record in record.isSchemaEligible && !records.contains { $0.isSchemaEligible && $0.schemaTypes.contains("BreadcrumbList") } }
            ,issue("Schema type does not match page type", "Issue", "High") { $0.isSchemaEligible && $0.schemaCompatibility == "Mismatch" && $0.classificationConfidence >= 0.55 }
            ,issue("Incomplete primary schema", "Warning", "Medium") { $0.isSchemaEligible && !$0.primarySchemaType.isEmpty && $0.schemaCompleteness < 0.75 }
            ,issue("Schema required fields missing", "Issue", "High") { $0.isSchemaEligible && !$0.schemaValidationErrors.isEmpty }
            ,issue("Backlinks: indexable page has no backlinks", "Opportunity", "Medium") { $0.isGSCEligible && $0.backlinkChecked && $0.backlinks == 0 }
            ,issue("Backlinks: lost link equity", "Issue", "High") { record in
                guard record.backlinks > 0 else { return false }
                let canonicalised = !record.canonical.isEmpty && DataForSEOBacklinks.urlKey(record.canonical) != DataForSEOBacklinks.urlKey(record.url.absoluteString)
                return (record.statusCode ?? 0) / 100 >= 3 || record.indexability == "Noindex" || canonicalised
            }
            ,issue("Backlinks: broken external backlinks", "Issue", "High") { $0.brokenBacklinks > 0 }
            ,issue("Backlinks: high spam score", "Warning", "Medium") { $0.backlinkChecked && $0.backlinkSpamScore >= 50 }
            ,issue("Page Weight: Heavy Pages", "Warning", "Medium") { $0.isSEOPage && $0.pageWeight > PageMetricsAnalyzer.configuration.weightWarning }
            ,issue("Page Weight: Abnormally Heavy Pages", "Warning", "High") { $0.isSEOPage && PageMetricsAnalyzer.isAbnormallyHeavy($0, medians: pageWeightMedians) }
            ,issue("AI: Heavy for AI Parsing", "Warning", "Medium") { $0.isSEOPage && $0.aiParsability == "Heavy for AI Parsing" }
            ,issue("AI: Very Heavy for AI Parsing", "Issue", "High") { $0.isSEOPage && $0.aiParsability == "Very Heavy for AI Parsing" }
            ,issue("AI: Excessive DOM Size", "Warning", "Medium") { $0.isSEOPage && $0.domNodeCount >= PageMetricsAnalyzer.configuration.domNodeWarning }
            ,issue("AI: Low Content-to-HTML Ratio", "Warning", "Medium") { $0.isSEOPage && $0.htmlSize >= PageMetricsAnalyzer.configuration.aiHTMLWarning && $0.contentToHTMLRatio > 0 && $0.contentToHTMLRatio < PageMetricsAnalyzer.configuration.contentRatioWarning }
            ,issue("AI: Excessive Inline Data", "Warning", "Medium") { $0.isSEOPage && ($0.inlineJavaScriptSize + $0.inlineCSSSize + $0.embeddedJSONSize) >= PageMetricsAnalyzer.configuration.inlineDataWarning }
        ].compactMap { $0 }
        if let homepage = records.first(where: { $0.isSEOPage && $0.depth == 0 }) {
            if homepage.pageWeight > PageMetricsAnalyzer.configuration.weightWarning { result.append(Issue(name: "Homepage: Heavy Page", type: "Warning", priority: homepage.pageWeight > PageMetricsAnalyzer.configuration.weightHigh ? "High" : "Medium", urlIDs: [homepage.id])) }
            if homepage.imageResourceSize > homepage.htmlSize && homepage.imageResourceSize > PageMetricsAnalyzer.configuration.weightWarning { result.append(Issue(name: "Homepage: Heavy Images", type: "Warning", priority: "Medium", urlIDs: [homepage.id])) }
            if homepage.javascriptResourceSize > PageMetricsAnalyzer.configuration.weightWarning { result.append(Issue(name: "Homepage: Heavy JavaScript", type: "Warning", priority: "Medium", urlIDs: [homepage.id])) }
            if homepage.aiParsability != "AI Friendly" { result.append(Issue(name: "Homepage: (homepage.aiParsability)", type: "Warning", priority: homepage.aiParsability.hasPrefix("Very") ? "High" : "Medium", urlIDs: [homepage.id])) }
        }
        if let report = gscSiteReport {
            let priorities: [String: (type: String, priority: String)] = [
                "404": ("Issue", "High"), "soft404": ("Issue", "High"), "5xx": ("Issue", "High"), "redirect-error": ("Issue", "High"),
                "redirect": ("Warning", "Medium"), "crawled-not-indexed": ("Warning", "Medium"), "discovered-not-indexed": ("Warning", "Medium"),
                "canonical": ("Warning", "Medium"), "robots": ("Warning", "Medium"), "noindex": ("Warning", "Low"), "not-indexed": ("Warning", "Medium")
            ]
            for metric in report.metrics where metric.count > 0 && metric.key != "indexed" {
                let kind = priorities[metric.key] ?? ("Warning", "Medium")
                let normalized = Set(metric.examples.map { $0.trimmingCharacters(in: CharacterSet(charactersIn: "/")) })
                let ids = Set(records.filter { normalized.contains($0.url.absoluteString.trimmingCharacters(in: CharacterSet(charactersIn: "/"))) }.map(\.id))
                result.append(Issue(name: "GSC: \(metric.label)", type: kind.type, priority: kind.priority, urlIDs: ids, externalURLs: metric.examples, reportedCount: metric.count))
            }
        }
        if let report = gscCoreWebVitalsReport {
            for metric in report.metrics where metric.count > 0 {
                let normalized = Set(metric.examples.map { $0.trimmingCharacters(in: CharacterSet(charactersIn: "/")) })
                let ids = Set(records.filter { normalized.contains($0.url.absoluteString.trimmingCharacters(in: CharacterSet(charactersIn: "/"))) }.map(\.id))
                let priority = metric.group.lowercased().contains("poor") ? "High" : "Medium"
                result.append(Issue(name: "GSC Core Web Vitals · \(metric.group): \(metric.label)", type: "Warning", priority: priority, urlIDs: ids, externalURLs: metric.examples, reportedCount: metric.count))
            }
        }
        return result
    }
}

enum OverviewBuilder {
    static func make(_ records: [CrawlRecord], gscSiteReport: GSCSiteReport? = nil, gscCoreWebVitalsReport: GSCCoreWebVitalsReport? = nil) -> [OverviewItem] {
        let html = records.filter(\.isSEOPage)
        // Page-content recommendations only apply to indexable documents. A
        // noindex page remains visible under Directives, but it should not be
        // told to add/shorten a title, description, heading or canonical.
        let indexableHTML = html.filter { $0.indexability == "Indexable" }
        let canonicalPages = indexableHTML.filter(\.isCanonicalEligible)
        let schemaPages = indexableHTML.filter(\.isSchemaEligible)
        // XML sitemap page coverage is meaningful only for crawlable HTML pages.
        // Images and other binary resources are audited in the Images section.
        let sitemapPages = records.filter(\.isSEOPage)
        let robotsBlocked = records.filter { !$0.robotsBlockedBy.isEmpty }
        let gscEligible = records.filter { $0.kind == .internalURL && $0.isGSCEligible }
        let gscInspected = gscEligible.filter { $0.searchConsoleIndexStatus != "Not checked" && $0.searchConsoleIndexStatus != "Unavailable" }
        let internalURLs = records.filter { $0.kind == .internalURL }
        let externalURLs = records.filter { $0.kind == .external }
        func ids(_ source: [CrawlRecord], _ test: (CrawlRecord) -> Bool = { _ in true }) -> Set<UUID> { Set(source.filter(test).map(\.id)) }
        func row(_ name: String, _ source: [CrawlRecord], _ test: @escaping (CrawlRecord) -> Bool = { _ in true }) -> OverviewItem { OverviewItem(name: name, urlIDs: ids(source, test), denominator: source.count) }
        func section(_ name: String, _ source: [CrawlRecord], _ children: [OverviewItem]) -> OverviewItem { OverviewItem(name: name, urlIDs: ids(source), denominator: source.count, children: children) }
        func duplicates(_ key: (CrawlRecord) -> String) -> Set<UUID> {
            let groups = Dictionary(grouping: indexableHTML.filter { !key($0).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }, by: key)
            return Set(groups.values.filter { $0.count > 1 }.flatMap { $0.map(\.id) })
        }
        func duplicateRow(_ name: String, _ key: @escaping (CrawlRecord) -> String) -> OverviewItem { OverviewItem(name: name, urlIDs: duplicates(key), denominator: indexableHTML.count) }
        let robotsRows: [OverviewItem] = [row("Blocked URLs", robotsBlocked)] + Dictionary(grouping: robotsBlocked, by: \.robotsBlockedBy)
            .map { rule, urls in OverviewItem(name: rule, urlIDs: Set(urls.map(\.id)), denominator: records.count) }
            .sorted { $0.name < $1.name }
        let statusRows: ([CrawlRecord], String) -> [OverviewItem] = { source, prefix in
            [row("\(prefix)All", source), row("\(prefix)Blocked by Robots.txt", source, { _ in false }), row("\(prefix)Blocked Resource", source, { _ in false }), row("\(prefix)No Response", source, { !$0.error.isEmpty }), row("\(prefix)Success (2xx)", source, { ($0.statusCode ?? 0) / 100 == 2 && !$0.hasRedirect }), row("\(prefix)Redirection (3xx)", source, { $0.hasRedirect || ($0.statusCode ?? 0) / 100 == 3 }), row("\(prefix)Redirection (JavaScript)", source, { _ in false }), row("\(prefix)Redirection (Meta Refresh)", source, { _ in false }), row("\(prefix)Redirect Chain", source, { $0.redirectChain.count > 2 }), row("\(prefix)Redirect Loop", source, { _ in false }), row("\(prefix)Client Error (4xx)", source, { ($0.statusCode ?? 0) / 100 == 4 }), row("\(prefix)Server Error (5xx)", source, { ($0.statusCode ?? 0) / 100 == 5 })]
        }
        var result: [OverviewItem] = [
            section("Summary", records, [row("Internal", internalURLs), row("External", externalURLs)]),
            section("Crawl Data", records, [row("Internal", internalURLs), row("External", externalURLs)]),
            section("Security", records, [row("All", records), row("HTTP URLs", records, { $0.url.scheme == "http" }), row("HTTPS URLs", records, { $0.url.scheme == "https" }), row("Mixed Content", html, { $0.url.scheme == "https" && $0.images.contains { $0.url.hasPrefix("http:") } }), row("Form URL Insecure", html, { _ in false }), row("Form on HTTP URL", html, { _ in false }), row("Unsafe Cross-Origin Links", html, { _ in false }), row("Protocol-Relative Resource Links", html, { _ in false }), row("Missing HSTS Header", records, { $0.url.scheme == "https" && $0.securityHeaders["Strict-Transport-Security"] == nil }), row("Missing Content-Security-Policy Header", records, { $0.url.scheme == "https" && $0.securityHeaders["Content-Security-Policy"] == nil }), row("Missing X-Content-Type-Options Header", records, { $0.url.scheme == "https" && $0.securityHeaders["X-Content-Type-Options"] == nil }), row("Missing X-Frame-Options Header", records, { $0.url.scheme == "https" && $0.securityHeaders["X-Frame-Options"] == nil }), row("Missing Secure Referrer-Policy Header", records, { $0.url.scheme == "https" && $0.securityHeaders["Referrer-Policy"] == nil }), row("Bad Content Type", records, { $0.isHTML && !$0.contentType.lowercased().contains("text/html") })]),
            section("Response Codes", records, [section("Internal & External", records, statusRows(records, "")), section("Internal", internalURLs, statusRows(internalURLs, "Internal ")), section("External", externalURLs, statusRows(externalURLs, "External "))]),
            section("URL", internalURLs, [row("All", internalURLs), row("Non ASCII Characters", internalURLs, { $0.url.absoluteString.unicodeScalars.contains { $0.value > 127 } }), row("Underscores", internalURLs, { $0.url.path.contains("_") }), row("Uppercase", internalURLs, { $0.url.path.rangeOfCharacter(from: .uppercaseLetters) != nil }), row("Multiple Slashes", internalURLs, { $0.url.path.contains("//") }), row("Repetitive Path", internalURLs, { $0.url.pathComponents.dropFirst().containsDuplicates }), row("Contains Space", internalURLs, { $0.url.absoluteString.contains(" ") || $0.url.absoluteString.contains("%20") }), row("Internal Search", internalURLs, { $0.url.path.lowercased().contains("search") || $0.url.query?.lowercased().contains("search") == true }), row("Parameters", internalURLs, { $0.url.query != nil }), row("Broken Bookmark", internalURLs, { _ in false }), row("GA Tracking Parameters", internalURLs, { $0.url.query?.lowercased().contains("utm_") == true || $0.url.query?.lowercased().contains("gclid") == true }), row("Over 115 Characters", internalURLs, { $0.url.absoluteString.count > 115 })]),
            section("Page Titles", indexableHTML, [row("All", indexableHTML), row("Missing", indexableHTML, { $0.title.isEmpty }), duplicateRow("Duplicate", { $0.title }), row("Over 60 Characters", indexableHTML, { $0.title.count > 60 }), row("Below 30 Characters", indexableHTML, { !$0.title.isEmpty && $0.title.count < 30 }), row("Over 561 Pixels", indexableHTML, { $0.title.count > 60 }), row("Below 200 Pixels", indexableHTML, { !$0.title.isEmpty && $0.title.count < 20 }), row("Same as H1", indexableHTML, { !$0.title.isEmpty && $0.title == $0.h1 }), row("Multiple", indexableHTML, { _ in false }), row("Outside <head>", indexableHTML, { _ in false })]),
            section("Meta Description", indexableHTML, [row("All", indexableHTML), row("Missing", indexableHTML, { $0.metaDescription.isEmpty }), duplicateRow("Duplicate", { $0.metaDescription }), row("Over 155 Characters", indexableHTML, { $0.metaDescription.count > 155 }), row("Below 70 Characters", indexableHTML, { !$0.metaDescription.isEmpty && $0.metaDescription.count < 70 }), row("Over 985 Pixels", indexableHTML, { $0.metaDescription.count > 155 }), row("Below 400 Pixels", indexableHTML, { !$0.metaDescription.isEmpty && $0.metaDescription.count < 70 }), row("Multiple", indexableHTML, { _ in false }), row("Outside <head>", indexableHTML, { _ in false })]),
            section("Meta Keywords", indexableHTML, [row("All", indexableHTML), row("Missing", indexableHTML, { $0.metaKeywords.isEmpty }), duplicateRow("Duplicate", { $0.metaKeywords }), row("Multiple", indexableHTML, { _ in false })]),
            section("H1", indexableHTML, [row("All", indexableHTML), row("Missing", indexableHTML, { $0.h1Count == 0 }), duplicateRow("Duplicate", { $0.h1 }), row("Over 70 Characters", indexableHTML, { $0.h1.count > 70 }), row("Multiple", indexableHTML, { $0.h1Count > 1 }), row("Alt Text in H1", indexableHTML, { _ in false }), row("Non-Sequential", indexableHTML, { _ in false })]),
            section("H2", indexableHTML, [row("All", indexableHTML), row("Missing", indexableHTML, { $0.h2.isEmpty }), duplicateRow("Duplicate", { $0.h2 }), row("Over 70 Characters", indexableHTML, { $0.h2.count > 70 }), row("Multiple", indexableHTML, { $0.h2Count > 1 }), row("Non-Sequential", indexableHTML, { _ in false })]),
            section("Content", indexableHTML, [row("All", indexableHTML), row("Exact Duplicates", indexableHTML, { _ in false }), row("Near Duplicates", indexableHTML, { _ in false }), row("Low Content Pages", indexableHTML, { $0.wordCount > 0 && $0.wordCount < 200 }), row("Soft 404 Pages", indexableHTML, { _ in false }), row("Spelling Errors", indexableHTML, { _ in false }), row("Grammar Errors", indexableHTML, { _ in false }), row("Readability Difficult", indexableHTML, { _ in false }), row("Readability Very Difficult", indexableHTML, { _ in false }), row("Lorem Ipsum Placeholder", indexableHTML, { _ in false })]),
            section("Images", records, [row("Images on HTML Pages", html, { !$0.images.isEmpty }), row("Image Resources Crawled", records, { $0.isImageResource }), row("Broken Image Resources", records, { $0.isImageCandidate && (!$0.error.isEmpty || ($0.statusCode ?? 0) >= 400) }), row("Heavy Image Resources", records, { $0.isImageResource && ($0.statusCode ?? 0) / 100 == 2 && $0.size > 100_000 }), row("Over 100 KB", html, { $0.images.contains { $0.size > 100_000 } }), row("Missing Alt Text", html, { $0.images.contains { $0.alt.trimmingCharacters(in: .whitespaces).isEmpty } }), row("Missing Alt Attribute", html, { _ in false }), row("Alt Text Over 100 Characters", html, { $0.images.contains { $0.alt.count > 100 } }), row("Background Images", html, { _ in false }), row("Incorrectly Sized Images", html, { _ in false }), row("Missing Size Attributes", html, { $0.images.contains { $0.width.isEmpty || $0.height.isEmpty } })]),
            section("Canonicals", canonicalPages, [row("All", canonicalPages), row("Contains Canonical", canonicalPages, { !$0.canonical.isEmpty }), row("Self Referencing", canonicalPages, { !$0.canonical.isEmpty && $0.canonical.trimmingCharacters(in: CharacterSet(charactersIn: "/")) == $0.url.absoluteString.trimmingCharacters(in: CharacterSet(charactersIn: "/")) }), row("Canonicalised", canonicalPages, { !$0.canonical.isEmpty && $0.canonical.trimmingCharacters(in: CharacterSet(charactersIn: "/")) != $0.url.absoluteString.trimmingCharacters(in: CharacterSet(charactersIn: "/")) }), row("Missing", canonicalPages, { $0.canonical.isEmpty }), row("Multiple", canonicalPages, { $0.canonicalCount > 1 }), row("Multiple Conflicting", canonicalPages, { $0.canonicalCount > 1 }), row("Non-Indexable Canonical", canonicalPages, { _ in false }), row("Canonical Is Relative", canonicalPages, { !$0.canonicalRaw.isEmpty && !$0.canonicalRaw.contains("://") })]),
            section("Pagination", html, [row("All", html), row("Contains Pagination", html, { _ in false }), row("First Page", html, { _ in false }), row("Paginated 2+ Pages", html, { _ in false }), row("Pagination URL Not in Anchor Tag", html, { _ in false }), row("Non-200 Pagination URLs", html, { _ in false }), row("Unlinked Pagination URLs", html, { _ in false }), row("Non-Indexable", html, { _ in false }), row("Multiple Pagination URLs", html, { _ in false }), row("Pagination Loop", html, { _ in false }), row("Sequence Error", html, { _ in false })]),
            section("robots.txt", robotsBlocked, robotsRows),
            section("Google Search Console · URL inspection", gscInspected, [row("GSC · checked", gscInspected), row("GSC · unavailable / property access", gscEligible, { $0.searchConsoleIndexStatus == "Unavailable" }), row("GSC · indexed", gscInspected, { $0.searchConsoleIndexStatus == "Indexed" }), row("GSC · excluded", gscInspected, { $0.searchConsoleIndexStatus == "Not indexed" }), row("GSC · robots blocked", gscInspected, { $0.searchConsoleRobotsStatus == "Blocked" }), row("GSC · noindex", gscInspected, { $0.searchConsoleNoindexStatus.hasPrefix("noindex") }), row("GSC · mobile issues", gscInspected, { !$0.searchConsoleMobileIssues.isEmpty }), row("GSC · rich result errors", gscInspected, { !$0.searchConsoleRichResultErrors.isEmpty }), row("GSC · Top 10 URLs", gscInspected, { $0.searchConsolePerformanceChecked && $0.searchConsoleQueriesTop10 > 0 }), row("GSC · URLs with clicks", gscInspected, { $0.searchConsolePerformanceChecked && $0.searchConsoleClicks7d > 0 }), row("GSC · URLs without clicks", gscInspected, { $0.searchConsolePerformanceChecked && $0.searchConsoleClicks7d == 0 }), row("GSC · past Top 20", gscInspected, { $0.searchConsolePerformanceChecked && $0.searchConsoleQueryCount > 0 && $0.searchConsoleQueriesTop20 == 0 }), row("GSC · no queries", gscInspected, { $0.searchConsolePerformanceChecked && $0.searchConsoleQueryCount == 0 })]),
            section("Directives", html, [row("All", html), row("Index", html, { !$0.robots.lowercased().contains("noindex") }), row("Noindex", html, { $0.robots.lowercased().contains("noindex") }), row("Follow", html, { !$0.robots.lowercased().contains("nofollow") }), row("Nofollow", html, { $0.robots.lowercased().contains("nofollow") }), row("None", html, { $0.robots.lowercased().contains("none") }), row("NoArchive", html, { $0.robots.lowercased().contains("noarchive") }), row("NoSnippet", html, { $0.robots.lowercased().contains("nosnippet") }), row("Max-Snippet", html, { $0.robots.lowercased().contains("max-snippet") }), row("Max-Image-Preview", html, { $0.robots.lowercased().contains("max-image-preview") }), row("Max-Video-Preview", html, { $0.robots.lowercased().contains("max-video-preview") }), row("NoODP", html, { $0.robots.lowercased().contains("noodp") }), row("NoYDIR", html, { $0.robots.lowercased().contains("noydir") }), row("NoImageIndex", html, { $0.robots.lowercased().contains("noimageindex") }), row("NoTranslate", html, { $0.robots.lowercased().contains("notranslate") }), row("Unavailable_After", html, { $0.robots.lowercased().contains("unavailable_after") }), row("Refresh", html, { _ in false })]),
            section("Hreflang", html, [row("All", html), row("Contains hreflang", html, { !$0.hreflang.isEmpty }), row("Non-200 hreflang URLs", html, { _ in false }), row("Unlinked hreflang URLs", html, { _ in false }), row("Missing Return Links", html, { _ in false }), row("Inconsistent Language & Region Codes", html, { _ in false }), row("Non-Canonical Return Links", html, { _ in false }), row("Noindex Return Links", html, { _ in false }), row("Incorrect Language & Region Codes", html, { record in record.hreflangCodes.contains { code in code.lowercased() != "x-default" && code.range(of: "^[a-z]{2,3}(-[A-Z]{2}|-[0-9]{3})?$", options: .regularExpression) == nil } }), row("Multiple Entries", html, { Set($0.hreflangCodes.map { $0.lowercased() }).count < $0.hreflangCodes.count }), row("Missing Self Reference", html, { record in !record.hreflangTargets.isEmpty && !record.hreflangTargets.contains { $0.url.trimmingCharacters(in: CharacterSet(charactersIn: "/")) == record.url.absoluteString.trimmingCharacters(in: CharacterSet(charactersIn: "/")) } }), row("Not Using Canonical", html, { _ in false }), row("Missing X-Default", html, { !$0.hreflangCodes.isEmpty && !$0.hasXDefault }), row("Missing", html, { _ in false }), row("Outside <head>", html, { _ in false })]),
            section("JavaScript", html, [row("All", html), row("Pages with Blocked Resources", html, { _ in false }), row("Contains JavaScript Links", html, { _ in false }), row("Contains JavaScript Content", html, { _ in false }), row("Noindex Only in Original HTML", html, { _ in false }), row("Nofollow Only in Original HTML", html, { _ in false }), row("Canonical Only in Rendered HTML", html, { _ in false }), row("Canonical Mismatch", html, { _ in false }), row("Page Title Only in Rendered HTML", html, { _ in false }), row("Page Title Updated by JavaScript", html, { _ in false }), row("Meta Description Only in Rendered HTML", html, { _ in false })]),
            section("Links", html, [row("All", html), row("Pages With High Crawl Depth", html, { $0.depth > 5 }), row("Pages Without Internal Outlinks", html, { $0.internalLinks == 0 }), row("Internal Nofollow Outlinks", html, { _ in false }), row("Internal Outlinks With No Anchor Text", html, { _ in false }), row("Non-Descriptive Anchor Text In Internal Outlinks", html, { _ in false }), row("Pages With High External Outlinks", html, { $0.externalLinks > 100 }), row("Pages With High Internal Outlinks", html, { $0.internalLinks > 100 }), row("Follow & Nofollow Internal Inlinks", html, { _ in false }), row("Internal Nofollow Inlinks Only", html, { _ in false }), row("Outlinks To Localhost", html, { _ in false }), row("Pages Without Internal Inlinks", html, { $0.isSEOPage && $0.depth > 0 && $0.inlinks == 0 })]),
            section("Sitemaps", sitemapPages, [row("All", sitemapPages), row("URLs in Sitemap", sitemapPages, { $0.inSitemap }), row("URLs not in Sitemap", sitemapPages, { !$0.inSitemap }), row("Orphan URLs", sitemapPages, { $0.inlinks == 0 && $0.depth > 0 }), row("Non-Indexable URLs in Sitemap", sitemapPages, { $0.inSitemap && $0.indexability == "Noindex" }), row("Technical URLs in Sitemap", sitemapPages, { $0.inSitemap && ($0.url.query != nil || $0.url.path.contains("wp-") || $0.url.path.contains("index.")) }), row("URLs in Multiple Sitemaps", sitemapPages, { _ in false }), row("XML Sitemap with over 50K URLs", sitemapPages, { _ in false }), row("XML Sitemap over 50MB", sitemapPages, { _ in false })]),
            section("Validation", html, [row("All", html), row("Invalid HTML Elements in Head", html, { _ in false }), row("<body> Element Preceding <html>", html, { _ in false }), row("<head> Not First In <html> Element", html, { _ in false }), row("Missing <head> Tag", html, { _ in false }), row("Multiple <head> Tags", html, { _ in false }), row("Missing <body> Tag", html, { _ in false }), row("Multiple <body> Tags", html, { _ in false }), row("HTML Document Over 15MB", html, { $0.size > 15_000_000 })]),
            section("WordPress", html, [row("All WordPress pages", html, { $0.cmsName == "WordPress" }), row("Technical head links", html, { !$0.wordPressHeadFindings.isEmpty }), row("RSS / comments feed links", html, { $0.wordPressHeadFindings.contains("RSS/Comments feed discovery links") }), row("RSD / XML-RPC link", html, { $0.wordPressHeadFindings.contains("RSD/XML-RPC discovery link") }), row("Shortlink", html, { $0.wordPressHeadFindings.contains("WordPress shortlink") }), row("WordPress version generator", html, { $0.wordPressHeadFindings.contains("WordPress version generator meta") })]),
            section("Link Metrics", records, [row("All", records)])
            ,section("Page Types", html, ["Homepage", "Service", "Product", "Category", "Article", "News", "Case Study", "Location", "Reviews", "Contact", "Doctor", "AI Bust Page", "Search", "Listing", "System", "Unknown"].map { type in row(type, html, { $0.pageType == type }) })
            ,section("Structured Data (JSON-LD)", schemaPages, [row("All pages", schemaPages), row("Pages with JSON-LD", schemaPages, { !$0.schemaTypes.isEmpty }), row("Pages without JSON-LD", schemaPages, { $0.schemaTypes.isEmpty }), row("Organization / Business", schemaPages, { $0.schemaTypes.contains { ["Organization", "LocalBusiness", "Corporation", "ProfessionalService"].contains($0) } }), row("BreadcrumbList", schemaPages, { $0.schemaTypes.contains("BreadcrumbList") }), row("Product", schemaPages, { $0.schemaTypes.contains("Product") }), row("Review", schemaPages, { $0.schemaTypes.contains("Review") || $0.schemaTypes.contains("AggregateRating") }), row("Article / BlogPosting", schemaPages, { $0.schemaTypes.contains("Article") || $0.schemaTypes.contains("BlogPosting") || $0.schemaTypes.contains("NewsArticle") }), row("FAQPage", schemaPages, { $0.schemaTypes.contains("FAQPage") }), row("WebSite", schemaPages, { $0.schemaTypes.contains("WebSite") }), row("WebPage", schemaPages, { $0.schemaTypes.contains("WebPage") }), row("Service", schemaPages, { $0.schemaTypes.contains("Service") }), row("Person", schemaPages, { $0.schemaTypes.contains("Person") }), row("VideoObject", schemaPages, { $0.schemaTypes.contains("VideoObject") }), row("Event", schemaPages, { $0.schemaTypes.contains("Event") }), row("JobPosting", schemaPages, { $0.schemaTypes.contains("JobPosting") })])
            ,section("Schema Intelligence", schemaPages, [row("Primary schema mismatch", schemaPages, { $0.schemaCompatibility == "Mismatch" }), row("Incomplete primary schema", schemaPages, { !$0.primarySchemaType.isEmpty && $0.schemaCompleteness < 0.75 })])
        ]
        if let site = gscSiteReport {
            let matching: (GSCSiteReport.Metric) -> Set<UUID> = { metric in
                Set(records.filter { record in metric.examples.contains { $0.trimmingCharacters(in: CharacterSet(charactersIn: "/")) == record.url.absoluteString.trimmingCharacters(in: CharacterSet(charactersIn: "/")) } }.map(\.id))
            }
            let rows = site.metrics.map { metric in OverviewItem(name: metric.label, urlIDs: matching(metric), denominator: max(1, site.total), displayCount: metric.count) }
            result.insert(OverviewItem(name: "Google Search Console · Page Indexing", urlIDs: Set(rows.flatMap(\.urlIDs)), denominator: max(1, site.total), children: rows, displayCount: site.total), at: min(13, result.count))
        }
        if let core = gscCoreWebVitalsReport {
            let matching: (GSCCoreWebVitalsReport.Metric) -> Set<UUID> = { metric in
                Set(records.filter { record in metric.examples.contains { $0.trimmingCharacters(in: CharacterSet(charactersIn: "/")) == record.url.absoluteString.trimmingCharacters(in: CharacterSet(charactersIn: "/")) } }.map(\.id))
            }
            let groups = ["Poor", "Needs improvement"].compactMap { group -> OverviewItem? in
                let metrics = core.metrics.filter { $0.group == group }
                guard !metrics.isEmpty else { return nil }
                let rows = metrics.map { OverviewItem(name: $0.label, urlIDs: matching($0), denominator: max(1, core.total), displayCount: $0.count) }
                return OverviewItem(name: group, urlIDs: Set(rows.flatMap(\.urlIDs)), denominator: max(1, core.total), children: rows, displayCount: metrics.reduce(0) { $0 + $1.count })
            }
            result.append(OverviewItem(name: "Google Search Console · Mobile Core Web Vitals", urlIDs: Set(groups.flatMap(\.urlIDs)), denominator: max(1, core.total), children: groups, displayCount: core.total))
        }
        let metricPages = html.filter { $0.pageWeight > 0 }
        if !metricPages.isEmpty {
            let medians = PageMetricsAnalyzer.typeMedians(metricPages)
            let homepage = metricPages.first(where: { $0.depth == 0 })
            let heavy = metricPages.filter { $0.pageWeight > PageMetricsAnalyzer.configuration.weightWarning }
            let abnormal = metricPages.filter { PageMetricsAnalyzer.isAbnormallyHeavy($0, medians: medians) }
            let pageMetric = { (name: String, value: Int) in OverviewItem(name: name, urlIDs: [], denominator: 1, displayCount: value) }
            let typeRows = medians.sorted { $0.key < $1.key }.map { pageMetric("\($0.key) median (KB)", $0.value / 1_024) }
            var weightRows = [
                pageMetric("Median Page Weight (KB)", PageMetricsAnalyzer.median(metricPages.map(\.pageWeight)) / 1_024),
                OverviewItem(name: "Heavy Pages", urlIDs: Set(heavy.map(\.id)), denominator: metricPages.count),
                OverviewItem(name: "Abnormally Heavy Pages", urlIDs: Set(abnormal.map(\.id)), denominator: metricPages.count)
            ]
            if let homepage {
                weightRows.append(contentsOf: [
                    pageMetric("Homepage weight (KB)", homepage.pageWeight / 1_024),
                    pageMetric("Homepage HTML (KB)", homepage.htmlSize / 1_024),
                    pageMetric("Homepage images (KB)", homepage.imageResourceSize / 1_024),
                    pageMetric("Homepage requests", homepage.resourceRequestCount)
                ])
            }
            result.append(OverviewItem(name: "Page Weight", urlIDs: Set(metricPages.map(\.id)), denominator: metricPages.count, children: weightRows + typeRows))
            let heavyAI = metricPages.filter { $0.aiParsability == "Heavy for AI Parsing" }
            let veryHeavyAI = metricPages.filter { $0.aiParsability == "Very Heavy for AI Parsing" }
            let largeDOM = metricPages.filter { $0.domNodeCount >= PageMetricsAnalyzer.configuration.domNodeWarning }
            let lowRatio = metricPages.filter { $0.htmlSize >= PageMetricsAnalyzer.configuration.aiHTMLWarning && $0.contentToHTMLRatio > 0 && $0.contentToHTMLRatio < PageMetricsAnalyzer.configuration.contentRatioWarning }
            let inlineData = metricPages.filter { $0.inlineJavaScriptSize + $0.inlineCSSSize + $0.embeddedJSONSize >= PageMetricsAnalyzer.configuration.inlineDataWarning }
            result.append(OverviewItem(name: "AI Parsability", urlIDs: Set(metricPages.map(\.id)), denominator: metricPages.count, children: [
                OverviewItem(name: "AI Friendly", urlIDs: Set(metricPages.filter { $0.aiParsability == "AI Friendly" }.map(\.id)), denominator: metricPages.count),
                OverviewItem(name: "Heavy for AI Parsing", urlIDs: Set(heavyAI.map(\.id)), denominator: metricPages.count),
                OverviewItem(name: "Very Heavy for AI Parsing", urlIDs: Set(veryHeavyAI.map(\.id)), denominator: metricPages.count),
                OverviewItem(name: "Large DOM", urlIDs: Set(largeDOM.map(\.id)), denominator: metricPages.count),
                OverviewItem(name: "Low Content / HTML Ratio", urlIDs: Set(lowRatio.map(\.id)), denominator: metricPages.count),
                OverviewItem(name: "Large Inline Data", urlIDs: Set(inlineData.map(\.id)), denominator: metricPages.count),
                pageMetric("Median HTML (KB)", PageMetricsAnalyzer.median(metricPages.map(\.htmlSize)) / 1_024),
                pageMetric("Median HTML tokens", PageMetricsAnalyzer.median(metricPages.map(\.estimatedHTMLTokens))),
                pageMetric("Median DOM nodes", PageMetricsAnalyzer.median(metricPages.map(\.domNodeCount)))
            ]))
        }
        return result
    }
}

enum BacklinkOverviewBuilder {
    static func make(_ records: [CrawlRecord], report: BacklinkReport?) -> [OverviewItem] {
        guard let report else { return [] }
        let eligible = records.filter { $0.isGSCEligible }
        let linked = eligible.filter { $0.backlinkChecked && $0.backlinks > 0 }
        let unlinked = eligible.filter { $0.backlinkChecked && $0.backlinks == 0 }
        let lostEquity = records.filter { $0.backlinks > 0 && (($0.statusCode ?? 0) / 100 >= 3 || $0.indexability == "Noindex" || (!$0.canonical.isEmpty && DataForSEOBacklinks.urlKey($0.canonical) != DataForSEOBacklinks.urlKey($0.url.absoluteString))) }
        let highSpam = eligible.filter { $0.backlinkChecked && $0.backlinkSpamScore >= 50 }
        func metric(_ name: String, _ value: Int) -> OverviewItem { OverviewItem(name: name, urlIDs: [], denominator: 1, displayCount: value) }
        func urls(_ name: String, _ values: [CrawlRecord]) -> OverviewItem { OverviewItem(name: name, urlIDs: Set(values.map(\.id)), denominator: eligible.count) }
        return [OverviewItem(name: "Backlinks", urlIDs: Set(eligible.map(\.id)), denominator: max(eligible.count, 1), children: [
            metric("Domain Rank", report.domain.rank),
            metric("Backlinks", report.domain.backlinks),
            metric("Referring Domains", report.domain.referringDomains),
            metric("Referring Main Domains", report.domain.referringMainDomains),
            metric("Referring Pages", report.domain.referringPages),
            metric("Referring IPs", report.domain.referringIPs),
            metric("Referring Subnets", report.domain.referringSubnets),
            metric("Dofollow Backlinks", report.domain.dofollowBacklinks),
            metric("Nofollow Backlinks", report.domain.nofollowBacklinks),
            metric("Broken Backlinks", report.domain.brokenBacklinks),
            metric("Backlink Spam Score", report.domain.spamScore),
            urls("Pages receiving backlinks", linked),
            urls("Indexable pages without backlinks", unlinked),
            urls("Lost link equity", lostEquity),
            urls("High backlink spam score", highSpam)
        ])]
    }
}

private extension Collection where Element: Hashable {
    var containsDuplicates: Bool { Set(self).count != count }
}

enum CSV {
    static func esc(_ value: String) -> String { "\"" + value.replacingOccurrences(of: "\"", with: "\"\"") + "\"" }
    static func urls(_ records: [CrawlRecord]) -> [String] { ["URL,Status Code,Status,Content Type,Indexability,Transport,Primary Status,Chrome CDP Status,Chrome Verification,GSC Indexed,GSC Fetch Error,GSC Indexing Issue,GSC Google Canonical,GSC Last Crawl,GSC Robots,GSC Noindex,GSC Sitemap,GSC Rich Results Errors,GSC Mobile Usability Issues,Title,Title Length,Meta Description,Description Length,H1,H2,Canonical,Word Count,Crawl Depth,Inlinks,Outlinks,Response Time,Decoded Response Bytes,Transferred Bytes,Content Encoding,Page Weight,Decoded HTML Size,Images Size,JS Size,CSS Size,Requests,AI Parsability,HTML Tokens,DOM Nodes"] + records.map { [esc($0.url.absoluteString), $0.statusText, esc($0.error), esc($0.contentType), esc($0.indexability), esc($0.transportUsed), $0.originalStatus.map(String.init) ?? "", $0.cdpStatus.map(String.init) ?? "", esc($0.verificationResult), esc($0.searchConsoleIndexStatus), esc($0.searchConsoleFetchStatus), esc($0.searchConsoleCoverage), esc($0.searchConsoleGoogleCanonical), esc($0.searchConsoleLastCrawl), esc($0.searchConsoleRobotsStatus), esc($0.searchConsoleNoindexStatus), esc($0.searchConsoleSitemaps.joined(separator: " | ")), esc($0.searchConsoleRichResultErrors.joined(separator: " | ")), esc($0.searchConsoleMobileIssues.joined(separator: " | ")), esc($0.title), "\($0.title.count)", esc($0.metaDescription), "\($0.metaDescription.count)", esc($0.h1), esc($0.h2), esc($0.canonical), "\($0.wordCount)", "\($0.depth)", "\($0.inlinks)", "\($0.internalLinks + $0.externalLinks)", String(format: "%.3f", $0.responseTime), "\($0.size)", "\($0.transferredSize)", esc($0.contentEncoding), "\($0.pageWeight)", "\($0.htmlSize)", "\($0.imageResourceSize)", "\($0.javascriptResourceSize)", "\($0.cssResourceSize)", "\($0.resourceRequestCount)", esc($0.aiParsability), "\($0.estimatedHTMLTokens)", "\($0.domNodeCount)"].joined(separator: ",") } }
    static func issues(_ issues: [Issue], total: Int) -> [String] { ["Issue Name,Type,Priority,URLs,% of Total"] + issues.map { "\(esc($0.name)),\($0.type),\($0.priority),\($0.count),\(total == 0 ? 0 : Double($0.count) / Double(total) * 100)" } }
    static func overview(_ items: [OverviewItem], total: Int) -> [String] {
        func flatten(_ item: OverviewItem, level: Int) -> [(OverviewItem, Int)] { [(item, level)] + item.children.flatMap { flatten($0, level: level + 1) } }
        return ["Metric,URLs,% of Total"] + items.flatMap { flatten($0, level: 0) }.map { item, level in "\(esc(String(repeating: "  ", count: level) + item.name)),\(item.count),\(item.denominator == 0 ? 0 : Double(item.count) / Double(item.denominator) * 100)" }
    }
    static func images(_ records: [CrawlRecord]) -> [String] { ["Page URL,Image URL"] + records.flatMap { r in r.images.filter { $0.alt.isEmpty }.map { "\(esc(r.url.absoluteString)),\(esc($0.url))" } } }
}
