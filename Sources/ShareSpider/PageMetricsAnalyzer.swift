import Foundation

/// Local, deterministic thresholds. They are ShareSpider recommendations, not
/// Google or model-provider limits, and can be adjusted in one place without
/// touching crawler or UI code.
struct PageMetricsConfiguration: Sendable {
    var weightWarning = 3 * 1_024 * 1_024
    var weightHigh = 5 * 1_024 * 1_024
    var weightCritical = 10 * 1_024 * 1_024
    var anomalyMultiplier = 2.5
    var aiHTMLWarning = 600 * 1_024
    var aiHTMLCritical = 1_500 * 1_024
    var aiTokenWarning = 150_000
    var aiTokenCritical = 375_000
    var domNodeWarning = 3_000
    var domNodeCritical = 8_000
    var contentRatioWarning = 0.08
    var inlineDataWarning = 300 * 1_024
}

enum PageMetricsAnalyzer {
    static let configuration = PageMetricsConfiguration()

    static func primaryCause(for record: CrawlRecord) -> String {
        let values: [(String, Int)] = [
            ("Images", record.imageResourceSize), ("JavaScript", record.javascriptResourceSize),
            ("CSS", record.cssResourceSize), ("Fonts", record.fontResourceSize),
            ("Third-party", record.thirdPartyResourceSize), ("HTML", record.htmlSize),
            ("Other", record.otherResourceSize)
        ]
        return values.max(by: { $0.1 < $1.1 }).map { $0.1 > 0 ? $0.0 : "HTML" } ?? "Unknown"
    }

    static func aiAssessment(for record: CrawlRecord) -> String {
        let c = configuration
        let inline = record.inlineJavaScriptSize + record.inlineCSSSize + record.embeddedJSONSize
        if record.htmlSize >= c.aiHTMLCritical || record.estimatedHTMLTokens >= c.aiTokenCritical || record.domNodeCount >= c.domNodeCritical { return "Very Heavy for AI Parsing" }
        // A low text-to-HTML ratio is useful diagnostic context, but it must
        // not by itself turn a page that is below every project size limit into
        // a “heavy” finding. The headline status is reserved for an actual
        // HTML/token/DOM/inline-data threshold breach.
        if record.htmlSize >= c.aiHTMLWarning || record.estimatedHTMLTokens >= c.aiTokenWarning || record.domNodeCount >= c.domNodeWarning || inline >= c.inlineDataWarning { return "Heavy for AI Parsing" }
        return "AI Friendly"
    }

    static func median(_ values: [Int]) -> Int {
        let sorted = values.sorted()
        guard !sorted.isEmpty else { return 0 }
        let middle = sorted.count / 2
        return sorted.count.isMultiple(of: 2) ? (sorted[middle - 1] + sorted[middle]) / 2 : sorted[middle]
    }

    static func typeMedians(_ records: [CrawlRecord]) -> [String: Int] {
        Dictionary(grouping: records.filter(\.isSEOPage), by: \.pageType).compactMapValues { group in
            guard group.count >= 3 else { return nil }
            return median(group.map(\.pageWeight))
        }
    }

    static func isAbnormallyHeavy(_ record: CrawlRecord, medians: [String: Int]) -> Bool {
        guard record.pageWeight > configuration.weightWarning,
              let median = medians[record.pageType], median > 0 else { return false }
        return Double(record.pageWeight) > Double(median) * configuration.anomalyMultiplier
    }
}
