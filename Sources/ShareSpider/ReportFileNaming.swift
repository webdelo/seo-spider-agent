import Foundation

enum ReportFileNaming {
    static func csvFileName(report: String, site: String, date: Date = Date()) -> String {
        let host = URL(string: site)?.host ?? site
        let safeHost = host.replacingOccurrences(of: "[^A-Za-z0-9.-]", with: "-", options: .regularExpression)
        let safeReport = report
            .replacingOccurrences(of: ".csv", with: "", options: [.caseInsensitive])
            .replacingOccurrences(of: "[^A-Za-z0-9 ._-]", with: "-", options: .regularExpression)
        let formatter = DateFormatter(); formatter.locale = Locale(identifier: "en_US_POSIX"); formatter.dateFormat = "yyyy-MM-dd_HH-mm-ss"
        return "SEOSpiderAgent-\(safeReport)-\(safeHost.isEmpty ? "site" : safeHost)-\(formatter.string(from: date)).csv"
    }
    static func stem(for startURL: String, report: String, date: Date = Date()) -> String {
        let host = URL(string: startURL)?.host ?? startURL
        let safeHost = host.replacingOccurrences(of: "[^A-Za-z0-9.-]", with: "-", options: .regularExpression)
        let formatter = DateFormatter(); formatter.locale = Locale(identifier: "en_US_POSIX"); formatter.dateFormat = "yyyy-MM-dd_HH-mm-ss"
        return "\(safeHost)_\(formatter.string(from: date))_\(report)"
    }
    static var downloadsDirectory: URL {
        let directory = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first!.appendingPathComponent("ShareSpider Reports", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }
    static func downloadsURL(for startURL: String, report: String) -> URL { downloadsDirectory.appendingPathComponent(stem(for: startURL, report: report) + ".pdf") }
}
