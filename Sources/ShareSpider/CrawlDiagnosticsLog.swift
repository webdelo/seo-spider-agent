import Foundation

/// Per-run, client-side evidence for diagnosing why a site treats the HTTP
/// crawler differently from a browser. It deliberately records no cookies,
/// authorization headers or response bodies.
actor CrawlDiagnosticsLog {
    let fileURL: URL

    init(startURL: String, date: Date = Date()) {
        let downloads = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first!
        let host = URL(string: startURL)?.host ?? "project"
        let safeHost = host.replacingOccurrences(of: "[^A-Za-z0-9.-]", with: "-", options: .regularExpression)
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd_HH-mm-ss"
        fileURL = downloads.appendingPathComponent("log-\(formatter.string(from: date))-\(safeHost).txt")
        try? "ShareSpider crawl diagnostics\nProject: \(startURL)\nStarted: \(ISO8601DateFormatter().string(from: date))\n\n".write(to: fileURL, atomically: true, encoding: .utf8)
    }

    func configuration(settings: CrawlSettings) {
        append("CONFIG\tconcurrency=\(settings.concurrency)\ttimeoutSeconds=\(settings.timeout)\tuserAgent=\(settings.userAgent)\taccept=text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.7\tacceptLanguage=en-US,en;q=0.9")
    }

    /// Write only anomalies and transport decisions, rather than every healthy
    /// page: large crawls remain readable and the file cannot become another
    /// memory or disk bottleneck.
    func record(_ record: CrawlRecord, event: String) {
        let timestamp = ISO8601DateFormatter().string(from: Date())
        append([
            timestamp,
            event,
            "url=\(record.url.absoluteString)",
            "status=\(record.statusCode.map(String.init) ?? "none")",
            "originalStatus=\(record.originalStatus.map(String.init) ?? "none")",
            "cdpStatus=\(record.cdpStatus.map(String.init) ?? "none")",
            "transport=\(record.transportUsed)",
            "contentType=\(record.contentType)",
            "bytes=\(record.size)",
            "durationMs=\(Int(record.responseTime * 1_000))",
            "suspectedWAF=\(record.suspectedWAF)",
            "verification=\(record.verificationResult)",
            "error=\(record.error)"
        ].map(sanitize).joined(separator: "\t"))
    }

    func transition(url: URL, from: String, to: String, reason: String) {
        append([ISO8601DateFormatter().string(from: Date()), "TRANSPORT", "url=\(url.absoluteString)", "from=\(from)", "to=\(to)", "reason=\(reason)"].map(sanitize).joined(separator: "\t"))
    }

    private func append(_ line: String) {
        guard let data = (line + "\n").data(using: .utf8), let handle = try? FileHandle(forWritingTo: fileURL) else { return }
        defer { try? handle.close() }
        try? handle.seekToEnd()
        try? handle.write(contentsOf: data)
    }

    private func sanitize(_ value: String) -> String {
        value.replacingOccurrences(of: "\n", with: " ").replacingOccurrences(of: "\r", with: " ").replacingOccurrences(of: "\t", with: " ")
    }
}
