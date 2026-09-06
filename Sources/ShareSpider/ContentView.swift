import SwiftUI
import AppKit

struct BrandLogo: View {
    let width: CGFloat
    let height: CGFloat

    var body: some View {
        if let url = Bundle.module.url(forResource: "overview-logo-cropped", withExtension: "png"),
           let image = NSImage(contentsOf: url) {
            Image(nsImage: image)
                .resizable()
                .scaledToFit()
                .frame(width: width, height: height)
                .accessibilityLabel("SEO Spider Agent")
        } else {
            Text("SEO Spider Agent")
                .font(.headline)
                .accessibilityLabel("SEO Spider Agent")
        }
    }
}

struct URLActions: View {
    let url: URL
    var body: some View { HStack(spacing: 6) { Button { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(url.absoluteString, forType: .string) } label: { Image(systemName: "doc.on.doc") }.buttonStyle(.plain).help("Copy URL"); Button { NSWorkspace.shared.open(url) } label: { Image(systemName: "arrow.up.forward.app") }.buttonStyle(.plain).help("Open in browser") } }
}

struct ScenariosView: View {
    @ObservedObject var model: CrawlViewModel
    @ObservedObject var store: ScenarioStore
    @Environment(\.dismiss) private var dismiss
    @State private var section = 0
    @State private var severity: TechnicalTaskPDFReport.Severity = .highMedium
    @State private var batchURLs = ""
    @State private var reportKind: ScenarioReportKind = .both
    @State private var scheduleName = "Weekly SEO monitoring"
    @State private var cadenceDays = 7
    @State private var firstRun = Date().addingTimeInterval(3600)

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack { Label("Scenarios", systemImage: "rectangle.3.group").font(.title2.weight(.semibold)); Spacer(); Button("Done") { dismiss() } }
            Picker("Scenario", selection: $section) { Text("Technical task").tag(0); Text("Batch check").tag(1); Text("Schedule").tag(2) }.pickerStyle(.segmented)
            Divider()
            Group {
                if section == 0 { technicalTask }
                else if section == 1 { batchCheck }
                else { schedule }
            }
            Spacer(minLength: 0)
        }
        .padding(20).frame(width: 670, height: 560)
    }

    private var technicalTask: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Developer / optimizer technical task").font(.headline)
            Text("Creates a PDF from the current crawl. Each task contains the affected URL, the source page and anchor where available, redirect chains, and hreflang details.").foregroundStyle(.secondary)
            Picker("Include", selection: $severity) { ForEach(TechnicalTaskPDFReport.Severity.allCases) { Text($0.rawValue).tag($0) } }.frame(width: 260)
            Button("Export technical tasks PDF") { model.exportTechnicalTasks(severity: severity) }.buttonStyle(.borderedProminent).disabled(model.records.isEmpty)
            if model.records.isEmpty { Text("Run a crawl first to export a technical task.").font(.caption).foregroundStyle(.secondary) }
        }
    }

    private var batchCheck: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("One-time batch check").font(.headline)
            Text("One domain per line. Sites are crawled sequentially and each one receives its own folder and PDF report.").foregroundStyle(.secondary)
            TextEditor(text: $batchURLs).font(.body.monospaced()).overlay(RoundedRectangle(cornerRadius: 6).stroke(.quaternary)).frame(height: 145)
            HStack { Picker("Reports", selection: $reportKind) { ForEach(ScenarioReportKind.allCases) { Text($0.rawValue).tag($0) } }.frame(width: 210); Picker("Task priority", selection: $severity) { ForEach(TechnicalTaskPDFReport.Severity.allCases) { Text($0.rawValue).tag($0) } }.frame(width: 190) }
            Text("Reports save automatically to: \(ReportFileNaming.downloadsDirectory.path)").font(.caption).foregroundStyle(.secondary).lineLimit(1)
            Button(model.batchRunning ? "Running…" : "Run batch check") { model.runBatch(urlStrings: parsedURLs, kind: reportKind, severity: severity, outputDirectory: ReportFileNaming.downloadsDirectory) }.buttonStyle(.borderedProminent).disabled(model.batchRunning || parsedURLs.isEmpty)
            if let progress = model.batchProgress {
                Text(progress.label).font(.caption).foregroundStyle(progress.error.isEmpty ? Color.secondary : Color.red)
                if !progress.summaryReportPath.isEmpty {
                    Text("Critical issues summary: \(progress.summaryReportPath)").font(.caption).foregroundStyle(.green).lineLimit(1)
                }
            }
        }
    }

    private var schedule: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Scheduled monitoring").font(.headline)
            Text("Schedules are stored locally. A due check runs when ShareSpider is open; the app does not install a background service.").foregroundStyle(.secondary)
            TextField("Project name", text: $scheduleName)
            TextEditor(text: $batchURLs).font(.body.monospaced()).overlay(RoundedRectangle(cornerRadius: 6).stroke(.quaternary)).frame(height: 100)
            HStack { Stepper("Every \(cadenceDays) day(s)", value: $cadenceDays, in: 1...365); DatePicker("First run", selection: $firstRun) }
            HStack { Picker("Reports", selection: $reportKind) { ForEach(ScenarioReportKind.allCases) { Text($0.rawValue).tag($0) } }.frame(width: 210); Picker("Task priority", selection: $severity) { ForEach(TechnicalTaskPDFReport.Severity.allCases) { Text($0.rawValue).tag($0) } }.frame(width: 190) }
            Text("Reports save automatically to: \(ReportFileNaming.downloadsDirectory.path)").font(.caption).foregroundStyle(.secondary).lineLimit(1)
            Button("Add schedule") { store.add(name: scheduleName.isEmpty ? "SEO monitoring" : scheduleName, urls: parsedURLs, cadenceDays: cadenceDays, reportKind: reportKind, severity: severity, outputDirectory: ReportFileNaming.downloadsDirectory.path, firstRun: firstRun) }.disabled(parsedURLs.isEmpty)
            Divider()
            ScrollView { VStack(alignment: .leading, spacing: 6) { ForEach(store.schedules) { item in HStack { VStack(alignment: .leading) { Text(item.name).fontWeight(.semibold); Text("\(item.urls.count) site(s) · next run \(item.nextRun.formatted(date: .abbreviated, time: .shortened))").font(.caption).foregroundStyle(.secondary) }; Spacer(); Button("Run now") { model.runBatch(urlStrings: item.urls, kind: item.reportKind, severity: item.severity, outputDirectory: URL(fileURLWithPath: item.outputDirectory)); store.markStarted(item.id) }; Button(role: .destructive) { store.remove(item) } label: { Image(systemName: "trash") }.buttonStyle(.borderless) } } }.frame(maxWidth: .infinity, alignment: .leading) }.frame(maxHeight: 105)
        }
    }

    private var parsedURLs: [String] { batchURLs.components(separatedBy: CharacterSet(charactersIn: "\n,; ")).map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty } }
}

struct ProjectJournalView: View {
    @ObservedObject var model: CrawlViewModel
    @ObservedObject var journal: ProjectJournalStore
    @Environment(\.dismiss) private var dismiss
    @State private var selectedID: UUID?
    @State private var name = ""
    @State private var url = "https://"
    @State private var kind: ProjectKind = .ongoing
    @State private var importText = ""
    @State private var importStatus = ""
    @State private var regularEnabled = false
    @State private var regularTime = Date()
    @State private var scheduleStatus = ""
    private var selected: SEOProject? { journal.projects.first { $0.id == selectedID } ?? journal.projects.first }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack { Label("Projects and error journal", systemImage: "folder.badge.gearshape").font(.title2.weight(.semibold)); Spacer() }
            HStack(alignment: .top, spacing: 14) {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Projects").font(.headline)
                    ScrollView(.vertical, showsIndicators: true) {
                        LazyVStack(alignment: .leading, spacing: 4) {
                            ForEach(journal.projects) { project in
                                Button { select(project) } label: {
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(project.name).fontWeight(.semibold).lineLimit(1)
                                        Text(project.kind.rawValue).font(.caption).foregroundStyle(.secondary)
                                        Text(project.regularCheckTime.map { "Regular: \($0.formatted(date: .omitted, time: .shortened))" } ?? "Manual check").font(.caption).foregroundStyle(.secondary)
                                    }.frame(maxWidth: .infinity, alignment: .leading).padding(7).background(selectedID == project.id ? Color.accentColor.opacity(0.16) : Color.clear).clipShape(RoundedRectangle(cornerRadius: 6))
                                }.buttonStyle(.plain)
                            }
                        }.padding(.trailing, 5)
                    }.frame(width: 245, height: 395).overlay(RoundedRectangle(cornerRadius: 6).stroke(.quaternary))
                    Divider()
                    TextField("Project name", text: $name)
                    TextField("Start URL", text: $url)
                    Picker("Type", selection: $kind) { ForEach(ProjectKind.allCases) { Text($0.rawValue).tag($0) } }.pickerStyle(.menu)
                    Button("Add project") { let projectName = name.trimmingCharacters(in: .whitespacesAndNewlines); guard !projectName.isEmpty, URL(string: url) != nil else { return }; journal.add(name: projectName, startURL: url, kind: kind); selectedID = journal.projects.last?.id; name = ""; url = "https://" }.disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || url == "https://")
                    Divider()
                    Text("Bulk import").font(.headline)
                    Text("One project per line: Name https://example.com").font(.caption).foregroundStyle(.secondary)
                    TextEditor(text: $importText).font(.caption.monospaced()).overlay(RoundedRectangle(cornerRadius: 5).stroke(.quaternary)).frame(height: 100)
                    Button("Import projects") {
                        let summary = journal.importProjects(from: importText, kind: kind)
                        importStatus = "Added: \(summary.added) · already present: \(summary.duplicates)" + (summary.invalidLines.isEmpty ? "" : " · skipped: \(summary.invalidLines.count)")
                        if selectedID == nil { selectedID = journal.projects.last?.id }
                    }
                    .disabled(importText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    if !importStatus.isEmpty { Text(importStatus).font(.caption).foregroundStyle(.secondary) }
                }
                Divider()
                ScrollView(.vertical, showsIndicators: true) {
                VStack(alignment: .leading, spacing: 10) {
                    if let project = selected {
                        HStack { VStack(alignment: .leading) { Text(project.name).font(.title3.weight(.semibold)); Text(project.startURL).foregroundStyle(.secondary) }; Spacer(); Button("Run project") { model.start(project: project); dismiss() }.buttonStyle(.borderedProminent); Button(role: .destructive) { journal.remove(project); selectedID = journal.projects.first?.id } label: { Image(systemName: "trash") }.buttonStyle(.borderless) }
                        Text("Latest check: \(project.latestRun?.date.formatted(date: .abbreviated, time: .shortened) ?? "not run yet") · \(project.latestRun?.urlCount ?? 0) URLs").font(.caption).foregroundStyle(.secondary)
                        Divider()
                        Text("Regularity").font(.headline)
                        Toggle("Run automatically every day", isOn: Binding(get: { regularEnabled }, set: { enabled in updateSchedule(project: project, enabled: enabled, time: regularTime) }))
                        if regularEnabled {
                            HStack {
                                DatePicker("Time", selection: $regularTime, displayedComponents: .hourAndMinute).labelsHidden()
                                    .onChange(of: regularTime) { _, newTime in updateSchedule(project: project, enabled: true, time: newTime) }
                                Text("The slot is reserved for 10 minutes.").font(.caption).foregroundStyle(.secondary)
                            }
                        }
                        if !scheduleStatus.isEmpty { Text(scheduleStatus).font(.caption).foregroundStyle(.red) }
                        Divider()
                        Text("Error journal").font(.headline)
                        if !project.runs.isEmpty {
                            errorHistoryTable(project)
                        } else { Text("No errors have been recorded yet. Run the project to create its first journal entry.").foregroundStyle(.secondary) }
                    } else { ContentUnavailableView("Select or add a project", systemImage: "folder") }
                }.frame(maxWidth: .infinity, alignment: .leading).padding(.trailing, 8)
                }
            }
        }
        .padding(20).frame(width: 930, height: 720)
        .overlay(alignment: .topTrailing) {
            Button("Close", systemImage: "xmark") { dismiss() }
                .buttonStyle(.bordered)
                .padding(16)
                .accessibilityLabel("Close projects")
        }
        .onAppear { syncSchedule() }
        .onChange(of: selectedID) { _, _ in syncSchedule() }
    }

    private func select(_ project: SEOProject) { selectedID = project.id; syncSchedule(for: project) }
    private func syncSchedule(for project: SEOProject? = nil) {
        let value = project ?? selected
        regularEnabled = value?.regularCheckTime != nil
        regularTime = value?.regularCheckTime ?? Date()
        scheduleStatus = ""
    }
    private func updateSchedule(project: SEOProject, enabled: Bool, time: Date) {
        let error = journal.setRegularSchedule(projectID: project.id, time: enabled ? time : nil)
        scheduleStatus = error ?? ""
        if error == nil { regularEnabled = enabled; regularTime = time }
        else { regularEnabled = project.regularCheckTime != nil; regularTime = project.regularCheckTime ?? time }
    }

    @ViewBuilder private func errorHistoryTable(_ project: SEOProject) -> some View {
        let runs = project.runs.sorted { $0.date > $1.date }
        let rows = journalRows(runs)
        ScrollView(.horizontal, showsIndicators: true) {
            Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 7) {
                GridRow {
                    Text("Issue").fontWeight(.semibold).frame(width: 290, alignment: .leading)
                    ForEach(runs) { run in
                        Text(compactDate(run.date))
                            .fontWeight(.semibold).frame(width: 108, alignment: .leading).lineLimit(1)
                    }
                }
                ForEach(rows, id: \.label) { row in
                    GridRow {
                        Text(row.label).frame(width: 290, alignment: .leading).lineLimit(1).truncationMode(.tail)
                        ForEach(runs) { run in
                            Text(row.value(run))
                                .monospacedDigit().frame(width: 108, alignment: .leading)
                        }
                    }
                }
            }
            .font(.body)
            .padding(.bottom, 3)
        }
        Text("Latest check is the first column; prior checks remain to the right for comparison.").font(.caption).foregroundStyle(.secondary)
    }

    private struct JournalRow {
        var label: String
        var value: (ProjectRun) -> String
    }
    private func compactDate(_ date: Date) -> String {
        let formatter = DateFormatter(); formatter.locale = Locale(identifier: "en_US_POSIX"); formatter.dateFormat = "dd.MM.yy"
        return formatter.string(from: date)
    }
    private func journalRows(_ runs: [ProjectRun]) -> [JournalRow] {
        var rows = Set(runs.flatMap { $0.errors.keys }).sorted().map { issue in JournalRow(label: issue) { $0.errors[issue].map(String.init) ?? "—" } }
        func pendingStatus(_ run: ProjectRun) -> String {
            // A stopped app cannot finish an in-flight network task. Show a
            // truthful state instead of a permanent spinner in old journal rows.
            guard run.id == runs.first?.id, Date().timeIntervalSince(run.date) < 90 else { return "Not checked" }
            return "Checking…"
        }
        func metric(_ label: String, _ strategy: String, _ value: @escaping (JournalPageSpeedMetric) -> String) {
            guard runs.contains(where: { $0.pageSpeed.contains { $0.strategy.lowercased() == strategy } }) else { return }
            rows.append(JournalRow(label: "PageSpeed \(strategy.capitalized) · \(label)") { run in
                // The crawl entry is written first, then PageSpeed updates it.
                // Make that short interval explicit instead of showing a dash
                // which looks like the check was silently skipped.
                guard let result = run.pageSpeed.first(where: { $0.strategy.lowercased() == strategy }) else {
                    return pendingStatus(run)
                }
                guard !result.error.isEmpty else { return value(result) }
                if result.error.contains("429") { return "Quota 429" }
                if result.error.localizedCaseInsensitiveContains("not connected") { return "Not connected" }
                return "Unavailable"
            })
        }
        metric("Score", "mobile") { $0.score.map(String.init) ?? "—" }; metric("LCP", "mobile") { $0.lcp }; metric("CLS", "mobile") { $0.cls }
        metric("Score", "desktop") { $0.score.map(String.init) ?? "—" }; metric("LCP", "desktop") { $0.lcp }; metric("CLS", "desktop") { $0.cls }
        // Keep these rows present even before the first GSC inspection.  Do not
        // use an ambiguous dash for a missing authorization: it previously made
        // a failed/non-started GSC inspection indistinguishable from a zero
        // result in the project history.
        // The public Search Console API exposes URL Inspection, rather than
        // the aggregate Page indexing chart.  State the inspected-crawl scope
        // in every row so these values are never mistaken for property totals.
        let gsc: [(String, (JournalSearchConsoleSummary) -> Int)] = [
            ("GSC · checked", { $0.checkedURLs }),
            ("GSC · indexed", { $0.indexedURLs }),
            ("GSC · excluded", { max(0, $0.checkedURLs - $0.indexedURLs) }),
            ("GSC · 404", { $0.notFoundURLs }),
            ("GSC · redirects", { $0.redirectURLs }),
            ("GSC · canonical excluded", { $0.nonIndexedCanonicalURLs }),
            ("GSC · 5xx", { $0.serverErrorURLs }),
            ("GSC · indexing issues", { $0.indexingIssueURLs }),
            ("GSC · robots blocked", { $0.robotsBlockedURLs ?? 0 }),
            ("GSC · noindex", { $0.noindexURLs ?? 0 }),
            ("GSC · mobile issues", { $0.mobileIssueURLs ?? 0 })
        ]
        for (name, extract) in gsc {
            rows.append(JournalRow(label: name) { run in
                if let summary = run.searchConsole {
                    if let reason = summary.unavailableReason, !reason.isEmpty {
                        if reason == "Checking…" { return "Checking…" }
                        if reason.localizedCaseInsensitiveContains("superseded") { return "Superseded" }
                        if reason.localizedCaseInsensitiveContains("interrupted") { return "Interrupted" }
                        return reason.localizedCaseInsensitiveContains("do not own this site") ? "No property access" : "Unavailable"
                    }
                    return String(extract(summary))
                }
                return SearchConsoleAuth.shared.isConnected ? pendingStatus(run) : "Not connected"
            })
        }
        // Separate property-wide Page Indexing report, fetched from the GSC
        // interface through the dedicated local Chrome profile. It must never
        // be mistaken for the URL Inspection API rows above.
        let gscSite: [(String, String)] = [
            ("GSC Page Indexing · indexed", "indexed"),
            ("GSC Page Indexing · not indexed", "not-indexed"),
            ("GSC Page Indexing · 404", "404"),
            ("GSC Page Indexing · Soft 404", "soft404"),
            ("GSC Page Indexing · page with redirect", "redirect"),
            ("GSC Page Indexing · redirect error", "redirect-error"),
            ("GSC Page Indexing · 5xx", "5xx"),
            ("GSC Page Indexing · crawled, not indexed", "crawled-not-indexed"),
            ("GSC Page Indexing · discovered, not indexed", "discovered-not-indexed"),
            ("GSC Page Indexing · canonical issue", "canonical"),
            ("GSC Page Indexing · robots blocked", "robots"),
            ("GSC Page Indexing · noindex", "noindex"),
            ("GSC Page Indexing · mobile issues", "mobile")
        ]
        for (name, key) in gscSite {
            rows.append(JournalRow(label: name) { run in
                guard let report = run.searchConsole?.siteReport else { return "—" }
                return String(report.count(key))
            })
        }
        rows.append(JournalRow(label: "GSC Core Web Vitals · mobile Poor") { run in
            String(run.searchConsole?.coreWebVitalsReport?.metrics.filter { $0.group == "Poor" }.reduce(0) { $0 + $1.count } ?? 0)
        })
        rows.append(JournalRow(label: "GSC Core Web Vitals · mobile Needs improvement") { run in
            String(run.searchConsole?.coreWebVitalsReport?.metrics.filter { $0.group == "Needs improvement" }.reduce(0) { $0 + $1.count } ?? 0)
        })
        let traffic: [(String, (JournalSearchConsoleTrafficSummary) -> String)] = [
            ("GSC · Top 10 URLs", { String($0.visibleURLs) }),
            ("GSC · URLs with clicks", { String($0.clickedURLs) }),
            ("GSC · URLs without clicks", { String($0.zeroClickURLs) }),
            ("GSC · past Top 20", { String($0.noVisibilityURLs) }),
            ("GSC · no queries", { String($0.zeroQueryURLs) }),
            ("GSC · top countries", { $0.topCountries.map { "\($0.code) \(Int(($0.share * 100).rounded()))%" }.joined(separator: " · ") })
        ]
        for (name, extract) in traffic {
            rows.append(JournalRow(label: name) { run in
                guard let summary = run.searchConsole else { return SearchConsoleAuth.shared.isConnected ? pendingStatus(run) : "Not connected" }
                return summary.traffic.map(extract) ?? "—"
            })
        }
        if runs.contains(where: { $0.backlinks != nil }) {
            let backlinkRows: [(String, (JournalBacklinkSummary) -> String)] = [
                ("Backlinks · Domain Rank", { String($0.domainRank) }),
                ("Backlinks · total", { String($0.backlinks) }),
                ("Backlinks · referring domains", { String($0.referringDomains) }),
                ("Backlinks · broken", { String($0.brokenBacklinks) }),
                ("Backlinks · spam score", { String($0.spamScore) }),
                ("Backlinks · enriched URLs", { "\($0.enrichedURLs) / \($0.totalURLs)" })
            ]
            for (name, extract) in backlinkRows { rows.append(JournalRow(label: name) { run in run.backlinks.map(extract) ?? "—" }) }
        }
        return rows
    }
}

struct ContentView: View {
    @StateObject private var model = CrawlViewModel()
    @State private var tab = 0
    @State private var showSettings = false
    @State private var showScenarios = false
    @State private var showProjects = false
    @StateObject private var scenarios = ScenarioStore()
    @StateObject private var projectJournal = ProjectJournalStore.shared
    var body: some View {
        VStack(spacing: 0) {
            controlBar
            Divider()
            TabView(selection: $tab) {
                OverviewView(model: model, showURLs: { tab = 2 }).tabItem { Label("Overview", systemImage: "chart.bar.xaxis") }.tag(0)
                IssuesView(model: model, switchToURLs: { tab = 2 }).tabItem { Label("Issues", systemImage: "exclamationmark.triangle") }.tag(1)
                URLsView(model: model).tabItem { Label("URLs", systemImage: "list.bullet.rectangle") }.tag(2)
                BacklinksView(model: model).tabItem { Label("Backlinks", systemImage: "link") }.tag(3)
                AuditView(model: model).tabItem { Label("Audit", systemImage: "checklist") }.tag(4)
            }.padding(.horizontal, 12).padding(.top, 8)
            statusBar
        }
        .sheet(isPresented: $showSettings) { SettingsView(settings: $model.settings, localVision: $model.localVision) }
        .sheet(isPresented: $showScenarios) { ScenariosView(model: model, store: scenarios) }
        .sheet(isPresented: $showProjects) { ProjectJournalView(model: model, journal: projectJournal) }
        .task {
            if let pendingCommand = AutomationBridge.consumePendingCommand() {
                model.handleLaunchURL(pendingCommand)
            }
            // macOS may suspend an app that is not running, therefore scheduled
            // checks start as soon as ShareSpider is opened. One batch at a time
            // prevents separate projects from competing for the crawler.
            if let due = scenarios.due().first {
                model.runBatch(urlStrings: due.urls, kind: due.reportKind, severity: due.severity, outputDirectory: URL(fileURLWithPath: due.outputDirectory))
                scenarios.markStarted(due.id)
            } else if let project = projectJournal.dueRegularProjects().first {
                model.start(project: project)
                projectJournal.markRegularRun(project.id)
            }
            // MCP commands are also kept in a local file queue. Polling it makes
            // cold-start delivery reliable even when macOS sends the URL before
            // SwiftUI has attached its onOpenURL handler.
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                if let pendingCommand = AutomationBridge.consumePendingCommand() {
                    model.handleLaunchURL(pendingCommand)
                }
            }
        }
        .onOpenURL { url in
            if url.scheme == "sharespider", url.host == "projects", url.path == "/import", let payload = AutomationBridge.consumePendingProjectImport() {
                _ = projectJournal.importProjects(from: payload)
            } else {
                _ = AutomationBridge.consumePendingCommand()
                model.handleLaunchURL(url)
            }
        }
        .toolbar {
            ToolbarItem(placement: .navigation) {
                BrandLogo(width: 290, height: 46)
            }
        }
    }

    private var controlBar: some View {
        VStack(spacing: 7) {
            HStack(spacing: 10) {
                Picker("Mode", selection: $model.mode) { ForEach(CrawlMode.allCases) { Text($0.rawValue).tag($0) } }.pickerStyle(.segmented).frame(width: 160)
                if model.mode == .spider {
                    TextField("Start URL", text: $model.startText).textFieldStyle(.roundedBorder).frame(minWidth: 360)
                } else {
                    Text("List mode uses the URL list below.").foregroundStyle(.secondary)
                    Button("Import TXT / CSV") { model.importList() }
                }
                Button { model.start() } label: { Label(model.state == .paused ? "Resume" : "Start", systemImage: "play.fill") }.buttonStyle(.borderedProminent).disabled(model.state == .crawling)
                Button { model.pause() } label: { Label("Pause", systemImage: "pause.fill") }.disabled(model.state != .crawling)
                Button { model.stop() } label: { Label("Stop", systemImage: "stop.fill") }.disabled(model.state != .crawling && model.state != .paused)
                Button { model.clear() } label: { Label("Clear", systemImage: "trash") }
                Button { showScenarios = true } label: { Label("Scenarios", systemImage: "rectangle.3.group") }
                Button { showProjects = true } label: { Label("Projects", systemImage: "folder.badge.gearshape") }
                Menu { ForEach(ExportScope.allCases) { scope in Button(scope.rawValue) { model.export(scope) } } } label: { Label("Export", systemImage: "square.and.arrow.up") }
                Button { showSettings = true } label: { Image(systemName: "gearshape") }.help("Crawl settings")
            }
            if model.batchRunning, let batch = model.batchProgress {
                HStack(spacing: 9) {
                    ProgressView(value: Double(batch.completed), total: Double(max(1, batch.total))).progressViewStyle(.linear).frame(minWidth: 180, maxWidth: 260)
                    Text("Batch \(batch.completed + 1) of \(batch.total): \(batch.currentSite) · \(Int(batch.currentSiteProgress * 100))%").font(.caption.weight(.semibold)).lineLimit(1).truncationMode(.middle)
                    ScrollView(.horizontal, showsIndicators: true) {
                        HStack(spacing: 6) {
                            ForEach(batch.pendingSites, id: \.self) { site in
                                Text(site).font(.caption).lineLimit(1).padding(.horizontal, 8).padding(.vertical, 4).background(site == batch.currentSite ? Color.accentColor.opacity(0.16) : Color.secondary.opacity(0.10)).clipShape(Capsule())
                            }
                        }
                    }.frame(maxWidth: .infinity)
                }
            } else if model.state == .crawling || model.state == .paused || model.state == .finished {
                HStack(spacing: 9) {
                    ProgressView(value: model.crawlProgress).progressViewStyle(.linear).frame(minWidth: 260, maxWidth: .infinity)
                    Text(model.crawlProgressLabel).font(.caption.monospacedDigit()).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            // Site-wide Chrome reports and URL Inspection are independent from
            // crawling. Keep each status below the crawl bar so a completed
            // crawl is never mistaken for a completed Google import.
            if model.gscChromeSyncRunning {
                HStack(spacing: 9) {
                    ProgressView(value: Double(model.gscChromeProgress), total: Double(max(1, model.gscChromeTotal)))
                        .progressViewStyle(.linear)
                        .tint(.blue)
                        .frame(minWidth: 260, maxWidth: .infinity)
                    Text(model.gscChromeStage)
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
            if model.searchConsoleRunning {
                HStack(spacing: 9) {
                    ProgressView(value: Double(model.searchConsoleProgress), total: Double(max(1, model.searchConsoleTotal)))
                        .progressViewStyle(.linear)
                        .tint(.orange)
                        .frame(minWidth: 260, maxWidth: .infinity)
                    Text("Google Search Console · URL Inspection: \(model.searchConsoleProgress) / \(model.searchConsoleTotal) canonical HTML URLs")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            if model.backlinkRunning {
                HStack(spacing: 9) {
                    ProgressView(value: Double(model.backlinkProgress), total: Double(max(1, model.backlinkTotal)))
                        .progressViewStyle(.linear)
                        .tint(.purple)
                        .frame(minWidth: 260, maxWidth: .infinity)
                    Text("Backlinks · \(model.backlinkProgress) / \(model.backlinkTotal) · \(model.backlinkMessage)")
                        .font(.caption.monospacedDigit()).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                    Button("Stop") { model.stopBacklinkAnalysis() }.controlSize(.small)
                }
            }
        }.padding(12)
    }
    private var statusBar: some View {
        VStack(spacing: 6) {
            Divider(); HStack { Label(model.state.label, systemImage: model.state == .crawling ? "antenna.radiowaves.left.and.right" : "circle").foregroundStyle(model.state == .crawling ? .green : .secondary); Spacer(); Text("Processed: \(model.records.count)"); Text("Queued: \(model.queued)"); Text(model.speed); Text("Errors: \(model.errors)").foregroundStyle(model.errors > 0 ? .red : .secondary); ProgressView(value: model.progress).frame(width: 150) }.font(.caption).padding(.horizontal, 14).padding(.bottom, 8)
        }
    }
}

struct OverviewView: View {
    @ObservedObject var model: CrawlViewModel
    var showURLs: () -> Void
    var body: some View {
        GeometryReader { proxy in
            HStack(spacing: 0) {
                Group {
                    if let metric = model.overviewSelectionName {
                        AffectedURLsView(model: model, metric: metric, showURLs: showURLs)
                    } else {
                        ContentUnavailableView("Select a metric", systemImage: "cursorarrow.click", description: Text("Affected URLs will appear here."))
                    }
                }
                .frame(width: proxy.size.width * 0.6 - 1, alignment: .leading)
                .padding(.trailing, 10)
                Divider()
                overviewTree.frame(width: proxy.size.width * 0.4, alignment: .leading)
            }
        }
    }

    private var overviewTree: some View {
        VStack(alignment: .leading) {
            HStack {
                Text("Metric").fontWeight(.semibold)
                Spacer()
                Text("URLs").fontWeight(.semibold).frame(width: 80, alignment: .trailing)
                Text("% of Total").fontWeight(.semibold).frame(width: 100, alignment: .trailing)
            }
            .padding(.horizontal, 8).padding(.vertical, 8).background(.quaternary.opacity(0.45))
            List {
                ForEach(flatten(model.overview)) { entry in
                    let item = entry.item
                    HStack {
                        if entry.level > 0 { Color.clear.frame(width: CGFloat(entry.level * 12)) }
                        Image(systemName: item.children.isEmpty ? "circle.fill" : "chevron.down").font(.caption2).foregroundStyle(item.children.isEmpty ? .clear : .secondary)
                        Text(item.name)
                            .font(item.children.isEmpty ? .body : .body.weight(.semibold))
                            .lineLimit(1)
                            .truncationMode(.tail)
                        Spacer()
                        Text("\(item.count)").monospacedDigit().frame(width: 80, alignment: .trailing)
                        Text(item.denominator == 0 ? "0%" : String(format: "%.2f%%", Double(item.count) / Double(item.denominator) * 100)).monospacedDigit().frame(width: 100, alignment: .trailing)
                    }
                    .contentShape(Rectangle())
                    .onTapGesture { model.selectOverview(item) }
                }
            }
            .listStyle(.inset(alternatesRowBackgrounds: true))
        }
    }
    private struct Entry: Identifiable { let item: OverviewItem; let level: Int; var id: UUID { item.id } }
    private func flatten(_ items: [OverviewItem], level: Int = 0) -> [Entry] { items.flatMap { [Entry(item: $0, level: level)] + flatten($0.children, level: level + 1) } }
}

struct AffectedURLsView: View {
    @ObservedObject var model: CrawlViewModel
    let metric: String
    var showURLs: () -> Void
    private var records: [CrawlRecord] { model.records.filter { model.overviewSelectionIDs.contains($0.id) } }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Affected URLs").font(.title3.weight(.semibold))
                    Text(metric).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer()
                Button { model.clearOverviewSelection() } label: { Image(systemName: "xmark.circle.fill") }.buttonStyle(.plain).foregroundStyle(.secondary).help("Close affected URLs")
            }
            if let kind = model.backlinkDrilldownKind {
                BacklinkDrilldownList(model: model, kind: kind)
            } else if !model.overviewSelectionExternalURLs.isEmpty {
                Text("\(model.overviewSelectionExternalURLs.count) URL\(model.overviewSelectionExternalURLs.count == 1 ? "" : "s") reported by Google Search Console")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                GSCReportedURLList(urls: model.overviewSelectionExternalURLs, crawled: model.records)
            } else {
                Text("\(records.count) URL\(records.count == 1 ? "" : "s")").font(.caption).foregroundStyle(.secondary)
                if records.isEmpty && metric.hasPrefix("GSC") {
                    ContentUnavailableView(
                        "Google reported an aggregate count",
                        systemImage: "chart.bar",
                        description: Text("Google supplied the category total but did not provide individual URLs in this report. The existing crawl data is not replaced.")
                    )
                } else {
                    ProblemExampleList(problemName: metric, records: records)
                    Button("Open filtered table in URLs") { showURLs() }.buttonStyle(.borderedProminent).frame(maxWidth: .infinity, alignment: .trailing)
                }
            }
        }
        .padding(.trailing, 8)
    }
}

private struct BacklinkDrilldownList: View {
    @ObservedObject var model: CrawlViewModel
    let kind: BacklinkDrilldownKind
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if model.backlinkDrilldownRunning { ProgressView("Loading (kind.title.lowercased()) from DataForSEO…") }
            Text(kind == .referringDomains ? "Top 100 referring domains" : "Top 100 discovered backlinks")
                .font(.caption).foregroundStyle(.secondary)
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    if kind == .referringDomains {
                        ForEach(model.referringDomainDetails) { item in
                            VStack(alignment: .leading, spacing: 3) {
                                HStack { Text(item.domain).font(.body.weight(.semibold)); Spacer(); Text("Rank (item.rank)").monospacedDigit(); Text("Spam (item.spamScore)").monospacedDigit().foregroundStyle(item.spamScore >= 50 ? .red : .secondary) }
                                Text("\(item.backlinks) backlinks · \(item.referringPages) referring pages · first seen \(item.firstSeen)").font(.caption).foregroundStyle(.secondary)
                            }.padding(.vertical, 7); Divider()
                        }
                    } else {
                        ForEach(model.backlinkSourceDetails) { item in
                            VStack(alignment: .leading, spacing: 3) {
                                HStack { Text(item.sourceDomain.isEmpty ? item.sourceURL : item.sourceDomain).font(.body.weight(.semibold)).lineLimit(1); Spacer(); Text("Domain Rank (item.domainRank)").monospacedDigit() }
                                HStack { Text(item.sourceURL).font(.caption).lineLimit(1); if let url = URL(string: item.sourceURL) { URLActions(url: url) } }
                                Text("→ \(item.targetURL)").font(.caption).foregroundStyle(.secondary).lineLimit(1)
                                Text("\(item.dofollow ? "Dofollow" : "Nofollow") · page rank \(item.pageRank)\(item.anchor.isEmpty ? "" : " · anchor: \(item.anchor)")").font(.caption).foregroundStyle(item.broken ? .red : .secondary).lineLimit(2)
                            }.padding(.vertical, 7); Divider()
                        }
                    }
                }
            }
            if !model.backlinkMessage.isEmpty { Text(model.backlinkMessage).font(.caption).foregroundStyle(.secondary) }
        }
    }
}

struct IssuesView: View {
    @ObservedObject var model: CrawlViewModel
    var switchToURLs: () -> Void
    var body: some View {
        GeometryReader { proxy in
            HStack(spacing: 0) {
                Group {
                    if let issue = model.issueSelection { IssueURLsView(model: model, issue: issue) }
                    else { ContentUnavailableView("Select an issue", systemImage: "cursorarrow.click", description: Text("Affected URLs will appear here.")) }
                }
                .frame(width: proxy.size.width * 0.6 - 1, alignment: .leading)
                .padding(.trailing, 10)
                Divider()
                issueTable.frame(width: proxy.size.width * 0.4, alignment: .leading)
            }
        }
    }
    private var issueTable: some View {
        VStack(alignment: .leading) {
            Text("Issues").font(.title2.weight(.semibold))
            Table(model.issues) {
                TableColumn("Issue Name") { issue in Text(issue.name).contentShape(Rectangle()).onTapGesture { model.selectIssue(issue) } }
                TableColumn("Type") { Text($0.type) }
                TableColumn("Priority") { Text($0.priority).foregroundStyle($0.priority == "High" ? .red : $0.priority == "Medium" ? .orange : .secondary) }
                TableColumn("URLs") { Text("\($0.count)") }.width(60)
                TableColumn("% of Total") { Text(model.records.isEmpty ? "0%" : String(format: "%.1f%%", Double($0.count) / Double(model.records.count) * 100)) }.width(100)
            }.contextMenu(forSelectionType: Issue.ID.self) { _ in Button("Show affected URLs") { switchToURLs() } }
        }
    }
}

struct IssueURLsView: View {
    @ObservedObject var model: CrawlViewModel; let issue: Issue
    var body: some View { VStack(alignment: .leading, spacing: 8) { HStack { VStack(alignment: .leading) { Text("Affected URLs").font(.title3.weight(.semibold)); Text(issue.name).foregroundStyle(.secondary).lineLimit(2) }; Spacer(); Button { model.clearIssueSelection() } label: { Image(systemName: "xmark.circle.fill") }.buttonStyle(.plain) }; if !issue.externalURLs.isEmpty { GSCReportedURLList(urls: issue.externalURLs, crawled: model.records) } else { ProblemExampleList(problemName: issue.name, records: model.records.filter { issue.urlIDs.contains($0.id) }) } }.padding(.trailing, 8) }
}

/// URLs exported by the Page Indexing report can include URLs that this crawl
/// never discovered. Show them verbatim and add the current crawl state where
/// it is available, so a stale Google report (GSC 404 vs current 200) is clear.
struct GSCReportedURLList: View {
    let urls: [String]
    let crawled: [CrawlRecord]
    private func record(_ value: String) -> CrawlRecord? { crawled.first { $0.url.absoluteString.trimmingCharacters(in: CharacterSet(charactersIn: "/")) == value.trimmingCharacters(in: CharacterSet(charactersIn: "/")) } }
    var body: some View {
        List {
            ForEach(urls, id: \.self) { value in
                VStack(alignment: .leading, spacing: 3) {
                    HStack { Text(value).lineLimit(2).textSelection(.enabled); Spacer(); if let url = URL(string: value) { URLActions(url: url) } }
                    if let current = record(value) {
                        Text("ShareSpider now: \(current.statusText) · \(current.indexability)\(current.canonical.isEmpty ? "" : " · canonical: \(current.canonical)")")
                            .font(.caption).foregroundStyle((current.statusCode ?? 0) / 100 == 2 ? .green : .orange).lineLimit(2)
                    } else { Text("Not found in the current crawl.").font(.caption).foregroundStyle(.secondary) }
                }
            }
        }
    }
}

struct ProblemExampleList: View {
    let problemName: String
    let records: [CrawlRecord]
    /// Each affected URL can disclose the pages that point to it. Keeping this
    /// collapsed avoids an individual result consuming the whole left panel.
    @State private var expandedFoundOn = Set<UUID>()
    private var isTitleProblem: Bool { problemName.localizedCaseInsensitiveContains("title") }
    private var isImageAltProblem: Bool { problemName == "Images without alt text" || problemName == "Missing Alt Text" }
    private var isEmbeddedImageProblem: Bool { isImageAltProblem || problemName == "Images over 100 KB" || problemName == "Over 100 KB" }
    private var isImageResourceProblem: Bool { problemName == "Broken image resources" || problemName == "Heavy image resources" || problemName == "Broken Image Resources" || problemName == "Heavy Image Resources" }
    private var isRedirectProblem: Bool { problemName.localizedCaseInsensitiveContains("redirect") }
    private var isSchemaProblem: Bool { problemName.localizedCaseInsensitiveContains("schema") || problemName.localizedCaseInsensitiveContains("structured data") || ["Organization / Business", "BreadcrumbList", "Product", "Review", "FAQPage", "WebSite", "WebPage", "Service", "Person", "VideoObject", "Event", "JobPosting"].contains(problemName) }
    var body: some View {
        List {
            if isEmbeddedImageProblem {
                ForEach(Array(records.flatMap { page in page.images.filter { isImageAltProblem ? $0.alt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty : $0.size > 100_000 }.map { (page, $0) } }.prefix(10)), id: \.1.url) { page, image in
                    VStack(alignment: .leading, spacing: 3) {
                        HStack { Text(page.url.absoluteString).font(.caption).foregroundStyle(.secondary).textSelection(.enabled); Spacer(); URLActions(url: page.url) }
                        HStack { Text(image.url).lineLimit(2).textSelection(.enabled); Spacer(); if let imageURL = URL(string: image.url) { URLActions(url: imageURL) } }
                        Text(isImageAltProblem ? "Image without alt attribute" : "Image size: \(ByteCountFormatter.string(fromByteCount: Int64(image.size), countStyle: .file))").font(.caption).foregroundStyle(.orange)
                    }.contextMenu { Button("Open image") { if let url = URL(string: image.url) { NSWorkspace.shared.open(url) } }; Button("Open page") { NSWorkspace.shared.open(page.url) } }
                }
            } else {
                ForEach(records) { record in
                    VStack(alignment: .leading, spacing: 3) {
                        HStack {
                            Text(record.url.absoluteString).lineLimit(2).textSelection(.enabled)
                            Spacer()
                            URLActions(url: record.url)
                            if !record.foundOnURLs.isEmpty {
                                Button {
                                    if expandedFoundOn.contains(record.id) { expandedFoundOn.remove(record.id) }
                                    else { expandedFoundOn.insert(record.id) }
                                } label: {
                                    Image(systemName: expandedFoundOn.contains(record.id) ? "minus.circle" : "plus.circle")
                                }
                                .buttonStyle(.plain)
                                .help(expandedFoundOn.contains(record.id) ? "Hide pages where this URL was found" : "Show pages where this URL was found")
                            }
                        }
                        if isSchemaProblem { Text(record.schemaTypes.isEmpty ? "JSON-LD schema not found" : "JSON-LD: \(record.schemaTypes.joined(separator: ", "))").lineLimit(3).font(.caption).foregroundStyle(.secondary).textSelection(.enabled) }
                        else if isRedirectProblem, let source = record.redirectSources.first { Text("Redirect: \(source.absoluteString) → \(record.url.absoluteString)").lineLimit(3).font(.caption).foregroundStyle(.orange).textSelection(.enabled) }
                        else if isTitleProblem { Text(record.title.isEmpty ? "Title is missing" : record.title).lineLimit(3).textSelection(.enabled); Text("Title length: \(record.title.count) characters").font(.caption).foregroundStyle(.secondary) }
                        else if isImageResourceProblem { HStack(spacing: 8) { Text(record.statusText); Text(record.contentType); if record.size > 0 { Text(ByteCountFormatter.string(fromByteCount: Int64(record.size), countStyle: .file)) } }.font(.caption).foregroundStyle(record.statusCode.map { $0 >= 400 } == true ? .red : .secondary) }
                        else { HStack(spacing: 8) { Text(record.statusText); if !record.title.isEmpty { Text(record.title).lineLimit(1) } }.font(.caption).foregroundStyle(.secondary) }
                        if expandedFoundOn.contains(record.id) { FoundOnLinks(urls: record.foundOnURLs) }
                    }.contextMenu { Button("Open in browser") { NSWorkspace.shared.open(record.url) }; Button("Copy URL") { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(record.url.absoluteString, forType: .string) } }
                }
            }
        }
    }
}

/// References are stored while crawling, so a broken target is paired with the
/// HTML page where the optimiser should replace or correct that link.
struct FoundOnLinks: View {
    let urls: [URL]
    @State private var showAll = false
    var body: some View {
        let displayedURLs = showAll ? urls : Array(urls.prefix(1))
        VStack(alignment: .leading, spacing: 2) {
            Text("Found on:").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            ForEach(displayedURLs, id: \.absoluteString) { url in
                HStack(spacing: 5) { Text(url.absoluteString).font(.caption).foregroundStyle(.secondary).lineLimit(1).textSelection(.enabled); URLActions(url: url) }
            }
            if urls.count > 1 {
                Button(showAll ? "Hide source links" : "Show all \(urls.count) source links") { showAll.toggle() }
                    .buttonStyle(.link)
                    .font(.caption)
            }
        }.padding(.leading, 2)
    }
}

struct BacklinksView: View {
    @ObservedObject var model: CrawlViewModel
    @State private var donorFilter = "All donors"
    @State private var anchorFilter = "All anchors"
    @State private var linkFilter = "All links"
    @State private var statusFilter = "Active"

    private var statusScopedLinks: [BacklinkSourceDetail] {
        switch statusFilter {
        case "Lost": return model.backlinkSourceDetails.filter(\.isLost)
        case "All records": return model.backlinkSourceDetails
        default: return model.backlinkSourceDetails.filter { !$0.isLost }
        }
    }
    private var activeLinks: [BacklinkSourceDetail] { model.backlinkSourceDetails.filter { !$0.isLost } }
    private var lostLinks: [BacklinkSourceDetail] { model.backlinkSourceDetails.filter(\.isLost) }

    private var sources: [BacklinkSourceDetail] {
        statusScopedLinks.filter { item in
            let donorMatches = donorFilter == "All donors" || BacklinkClassifier.donorType(for: item).rawValue == donorFilter
            let anchorMatches = anchorFilter == "All anchors" || BacklinkClassifier.anchorType(for: item, target: model.startText).rawValue == anchorFilter
            let linkMatches: Bool
            switch linkFilter {
            case "Dofollow": linkMatches = item.dofollow
            case "Nofollow": linkMatches = !item.dofollow
            case "Broken": linkMatches = item.broken
            default: linkMatches = true
            }
            return donorMatches && anchorMatches && linkMatches
        }
    }

    private var donorCounts: [(String, Int)] {
        BacklinkClassifier.DonorType.allCases.map { type in
            (type.rawValue, statusScopedLinks.filter { BacklinkClassifier.donorType(for: $0) == type }.count)
        }.filter { $0.1 > 0 }
    }

    private var anchorCounts: [(String, Int)] {
        BacklinkClassifier.AnchorType.allCases.map { type in
            (type.rawValue, statusScopedLinks.filter { BacklinkClassifier.anchorType(for: $0, target: model.startText) == type }.count)
        }.filter { $0.1 > 0 }
    }

    private var yearlyHistory: [BacklinkYearSummary] {
        let grouped = Dictionary(grouping: model.backlinkHistory) { String($0.date.prefix(4)) }
        return grouped.compactMap { year, points in
            guard year.count == 4 else { return nil }
            let sorted = points.sorted { $0.date < $1.date }
            return BacklinkYearSummary(year: year, activeAtYearEnd: sorted.last?.backlinks ?? 0, gained: points.reduce(0) { $0 + $1.newBacklinks }, lost: points.reduce(0) { $0 + $1.lostBacklinks }, domainsAtYearEnd: sorted.last?.referringDomains ?? 0)
        }.sorted { $0.year > $1.year }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Backlink Intelligence").font(.title2.weight(.semibold))
                    Text("Donor pages, anchors and practical donor-type classification.").foregroundStyle(.secondary)
                }
                Spacer()
                Button(model.backlinkDrilldownRunning ? "Loading…" : "Load active links & history") {
                    model.loadBacklinkSourceAnalysis()
                }
                .buttonStyle(.borderedProminent)
                .disabled(model.backlinkDrilldownRunning || model.records.isEmpty)
                Button("Import GSC links CSV") { model.importGSCBacklinkCSV() }
                    .disabled(model.backlinkDrilldownRunning || model.gscChromeLinkSyncRunning)
                Button(model.gscChromeLinkSyncRunning ? "Syncing GSC links…" : "Sync GSC links via Chrome") {
                    model.syncGSCBacklinksThroughChrome()
                }
                .disabled(model.backlinkDrilldownRunning || model.gscChromeLinkSyncRunning)
                .help("Exports the Google Search Console Links report through the local ShareSpider Chrome profile, then imports it as a separate comparison dataset.")
            }

            if model.backlinkDrilldownRunning {
                HStack { ProgressView(); Text("DataForSEO is loading active and lost donor records, plus the historical trend. This does not re-crawl your site.").foregroundStyle(.secondary) }
            }
            if model.gscChromeLinkSyncRunning {
                HStack { ProgressView(); Text("Google Search Console Links export is running in the local ShareSpider Chrome profile.").foregroundStyle(.secondary) }
            }

            if model.backlinkSourceDetails.isEmpty {
                ContentUnavailableView(
                    "Load backlink sources",
                    systemImage: "link.badge.plus",
                    description: Text("The analysis separates active links from links explicitly marked as lost by DataForSEO, then adds annual acquisition/loss history. It also uses source URL, anchor, domain rank, follow attribute, spam score and source platform to classify donor pages."))
            } else {
                loadedContent
            }
            if !model.backlinkMessage.isEmpty { Text(model.backlinkMessage).font(.caption).foregroundStyle(.secondary) }
        }
        .padding()
    }

    private var loadedContent: some View {
        let all = model.backlinkSourceDetails
        return VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                MetricPill(label: "Active links", value: "\(activeLinks.count)", accent: .green)
                MetricPill(label: "Lost links", value: "\(lostLinks.count)", accent: lostLinks.isEmpty ? .secondary : .red)
                MetricPill(label: "All-time records", value: "\(all.count)")
                MetricPill(label: "Active domains", value: "\(Set(activeLinks.map(\.sourceDomain)).count)")
                MetricPill(label: "Dofollow active", value: "\(activeLinks.filter(\.dofollow).count)")
                MetricPill(label: "Broken targets", value: "\(activeLinks.filter(\.broken).count)", accent: .red)
            }
            if let importReport = model.gscBacklinkImport {
                let comparison = GSCBacklinkImportService.comparison(gsc: importReport, dataForSEO: model.backlinkSourceDetails)
                GroupBox("Google Search Console comparison") {
                    VStack(alignment: .leading, spacing: 7) {
                        Text("Imported from Search Console: \(comparison.gscDomains) donor domains · \(importReport.importedAt.formatted(date: .abbreviated, time: .shortened))")
                        Text("Confirmed by active DataForSEO domains: \(comparison.confirmedDomains) of \(comparison.dataForSEOActiveDomains) (\(comparison.confirmationPercent)% of DataForSEO active donors).")
                            .fontWeight(.semibold)
                        Text("Google-only donor domains: \(comparison.gscOnlyDomains.count) · DataForSEO-only active donor domains: \(comparison.dataForSEOOnlyDomains.count)")
                            .foregroundStyle(.secondary)
                        if !comparison.gscOnlyDomains.isEmpty {
                            Text("GSC-only examples: \(comparison.gscOnlyDomains.prefix(10).joined(separator: ", "))")
                                .font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                        }
                        Text("Search Console confirms that Google has observed a link; it does not provide active/lost status. Active and lost status remains from DataForSEO.")
                            .font(.caption).foregroundStyle(.secondary)
                    }.frame(maxWidth: .infinity, alignment: .leading)
                }
            } else {
                GroupBox("Google Search Console comparison") {
                    Text("Google does not provide the Links report through its public API. Export “Top linking sites” or “More sample links” in Search Console, then import the CSV here or through MCP. This supplements DataForSEO; it never replaces it.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            historyView
            GroupBox("Donor page type") {
                FlowLayout(spacing: 7) {
                    FilterChip(title: "All donors", count: statusScopedLinks.count, selected: donorFilter == "All donors") { donorFilter = "All donors" }
                    ForEach(donorCounts, id: \.0) { item in
                        FilterChip(title: item.0, count: item.1, selected: donorFilter == item.0) { donorFilter = item.0 }
                    }
                }.frame(maxWidth: .infinity, alignment: .leading)
            }
            HStack(spacing: 12) {
                GroupBox("Record status") {
                    Picker("", selection: $statusFilter) {
                        Text("Active").tag("Active"); Text("Lost").tag("Lost"); Text("All records").tag("All records")
                    }.labelsHidden().frame(width: 140)
                }
                GroupBox("Anchor type") {
                    FlowLayout(spacing: 7) {
                        FilterChip(title: "All anchors", count: statusScopedLinks.count, selected: anchorFilter == "All anchors") { anchorFilter = "All anchors" }
                        ForEach(anchorCounts, id: \.0) { item in
                            FilterChip(title: item.0, count: item.1, selected: anchorFilter == item.0) { anchorFilter = item.0 }
                        }
                    }
                }
                GroupBox("Link attribute") {
                    Picker("", selection: $linkFilter) {
                        Text("All links").tag("All links"); Text("Dofollow").tag("Dofollow"); Text("Nofollow").tag("Nofollow"); Text("Broken").tag("Broken")
                    }.labelsHidden().frame(width: 150)
                }
            }
            Text("\(sources.count) \(statusFilter.lowercased()) source link\(sources.count == 1 ? "" : "s") shown · donor labels use DataForSEO facts plus editable JSON rules.")
                .font(.caption).foregroundStyle(.secondary)
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 8) {
                    ForEach(sources) { item in BacklinkSourceRow(item: item, site: model.startText) }
                }
            }
        }
    }

    private var historyView: some View { BacklinkHistoryView(years: yearlyHistory) }
}

private struct BacklinkSourceRow: View {
    let item: BacklinkSourceDetail
    let site: String
    var body: some View {
        let donorType = BacklinkClassifier.donorType(for: item)
        let anchorType = BacklinkClassifier.anchorType(for: item, target: site)
        VStack(alignment: .leading, spacing: 5) {
            HStack {
                Text(item.sourceDomain.isEmpty ? item.sourceURL : item.sourceDomain).font(.headline).lineLimit(1)
                Spacer()
                Text("DR \(item.domainRank)").monospacedDigit().foregroundStyle(.secondary)
                if item.spamScore > 0 { Text("Spam \(item.spamScore)").monospacedDigit().foregroundStyle(item.spamScore >= 50 ? .red : .secondary) }
            }
            HStack(spacing: 6) {
                Text(item.sourceURL).lineLimit(1).font(.caption)
                if let url = URL(string: item.sourceURL) { URLActions(url: url) }
            }
            if !item.sourceTitle.isEmpty { Text(item.sourceTitle).font(.caption).foregroundStyle(.secondary).lineLimit(1) }
            HStack(spacing: 6) {
                Text(donorType.rawValue).font(.caption.weight(.semibold)).padding(.horizontal, 7).padding(.vertical, 3).background(.blue.opacity(0.12), in: Capsule())
                Text(anchorType.rawValue).font(.caption.weight(.semibold)).padding(.horizontal, 7).padding(.vertical, 3).background(.purple.opacity(0.12), in: Capsule())
                Text(item.isLost ? "Lost" : "Active").font(.caption.weight(.semibold)).padding(.horizontal, 7).padding(.vertical, 3).background((item.isLost ? Color.red : Color.green).opacity(0.14), in: Capsule()).foregroundStyle(item.isLost ? .red : .green)
                Text(item.dofollow ? "Dofollow" : "Nofollow").font(.caption).foregroundStyle(item.dofollow ? .green : .secondary)
                if !item.semanticLocation.isEmpty { Text(item.semanticLocation).font(.caption).foregroundStyle(.secondary) }
                if !item.platformTypes.isEmpty { Text(item.platformTypes.joined(separator: ", ")).font(.caption).foregroundStyle(.secondary) }
            }
            Text(item.anchor.isEmpty ? "Anchor: —" : "Anchor: \(item.anchor)").font(.caption).lineLimit(2)
            if !item.firstSeen.isEmpty || !item.lastSeen.isEmpty {
                Text("First seen: \(item.firstSeen.isEmpty ? "—" : item.firstSeen) · Last seen: \(item.lastSeen.isEmpty ? "—" : item.lastSeen)")
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Text("Target: \(item.targetURL.isEmpty ? site : item.targetURL) · \(BacklinkClassifier.evidence(for: item))").font(.caption).foregroundStyle(item.broken || item.isLost ? .red : .secondary).lineLimit(1)
        }
        .padding(10).frame(maxWidth: .infinity, alignment: .leading)
        .background(.background, in: RoundedRectangle(cornerRadius: 8)).overlay(RoundedRectangle(cornerRadius: 8).stroke(.quaternary))
    }
}

private struct BacklinkYearSummary: Identifiable {
    var year: String
    var activeAtYearEnd: Int
    var gained: Int
    var lost: Int
    var domainsAtYearEnd: Int
    var id: String { year }
}

private struct BacklinkHistoryView: View {
    let years: [BacklinkYearSummary]
    var body: some View {
        if !years.isEmpty {
            GroupBox("Backlink history") {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Year-end active links plus links first seen and explicitly lost during each year. A link remains active regardless of its last-seen date; it moves to Lost only when DataForSEO marks it as removed.")
                        .font(.caption).foregroundStyle(.secondary)
                    ScrollView(.horizontal, showsIndicators: true) {
                        HStack(spacing: 8) {
                            ForEach(years) { year in BacklinkYearCard(year: year) }
                        }
                    }
                }
            }
        }
    }
}

private struct BacklinkYearCard: View {
    let year: BacklinkYearSummary
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(year.year).font(.headline)
            Text("Active: \(year.activeAtYearEnd)").font(.caption)
            Text("+\(year.gained) acquired").font(.caption).foregroundStyle(.green)
            if year.lost == 0 {
                Text("−0 lost").font(.caption).foregroundStyle(.secondary)
            } else {
                Text("−\(year.lost) lost").font(.caption).foregroundStyle(.red)
            }
            Text("Domains: \(year.domainsAtYearEnd)").font(.caption).foregroundStyle(.secondary)
        }
        .padding(9).frame(width: 145, alignment: .leading)
        .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 8))
    }
}

private struct MetricPill: View {
    let label: String; let value: String; var accent: Color = .primary
    var body: some View { VStack(alignment: .leading, spacing: 2) { Text(value).font(.title3.weight(.semibold)).foregroundStyle(accent); Text(label).font(.caption).foregroundStyle(.secondary) }.padding(9).frame(minWidth: 96, alignment: .leading).background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 8)) }
}

private struct FilterChip: View {
    let title: String; let count: Int; let selected: Bool; let action: () -> Void
    var body: some View { Button(action: action) { Text("\(title) \(count)").font(.caption.weight(selected ? .semibold : .regular)) }.buttonStyle(.borderedProminent).tint(selected ? .accentColor : .gray.opacity(0.55)).controlSize(.small) }
}

/// Small wrapping layout for compact donor and anchor filters.
private struct FlowLayout: Layout {
    var spacing: CGFloat = 6
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? 800
        var x: CGFloat = 0, y: CGFloat = 0, rowHeight: CGFloat = 0
        for view in subviews { let size = view.sizeThatFits(.unspecified); if x > 0 && x + size.width > width { x = 0; y += rowHeight + spacing; rowHeight = 0 }; x += size.width + spacing; rowHeight = max(rowHeight, size.height) }
        return CGSize(width: width, height: y + rowHeight)
    }
    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, rowHeight: CGFloat = 0
        for view in subviews { let size = view.sizeThatFits(.unspecified); if x > bounds.minX && x + size.width > bounds.maxX { x = bounds.minX; y += rowHeight + spacing; rowHeight = 0 }; view.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size)); x += size.width + spacing; rowHeight = max(rowHeight, size.height) }
    }
}

struct AuditView: View {
    @ObservedObject var model: CrawlViewModel
    @State private var enlargedScreenshot: VisualAuditResult?
    var body: some View {
        AnyView(auditContent)
    }

    private var auditContent: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                HStack {
                    VStack(alignment: .leading) {
                        Text("Audit").font(.title2.weight(.semibold))
                        Text("Technical audit and AI-assisted analysis of crawl, backlink and Search Console data.").foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button(model.auditRunning ? "Auditing…" : "Run Audit") { model.runAudit() }.buttonStyle(.borderedProminent).disabled(model.auditRunning || model.records.isEmpty)
                    Button(model.aiAuditRunning ? "Running AI Audit…" : "AI Helper") { model.runAIAudit() }.buttonStyle(.borderedProminent).disabled(model.aiAuditRunning || model.records.isEmpty)
                    Button("Reset results", role: .destructive) { model.resetAuditAndCrawl() }
                        .disabled(model.auditRunning || model.aiAuditRunning || model.visualAuditRunning || model.pageSpeedRunning)
                    if let report = model.auditReport {
                        Button("Export client PDF") {
                            _ = ClientPDFReport.export(report: report, records: model.records, issues: model.issues, approvedVisualIDs: model.approvedVisualIssueIDs, startURL: model.startText)
                        }.disabled(model.auditRunning)
                        HStack(spacing: 0) {
                            Button("Export technical tasks") {
                                model.exportTechnicalTasks(severity: .highMedium)
                            }
                            Menu {
                                ForEach(TechnicalTaskPDFReport.Severity.allCases) { severity in
                                    Button("\(severity.rawValue) priority") {
                                        model.exportTechnicalTasks(severity: severity)
                                    }
                                }
                            } label: {
                                Image(systemName: "chevron.down")
                            }
                            .menuStyle(.borderlessButton)
                            .frame(width: 27)
                        }
                        .help("Save a developer / SEO specialist task brief. The main button exports High + Medium tasks; the arrow selects another priority.")
                        .disabled(model.auditRunning || model.records.isEmpty)
                    }
                    if model.aiAuditReport != nil {
                        Button("Export AI Audit PDF") { model.exportAIAuditPDF() }.disabled(model.aiAuditRunning)
                    }
                }
                aiAuditResults
                if let report = model.auditReport {
                    GroupBox("Domain profile") {
                        VStack(alignment: .leading, spacing: 6) {
                            HStack { Text("Ahrefs Domain Rating").fontWeight(.semibold); Spacer(); if let dr = report.siteProfile.domainRating { Text(String(format: "%.1f / 100", dr)).font(.title3.weight(.bold)) } else { Text("Unavailable").foregroundStyle(.orange) } }
                            if !report.siteProfile.domainRatingError.isEmpty { Text(report.siteProfile.domainRatingError).font(.caption).foregroundStyle(.secondary) }
                            Text("Source: Domain Rating by Ahrefs").font(.caption2).foregroundStyle(.secondary)
                            Divider()
                            Text("Primary server IP: \(report.siteProfile.ipAddresses.first ?? "could not be resolved")")
                            Divider()
                            HStack { Text("CMS").fontWeight(.semibold); Spacer(); Text(report.siteProfile.cmsName) }
                            if report.siteProfile.cmsName == "Unknown" { Text("No CMS signature matched. Add or adjust signatures in cms-detection-rules.json.").font(.caption).foregroundStyle(.secondary) }
                            else { Text("Confidence \(Int(report.siteProfile.cmsConfidence * 100))% · \(report.siteProfile.cmsEvidence.joined(separator: ", "))").font(.caption).foregroundStyle(.secondary) }
                        }
                    }
                    GroupBox("External Link Profile · DataForSEO") {
                        if let backlinks = model.backlinkReport {
                            let profile = backlinks.domain
                            let eligible = model.records.filter { $0.isGSCEligible }
                            let linked = eligible.filter { $0.backlinkChecked && $0.backlinks > 0 }
                            let unlinked = eligible.filter { $0.backlinkChecked && $0.backlinks == 0 }
                            let lostEquity = model.records.filter { $0.backlinks > 0 && (($0.statusCode ?? 0) / 100 >= 3 || $0.indexability == "Noindex") }
                            VStack(alignment: .leading, spacing: 6) {
                                HStack { Text("Domain Rank \(profile.rank)"); Divider().frame(height: 16); Text("\(profile.backlinks) backlinks"); Divider().frame(height: 16); Text("\(profile.referringDomains) referring domains"); Divider().frame(height: 16); Text("Spam score \(profile.spamScore)") }
                                Text("Dofollow \(profile.dofollowBacklinks) · Nofollow \(profile.nofollowBacklinks) · Broken backlinks \(profile.brokenBacklinks) · Referring IPs \(profile.referringIPs) · Subnets \(profile.referringSubnets)").foregroundStyle(.secondary)
                                Divider()
                                Text("\(unlinked.count) of \(eligible.count) indexable self-canonical pages have no detected external backlinks (\(eligible.isEmpty ? 0 : Int(Double(unlinked.count) / Double(eligible.count) * 100))%).").fontWeight(.semibold)
                                if !lostEquity.isEmpty { Text("Lost link equity: \(lostEquity.count) non-preferred / unavailable URLs still receive \(lostEquity.reduce(0) { $0 + $1.backlinks }) backlinks.").foregroundStyle(.orange) }
                                let byType = Dictionary(grouping: eligible, by: \.displayPageType).map { (type: $0.key, pages: $0.value.count, backlinks: $0.value.reduce(0) { $0 + $1.backlinks }, without: $0.value.filter { $0.backlinkChecked && $0.backlinks == 0 }.count) }.sorted { $0.backlinks > $1.backlinks }
                                if !byType.isEmpty { Text("Distribution by page type").font(.caption.weight(.semibold)); ForEach(byType, id: \.type) { item in Text("\(item.type): \(item.backlinks) backlinks · \(item.pages) pages · \(item.without) without links").font(.caption).foregroundStyle(.secondary) } }
                                let examples = unlinked.prefix(10)
                                if !examples.isEmpty { Divider(); Text("Examples without backlinks (up to 10)").font(.caption.weight(.semibold)); ForEach(Array(examples), id: \.id) { record in HStack { Text(record.url.absoluteString).lineLimit(1); URLActions(url: record.url) } } }
                                Text("Updated \(backlinks.fetchedAt.formatted(date: .abbreviated, time: .shortened)) · \(backlinks.apiRequests) API request(s) · cached for 7 days").font(.caption).foregroundStyle(.secondary)
                            }
                        } else {
                            VStack(alignment: .leading, spacing: 6) { Text("Backlink data has not been loaded for this crawl.").foregroundStyle(.secondary); Button(model.backlinkRunning ? "Loading Backlinks…" : "Refresh Backlink Data") { model.refreshBacklinkData() }.disabled(model.backlinkRunning || model.records.isEmpty); Text(model.backlinkMessage).font(.caption).foregroundStyle(.secondary) }
                        }
                    }
                    SitemapAuditView(sitemap: report.sitemap)
                    HreflangAuditView(results: report.hreflang)
                    GroupBox("Domain mirrors and redirects") {
                        VStack(alignment: .leading) {
                            ForEach(report.mirrors) { result in
                                HStack { Text(result.source.absoluteString); URLActions(url: result.source); Spacer(); Text(mirrorCode(result)); Text("→ \(result.finalURL?.absoluteString ?? result.error)").foregroundStyle(.secondary).lineLimit(1); if let final = result.finalURL { URLActions(url: final) } }
                            }
                            ForEach(report.findings.filter { $0.title.localizedCaseInsensitiveContains("redirect") }) { finding in
                                Divider()
                                Text("\(finding.severity) · \(finding.title): \(finding.detail)").foregroundStyle(finding.severity == "High" ? .red : .orange)
                            }
                        }
                    }
                    GroupBox("robots.txt") {
                        let robots = report.robots
                        VStack(alignment: .leading, spacing: 5) {
                            if !robots.available { Text("robots.txt is unavailable or could not be read: \(robots.error)").foregroundStyle(.red) }
                            else {
                                Text("Sections for crawlers: \(robots.sections) · effective directives: \(robots.effectiveRules)")
                                Text("Google: \(robots.googleRules) rules (\(robots.googleRuleSource))")
                                Text("Bing: \(robots.bingRules) rules (\(robots.bingRuleSource)) · Yandex: \(robots.yandexRules) rules (\(robots.yandexRuleSource))")
                                Text("Blocked discovered URLs: \(robots.blockedURLCount)")
                                ForEach(robots.blockingRules) { rule in
                                    Text("\(rule.rule) — \(rule.urlCount) URL\(rule.urlCount == 1 ? "" : "s")").font(.caption).foregroundStyle(.secondary)
                                }
                                if robots.blocksSite { Text("CRITICAL: robots.txt contains Disallow: / for at least one selected crawler. Check the Google, Bing and Yandex rule sources above.").foregroundStyle(.red) }
                                else if robots.isIneffective { Text("robots.txt is not optimised: it contains only allow-all directives (Allow: /) and/or empty Disallow directives. Sitemap links do not count as indexing rules. Add meaningful Allow/Disallow rules for technical areas.").foregroundStyle(.red) }
                                else { Text("robots.txt contains effective crawler directives.").foregroundStyle(.green) }
                                if robots.commentLines > 0 { Text("Maintenance note: \(robots.commentLines) comment line(s) (#) found. Remove outdated comments and duplicate allow-all sections to keep robots.txt concise and easy to maintain.").foregroundStyle(.orange) }
                            }
                        }
                    }
                    GroupBox("Google Search Console URL inspection") {
                        let inspected = model.records.filter { $0.searchConsoleIndexStatus != "Not checked" && $0.searchConsoleIndexStatus != "Unavailable" }
                        let robotsBlocked = inspected.filter { $0.searchConsoleRobotsStatus == "Blocked" }
                        let noindex = inspected.filter { $0.searchConsoleNoindexStatus.hasPrefix("noindex") }
                        let mobileIssues = inspected.filter { !$0.searchConsoleMobileIssues.isEmpty }
                        VStack(alignment: .leading, spacing: 6) {
                            if inspected.isEmpty {
                                Text("No URL Inspection data yet. Open URLs and choose Fetch Search Console after the crawl.").foregroundStyle(.secondary)
                            } else {
                                Text("Inspected crawl URLs: \(inspected.count) · Indexed: \(inspected.filter { $0.searchConsoleIndexStatus == "Indexed" }.count) · Excluded: \(inspected.filter { $0.searchConsoleIndexStatus == "Not indexed" }.count)")
                                Text("Blocked by Google robots.txt: \(robotsBlocked.count) · Google noindex: \(noindex.count) · Google mobile-usability issues: \(mobileIssues.count)")
                                gscExamples("Blocked by Google robots.txt", robotsBlocked) { $0.searchConsoleRobotsStatus }
                                gscExamples("noindex detected by Google", noindex) { $0.searchConsoleNoindexStatus }
                                gscExamples("Google mobile-usability issues", mobileIssues) { $0.searchConsoleMobileIssues.joined(separator: "; ") }
                            }
                        }
                    }
                    GroupBox("Google Search Console · site-wide Page indexing") {
                        VStack(alignment: .leading, spacing: 6) {
                            if let site = model.gscSiteReport {
                                Text("Last successful Google update: \(site.importedAt.formatted(date: .abbreviated, time: .shortened)) · \(site.total) URLs reported by Google.")
                                ForEach(site.metrics) { metric in
                                    HStack { Text(metric.label); Spacer(); Text("\(metric.count)").fontWeight(.semibold) }
                                }
                                Text("This is Google’s view of the property as a whole, including URLs the crawl never discovered. For matching URLs, the Issues panel also shows the current ShareSpider response so stale Google findings are clear.").font(.caption).foregroundStyle(.secondary)
                            } else { Text("No Page Indexing report received yet. Use Sync GSC Page Indexing in URLs; ShareSpider opens its dedicated signed-in Chrome profile and automatically imports the report.").foregroundStyle(.secondary) }
                        }
                    }
                    GroupBox("Google Search Console · mobile Core Web Vitals") {
                        VStack(alignment: .leading, spacing: 6) {
                            if let report = model.gscCoreWebVitalsReport {
                                Text("Last successful Google update: \(report.importedAt.formatted(date: .abbreviated, time: .shortened))")
                                ForEach(["Poor", "Needs improvement"], id: \.self) { group in
                                    let metrics = report.metrics.filter { $0.group == group }
                                    if !metrics.isEmpty {
                                        Text(group).font(.headline).foregroundStyle(group == "Poor" ? .red : .orange)
                                        ForEach(metrics) { metric in HStack { Text(metric.label); Spacer(); Text("\(metric.count)").fontWeight(.semibold) } }
                                    }
                                }
                                Text("Mobile field-data groups are imported from Google Search Console; click the matching Overview metric to inspect any URL samples Google provides.").font(.caption).foregroundStyle(.secondary)
                            } else {
                                Text("No mobile Core Web Vitals report received yet. Use Sync GSC Core Web Vitals in URLs.").foregroundStyle(.secondary)
                            }
                        }
                    }
                    GroupBox("Google Search Console · organic visibility (last 7 complete days)") {
                        let performance = model.records.filter { $0.isGSCEligible && $0.searchConsolePerformanceChecked }
                        VStack(alignment: .leading, spacing: 6) {
                            if performance.isEmpty {
                                Text("No Search Analytics data yet. Fetch Search Console in URLs; only canonical HTML pages are sent to Google.").foregroundStyle(.secondary)
                            } else {
                                Text("Visible in Top 10: \(performance.filter { $0.searchConsoleQueriesTop10 > 0 }.count) · With clicks: \(performance.filter { $0.searchConsoleClicks7d > 0 }.count) · Without clicks: \(performance.filter { $0.searchConsoleClicks7d == 0 }.count)")
                                Text("Without Top 20 visibility: \(performance.filter { $0.searchConsoleQueryCount > 0 && $0.searchConsoleQueriesTop20 == 0 }.count) · Without search queries: \(performance.filter { $0.searchConsoleQueryCount == 0 }.count)").foregroundStyle(.secondary)
                                let types = Dictionary(grouping: performance, by: \.displayPageType).map { (type: $0.key, clicks: $0.value.reduce(0) { $0 + $1.searchConsoleClicks7d }) }.sorted { $0.clicks > $1.clicks }
                                if !types.isEmpty { Text("Traffic by page type: " + types.map { "\($0.type) \($0.clicks) clicks" }.joined(separator: " · ")).font(.caption).foregroundStyle(.secondary) }
                                let top = performance.filter { $0.searchConsoleClicks7d > 0 }.sorted { $0.searchConsoleClicks7d > $1.searchConsoleClicks7d }.prefix(10)
                                if !top.isEmpty {
                                    Divider(); Text("Top clicked pages").font(.caption.weight(.semibold))
                                    ForEach(Array(top), id: \.id) { record in HStack { Text(record.url.absoluteString).lineLimit(1); URLActions(url: record.url); Spacer(); Text("\(record.searchConsoleClicks7d) clicks · \(record.searchConsoleQueriesTop10) Top 10 queries").foregroundStyle(.secondary) } }
                                }
                                gscExamples("Pages without clicks", performance.filter { $0.searchConsoleClicks7d == 0 }) { "\($0.searchConsoleQueryCount) query / queries" }
                                gscExamples("Pages without Top 20 visibility", performance.filter { $0.searchConsoleQueryCount > 0 && $0.searchConsoleQueriesTop20 == 0 }) { _ in "best position is past Top 20" }
                                gscExamples("Pages without search queries", performance.filter { $0.searchConsoleQueryCount == 0 }) { _ in "no Search Analytics query in the last 7 complete days" }
                            }
                        }
                    }
                    GroupBox("Analytics") { VStack(alignment: .leading, spacing: 4) { Text("Analytics code detected on \(report.analyticsPages) of \(report.totalHTMLPages) HTML pages."); Text("Detected IDs: \(report.analyticsIDs.isEmpty ? "not found" : report.analyticsIDs.sorted().joined(separator: ", ")).").foregroundStyle(.secondary); Text("Detection is based on the page HTML (gtag, dataLayer and Google tag scripts); it does not confirm that analytics events are successfully sent.").font(.caption).foregroundStyle(.secondary) } }
                    GroupBox("Technical findings") {
                        VStack(alignment: .leading, spacing: 9) {
                            ForEach(report.findings.filter { !$0.title.localizedCaseInsensitiveContains("redirect") }) { finding in
                                VStack(alignment: .leading, spacing: 3) {
                                    Text("\(finding.severity) · \(finding.title)").fontWeight(.semibold).foregroundStyle(finding.severity == "High" ? .red : finding.severity == "Medium" ? .orange : .secondary)
                                    Text(finding.detail).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.vertical, 3)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    if !model.issues.isEmpty {
                        VStack(alignment: .leading, spacing: 12) {
                            Text("Crawl issues").font(.title3.weight(.semibold))
                            Text("Problems found during crawling, written for a client report. Each item includes representative affected pages.").foregroundStyle(.secondary)
                            ForEach(model.issues) { issue in
                                AuditIssueCard(issue: issue, records: model.records)
                            }
                        }
                        AuditIssueSegmentation(records: model.records, issues: model.issues)
                    }
                    GroupBox("Site setup and system duplicates") { Text(clientSummary(report)) }
                    GroupBox("PageSpeed Insights") {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Checks only the homepage and one representative internal page. Requests run sequentially, wait between calls and are cached.").foregroundStyle(.secondary)
                            Button(model.pageSpeedRunning ? "Checking…" : "Run PageSpeed Insights") { model.runPageSpeed() }.disabled(model.pageSpeedRunning)
                            ForEach(model.pageSpeedResults) { item in HStack { Text(item.strategy.capitalized).font(.caption.weight(.semibold)).padding(.horizontal, 6).padding(.vertical, 3).background(.quaternary).clipShape(Capsule()); Text(item.url).lineLimit(1); if let url = URL(string: item.url) { URLActions(url: url) }; Spacer(); if let score = item.score { Text("Performance \(score)"); Text("LCP \(item.lcp) · CLS \(item.cls)").foregroundStyle(.secondary) } else { Text(item.error).foregroundStyle(.orange) } } }
                        }
                    }
                    GroupBox("Visual Audit · Safari / WebKit Compatibility") {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("By default one URL is inspected. Its Desktop 1440×900 and Mobile 390×844 renders are divided into viewport blocks; every block receives a Local AI verdict. Review and tick only confirmed defects; those selections are prepared for the future PDF audit.").foregroundStyle(.secondary)
                            Button(model.visualAuditRunning ? "Rendering…" : "Run Visual Audit") { model.runVisualAudit() }.disabled(model.visualAuditRunning || model.records.isEmpty)
                            if model.visualAuditRunning {
                                HStack(spacing: 8) {
                                    ProgressView().controlSize(.small)
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(model.visualAuditProgress?.description ?? "Preparing visual audit…").font(.caption.weight(.semibold))
                                        if let progress = model.visualAuditProgress {
                                            Text(progress.url.absoluteString).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                                        }
                                    }
                                }
                                .padding(9)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .background(.quaternary)
                                .clipShape(RoundedRectangle(cornerRadius: 8))
                            }
                            if !model.visualAuditResults.isEmpty {
                                let total = model.visualAuditResults.reduce(0) { $0 + $1.blocks.count }
                                Text("\(total) visual blocks analysed · \(model.approvedVisualIssueIDs.count) confirmed for future PDF").font(.caption).foregroundStyle(.secondary)
                                LazyVStack(alignment: .leading, spacing: 12) {
                                    ForEach(model.visualAuditResults) { result in
                                        if !result.comparisonSummary.isEmpty { Text("Desktop ↔ Mobile: \(result.comparisonSummary)").font(.caption).padding(10).background(.quaternary).clipShape(RoundedRectangle(cornerRadius: 8)) }
                                        ForEach(result.blocks) { block in
                                            VisualBlockCard(result: result, block: block, approvedIDs: model.approvedVisualIssueIDs) { id, value in model.setVisualIssueApproved(id, value) }
                                        }
                                    }
                                }
                            }
                        }
                    }
                } else {
                    ContentUnavailableView("Run technical audit", systemImage: "checklist", description: Text("First crawl the site, then press Run Audit."))
                }
            }.padding()
        }
    }
    @ViewBuilder
    private var aiAuditResults: some View {
        if model.aiAuditRunning {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) { ProgressView(); Text(stageLabel(model.aiAuditStage)).foregroundStyle(.secondary) }
                stageRow("Link Profile Analysis", stage: .linkAnalysis)
                stageRow("Technical SEO Analysis", stage: .technicalAnalysis)
                stageRow("GSC Analysis", stage: .gscAnalysis)
                stageRow("Executive Summary", stage: .executiveSummary)
            }.padding()
        }
        if let report = model.aiAuditReport {
            GroupBox("Executive summary") { Text(report.executiveSummary).fontWeight(.bold).frame(maxWidth: .infinity, alignment: .leading) }
            HStack(spacing: 10) {
                AIAuditSummaryCard(title: "Crawl", detail: "\(report.crawlSummary.totalURLs) URLs · \(report.crawlSummary.errorCount) errors\n\(report.crawlSummary.missingTitles) missing titles")
                AIAuditSummaryCard(title: "Backlinks", detail: "DR \(report.backlinkSummary.domainRank) · \(report.backlinkSummary.totalBacklinks) links\n\(report.backlinkSummary.referringDomains) referring domains")
                AIAuditSummaryCard(title: "Search Console", detail: report.searchConsoleSummary.available ? "\(report.searchConsoleSummary.indexedPages) indexed · \(report.searchConsoleSummary.notIndexedPages) not indexed\n\(report.searchConsoleSummary.clicks7d) clicks · \(report.searchConsoleSummary.impressions7d) impressions" : "Unavailable\n\(report.searchConsoleSummary.unavailableReason)")
            }
            GroupBox("Анализ ссылочного профиля") { Text(report.backlinkAnalysis).frame(maxWidth: .infinity, alignment: .leading) }
            GroupBox("Технические ошибки") { Text(report.technicalAnalysis).frame(maxWidth: .infinity, alignment: .leading) }
            GroupBox("Ошибки Search Console") { Text(report.searchConsoleAnalysis).frame(maxWidth: .infinity, alignment: .leading) }
            if !report.findings.isEmpty { Text("Findings").font(.title3.weight(.semibold)) }
            ForEach(report.findings) { finding in
                GroupBox {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("\(finding.severity) · \(finding.category)").font(.caption.weight(.bold)).foregroundStyle(finding.severity == "High" ? .red : finding.severity == "Medium" ? .orange : .secondary)
                        Text(finding.title).font(.headline); Text(finding.summary).foregroundStyle(.secondary)
                        ForEach(finding.affectedURLs.prefix(5), id: \.self) { text in if let url = URL(string: text) { Link(text, destination: url).font(.caption).lineLimit(1) } }
                        Text("Recommendation: \(finding.recommendation)").font(.subheadline.weight(.medium))
                    }.frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        } else if !model.aiAuditRunning { ContentUnavailableView("Use AI Helper", systemImage: "sparkles", description: Text("First crawl the site, then run the AI audit. It remains useful without an API key using its built-in fallback.")) }
    }
    @ViewBuilder
    private func stageRow(_ title: String, stage: AIAuditStage) -> some View {
        let current = model.aiAuditStage == stage
        let done = stageOrderIndex(model.aiAuditStage) > stageOrderIndex(stage)
        HStack(spacing: 8) {
            if done { Image(systemName: "checkmark.circle.fill").foregroundStyle(.green) }
            else if current { ProgressView().controlSize(.small) }
            else { Image(systemName: "circle").foregroundStyle(.tertiary) }
            Text(title).foregroundStyle(current ? .primary : .secondary)
        }
    }
    private func stageOrderIndex(_ stage: AIAuditStage) -> Int {
        switch stage { case .notStarted, .collectingData: 0; case .linkAnalysis: 1; case .technicalAnalysis: 2; case .gscAnalysis: 3; case .codexAnalysis, .verification, .executiveSummary: 4; case .complete: 5 }
    }
    private func stageLabel(_ stage: AIAuditStage) -> String {
        switch stage { case .collectingData: "Collecting audit data…"; case .linkAnalysis: "Analyzing link profile…"; case .technicalAnalysis: "Analyzing technical SEO…"; case .gscAnalysis: "Analyzing Search Console…"; case .executiveSummary: "Writing executive summary…"; case .complete: "AI audit complete"; default: "Preparing AI audit…" }
    }
    @ViewBuilder
    private func gscExamples(_ title: String, _ records: [CrawlRecord], detail: @escaping (CrawlRecord) -> String) -> some View {
        if !records.isEmpty {
            VStack(alignment: .leading, spacing: 2) {
                Text("\(title) · \(records.count)").font(.caption.weight(.semibold)).foregroundStyle(.orange)
                ForEach(records.prefix(10)) { record in
                    HStack(spacing: 5) {
                        Text(record.url.absoluteString).font(.caption).lineLimit(1)
                        URLActions(url: record.url)
                        Text(detail(record)).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                }
            }
        }
    }
    private func clientSummary(_ report: AuditReport) -> String { let mirror = report.findings.contains { $0.title.contains("mirror") } ? "Mirror configuration needs attention." : "The primary site mirror is configured consistently."; let duplicates = report.findings.contains { $0.title.contains("duplicate") } ? " Indexable technical URLs were found; configure redirects and remove them from internal links and sitemaps." : " No indexable technical duplicates were detected in crawled URLs."; return mirror + duplicates }
    private func mirrorCode(_ result: MirrorResult) -> String { guard !result.redirectStatuses.isEmpty else { return result.status.map(String.init) ?? "No response" }; return result.redirectStatuses.map(String.init).joined(separator: " → ") + " → " + (result.status.map(String.init) ?? "?") }
}

private struct AIAuditSummaryCard: View {
    let title: String
    let detail: String
    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title.uppercased()).font(.caption.weight(.bold)).foregroundStyle(.secondary)
            Text(detail).font(.subheadline).fixedSize(horizontal: false, vertical: true)
        }
        .padding(10).frame(maxWidth: .infinity, minHeight: 76, alignment: .leading)
        .background(.quaternary.opacity(0.45), in: RoundedRectangle(cornerRadius: 8))
    }
}

private struct SitemapAuditView: View {
    let sitemap: SitemapAudit
    var body: some View {
        GroupBox("XML sitemap analysis") {
            VStack(alignment: .leading, spacing: 6) {
                if !sitemap.error.isEmpty { Text(sitemap.error).foregroundStyle(.red) }
                else {
                    Text("Found \(sitemap.roots.count) root sitemap\(sitemap.roots.count == 1 ? "" : "s") · \(sitemap.documents.count) XML file\(sitemap.documents.count == 1 ? "" : "s") · \(sitemap.urls.count) page URL\(sitemap.urls.count == 1 ? "" : "s")")
                    if sitemap.nestedCount > 0 { Text("Multi-level structure: \(sitemap.nestedCount) sitemap index file\(sitemap.nestedCount == 1 ? "" : "s") was expanded recursively.").foregroundStyle(.secondary) }
                    ForEach(sitemap.documents) { SitemapDocumentRow(document: $0) }
                    let multiple = sitemap.urlSources.filter { $0.value.count > 1 }
                    if !multiple.isEmpty { Text("Warning: \(multiple.count) URL(s) occur in more than one sitemap.").foregroundStyle(.orange) }
                    if sitemap.documents.contains(where: { $0.urlCount > 50_000 }) { Text("Warning: an XML sitemap has more than 50,000 URLs.").foregroundStyle(.orange) }
                    if sitemap.documents.contains(where: { $0.byteSize > 50 * 1_024 * 1_024 }) { Text("Warning: an XML sitemap is larger than 50 MB.").foregroundStyle(.orange) }
                    Divider()
                    SitemapSummaryView(summary: sitemap.summary)
                    if !sitemap.notCrawled.isEmpty {
                        Text("URLs in sitemap but not found in crawl: \(sitemap.notCrawled.count)").foregroundStyle(.orange)
                        ForEach(Array(sitemap.notCrawled.prefix(10)), id: \.self) { value in Text("• \(value)").font(.caption).lineLimit(1) }
                    }
                    let broken = sitemap.checks.filter { !$0.error.isEmpty || (($0.status ?? 0) / 100 != 2) }
                    if !broken.isEmpty {
                        Text("Broken sitemap URLs (direct check): \(broken.count)").foregroundStyle(.red)
                        ForEach(broken.prefix(10)) { item in HStack { Text("• \(item.url.absoluteString)").font(.caption).lineLimit(1); URLActions(url: item.url); Spacer(); Text(item.status.map(String.init) ?? item.error).font(.caption).foregroundStyle(.red) } }
                    }
                }
            }
        }
    }
}

private struct SitemapSummaryView: View {
    let summary: SitemapSummary
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Sitemap summary").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            HStack(spacing: 14) {
                metric("Non-canonical", summary.nonCanonical, color: .orange)
                metric("Broken", summary.broken, color: .red)
                metric("Redirects", summary.redirects, color: .orange)
                metric("Missing from sitemap", summary.missingFromSitemap, color: .orange)
                metric("Isolated in sitemap", summary.isolated, color: .orange)
            }
        }
    }
    private func metric(_ title: String, _ value: Int, color: Color) -> some View {
        VStack(alignment: .leading, spacing: 1) { Text("\(value)").font(.title3.weight(.bold)).foregroundStyle(value == 0 ? .green : color); Text(title).font(.caption2).foregroundStyle(.secondary) }
    }
}

private struct SitemapDocumentRow: View {
    let document: SitemapDocument
    var body: some View {
        HStack(alignment: .top) {
            Text(document.type == "sitemapindex" ? "Index" : "URL set").font(.caption.weight(.semibold)).padding(.horizontal, 6).padding(.vertical, 3).background(.quaternary).clipShape(Capsule())
            Text(document.url.absoluteString).lineLimit(1); URLActions(url: document.url); Spacer()
            if document.error.isEmpty {
                Text("\(document.urlCount) URLs · \(ByteCountFormatter.string(fromByteCount: Int64(document.byteSize), countStyle: .file))").font(.caption).foregroundStyle(.secondary)
            } else {
                Text(document.error).font(.caption).foregroundStyle(.red)
            }
        }
    }
}

private struct HreflangAuditView: View {
    let results: [HreflangResult]
    @State private var showAllChecks = false
    var body: some View {
        GroupBox("hreflang validation") {
            if results.isEmpty { Text("No hreflang alternate links were found on crawled HTML pages.").foregroundStyle(.secondary) }
            else {
                VStack(alignment: .leading, spacing: 6) {
                    let problems = results.filter { isProblem($0) }
                    HStack(spacing: 14) {
                        Text("Checked: \(results.count)")
                        Text("Problems: \(problems.count)").foregroundStyle(problems.isEmpty ? .green : .orange)
                        Text("Final 200: \(results.count - results.filter { ($0.status ?? 0) / 100 != 2 || $0.finalURL != $0.target }.count)").foregroundStyle(.secondary)
                        Text("Missing return links: \(results.filter { $0.returnLinkCheckable && !$0.reciprocal }.count)").foregroundStyle(.secondary)
                    }.font(.caption)
                    if problems.isEmpty { Text("All checked hreflang targets are final 200 URLs and have valid return links.").foregroundStyle(.green) }
                    else {
                        Text("Problem examples (up to 10)").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                        ForEach(problems.prefix(10)) { result in HreflangResultRow(result: result) }
                        if problems.count > 10 { Text("and \(problems.count - 10) more problem(s)").font(.caption).foregroundStyle(.secondary) }
                    }
                    DisclosureGroup("Show all \(results.count) checked hreflang links", isExpanded: $showAllChecks) {
                        LazyVStack(alignment: .leading, spacing: 6) { ForEach(results) { HreflangResultRow(result: $0) } }
                    }.font(.caption)
                }
            }
        }
    }
    private func isProblem(_ result: HreflangResult) -> Bool { (result.status ?? 0) / 100 != 2 || result.finalURL != result.target || (result.returnLinkCheckable && !result.reciprocal) || !result.validCode || !result.selfReference || result.targetNoindex || result.duplicateCode || result.conflict || !result.languageMatches }
}

private struct HreflangResultRow: View {
    let result: HreflangResult
    private var problem: Bool { (result.status ?? 0) / 100 != 2 || result.finalURL != result.target || (result.returnLinkCheckable && !result.reciprocal) || !result.validCode || !result.selfReference || result.targetNoindex || result.duplicateCode || result.conflict || !result.languageMatches }
    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack { Text(result.code).font(.caption.weight(.bold)).padding(.horizontal, 6).padding(.vertical, 3).background(.quaternary).clipShape(Capsule()); Text(result.target.absoluteString).lineLimit(1); URLActions(url: result.target); Spacer(); Text(result.status.map(String.init) ?? "Error").foregroundStyle(problem ? .red : .green) }
            Text("Source: \(result.source.absoluteString) · \(result.returnLinkCheckable ? (result.reciprocal ? "return link found" : "return link missing") : "return link not verified")\(result.selfReference ? " · self-reference found" : " · self-reference missing")\(!result.validCode ? " · invalid language/region code" : "")\(result.duplicateCode ? " · duplicate code" : "")\(result.conflict ? " · conflicting target" : "")\(result.targetNoindex ? " · target noindex" : "")\(!result.languageMatches ? " · html lang \(result.targetLanguage) differs from hreflang" : "")\(result.finalURL != result.target ? " · redirects to \(result.finalURL?.absoluteString ?? result.error)" : "")").font(.caption).foregroundStyle(problem ? .orange : .secondary).lineLimit(2)
        }
    }
}

struct VisualFindingCard: View {
    let result: VisualAuditResult
    let issue: VisualIssue
    let approved: Bool
    let setApproved: (Bool) -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            Group {
                if let image = NSImage(contentsOfFile: issue.evidencePath.isEmpty ? result.previewPath : issue.evidencePath) {
                    Image(nsImage: image).resizable().scaledToFit().frame(width: 280, height: 190).background(Color.black.opacity(0.04))
                } else {
                    ContentUnavailableView("Screenshot unavailable", systemImage: "photo")
                        .frame(width: 280, height: 190)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 8))

            VStack(alignment: .leading, spacing: 7) {
                HStack { Text(issue.type).font(.headline).foregroundStyle(issue.source == "Local model" ? .red : .orange); Spacer(); Toggle("Include in PDF", isOn: Binding(get: { approved }, set: setApproved)).toggleStyle(.checkbox).controlSize(.small) }
                Text(issue.detail).fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 6) { Text(viewportLabel).font(.caption.weight(.semibold)).padding(.horizontal, 7).padding(.vertical, 3).background(.quaternary).clipShape(Capsule()); Text(issue.source).font(.caption).foregroundStyle(.secondary) }
                HStack(alignment: .firstTextBaseline) { Text(result.url.absoluteString).font(.caption).lineLimit(2).textSelection(.enabled); URLActions(url: result.url) }
                if !issue.evidencePath.isEmpty { Button("Open block screenshot") { let url = URL(fileURLWithPath: issue.evidencePath); if !NSWorkspace.shared.open(url) { NSWorkspace.shared.activateFileViewerSelecting([url]) } }.controlSize(.small) }
            }
        }
        .padding(12)
        .background(Color.white)
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(approved ? Color.accentColor : Color.gray.opacity(0.25), lineWidth: approved ? 2 : 1))
    }
    private var viewportLabel: String { result.viewport == "Mobile" ? "Mobile · 390 × 844" : "Desktop · 1440 × 900" }
}

struct VisualBlockCard: View {
    let result: VisualAuditResult
    let block: VisualBlock
    let approvedIDs: Set<UUID>
    let setApproved: (UUID, Bool) -> Void
    private var needsReview: Bool { block.verdict == "Needs review" }
    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            if let image = NSImage(contentsOfFile: block.screenshotPath) {
                Image(nsImage: image).resizable().scaledToFit().frame(width: 300, height: 220).background(Color.black.opacity(0.04)).clipShape(RoundedRectangle(cornerRadius: 8))
            }
            VStack(alignment: .leading, spacing: 7) {
                HStack { Text("Block \(block.index) · \(block.verdict)").font(.headline).foregroundStyle(block.verdict == "All good" ? .green : needsReview ? .orange : .secondary); Spacer(); if needsReview { ForEach(block.issues) { issue in Toggle("Include in PDF", isOn: Binding(get: { approvedIDs.contains(issue.id) }, set: { setApproved(issue.id, $0) })).toggleStyle(.checkbox).controlSize(.small) } } }
                Text(block.detail).font(.subheadline).fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 6) { Text(result.viewport == "Mobile" ? "Mobile · 390 × 844" : "Desktop · 1440 × 900").font(.caption.weight(.semibold)).padding(.horizontal, 7).padding(.vertical, 3).background(.quaternary).clipShape(Capsule()); Text(block.source).font(.caption).foregroundStyle(.secondary) }
                HStack { Text(result.url.absoluteString).font(.caption).lineLimit(1).textSelection(.enabled); URLActions(url: result.url) }
            }
        }
        .padding(12).background(Color.white).clipShape(RoundedRectangle(cornerRadius: 10)).overlay(RoundedRectangle(cornerRadius: 10).stroke(needsReview ? Color.orange.opacity(0.5) : Color.gray.opacity(0.2)))
    }
}

struct VisualScreenshotTile: View {
    let result: VisualAuditResult
    let open: () -> Void
    var body: some View { Button(action: open) { VStack(alignment: .leading, spacing: 6) { Group { if !result.previewPath.isEmpty, let image = NSImage(contentsOfFile: result.previewPath) { Image(nsImage: image).resizable().scaledToFill() } else if !result.screenshotPath.isEmpty { AnnotatedVisualScreenshot(result: result, contentMode: .fill) } else { ZStack { Color.gray.opacity(0.15); Image(systemName: "exclamationmark.triangle").font(.title).foregroundStyle(.orange) } } }.frame(height: 150).clipShape(RoundedRectangle(cornerRadius: 8)); Text("\(result.viewport) · \(result.url.host ?? result.url.absoluteString)").lineLimit(1).font(.caption.weight(.semibold)); Text(result.error.isEmpty ? "\(result.issues.count) visual issue\(result.issues.count == 1 ? "" : "s")" : result.error).lineLimit(2).font(.caption).foregroundStyle(result.error.isEmpty ? Color.secondary : Color.red); Text(result.usedLocalModel ? "Local AI" : "WebKit fallback · AI unavailable").lineLimit(1).font(.caption2).foregroundStyle(result.usedLocalModel ? .green : .orange) }.padding(8).background(.background).clipShape(RoundedRectangle(cornerRadius: 10)).overlay(RoundedRectangle(cornerRadius: 10).stroke(.quaternary)) }.buttonStyle(.plain) }
}

struct VisualScreenshotDetail: View {
    let result: VisualAuditResult
    @Environment(\.dismiss) private var dismiss
    var body: some View { VStack(alignment: .leading, spacing: 10) { HStack { VStack(alignment: .leading) { Text("\(result.viewport) · \(result.url.absoluteString)").font(.headline); Text("\(result.issues.count) visual issues · numbered markers match the list below · full-page capture").font(.caption).foregroundStyle(.secondary) }; Spacer(); Button("Open file") { openScreenshotFile() }; Button("Done") { dismiss() } }; Text(result.aiStatus).font(.caption).foregroundStyle(result.usedLocalModel ? .green : .orange).textSelection(.enabled); if !result.usedLocalModel { Text("The items below are WebKit fallback checks, not AI findings. Configure and start the local Ollama model to receive AI conclusions.").font(.caption).foregroundStyle(.secondary) }; if !result.screenshotPath.isEmpty { ScrollView([.horizontal, .vertical]) { AnnotatedVisualScreenshot(result: result, contentMode: .fit).frame(width: displayWidth, height: displayHeight) } } else { ContentUnavailableView("Screenshot unavailable", systemImage: "photo") }; Divider(); ScrollView { ForEach(Array(result.issues.enumerated()), id: \.element.id) { index, issue in VStack(alignment: .leading, spacing: 2) { Text("\(index + 1). \(issue.type)").font(.caption.weight(.semibold)).foregroundStyle(issue.source == "Local model" ? .red : .orange); Text(issue.detail).font(.caption); Text("Source: \(issue.source) · area: \(issue.selector)").font(.caption2).foregroundStyle(.secondary) }.padding(.vertical, 3) } } }.padding().frame(minWidth: 760, minHeight: 600) }
    private var displayWidth: CGFloat { result.viewport == "Mobile" ? 700 : 1_100 }
    private var displayHeight: CGFloat { let width = max(result.screenshotWidth, 1); return displayWidth * CGFloat(result.screenshotHeight / width) }
    private func openScreenshotFile() { let path = FileManager.default.fileExists(atPath: result.screenshotPath) ? result.screenshotPath : result.previewPath; guard !path.isEmpty else { return }; let url = URL(fileURLWithPath: path); if !NSWorkspace.shared.open(url) { NSWorkspace.shared.activateFileViewerSelecting([url]) } }
}

/// Renders the captured page with numbered rectangles for every visual finding.
/// The labels deliberately use the same order as the list in `VisualScreenshotDetail`.
struct AnnotatedVisualScreenshot: View {
    let result: VisualAuditResult
    let contentMode: ContentMode

    private var screenshotSize: CGSize {
        if result.screenshotWidth > 0, result.screenshotHeight > 0 {
            return CGSize(width: result.screenshotWidth, height: result.screenshotHeight)
        }
        return result.viewport == "Mobile" ? CGSize(width: 390, height: 844) : CGSize(width: 1440, height: 900)
    }

    var body: some View {
        GeometryReader { proxy in
            if let image = NSImage(contentsOfFile: result.screenshotPath) {
                ZStack(alignment: .topLeading) {
                    Image(nsImage: image)
                        .resizable()
                        .aspectRatio(contentMode: contentMode)
                        .frame(width: proxy.size.width, height: proxy.size.height)
                        .clipped()
                    ForEach(Array(result.issues.enumerated()), id: \.element.id) { index, issue in
                        marker(number: index + 1, issue: issue, in: proxy.size)
                    }
                }
                .clipped()
            }
        }
    }

    @ViewBuilder
    private func marker(number: Int, issue: VisualIssue, in size: CGSize) -> some View {
        let left = max(0, min(issue.x, Double(screenshotSize.width - 1))) / screenshotSize.width * size.width
        let top = max(0, min(issue.y, Double(screenshotSize.height - 1))) / screenshotSize.height * size.height
        let width = max(28, min(issue.width > 0 ? issue.width : 90, Double(screenshotSize.width))) / screenshotSize.width * size.width
        let height = max(24, min(issue.height > 0 ? issue.height : 36, Double(screenshotSize.height))) / screenshotSize.height * size.height
        ZStack(alignment: .topLeading) {
            RoundedRectangle(cornerRadius: 3).stroke(.red, lineWidth: 2).frame(width: width, height: height)
            Text("\(number)").font(.caption2.bold()).foregroundStyle(.white).padding(4).background(.red).clipShape(Circle())
        }
        .offset(x: left, y: top)
    }
}

struct AuditIssueCard: View {
    let issue: Issue
    let records: [CrawlRecord]
    private var examples: [CrawlRecord] { Array(records.filter { issue.urlIDs.contains($0.id) }.prefix(10)) }
    private var isTitleProblem: Bool { issue.name.localizedCaseInsensitiveContains("title") }
    private var isImageAltProblem: Bool { issue.name == "Images without alt text" }
    private var isEmbeddedImageProblem: Bool { isImageAltProblem || issue.name == "Images over 100 KB" }
    private var isImageResourceProblem: Bool { issue.name == "Broken image resources" || issue.name == "Heavy image resources" }
    private var isRedirectProblem: Bool { issue.name.localizedCaseInsensitiveContains("redirect") }
    private var isMetadataProblem: Bool {
        issue.name.localizedCaseInsensitiveContains("title") || issue.name.localizedCaseInsensitiveContains("meta description")
    }
    private var isSchemaProblem: Bool { issue.name.localizedCaseInsensitiveContains("schema") || issue.name.localizedCaseInsensitiveContains("structured data") }
    private var description: String {
        switch issue.name {
        case "Internal server/client errors": return "These pages return an error or could not be loaded. Search engines and visitors may be unable to access their content."
        case "Broken image resources": return "Image files could not be loaded or return an HTTP error. Replace broken source URLs or restore the missing files."
        case "Heavy image resources": return "These image files exceed 100 KB. Compress, resize or serve modern formats to reduce page weight and loading time."
        case "Missing page title": return "Pages have no title tag. Add a unique, descriptive title in the HTML head for each affected page."
        case "Missing meta description": return "Pages have no meta description. Add concise unique descriptions to improve how pages are presented in search results."
        case "Missing H1": return "Pages do not contain a primary H1 heading. Add one clear page-level heading that matches the page topic."
        case "Missing canonical": return "Pages do not declare a canonical URL. Add a canonical tag to help consolidate duplicate signals."
        case "Title too long": return "Titles exceed the recommended length and may be truncated in search results. Shorten them while retaining the primary topic."
        case "Title too short": return "Titles are too short to communicate the page topic clearly. Expand them with a unique descriptive phrase."
        case "Low content": return "Pages contain little visible text. Review whether more useful, original content is needed or whether the page should be excluded from indexing."
        case "HTTP URL": return "Pages are available via unencrypted HTTP. Redirect them permanently to the preferred HTTPS version."
        case "URL with parameters": return "Parameterized URLs were found. Check canonical tags, internal links and indexability to avoid duplicate pages."
        case "Images without alt text": return "Images have no alternative text. Add useful alt attributes for accessibility and image search context."
        case "Missing security headers": return "One or more recommended HTTPS security headers are missing. Configure them at the web server or CDN level."
        case "Internal redirects (3xx)": return "Internal links point to URLs that redirect before loading the final page. Update internal links to use the final URL directly, avoiding unnecessary crawl and page-load hops."
        case "WordPress technical head links": return "The WordPress template exposes service and duplicate-link tags in the HTML head. Remove unused RSS/comments feeds, RSD/XML-RPC discovery, shortlinks and WordPress version generator tags from the public code."
        case "Pages without JSON-LD structured data": return "These pages do not contain JSON-LD schema markup. Add relevant schema.org markup to help search engines understand page entities and content."
        case "Missing Organization / Business schema": return "No Organization or LocalBusiness structured data was found on the crawled site. Add it, normally on the home page or site-wide template, with name, URL, logo and contact details."
        case "Missing BreadcrumbList schema": return "No BreadcrumbList structured data was found. Add breadcrumb schema to eligible navigational pages so search engines can understand page hierarchy."
        default: return "This issue requires review. Inspect the affected URLs and apply a consistent technical SEO fix."
        }
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack { Text(issue.name).font(.headline); Spacer(); Text(issue.priority.uppercased()).font(.caption.weight(.bold)).foregroundStyle(issue.priority == "High" ? .red : issue.priority == "Medium" ? .orange : .secondary); Text("\(issue.count) URLs").font(.caption).foregroundStyle(.secondary) }
            Text(description).foregroundStyle(.secondary)
            if !examples.isEmpty {
                Divider()
                Text("Examples (up to 10)").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                if isEmbeddedImageProblem {
                    ForEach(Array(examples.flatMap { page in page.images.filter { isImageAltProblem ? $0.alt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty : $0.size > 100_000 }.map { "\(page.url.absoluteString)\nImage: \($0.url)\(isImageAltProblem ? "" : " (\(ByteCountFormatter.string(fromByteCount: Int64($0.size), countStyle: .file)))")" } }.prefix(10)), id: \.self) { example in
                        Text("• \(example)").font(.caption).textSelection(.enabled)
                    }
                } else {
                    ForEach(examples) { record in
                        VStack(alignment: .leading, spacing: 2) {
                            HStack(alignment: .firstTextBaseline) { Text("•").foregroundStyle(.secondary); Text(record.url.absoluteString).font(.caption).textSelection(.enabled); URLActions(url: record.url); Spacer(minLength: 8); Text(record.statusText).font(.caption.monospacedDigit()).foregroundStyle(.secondary) }
                            if isSchemaProblem { Text(record.schemaTypes.isEmpty ? "JSON-LD schema not found" : "JSON-LD: \(record.schemaTypes.joined(separator: ", "))").font(.caption).foregroundStyle(.secondary).padding(.leading, 14).textSelection(.enabled) }
                            else if issue.name == "WordPress technical head links" { Text(record.wordPressHeadFindings.joined(separator: " · ")).font(.caption).foregroundStyle(.orange).padding(.leading, 14).textSelection(.enabled) }
                            else if isRedirectProblem, let source = record.redirectSources.first { Text("Redirect: \(source.absoluteString) → \(record.url.absoluteString)").font(.caption).foregroundStyle(.orange).padding(.leading, 14).textSelection(.enabled) }
                            else if isTitleProblem { Text("Title (\(record.title.count)): \(record.title.isEmpty ? "missing" : record.title)").font(.caption).foregroundStyle(.secondary).padding(.leading, 14).textSelection(.enabled) }
                            else if isImageResourceProblem { Text("\(record.contentType) · \(record.size > 0 ? ByteCountFormatter.string(fromByteCount: Int64(record.size), countStyle: .file) : "size unavailable")").font(.caption).foregroundStyle(record.statusCode.map { $0 >= 400 } == true ? .red : .secondary).padding(.leading, 14) }
                            // A title/description problem belongs to the page
                            // itself; referrer URLs are noise in these audit
                            // cards. Keep link sources for link/directive and
                            // response-code problems, where they are actionable.
                            if !isMetadataProblem && !record.foundOnURLs.isEmpty { FoundOnLinks(urls: record.foundOnURLs).padding(.leading, 14) }
                        }
                    }
                }
            }
        }
        .padding(14)
        .background(Color.white)
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(.quaternary, lineWidth: 1))
    }
}

/// Shows which kinds of page carry each problem without duplicating the full
/// example cards. This helps a client see whether a fix belongs to services,
/// articles, categories, or another template.
private struct AuditIssueSegmentation: View {
    private struct Segment: Identifiable {
        let type: String
        let issues: [Issue]
        var id: String { type }
    }

    let records: [CrawlRecord]
    let issues: [Issue]

    private var segments: [Segment] {
        let pages = records.filter { $0.isSEOPage }
        let types = Set(pages.map(\.displayPageType)).sorted()
        return types.compactMap { type in
            let ids = Set(pages.filter { $0.displayPageType == type }.map(\.id))
            let matching = issues.compactMap { issue -> Issue? in
                let affected = issue.urlIDs.filter { ids.contains($0) }
                guard !affected.isEmpty else { return nil }
                return Issue(name: issue.name, type: issue.type, priority: issue.priority, urlIDs: affected)
            }
            return matching.isEmpty ? nil : Segment(type: type, issues: matching.sorted { $0.count > $1.count })
        }
    }

    var body: some View {
        GroupBox("Issue segmentation by page type") {
            VStack(alignment: .leading, spacing: 6) {
                Text("Shows which page templates are affected; this does not run another crawl.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                ForEach(segments) { segment in
                    DisclosureGroup("\(segment.type) · \(segment.issues.reduce(0) { $0 + $1.count }) affected issue occurrences") {
                        ForEach(segment.issues) { issue in
                            HStack {
                                Text(issue.name)
                                Spacer()
                                Text("\(issue.count)")
                                    .monospacedDigit()
                                    .foregroundStyle(issue.priority == "High" ? .red : issue.priority == "Medium" ? .orange : .secondary)
                            }
                            .font(.caption)
                        }
                    }
                }
            }
        }
    }
}

struct URLsView: View {
    @ObservedObject var model: CrawlViewModel
    @State private var query = ""; @State private var selection = Set<UUID>(); @State private var filter = "All"
    private var visible: [CrawlRecord] { model.records.filter { record in (model.overviewSelectionName == nil || model.overviewSelectionIDs.contains(record.id)) && (filter == "All" || (filter == "Errors" && (!record.error.isEmpty || (record.statusCode ?? 0) >= 400)) || (filter == "HTML" && record.isHTML)) && (query.isEmpty || record.url.absoluteString.localizedCaseInsensitiveContains(query) || record.title.localizedCaseInsensitiveContains(query)) } }
    var body: some View {
        VStack(spacing: 8) {
        HStack { VStack(alignment: .leading) { Text("URLs").font(.title2.weight(.semibold)); if let metric = model.overviewSelectionName { Text("Overview filter: \(metric) (\(model.overviewSelectionIDs.count))").font(.caption).foregroundStyle(.secondary) } }; Spacer(); if model.overviewSelectionName != nil { Button("Clear overview filter") { model.clearOverviewSelection() }.controlSize(.small) }; Button(model.searchConsoleRunning ? "Checking Search Console…" : "Fetch Search Console") { model.inspectSearchConsole(urlIDs: Set(visible.map(\.id))) }.disabled(model.searchConsoleRunning || visible.isEmpty).help("Checks only URLs currently shown in the table"); Button(model.gscChromePageIndexingSyncRunning ? "Syncing Page Indexing…" : "Sync GSC Page Indexing") { model.syncGSCPageIndexingThroughChrome() }.disabled(model.gscChromePageIndexingSyncRunning).help("Uses Chrome for the Page Indexing report."); Button(model.gscChromeCoreWebVitalsSyncRunning ? "Syncing Core Web Vitals…" : "Sync GSC Core Web Vitals") { model.syncGSCCoreWebVitalsThroughChrome() }.disabled(model.gscChromeCoreWebVitalsSyncRunning).help("Imports mobile Poor / Needs improvement groups from Chrome."); Button(model.backlinkRunning ? "Loading Backlinks…" : "Refresh Backlink Data") { model.refreshBacklinkData() }.disabled(model.backlinkRunning || model.records.isEmpty).help("Loads the DataForSEO domain summary and page metrics; results are cached for 7 days."); Picker("Filter", selection: $filter) { Text("All").tag("All"); Text("Errors").tag("Errors"); Text("HTML").tag("HTML") }.frame(width: 130); TextField("Search URLs or titles", text: $query).textFieldStyle(.roundedBorder).frame(width: 250) }
            if !model.searchConsoleMessage.isEmpty {
                HStack(spacing: 8) { if model.searchConsoleRunning { ProgressView().controlSize(.small) }; Text(model.searchConsoleMessage).font(.caption).foregroundStyle(.secondary); Spacer() }.frame(maxWidth: .infinity, alignment: .leading)
            }
            urlsTable.contextMenu(forSelectionType: CrawlRecord.ID.self) { ids in
                if let record = model.records.first(where: { ids.contains($0.id) }) { Button("Copy URL") { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(record.url.absoluteString, forType: .string) }; Button("Open in browser") { NSWorkspace.shared.open(record.url) } }
            } primaryAction: { ids in if let record = model.records.first(where: { ids.contains($0.id) }) { NSWorkspace.shared.open(record.url) } }
            /*Table(visible, selection: $selection) {
                Group {
                    TableColumn("URL") { record in HStack { Text(record.url.absoluteString).lineLimit(1); Spacer(); URLActions(url: record.url) } }.width(min: 250, ideal: 370)
                    TableColumn("Status") { Text($0.statusText).foregroundStyle(($0.statusCode ?? 200) >= 400 ? .red : .primary) }.width(65)
                    TableColumn("Content Type") { Text($0.contentType).lineLimit(1) }.width(115)
                    TableColumn("Indexability") { Text($0.indexability) }.width(90)
                    TableColumn("GSC indexed") { record in Text(record.searchConsoleIndexStatus).lineLimit(1).foregroundStyle(record.searchConsoleIndexStatus == "Not indexed" ? Color.orange : (record.searchConsoleIndexStatus == "Indexed" ? Color.green : Color.secondary)) }.width(105)
                    TableColumn("GSC fetch / error") { record in Text(record.searchConsoleFetchStatus).lineLimit(1).foregroundStyle(record.searchConsoleFetchStatus == "No error" || record.searchConsoleFetchStatus == "—" ? Color.secondary : Color.orange) }.width(min: 120, ideal: 160)
                    TableColumn("GSC indexing issue") { record in Text(record.searchConsoleCoverage.isEmpty ? "—" : record.searchConsoleCoverage).lineLimit(1).foregroundStyle(record.searchConsoleCoverage.isEmpty ? Color.secondary : Color.orange) }.width(min: 160, ideal: 240)
                    TableColumn("Google canonical") { record in Text(record.searchConsoleGoogleCanonical.isEmpty ? "—" : record.searchConsoleGoogleCanonical).lineLimit(1) }.width(min: 150, ideal: 250)
                    TableColumn("GSC last crawl") { record in Text(record.searchConsoleLastCrawl.isEmpty ? "—" : record.searchConsoleLastCrawl).lineLimit(1) }.width(min: 130, ideal: 175)
                    TableColumn("GSC robots") { record in Text(record.searchConsoleRobotsStatus.isEmpty ? "—" : record.searchConsoleRobotsStatus).lineLimit(1).foregroundStyle(record.searchConsoleRobotsStatus == "Blocked" ? Color.orange : Color.secondary) }.width(105)
                }
                Group {
                    TableColumn("GSC noindex") { record in Text(record.searchConsoleNoindexStatus.isEmpty ? "—" : record.searchConsoleNoindexStatus).lineLimit(1).foregroundStyle(record.searchConsoleNoindexStatus.hasPrefix("noindex") ? Color.orange : Color.secondary) }.width(min: 110, ideal: 155)
                    TableColumn("GSC sitemap") { record in Text(record.searchConsoleSitemaps.isEmpty ? "—" : record.searchConsoleSitemaps.joined(separator: ", ")).lineLimit(1) }.width(min: 150, ideal: 240)
                    TableColumn("GSC Rich Results errors") { record in Text(record.searchConsoleRichResultErrors.isEmpty ? "—" : record.searchConsoleRichResultErrors.joined(separator: "; ")).lineLimit(1).foregroundStyle(record.searchConsoleRichResultErrors.isEmpty ? Color.secondary : Color.orange) }.width(min: 160, ideal: 250)
                    TableColumn("GSC mobile issues") { record in Text(record.searchConsoleMobileIssues.isEmpty ? "—" : record.searchConsoleMobileIssues.joined(separator: "; ")).lineLimit(1).foregroundStyle(record.searchConsoleMobileIssues.isEmpty ? Color.secondary : Color.orange) }.width(min: 160, ideal: 250)
                    TableColumn("Title") { Text($0.title).lineLimit(1) }.width(min: 150, ideal: 260)
                    TableColumn("Page Type") { Text($0.displayPageType) }.width(100)
                    TableColumn("Depth") { Text("\($0.depth)") }.width(50)
                }
                Group {
                    TableColumn("GSC clicks · 7d") { record in Text(record.searchConsolePerformanceChecked ? "\(record.searchConsoleClicks7d)" : "—") }.width(90)
                    TableColumn("GSC impressions · 7d") { record in Text(record.searchConsolePerformanceChecked ? "\(record.searchConsoleImpressions7d)" : "—") }.width(115)
                    TableColumn("GSC queries · Top 10") { record in Text(record.searchConsolePerformanceChecked ? "\(record.searchConsoleQueriesTop10)" : "—") }.width(125)
                    TableColumn("GSC queries · Top 20") { record in Text(record.searchConsolePerformanceChecked ? "\(record.searchConsoleQueriesTop20)" : "—") }.width(125)
                    TableColumn("GSC queries · total") { record in Text(record.searchConsolePerformanceChecked ? "\(record.searchConsoleQueryCount)" : "—") }.width(115)
                }
            }.contextMenu(forSelectionType: CrawlRecord.ID.self) { ids in
                if let record = model.records.first(where: { ids.contains($0.id) }) { Button("Copy URL") { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(record.url.absoluteString, forType: .string) }; Button("Open in browser") { NSWorkspace.shared.open(record.url) } }
            } primaryAction: { ids in if let record = model.records.first(where: { ids.contains($0.id) }) { NSWorkspace.shared.open(record.url) } }*/
            if model.mode == .list && model.records.isEmpty { TextEditor(text: $model.listText).font(.body.monospaced()).overlay(alignment: .topLeading) { if model.listText.isEmpty { Text("Paste one URL per line…").foregroundStyle(.tertiary).padding(8).allowsHitTesting(false) } }.frame(height: 130).border(.quaternary) }
        }
    }
    private var urlsTable: some View {
        Table(visible, selection: $selection) { basicColumns; inspectionColumns; performanceColumns; backlinkColumns; backlinkNetworkColumns }
    }
    @TableColumnBuilder<CrawlRecord, Never> private var basicColumns: some TableColumnContent<CrawlRecord, Never> {
        TableColumn("URL") { record in HStack { Text(record.url.absoluteString).lineLimit(1); Spacer(); URLActions(url: record.url) } }.width(min: 250, ideal: 370)
        TableColumn("Status") { Text($0.statusText).foregroundStyle(($0.statusCode ?? 200) >= 400 ? .red : .primary) }.width(65)
        TableColumn("Content Type") { Text($0.contentType).lineLimit(1) }.width(115)
        TableColumn("Indexability") { Text($0.indexability) }.width(90)
        TableColumn("Title") { Text($0.title).lineLimit(1) }.width(min: 150, ideal: 260)
        TableColumn("Page Type") { Text($0.displayPageType) }.width(100)
    }
    @TableColumnBuilder<CrawlRecord, Never> private var inspectionColumns: some TableColumnContent<CrawlRecord, Never> {
        TableColumn("GSC indexed") { Text($0.searchConsoleIndexStatus).lineLimit(1) }.width(105)
        TableColumn("GSC fetch / error") { Text($0.searchConsoleFetchStatus).lineLimit(1) }.width(min: 120, ideal: 160)
        TableColumn("GSC indexing issue") { Text($0.searchConsoleCoverage.isEmpty ? "—" : $0.searchConsoleCoverage).lineLimit(1) }.width(min: 160, ideal: 240)
        TableColumn("Google canonical") { Text($0.searchConsoleGoogleCanonical.isEmpty ? "—" : $0.searchConsoleGoogleCanonical).lineLimit(1) }.width(min: 150, ideal: 250)
        TableColumn("GSC last crawl") { Text($0.searchConsoleLastCrawl.isEmpty ? "—" : $0.searchConsoleLastCrawl).lineLimit(1) }.width(min: 130, ideal: 175)
        TableColumn("GSC robots") { Text($0.searchConsoleRobotsStatus.isEmpty ? "—" : $0.searchConsoleRobotsStatus).lineLimit(1) }.width(105)
        TableColumn("GSC noindex") { Text($0.searchConsoleNoindexStatus.isEmpty ? "—" : $0.searchConsoleNoindexStatus).lineLimit(1) }.width(min: 110, ideal: 155)
        TableColumn("GSC sitemap") { Text($0.searchConsoleSitemaps.isEmpty ? "—" : $0.searchConsoleSitemaps.joined(separator: ", ")).lineLimit(1) }.width(min: 150, ideal: 240)
        TableColumn("GSC Rich Results errors") { Text($0.searchConsoleRichResultErrors.isEmpty ? "—" : $0.searchConsoleRichResultErrors.joined(separator: "; ")).lineLimit(1) }.width(min: 160, ideal: 250)
        TableColumn("GSC mobile issues") { Text($0.searchConsoleMobileIssues.isEmpty ? "—" : $0.searchConsoleMobileIssues.joined(separator: "; ")).lineLimit(1) }.width(min: 160, ideal: 250)
    }
    @TableColumnBuilder<CrawlRecord, Never> private var performanceColumns: some TableColumnContent<CrawlRecord, Never> {
        TableColumn("GSC clicks · 7d") { Text($0.searchConsolePerformanceChecked ? "\($0.searchConsoleClicks7d)" : "—") }.width(90)
        TableColumn("GSC impressions · 7d") { Text($0.searchConsolePerformanceChecked ? "\($0.searchConsoleImpressions7d)" : "—") }.width(115)
        TableColumn("GSC queries · Top 10") { Text($0.searchConsolePerformanceChecked ? "\($0.searchConsoleQueriesTop10)" : "—") }.width(125)
        TableColumn("GSC queries · Top 20") { Text($0.searchConsolePerformanceChecked ? "\($0.searchConsoleQueriesTop20)" : "—") }.width(125)
        TableColumn("GSC queries · total") { Text($0.searchConsolePerformanceChecked ? "\($0.searchConsoleQueryCount)" : "—") }.width(115)
    }
    @TableColumnBuilder<CrawlRecord, Never> private var backlinkColumns: some TableColumnContent<CrawlRecord, Never> {
        TableColumn("Backlinks") { Text($0.backlinkChecked ? "\($0.backlinks)" : "—") }.width(82)
        TableColumn("Referring Domains") { Text($0.backlinkChecked ? "\($0.referringDomains)" : "—") }.width(125)
        TableColumn("Referring Main Domains") { Text($0.backlinkChecked ? "\($0.referringMainDomains)" : "—") }.width(155)
        TableColumn("Referring Pages") { Text($0.backlinkChecked ? "\($0.referringPages)" : "—") }.width(115)
        TableColumn("Page Rank") { Text($0.backlinkChecked ? "\($0.backlinkPageRank)" : "—") }.width(85)
        TableColumn("Spam Score") { Text($0.backlinkChecked ? "\($0.backlinkSpamScore)" : "—") }.width(90)
        TableColumn("Broken Backlinks") { Text($0.backlinkChecked ? "\($0.brokenBacklinks)" : "—") }.width(125)
        TableColumn("Dofollow") { Text($0.backlinkChecked ? "\($0.dofollowBacklinks)" : "—") }.width(80)
        TableColumn("Nofollow") { Text($0.backlinkChecked ? "\($0.nofollowBacklinks)" : "—") }.width(80)
    }
    @TableColumnBuilder<CrawlRecord, Never> private var backlinkNetworkColumns: some TableColumnContent<CrawlRecord, Never> {
        TableColumn("Referring IPs") { Text($0.backlinkChecked ? "\($0.referringIPs)" : "—") }.width(105)
        TableColumn("Referring Subnets") { Text($0.backlinkChecked ? "\($0.referringSubnets)" : "—") }.width(125)
    }
}

struct SettingsView: View {
    @Binding var settings: CrawlSettings
    @Binding var localVision: LocalVisionSettings
    @Environment(\.dismiss) private var dismiss
    @State private var pageSpeedKey = PSIKeychain.load()
    @State private var ahrefsKey = AhrefsKeychain.load()
    @State private var dataForSEOLogin = DataForSEOCredentials.load().login
    @State private var dataForSEOPassword = DataForSEOCredentials.load().password
    @StateObject private var searchConsole = SearchConsoleAuth.shared
    @State private var searchConsoleClientID = SearchConsoleAuth.shared.clientID
    @State private var searchConsoleClientSecret = SearchConsoleAuth.shared.clientSecret
    var body: some View { VStack(alignment: .leading) { Text("Crawl Settings").font(.title2.weight(.semibold)); Form { TextField("User-Agent", text: $settings.userAgent); Stepper("Concurrent requests: \(settings.concurrency)", value: $settings.concurrency, in: 1...32); Stepper("Timeout: \(Int(settings.timeout)) seconds", value: $settings.timeout, in: 5...120, step: 5); Stepper("Maximum depth: \(settings.maxDepth)", value: $settings.maxDepth, in: 0...30); Stepper("Maximum URLs: \(settings.maxURLs)", value: $settings.maxURLs, in: 10...100_000, step: 100); Stepper("Visual audit pages: \(settings.visualAuditPageLimit)", value: $settings.visualAuditPageLimit, in: 1...8); Picker("robots.txt crawl mode", selection: $settings.respectRobots) { Text("Crawl pages even when blocked (default)").tag(false); Text("Do not crawl URLs blocked by robots.txt").tag(true) }; Text("Blocked URLs are always recorded with the matching Disallow rule for Overview and Audit.").font(.caption).foregroundStyle(.secondary); Toggle("Follow links marked nofollow", isOn: $settings.followNofollowLinks); Toggle("Crawl subdomains", isOn: $settings.crawlSubdomains); Toggle("Crawl URLs with parameters", isOn: $settings.crawlParameters); Section("Integrations · Ahrefs") { SecureField("Free Ahrefs API Key (for DR)", text: $ahrefsKey); Text("Stored locally in ShareSpider's Application Support folder.").font(.caption).foregroundStyle(.secondary) }; Section("Integrations · DataForSEO Backlinks") { TextField("API login", text: $dataForSEOLogin); SecureField("API password", text: $dataForSEOPassword); Text("Stored locally in ShareSpider's Application Support folder. Backlink enrichment runs only when you choose Refresh Backlink Data and is cached for 7 days.").font(.caption).foregroundStyle(.secondary) }; Section("Integrations · PageSpeed Insights") { SecureField("Optional Google API Key", text: $pageSpeedKey); Text("Stored locally in ShareSpider's Application Support folder. Leave blank to use the unauthenticated API quota.").font(.caption).foregroundStyle(.secondary) }; Section("Integrations · Google Search Console") { TextField("OAuth desktop client ID", text: $searchConsoleClientID); SecureField("OAuth client secret (optional)", text: $searchConsoleClientSecret); Text(searchConsole.status).font(.caption).foregroundStyle(searchConsole.isConnected ? .green : .secondary); HStack { Button(searchConsole.isAuthorizing ? "Waiting for Google…" : (searchConsole.isConnected ? "Reconnect" : "Connect Google Search Console")) { searchConsole.saveClient(clientID: searchConsoleClientID, clientSecret: searchConsoleClientSecret); Task { await searchConsole.authorize() } }.disabled(searchConsole.isAuthorizing); if searchConsole.isConnected { Button("Disconnect", role: .destructive) { searchConsole.disconnect() } } }; Text("Uses the configured Desktop OAuth client and requests read-only Search Console access. Credentials are stored locally by ShareSpider; no Keychain password is requested.").font(.caption).foregroundStyle(.secondary) }; Section("Integrations · Local visual model") { Toggle("Use local Ollama vision model", isOn: $localVision.enabled); TextField("Ollama endpoint", text: $localVision.endpoint); TextField("Vision model", text: $localVision.model); Text("Images remain on this Mac. Recommended starting model: qwen2.5vl:7b.").font(.caption).foregroundStyle(.secondary) } }; HStack { Spacer(); Button("Done") { PSIKeychain.save(pageSpeedKey); AhrefsKeychain.save(ahrefsKey); DataForSEOCredentials.save(login: dataForSEOLogin, password: dataForSEOPassword); searchConsole.saveClient(clientID: searchConsoleClientID, clientSecret: searchConsoleClientSecret); localVision.save(); dismiss() }.keyboardShortcut(.defaultAction) } }.padding().frame(width: 600) }
}
