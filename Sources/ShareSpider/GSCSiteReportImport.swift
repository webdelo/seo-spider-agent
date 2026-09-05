import Foundation

/// A separate, site-wide view from the Page indexing / mobile reports in GSC.
/// It intentionally does not overwrite per-URL Inspection API results.
struct GSCSiteReport: Codable, Hashable {
    struct Metric: Codable, Hashable, Identifiable {
        var id: String { key }
        var key: String
        var label: String
        var count: Int
        var examples: [String] = []
    }
    var target: String
    var importedAt = Date()
    var metrics: [Metric]

    /// The individual exclusion reasons are subdivisions of "Not indexed", so
    /// summing every row double-counts URLs. Prefer the two headline values
    /// for the denominator used in Overview.
    var total: Int {
        let headline = count("indexed") + count("not-indexed")
        return headline > 0 ? headline : metrics.reduce(0) { $0 + $1.count }
    }
    func count(_ key: String) -> Int { metrics.first(where: { $0.key == key })?.count ?? 0 }
}

enum GSCSiteReportImport {
    enum ImportError: LocalizedError { case empty, unsupported
        var errorDescription: String? { self == .empty ? "The GSC export is empty." : "This is not a recognised GSC Page indexing or mobile-usability CSV." }
    }
    private static var directory: URL {
        let url = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!.appendingPathComponent("ShareSpider/gsc-site-reports", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true); return url
    }
    static func load(target: String) -> GSCSiteReport? { try? JSONDecoder().decode(GSCSiteReport.self, from: Data(contentsOf: file(target))) }
    static func save(_ report: GSCSiteReport) { if let data = try? JSONEncoder().encode(report) { try? data.write(to: file(report.target), options: .atomic) } }
    static func importCSV(_ text: String, target: String) throws -> GSCSiteReport {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw ImportError.empty }
        let rows = csv(text).filter { !$0.allSatisfy { $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty } }
        guard let header = rows.first else { throw ImportError.empty }
        let normalized = header.map(normalize)
        guard let reasonIndex = normalized.firstIndex(where: { $0.contains("reason") || $0.contains("причин") || $0.contains("issue") }),
              let countIndex = normalized.firstIndex(where: { $0 == "pages" || $0.contains("page") || $0.contains("страниц") || $0.contains("url") || $0.contains("urls") }) else { throw ImportError.unsupported }
        let urlIndex = normalized.firstIndex(where: { $0 == "url" || $0 == "urls" || $0.contains("example") || $0.contains("address") })
        var collected: [String: GSCSiteReport.Metric] = [:]
        for row in rows.dropFirst() where row.indices.contains(reasonIndex) && row.indices.contains(countIndex) {
            let sourceLabel = row[reasonIndex].trimmingCharacters(in: .whitespacesAndNewlines)
            let label = displayLabel(for: metricKey(sourceLabel), fallback: sourceLabel)
            guard !label.isEmpty else { continue }
            let count = Int(row[countIndex].replacingOccurrences(of: "[^0-9]", with: "", options: .regularExpression)) ?? 0
            let key = metricKey(sourceLabel)
            var metric = collected[key] ?? .init(key: key, label: label, count: 0)
            metric.count += count
            if let urlIndex, row.indices.contains(urlIndex), row[urlIndex].hasPrefix("http") {
                let url = row[urlIndex]
                if !metric.examples.contains(url) { metric.examples.append(url) }
            }
            collected[key] = metric
        }
        guard !collected.isEmpty else { throw ImportError.unsupported }
        // Keep the GSC section stable between imports. A missing category in
        // the live report means zero, not that the metric disappeared.
        let standard: [(String, String)] = [
            ("indexed", "Indexed"), ("not-indexed", "Not Indexed"),
            ("404", "Not Found (404)"), ("soft404", "Soft 404"),
            ("redirect", "Page With Redirect"), ("redirect-error", "Redirect Error"),
            ("crawled-not-indexed", "Crawled – Currently Not Indexed"),
            ("discovered-not-indexed", "Discovered – Currently Not Indexed"),
            ("canonical", "Canonical Issue"), ("robots", "Blocked by robots.txt"),
            ("noindex", "Excluded by noindex"), ("5xx", "Server Error (5xx)")
        ]
        for (key, label) in standard where collected[key] == nil {
            collected[key] = .init(key: key, label: label, count: 0)
        }
        let report = GSCSiteReport(target: target, metrics: collected.values.sorted { $0.label < $1.label })
        save(report); return report
    }
    static func metricKey(_ label: String) -> String {
        let value = normalize(label)
        if value.contains("soft 404") || value.contains("мягк") { return "soft404" }
        if value.contains("redirect error") || value.contains("ошибка переадрес") { return "redirect-error" }
        if value.contains("404") || value.contains("not found") || value.contains("не найден") { return "404" }
        if value.contains("redirect") || value.contains("переадрес") { return "redirect" }
        if value.contains("5xx") || value.contains("server error") || value.contains("ошибка сервера") { return "5xx" }
        if value.contains("robots") { return "robots" }
        if value.contains("noindex") { return "noindex" }
        if value.contains("canonical") || value.contains("канонич") { return "canonical" }
        if value.contains("crawled") || value.contains("просканирован") { return "crawled-not-indexed" }
        if value.contains("discovered") || value.contains("обнаружен") { return "discovered-not-indexed" }
        if value.contains("mobile") || value.contains("мобиль") { return "mobile" }
        if value.contains("indexed") && !value.contains("not indexed") && !value.contains("не проиндекс") { return "indexed" }
        if value.contains("not indexed") || value.contains("не проиндекс") { return "not-indexed" }
        return "other-" + value.replacingOccurrences(of: "[^a-z0-9]", with: "-", options: .regularExpression).prefix(40)
    }
    static func displayLabel(for key: String, fallback: String) -> String {
        switch key {
        case "indexed": "Indexed"
        case "not-indexed": "Not Indexed"
        case "404": "Not Found (404)"
        case "soft404": "Soft 404"
        case "redirect": "Page With Redirect"
        case "redirect-error": "Redirect Error"
        case "crawled-not-indexed": "Crawled – Currently Not Indexed"
        case "discovered-not-indexed": "Discovered – Currently Not Indexed"
        case "canonical": "Canonical Issue"
        case "robots": "Blocked by robots.txt"
        case "noindex": "Excluded by noindex"
        case "5xx": "Server Error (5xx)"
        default: fallback
        }
    }
    private static func file(_ target: String) -> URL { directory.appendingPathComponent((URL(string: target)?.host ?? target).lowercased().replacingOccurrences(of: "[^a-z0-9.-]", with: "_", options: .regularExpression) + ".json") }
    private static func normalize(_ value: String) -> String { value.lowercased().replacingOccurrences(of: "\u{feff}", with: "").trimmingCharacters(in: .whitespacesAndNewlines) }
    private static func csv(_ text: String) -> [[String]] {
        var output: [[String]] = [[]]; var field = ""; var quoted = false; let chars = Array(text); var i = 0
        while i < chars.count { let c = chars[i]; if c == "\"" { if quoted && i + 1 < chars.count && chars[i + 1] == "\"" { field.append(c); i += 1 } else { quoted.toggle() } } else if c == "," && !quoted { output[output.count - 1].append(field); field = "" } else if (c == "\n" || c == "\r") && !quoted { output[output.count - 1].append(field); field = ""; if !output.last!.isEmpty { output.append([]) }; if c == "\r" && i + 1 < chars.count && chars[i + 1] == "\n" { i += 1 } } else { field.append(c) }; i += 1 }
        if !field.isEmpty { output[output.count - 1].append(field) }; return output
    }
}
