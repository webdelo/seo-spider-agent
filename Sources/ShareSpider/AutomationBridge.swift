import Foundation

/// File bridge between the native app and the local ShareSpider MCP server.
/// It deliberately stores only launch commands and progress, never credentials
/// or crawl content.
enum AutomationBridge {
    private static var directory: URL {
        let path = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("ShareSpider", isDirectory: true)
        try? FileManager.default.createDirectory(at: path, withIntermediateDirectories: true)
        return path
    }
    static var pendingProjectImportURL: URL { directory.appendingPathComponent("pending-project-import.txt") }
    static var batchStatusURL: URL { directory.appendingPathComponent("batch-status.json") }
    static var auditStatusURL: URL { directory.appendingPathComponent("audit-status.json") }
    static var pendingCommandURL: URL { directory.appendingPathComponent("pending-command.txt") }
    static var pendingBacklinkRulesURL: URL { directory.appendingPathComponent("pending-backlink-classification-rules.json") }
    static var pendingGSCBacklinkExportURL: URL { directory.appendingPathComponent("pending-gsc-backlinks.csv") }
    static var pendingGSCSiteReportURL: URL { directory.appendingPathComponent("pending-gsc-site-report.csv") }
    static var performanceLogURL: URL { directory.appendingPathComponent("performance-log.jsonl") }

    static func consumePendingProjectImport() -> String? {
        guard let value = try? String(contentsOf: pendingProjectImportURL), !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        try? FileManager.default.removeItem(at: pendingProjectImportURL)
        return value
    }
    static func writeBatchStatus(_ status: BatchScenarioProgress) {
        guard let data = try? JSONEncoder().encode(status) else { return }
        try? data.write(to: batchStatusURL, options: .atomic)
    }
    struct AuditStatus: Codable {
        var site: String
        var state: String
        var checked: Int
        var problems: Int
        var missingReturnLinks: Int
        var examples: [String]
        var updatedAt: Date
    }
    static func writeAuditStatus(_ status: AuditStatus) {
        guard let data = try? JSONEncoder().encode(status) else { return }
        try? data.write(to: auditStatusURL, options: .atomic)
    }
    static func consumePendingCommand() -> URL? {
        guard let value = try? String(contentsOf: pendingCommandURL, encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines),
              let url = URL(string: value) else { return nil }
        try? FileManager.default.removeItem(at: pendingCommandURL)
        return url
    }
    static func consumePendingBacklinkRules() -> String? {
        guard let value = try? String(contentsOf: pendingBacklinkRulesURL, encoding: .utf8),
              !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        try? FileManager.default.removeItem(at: pendingBacklinkRulesURL)
        return value
    }
    static func consumePendingGSCBacklinkExport() -> String? {
        guard let value = try? String(contentsOf: pendingGSCBacklinkExportURL, encoding: .utf8),
              !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        try? FileManager.default.removeItem(at: pendingGSCBacklinkExportURL)
        return value
    }
    static func consumePendingGSCSiteReport() -> String? {
        guard let value = try? String(contentsOf: pendingGSCSiteReportURL, encoding: .utf8), !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        try? FileManager.default.removeItem(at: pendingGSCSiteReportURL)
        return value
    }
    static func logPerformance(site: String, stage: String, duration: TimeInterval, urlCount: Int = 0) {
        struct Entry: Codable { var timestamp: Date; var site: String; var stage: String; var durationSeconds: Double; var urlCount: Int }
        guard let payload = try? JSONEncoder().encode(Entry(timestamp: Date(), site: site, stage: stage, durationSeconds: duration, urlCount: urlCount)) else { return }
        let line = payload + Data([10])
        if FileManager.default.fileExists(atPath: performanceLogURL.path), let handle = try? FileHandle(forWritingTo: performanceLogURL) {
            defer { try? handle.close() }; try? handle.seekToEnd(); try? handle.write(contentsOf: line)
        } else { try? line.write(to: performanceLogURL, options: .atomic) }
    }
}
