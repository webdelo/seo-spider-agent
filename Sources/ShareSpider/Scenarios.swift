import Foundation

enum ScenarioReportKind: String, CaseIterable, Identifiable, Codable { case clientAudit = "Client audit", technicalTasks = "Technical tasks", both = "Both reports"; var id: String { rawValue } }

struct BatchScenarioProgress: Equatable, Codable {
    var completed = 0; var total = 0; var currentSite = ""; var currentSiteProgress: Double = 0; var pendingSites: [String] = []; var outputDirectory = ""; var error = ""; var summaryReportPath = ""; var reportPaths: [String] = []
    var label: String { total == 0 ? "Ready" : "\(completed) of \(total) sites · \(currentSite)" }
}

/// Compact, client-safe roll-up used after a one-time or scheduled batch.
/// Only High findings are included, so the final report remains an action list
/// instead of repeating every detail from every individual site report.
struct BatchCriticalIssue: Identifiable, Hashable {
    var id: String { title }
    var title: String
    var count: Int
    var examples: [String]
}

struct BatchSiteCriticalSummary: Identifiable, Hashable {
    var id: String { url }
    var name: String
    var url: String
    var issues: [BatchCriticalIssue]
}

struct ScheduledScenario: Identifiable, Codable, Hashable {
    var id = UUID(); var name: String; var urls: [String]; var cadenceDays: Int; var reportKind: ScenarioReportKind; var severity: TechnicalTaskPDFReport.Severity; var outputDirectory: String; var nextRun: Date
}

@MainActor
final class ScenarioStore: ObservableObject {
    @Published private(set) var schedules: [ScheduledScenario] = []
    private let key = "ShareSpider.scheduledScenarios"
    init() { if let data = UserDefaults.standard.data(forKey: key), let saved = try? JSONDecoder().decode([ScheduledScenario].self, from: data) { schedules = saved } }
    func add(name: String, urls: [String], cadenceDays: Int, reportKind: ScenarioReportKind, severity: TechnicalTaskPDFReport.Severity, outputDirectory: String, firstRun: Date) {
        schedules.append(ScheduledScenario(name: name, urls: urls, cadenceDays: cadenceDays, reportKind: reportKind, severity: severity, outputDirectory: outputDirectory, nextRun: firstRun)); save()
    }
    func remove(_ schedule: ScheduledScenario) { schedules.removeAll { $0.id == schedule.id }; save() }
    func due() -> [ScheduledScenario] { schedules.filter { $0.nextRun <= Date() } }
    func markStarted(_ id: UUID) { guard let index = schedules.firstIndex(where: { $0.id == id }) else { return }; schedules[index].nextRun = Calendar.current.date(byAdding: .day, value: max(1, schedules[index].cadenceDays), to: Date()) ?? Date().addingTimeInterval(86_400); save() }
    private func save() { if let data = try? JSONEncoder().encode(schedules) { UserDefaults.standard.set(data, forKey: key) } }
}
