import Foundation

/// Mobile Core Web Vitals as reported by GSC.  This is deliberately a
/// separate dataset from URL Inspection and Page Indexing.
struct GSCCoreWebVitalsReport: Codable, Hashable {
    struct Metric: Codable, Hashable, Identifiable {
        var id: String { key }
        var key: String
        var group: String
        var label: String
        var count: Int
        var examples: [String] = []
    }
    var target: String
    var importedAt = Date()
    var metrics: [Metric]
    var total: Int { metrics.reduce(0) { $0 + $1.count } }
}

enum GSCCoreWebVitalsImport {
    enum ImportError: LocalizedError { case empty, unsupported
        var errorDescription: String? { self == .empty ? "The Core Web Vitals export is empty." : "This is not a recognised mobile Core Web Vitals export." }
    }
    private static var directory: URL {
        let url = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("ShareSpider/gsc-core-web-vitals", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
    static func load(target: String) -> GSCCoreWebVitalsReport? { try? JSONDecoder().decode(GSCCoreWebVitalsReport.self, from: Data(contentsOf: file(target))) }
    static func save(_ report: GSCCoreWebVitalsReport) { if let data = try? JSONEncoder().encode(report) { try? data.write(to: file(report.target), options: .atomic) } }
    static func importCSV(_ text: String, target: String) throws -> GSCCoreWebVitalsReport {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw ImportError.empty }
        let rows = parse(text); guard let header = rows.first else { throw ImportError.empty }
        let names = header.map { $0.lowercased().trimmingCharacters(in: .whitespacesAndNewlines) }
        guard let groupIndex = names.firstIndex(where: { $0.contains("group") || $0.contains("severity") }),
              let issueIndex = names.firstIndex(where: { $0.contains("issue") || $0.contains("problem") }),
              let pagesIndex = names.firstIndex(where: { $0.contains("page") || $0.contains("url") }) else { throw ImportError.unsupported }
        let urlIndex = names.firstIndex(where: { $0 == "url" || $0.contains("example") })
        var output: [String: GSCCoreWebVitalsReport.Metric] = [:]
        for row in rows.dropFirst() where row.indices.contains(groupIndex) && row.indices.contains(issueIndex) {
            let group = row[groupIndex].trimmingCharacters(in: .whitespacesAndNewlines)
            let issue = row[issueIndex].trimmingCharacters(in: .whitespacesAndNewlines)
            guard !group.isEmpty, !issue.isEmpty else { continue }
            let normalizedGroup = group.localizedCaseInsensitiveContains("poor") ? "Poor" : "Needs improvement"
            let key = (normalizedGroup + "-" + issue).lowercased().replacingOccurrences(of: "[^a-z0-9]+", with: "-", options: .regularExpression)
            var metric = output[key] ?? .init(key: key, group: normalizedGroup, label: issue, count: 0)
            if row.indices.contains(pagesIndex) { metric.count += Int(row[pagesIndex].replacingOccurrences(of: "[^0-9]", with: "", options: .regularExpression)) ?? 0 }
            if let urlIndex, row.indices.contains(urlIndex), row[urlIndex].hasPrefix("http"), !metric.examples.contains(row[urlIndex]) { metric.examples.append(row[urlIndex]) }
            output[key] = metric
        }
        let report = GSCCoreWebVitalsReport(target: target, metrics: output.values.sorted { ($0.group, $0.label) < ($1.group, $1.label) })
        save(report); return report
    }
    private static func file(_ target: String) -> URL { directory.appendingPathComponent((URL(string: target)?.host ?? target).lowercased().replacingOccurrences(of: "[^a-z0-9.-]", with: "_", options: .regularExpression) + ".json") }
    private static func parse(_ text: String) -> [[String]] {
        var result: [[String]] = [[]]; var value = ""; var quote = false
        for character in text {
            if character == "\"" { quote.toggle() }
            else if character == "," && !quote { result[result.count - 1].append(value); value = "" }
            else if character == "\n" && !quote { result[result.count - 1].append(value); result.append([]); value = "" }
            else if character != "\r" { value.append(character) }
        }
        if !value.isEmpty { result[result.count - 1].append(value) }
        return result
    }
}
