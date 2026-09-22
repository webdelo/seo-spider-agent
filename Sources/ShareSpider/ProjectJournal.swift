import Foundation

enum ProjectKind: String, CaseIterable, Codable, Identifiable { case ongoing = "Ongoing monitoring", oneTime = "One-time audit"; var id: String { rawValue } }

struct JournalPageSpeedMetric: Codable, Hashable {
    var strategy = "mobile"; var score: Int?; var lcp = "—"; var cls = "—"; var error = ""
}

struct JournalSearchConsoleSummary: Codable, Hashable {
    var checkedURLs = 0
    var indexedURLs = 0
    var nonIndexedCanonicalURLs = 0
    var notFoundURLs = 0
    var redirectURLs = 0
    var serverErrorURLs = 0
    var indexingIssueURLs = 0
    /// Optional for backward compatibility with journal runs saved before the
    /// expanded URL Inspection fields were added.
    var robotsBlockedURLs: Int? = nil
    var noindexURLs: Int? = nil
    var mobileIssueURLs: Int? = nil
    var traffic: JournalSearchConsoleTrafficSummary? = nil
    var siteReport: GSCSiteReport? = nil
    var coreWebVitalsReport: GSCCoreWebVitalsReport? = nil
    /// Set when the API could not inspect any page. Without it an unavailable
    /// property was indistinguishable from a valid inspection with zero issues.
    var unavailableReason: String? = nil
}

struct JournalSearchConsoleTrafficSummary: Codable, Hashable {
    var visibleURLs = 0
    var clickedURLs = 0
    var zeroClickURLs = 0
    var noVisibilityURLs = 0
    var zeroQueryURLs = 0
    var topCountries: [SearchConsoleTrafficCountry] = []
}

struct JournalBacklinkSummary: Codable, Hashable {
    var domainRank = 0
    var backlinks = 0
    var referringDomains = 0
    var brokenBacklinks = 0
    var spamScore = 0
    var enrichedURLs = 0
    var totalURLs = 0
    var apiRequests = 0
    var fetchedAt = Date()
    var error = ""
}

struct ProjectRunChange: Hashable {
    var issue: String
    var previous: Int
    var current: Int
    var percentage: Int
}

struct JournalAIAudit: Codable, Hashable {
    var generatedAt = Date()
    var agent = "Codex"
    var finalSummary = ""
    var analyses: [AICodexAnalyst.CustomAnalysis] = []
}

struct ProjectRun: Identifiable, Codable, Hashable {
    var id = UUID(); var date = Date(); var urlCount = 0; var errors: [String: Int] = [:]
    var pageSpeed: [JournalPageSpeedMetric] = []
    var searchConsole: JournalSearchConsoleSummary? = nil
    var backlinks: JournalBacklinkSummary? = nil
    var aiAudit: JournalAIAudit? = nil
    init(id: UUID = UUID(), date: Date = Date(), urlCount: Int = 0, errors: [String: Int] = [:], pageSpeed: [JournalPageSpeedMetric] = [], searchConsole: JournalSearchConsoleSummary? = nil, backlinks: JournalBacklinkSummary? = nil, aiAudit: JournalAIAudit? = nil) {
        self.id = id; self.date = date; self.urlCount = urlCount; self.errors = errors; self.pageSpeed = pageSpeed; self.searchConsole = searchConsole; self.backlinks = backlinks; self.aiAudit = aiAudit
    }
    enum CodingKeys: String, CodingKey { case id, date, urlCount, errors, pageSpeed, searchConsole, backlinks, aiAudit }
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        date = try container.decodeIfPresent(Date.self, forKey: .date) ?? Date()
        urlCount = try container.decodeIfPresent(Int.self, forKey: .urlCount) ?? 0
        errors = try container.decodeIfPresent([String: Int].self, forKey: .errors) ?? [:]
        pageSpeed = try container.decodeIfPresent([JournalPageSpeedMetric].self, forKey: .pageSpeed) ?? []
        searchConsole = try container.decodeIfPresent(JournalSearchConsoleSummary.self, forKey: .searchConsole)
        backlinks = try container.decodeIfPresent(JournalBacklinkSummary.self, forKey: .backlinks)
        aiAudit = try container.decodeIfPresent(JournalAIAudit.self, forKey: .aiAudit)
    }
}

struct SEOProject: Identifiable, Codable, Hashable {
    var id = UUID(); var name: String; var startURL: String; var kind: ProjectKind; var runs: [ProjectRun] = []
    /// A local, daily time for a regular check. Nil means a one-time/manual project.
    var regularCheckTime: Date? = nil
    var lastRegularRunAt: Date? = nil
    var latestRun: ProjectRun? { runs.max { $0.date < $1.date } }
}

struct ProjectImportSummary: Equatable {
    var added = 0
    var duplicates = 0
    var invalidLines: [String] = []
}

@MainActor
final class ProjectJournalStore: ObservableObject {
    static let shared = ProjectJournalStore()
    /// Automation clients can place a newline-delimited import payload here.
    /// It is consumed once during app startup, through the same parser as the
    /// visible Bulk import field, and therefore never bypasses de-duplication.
    static let pendingImportDefaultsKey = "pending-projects-import-v1"
    @Published private(set) var projects: [SEOProject] = []
    private let file: URL
    init() {
        let directory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!.appendingPathComponent("ShareSpider", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        file = directory.appendingPathComponent("projects-journal.json")
        if let data = try? Data(contentsOf: file), let values = try? JSONDecoder().decode([SEOProject].self, from: data) { projects = values }
        mergeCanonicalDuplicates()
        if let pendingImport = AutomationBridge.consumePendingProjectImport() ?? UserDefaults.standard.string(forKey: Self.pendingImportDefaultsKey), !pendingImport.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            _ = importProjects(from: pendingImport)
            UserDefaults.standard.removeObject(forKey: Self.pendingImportDefaultsKey)
        }
    }
    func add(name: String, startURL: String, kind: ProjectKind) { projects.append(SEOProject(name: name, startURL: startURL, kind: kind)); save() }
    @discardableResult
    func importProjects(from text: String, kind: ProjectKind = .ongoing) -> ProjectImportSummary {
        var summary = ProjectImportSummary()
        for rawLine in text.components(separatedBy: .newlines) {
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !line.isEmpty else { continue }
            guard let entry = parseProjectLine(line) else { summary.invalidLines.append(line); continue }
            let duplicate = projects.contains { canonicalProjectKey($0.startURL) == canonicalProjectKey(entry.url) }
            if duplicate { summary.duplicates += 1; continue }
            projects.append(SEOProject(name: entry.name, startURL: entry.url, kind: kind))
            summary.added += 1
        }
        if summary.added > 0 { save() }
        return summary
    }
    func remove(_ project: SEOProject) { projects.removeAll { $0.id == project.id }; save() }
    func record(startURL: String, records: [CrawlRecord], issues: [Issue]) {
        let key = canonicalProjectKey(startURL)
        if let existing = projects.first(where: { canonicalProjectKey($0.startURL) == key }) {
            record(projectID: existing.id, records: records, issues: issues)
            return
        }
        let name = URL(string: startURL)?.host ?? startURL
        let project = SEOProject(name: name, startURL: startURL, kind: .oneTime)
        projects.append(project)
        record(projectID: project.id, records: records, issues: issues)
    }
    /// A regular project receives its own 10-minute slot. Intervals are checked
    /// on a 24-hour clock, including the midnight boundary.
    @discardableResult
    func setRegularSchedule(projectID: UUID, time: Date?) -> String? {
        guard let index = projects.firstIndex(where: { $0.id == projectID }) else { return "Project was not found." }
        guard let time else { projects[index].regularCheckTime = nil; projects[index].lastRegularRunAt = nil; save(); return nil }
        let normalizedTime = roundedToTenMinutes(time)
        let requested = secondsSinceMidnight(normalizedTime)
        let conflict = projects.enumerated().first { otherIndex, project in
            guard otherIndex != index, let scheduled = project.regularCheckTime else { return false }
            let difference = abs(secondsSinceMidnight(scheduled) - requested)
            return min(difference, 86_400 - difference) < 600
        }
        guard conflict == nil else { return "This 10-minute slot is already reserved by \(conflict!.element.name)." }
        projects[index].regularCheckTime = normalizedTime
        projects[index].lastRegularRunAt = nil
        save()
        return nil
    }
    func dueRegularProjects(at date: Date = Date()) -> [SEOProject] {
        let now = secondsSinceMidnight(date)
        return projects.filter { project in
            guard let time = project.regularCheckTime else { return false }
            let scheduled = secondsSinceMidnight(time)
            let passed = now >= scheduled && now < scheduled + 600
            let alreadyRanToday = project.lastRegularRunAt.map { Calendar.current.isDate($0, inSameDayAs: date) } ?? false
            return passed && !alreadyRanToday
        }
    }
    func markRegularRun(_ projectID: UUID) {
        guard let index = projects.firstIndex(where: { $0.id == projectID }) else { return }
        projects[index].lastRegularRunAt = Date(); save()
    }
    func record(projectID: UUID, records: [CrawlRecord], issues: [Issue]) {
        guard let index = projects.firstIndex(where: { $0.id == projectID }) else { return }
        var counters: [String: Int] = [:]
        for issue in issues where issue.count > 0 { counters[issue.name] = issue.count }
        projects[index].runs.append(ProjectRun(urlCount: records.count, errors: counters))
        // A journal is a trend log, not raw-crawl storage. Keep it compact.
        if projects[index].runs.count > 200 { projects[index].runs.removeFirst(projects[index].runs.count - 200) }
        save()
    }
    /// The crawl can start its asynchronous Google and PageSpeed checks before
    /// the final issue aggregation has completed.  Replace the provisional
    /// counters on the just-created run once that aggregation is ready.
    func updateIssueCounters(startURL: String, issues: [Issue]) {
        guard let projectIndex = index(for: startURL),
              let runIndex = projects[projectIndex].runs.indices.last else { return }
        var counters: [String: Int] = [:]
        for issue in issues where issue.count > 0 { counters[issue.name] = issue.count }
        objectWillChange.send()
        projects[projectIndex].runs[runIndex].errors = counters
        save()
    }
    func updateAIAudit(startURL: String, report: AIAuditReport, agent: AuditAgent) {
        guard let projectIndex = index(for: startURL), let runIndex = projects[projectIndex].runs.indices.last else { return }
        objectWillChange.send()
        projects[projectIndex].runs[runIndex].aiAudit = JournalAIAudit(generatedAt: report.generatedAt, agent: agent.title, finalSummary: report.verifiedSummary.isEmpty ? report.executiveSummary : report.verifiedSummary, analyses: report.customAnalyses)
        save()
    }
    func updatePageSpeed(startURL: String, results: [PageSpeedResult]) {
        guard let projectIndex = index(for: startURL), let runIndex = projects[projectIndex].runs.indices.last else { return }
        // The crawl record is visible before the asynchronous PSI response. Send
        // an explicit change event so an already-open Projects sheet redraws the
        // same date column instead of keeping temporary em dashes on screen.
        objectWillChange.send()
        projects[projectIndex].runs[runIndex].pageSpeed = results.map { JournalPageSpeedMetric(strategy: $0.strategy, score: $0.score, lcp: $0.lcp, cls: $0.cls, error: $0.error) }
        save()
    }
    func updateSearchConsole(startURL: String, records: [CrawlRecord], unavailableReason explicitUnavailableReason: String? = nil) {
        guard let projectIndex = index(for: startURL), let runIndex = projects[projectIndex].runs.indices.last else { return }
        let existingSiteReport = projects[projectIndex].runs[runIndex].searchConsole?.siteReport
        let inspected = records.filter { $0.searchConsoleIndexStatus != "Not checked" }
        guard !inspected.isEmpty || explicitUnavailableReason != nil else { return }
        let successful = inspected.filter { $0.searchConsoleIndexStatus != "Unavailable" }
        let unavailableReason: String?
        if let explicitUnavailableReason, !explicitUnavailableReason.isEmpty {
            unavailableReason = explicitUnavailableReason
        } else if successful.isEmpty {
            unavailableReason = inspected.compactMap { value in
                let message = value.searchConsoleFetchStatus.trimmingCharacters(in: .whitespacesAndNewlines)
                return message.isEmpty || message == "—" ? nil : message
            }.first
        } else {
            unavailableReason = nil
        }
        let summary = JournalSearchConsoleSummary(
            checkedURLs: successful.count,
            indexedURLs: successful.filter { $0.searchConsoleIndexStatus == "Indexed" }.count,
            // This is an exclusion reason reported by Google, not a local
            // inference from a page's canonical tag.  Previously every
            // non-indexed self-canonical URL was counted here, which made the
            // journal disagree with the Page indexing report in GSC.
            nonIndexedCanonicalURLs: successful.filter { record in
                guard record.searchConsoleIndexStatus == "Not indexed" else { return false }
                let coverage = record.searchConsoleCoverage.lowercased()
                return coverage.contains("canonical")
            }.count,
            notFoundURLs: successful.filter { $0.searchConsoleFetchStatus.hasPrefix("HTTP 404") || $0.searchConsoleFetchStatus == "Soft 404" }.count,
            redirectURLs: successful.filter { $0.searchConsoleFetchStatus.localizedCaseInsensitiveContains("redirect") }.count,
            serverErrorURLs: successful.filter { $0.searchConsoleFetchStatus.hasPrefix("HTTP 5xx") }.count,
            indexingIssueURLs: successful.filter { !$0.searchConsoleCoverage.isEmpty }.count,
            robotsBlockedURLs: successful.filter { $0.searchConsoleRobotsStatus == "Blocked" }.count,
            noindexURLs: successful.filter { $0.searchConsoleNoindexStatus.hasPrefix("noindex") }.count,
            mobileIssueURLs: successful.filter { !$0.searchConsoleMobileIssues.isEmpty }.count,
            siteReport: existingSiteReport,
            unavailableReason: unavailableReason
        )
        objectWillChange.send()
        projects[projectIndex].runs[runIndex].searchConsole = summary
        save()
    }
    func updateSearchConsoleTraffic(startURL: String, records: [CrawlRecord], countries: [SearchConsoleTrafficCountry]) {
        guard let projectIndex = index(for: startURL), let runIndex = projects[projectIndex].runs.indices.last else { return }
        let checked = records.filter { $0.isGSCEligible && $0.searchConsolePerformanceChecked }
        guard !checked.isEmpty else { return }
        let traffic = JournalSearchConsoleTrafficSummary(
            visibleURLs: checked.filter { $0.searchConsoleQueriesTop10 > 0 }.count,
            clickedURLs: checked.filter { $0.searchConsoleClicks7d > 0 }.count,
            zeroClickURLs: checked.filter { $0.searchConsoleClicks7d == 0 }.count,
            noVisibilityURLs: checked.filter { $0.searchConsoleQueryCount > 0 && $0.searchConsoleQueriesTop20 == 0 }.count,
            zeroQueryURLs: checked.filter { $0.searchConsoleQueryCount == 0 }.count,
            topCountries: countries
        )
        objectWillChange.send()
        if projects[projectIndex].runs[runIndex].searchConsole == nil { projects[projectIndex].runs[runIndex].searchConsole = JournalSearchConsoleSummary() }
        projects[projectIndex].runs[runIndex].searchConsole?.traffic = traffic
        save()
    }
    func updateSearchConsoleSiteReport(startURL: String, report: GSCSiteReport) {
        guard let projectIndex = index(for: startURL), let runIndex = projects[projectIndex].runs.indices.last else { return }
        objectWillChange.send()
        if projects[projectIndex].runs[runIndex].searchConsole == nil { projects[projectIndex].runs[runIndex].searchConsole = JournalSearchConsoleSummary() }
        projects[projectIndex].runs[runIndex].searchConsole?.siteReport = report
        save()
    }
    func updateGSCCoreWebVitals(startURL: String, report: GSCCoreWebVitalsReport) {
        guard let projectIndex = index(for: startURL), let runIndex = projects[projectIndex].runs.indices.last else { return }
        objectWillChange.send()
        if projects[projectIndex].runs[runIndex].searchConsole == nil { projects[projectIndex].runs[runIndex].searchConsole = JournalSearchConsoleSummary() }
        projects[projectIndex].runs[runIndex].searchConsole?.coreWebVitalsReport = report
        save()
    }
    func updateBacklinks(startURL: String, report: BacklinkReport, enrichedURLs: Int, totalURLs: Int) {
        guard let projectIndex = index(for: startURL), let runIndex = projects[projectIndex].runs.indices.last else { return }
        objectWillChange.send()
        let profile = report.domain
        projects[projectIndex].runs[runIndex].backlinks = JournalBacklinkSummary(domainRank: profile.rank, backlinks: profile.backlinks, referringDomains: profile.referringDomains, brokenBacklinks: profile.brokenBacklinks, spamScore: profile.spamScore, enrichedURLs: enrichedURLs, totalURLs: totalURLs, apiRequests: report.apiRequests, fetchedAt: report.fetchedAt, error: report.error)
        save()
    }
    /// Keeps client reports focused: only a material (20%+) movement compared
    /// with the immediately preceding completed crawl is reported.
    func materialChanges(startURL: String) -> [ProjectRunChange] {
        guard let index = index(for: startURL) else { return [] }
        let runs = projects[index].runs.sorted { $0.date > $1.date }
        guard runs.count >= 2 else { return [] }
        let current = runs[0].errors; let previous = runs[1].errors
        return Set(current.keys).union(previous.keys).compactMap { issue in
            let old = previous[issue] ?? 0; let new = current[issue] ?? 0
            guard old != new else { return nil }
            let percentage = old == 0 ? 100 : Int((Double(new - old) / Double(old) * 100).rounded())
            guard old == 0 || abs(percentage) >= 20 else { return nil }
            return ProjectRunChange(issue: issue, previous: old, current: new, percentage: percentage)
        }.sorted { abs($0.percentage) > abs($1.percentage) }
    }
    private func index(for startURL: String) -> Int? { projects.firstIndex { canonicalProjectKey($0.startURL) == canonicalProjectKey(startURL) } }
    /// Early builds permitted `example.com` and `https://example.com` to live
    /// as separate projects. Merge those histories on load so data collected
    /// by PageSpeed and Search Console stays under the visible project.
    private func mergeCanonicalDuplicates() {
        var merged: [SEOProject] = []
        var locations: [String: Int] = [:]
        for project in projects {
            let key = canonicalProjectKey(project.startURL)
            if let index = locations[key] {
                merged[index].runs.append(contentsOf: project.runs)
                merged[index].runs.sort { $0.date < $1.date }
            } else {
                locations[key] = merged.count
                merged.append(project)
            }
        }
        guard merged.count != projects.count else { return }
        projects = merged
        save()
    }
    private func save() { if let data = try? JSONEncoder().encode(projects) { try? data.write(to: file, options: .atomic) } }
    private func secondsSinceMidnight(_ date: Date) -> Int {
        let components = Calendar.current.dateComponents([.hour, .minute], from: date)
        return (components.hour ?? 0) * 3_600 + (components.minute ?? 0) * 60
    }
    private func roundedToTenMinutes(_ date: Date) -> Date {
        let calendar = Calendar.current
        let parts = calendar.dateComponents([.year, .month, .day, .hour, .minute], from: date)
        let minute = ((parts.minute ?? 0) / 10) * 10
        return calendar.date(from: DateComponents(year: parts.year, month: parts.month, day: parts.day, hour: parts.hour, minute: minute)) ?? date
    }
    private func canonicalProjectKey(_ raw: String) -> String {
        let qualified = raw.contains("://") ? raw : "https://" + raw
        guard var components = URLComponents(string: qualified) else { return raw.lowercased() }
        components.scheme = components.scheme?.lowercased(); components.host = components.host?.lowercased()
        components.path = components.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        return components.string?.lowercased() ?? raw.lowercased()
    }
    private func parseProjectLine(_ line: String) -> (name: String, url: String)? {
        let expression = #"(?i)(https?://[^\s]+|(?:www\.)?[a-z0-9-]+(?:\.[a-z0-9-]+)+(?:/[^\s]*)?)"#
        guard let regex = try? NSRegularExpression(pattern: expression),
              let match = regex.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)),
              let range = Range(match.range, in: line) else { return nil }
        let discovered = String(line[range]).trimmingCharacters(in: .punctuationCharacters)
        let lowercase = discovered.lowercased()
        let withScheme = lowercase.hasPrefix("http://") || lowercase.hasPrefix("https://") ? discovered : "https://\(discovered)"
        guard let url = URL(string: withScheme), let host = url.host, !host.isEmpty else { return nil }
        let prefix = String(line[..<range.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
        let suffix = String(line[range.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
        let label = (prefix.isEmpty ? suffix : prefix).trimmingCharacters(in: CharacterSet(charactersIn: "-–—:\t "))
        return (label.isEmpty ? host : label, url.absoluteString)
    }
}
