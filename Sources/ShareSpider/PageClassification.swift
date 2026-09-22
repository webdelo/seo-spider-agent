import Foundation

struct PageSignals: Sendable { let url: URL; let title: String; let h1: String; let schemaTypes: Set<String>; let ogType: String; let hasPrice: Bool; let hasAddToCart: Bool; let hasBookingForm: Bool; let hasAuthor: Bool; let hasPublishedDate: Bool; let hasPagination: Bool; let repeatedCardCount: Int; let h2Count: Int; let wordCount: Int; let currencyAmountCount: Int; let hasContactDetails: Bool }
private struct RuleSet: Decodable { let pageType: String; let category: String?; let minimumScore: Double?; let rules: [Rule] }
private struct Rule: Decodable { let signal: String; let `operator`: String; let value: String; let weight: Double }
struct ClassificationResult { let type: String; let aiBustCategory: String; let confidence: Double; let score: Double; let evidence: [String] }

enum PageClassifier {
    private static let rules: [RuleSet] = {
        let filenames = ["page-classification-rules", "ai-bust-page-classification-rules"]
        return filenames.flatMap { name -> [RuleSet] in
            guard let url = AppResources.url(forResource: name, withExtension: "json"),
                  let data = try? Data(contentsOf: url),
                  let value = try? JSONDecoder().decode([RuleSet].self, from: data) else { return [] }
            return value
        }
    }()
    static func classify(_ s: PageSignals) -> ClassificationResult {
        if s.url.path == "/" || s.url.path.isEmpty { return ClassificationResult(type: "Homepage", aiBustCategory: "", confidence: 1, score: 100, evidence: ["Root URL"]) }
        if s.url.path.range(of: #"/(news|novosti)(/|$)"#, options: .regularExpression) != nil {
            return ClassificationResult(type: "News", aiBustCategory: "", confidence: 0.95, score: 95, evidence: ["URL news section"])
        }
        let candidates = rules.map { set -> (RuleSet, Double, [String]) in
            let found = set.rules.filter { ruleMatches($0, s) }
            return (set, found.reduce(0) { $0 + $1.weight }, found.map { "\($0.signal) \($0.operator) \($0.value)" })
        }.filter { set, score, _ in
            // AI Bust pages require stronger evidence than ordinary page types: a clear URL
            // signal or corroborating heading/title signals, not a casual mention in body chrome.
            score >= (set.minimumScore ?? (set.pageType == "AI Bust Page" ? 70 : 25))
        }.sorted { $0.1 > $1.1 }
        guard let best = candidates.first, best.1 >= 25 else { return ClassificationResult(type: "Unknown", aiBustCategory: "", confidence: 0, score: candidates.first?.1 ?? 0, evidence: []) }
        let confidence = min(0.99, max(0.55, best.1 / 100))
        let category = best.0.pageType == "AI Bust Page" ? (best.0.category ?? "") : ""
        let evidence = category.isEmpty ? best.2 : ["AI Bust subtype: \(category)"] + best.2
        return ClassificationResult(type: best.0.pageType, aiBustCategory: category, confidence: confidence, score: best.1, evidence: evidence)
    }
    private static func ruleMatches(_ r: Rule, _ s: PageSignals) -> Bool {
        let string: String; let bool: Bool?; let number: Int?
        switch r.signal { case "url": string = s.url.absoluteString; bool = nil; number = nil; case "title": string = s.title; bool = nil; number = nil; case "h1": string = s.h1; bool = nil; number = nil; case "schemaTypes": string = s.schemaTypes.joined(separator: "|"); bool = nil; number = nil; case "ogType": string = s.ogType; bool = nil; number = nil; case "hasPrice": string = ""; bool = s.hasPrice; number = nil; case "hasAddToCart": string = ""; bool = s.hasAddToCart; number = nil; case "hasBookingForm": string = ""; bool = s.hasBookingForm; number = nil; case "hasAuthor": string = ""; bool = s.hasAuthor; number = nil; case "hasPublishedDate": string = ""; bool = s.hasPublishedDate; number = nil; case "hasPagination": string = ""; bool = s.hasPagination; number = nil; case "hasContactDetails": string = ""; bool = s.hasContactDetails; number = nil; case "repeatedCardCount": string = ""; bool = nil; number = s.repeatedCardCount; case "h2Count": string = ""; bool = nil; number = s.h2Count; case "wordCount": string = ""; bool = nil; number = s.wordCount; case "currencyAmountCount": string = ""; bool = nil; number = s.currencyAmountCount; default: return false }
        switch r.operator { case "equals": return (bool.map { String($0) == r.value }) ?? (number.map { String($0) == r.value }) ?? (string.lowercased() == r.value.lowercased()); case "contains": return string.localizedCaseInsensitiveContains(r.value); case "containsAny": return r.value.split(separator: "|").contains { string.localizedCaseInsensitiveContains(String($0)) }; case "matchesRegex": return (try? NSRegularExpression(pattern: r.value, options: .caseInsensitive).firstMatch(in: string, range: NSRange(string.startIndex..., in: string))) != nil; case "greaterThan": return (number ?? 0) > (Int(r.value) ?? 0); case "lessThan": return (number ?? 0) < (Int(r.value) ?? 0); default: return false }
    }
}
