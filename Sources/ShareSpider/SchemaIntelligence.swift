import Foundation

struct SchemaEntity: Sendable { var id: String; var types: Set<String>; var properties: [String: AnySendable] }
struct AnySendable: @unchecked Sendable { let value: Any }
struct SchemaInsight: Sendable { var entities: [SchemaEntity]; var primaryType: String; var compatibility: String; var completeness: Double }

enum SchemaIntelligence {
    static let requiredFields: [String: [String]] = [
        "Organization": ["name", "url"], "LocalBusiness": ["name", "address", "url"],
        "Product": ["name", "image", "offers"], "Article": ["headline", "datePublished", "author"],
        "BlogPosting": ["headline", "datePublished", "author"], "NewsArticle": ["headline", "datePublished", "author"],
        "FAQPage": ["mainEntity"], "BreadcrumbList": ["itemListElement"],
        "Review": ["reviewRating", "author"], "AggregateRating": ["ratingValue", "reviewCount"]
    ]
    static func analyze(jsonLD: String, pageType: String) -> SchemaInsight {
        guard let data = jsonLD.data(using: .utf8), let root = try? JSONSerialization.jsonObject(with: data) else { return SchemaInsight(entities: [], primaryType: "", compatibility: "Missing", completeness: 0) }
        var entities: [SchemaEntity] = []; collect(root, into: &entities)
        let contentTypes: Set<String> = ["Product", "Service", "MedicalProcedure", "Article", "BlogPosting", "NewsArticle", "FAQPage", "Physician", "Person", "LocalBusiness"]
        let primary = entities.max { score($0, contentTypes: contentTypes) < score($1, contentTypes: contentTypes) }
        let type = primary?.types.first ?? ""
        let compatible = compatibility(pageType: pageType, schema: type)
        return SchemaInsight(entities: entities, primaryType: type, compatibility: compatible, completeness: completeness(primary))
    }
    static func validations(jsonLD: String) -> [SchemaValidation] {
        guard let data = jsonLD.data(using: .utf8), let root = try? JSONSerialization.jsonObject(with: data) else { return [] }
        var entities: [SchemaEntity] = []; collect(root, into: &entities)
        return entities.flatMap { entity in entity.types.compactMap { type in
            guard let required = requiredFields[type] else { return nil }
            let missing = required.filter { property in
                guard let value = entity.properties[property]?.value else { return true }
                if let string = value as? String { return string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
                if let array = value as? [Any] { return array.isEmpty }
                return false
            }
            return missing.isEmpty ? nil : SchemaValidation(type: type, missing: missing)
        } }
    }
    private static func collect(_ value: Any, into output: inout [SchemaEntity]) {
        if let values = value as? [Any] { values.forEach { collect($0, into: &output) }; return }
        guard let dict = value as? [String: Any] else { return }
        if let graph = dict["@graph"] { collect(graph, into: &output) }
        let rawTypes = dict["@type"] as? [String] ?? (dict["@type"] as? String).map { [$0] } ?? []
        if !rawTypes.isEmpty { output.append(SchemaEntity(id: dict["@id"] as? String ?? "", types: Set(rawTypes), properties: dict.mapValues(AnySendable.init))) }
        for (_, value) in dict where value is [String: Any] || value is [Any] { collect(value, into: &output) }
    }
    private static func score(_ entity: SchemaEntity, contentTypes: Set<String>) -> Int { var value = entity.types.contains(where: contentTypes.contains) ? 50 : 0; if entity.types.contains("BreadcrumbList") || entity.types.contains("WebSite") || entity.types.contains("ImageObject") { value -= 50 }; if entity.types.contains("Organization") { value -= 30 }; if entity.properties["mainEntityOfPage"] != nil { value += 30 }; return value }
    private static func compatibility(pageType: String, schema: String) -> String {
        guard !schema.isEmpty else { return "Missing" }; let allowed: [String: Set<String>] = ["Product": ["Product"], "Service": ["Service", "MedicalProcedure"], "Article": ["Article", "BlogPosting", "NewsArticle"], "Doctor": ["Physician", "Person"], "Contact": ["LocalBusiness", "Organization"]]; guard let expected = allowed[pageType] else { return "Not applicable" }; return expected.contains(schema) ? "Compatible" : "Mismatch"
    }
    private static func completeness(_ entity: SchemaEntity?) -> Double { guard let entity else { return 0 }; let required = ["name"]; let recommended = ["description", "image", "url"]; let present = { (path: String) in entity.properties[path].map { if let s = $0.value as? String { return !s.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }; return true } ?? false }; let requiredScore = Double(required.filter(present).count) / Double(required.count) * 0.6; let recommendedScore = Double(recommended.filter(present).count) / Double(recommended.count) * 0.4; return requiredScore + recommendedScore }
}
