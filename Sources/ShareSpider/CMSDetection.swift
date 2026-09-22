import Foundation

private struct CMSRuleSet: Decodable { let name: String; let minimumScore: Double; let rules: [CMSRule] }
private struct CMSRule: Decodable { let signal: String; let `operator`: String; let value: String; let weight: Double }
struct CMSDetection { var name: String = "Unknown"; var confidence: Double = 0; var evidence: [String] = [] }

/// CMS signatures are data-driven: extend cms-detection-rules.json instead of
/// adding another conditional branch to the crawler.
enum CMSDetector {
    private static let definitions: [CMSRuleSet] = {
        guard let url = AppResources.url(forResource: "cms-detection-rules", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let value = try? JSONDecoder().decode([CMSRuleSet].self, from: data) else { return [] }
        return value
    }()

    static func detect(html: String, headers: [String: String]) -> CMSDetection {
        let headerText = headers.map { "\($0.key): \($0.value)" }.joined(separator: "\n")
        let candidates = definitions.compactMap { set -> (CMSRuleSet, Double, [String])? in
            let hits = set.rules.filter { rule in matches(rule, html: html, headers: headerText) }
            let score = hits.reduce(0) { $0 + $1.weight }
            guard score >= set.minimumScore else { return nil }
            return (set, score, hits.map { "\($0.signal): \($0.value)" })
        }.sorted { $0.1 > $1.1 }
        guard let best = candidates.first else { return CMSDetection() }
        return CMSDetection(name: best.0.name, confidence: min(0.99, best.1 / 100), evidence: best.2)
    }

    private static func matches(_ rule: CMSRule, html: String, headers: String) -> Bool {
        let text = rule.signal == "headers" ? headers : html
        switch rule.operator {
        case "contains": return text.localizedCaseInsensitiveContains(rule.value)
        case "matchesRegex": return (try? NSRegularExpression(pattern: rule.value, options: [.caseInsensitive]).firstMatch(in: text, range: NSRange(text.startIndex..., in: text))) != nil
        default: return false
        }
    }
}
