import Foundation

/// A separately cached donor-domain export. Ahrefs is intentionally not folded
/// into DataForSEO metrics: the two providers keep distinct indexes and update
/// schedules, which is exactly what the comparison needs to expose.
struct AhrefsBacklinkImport: Codable, Hashable, Sendable {
    var target = ""
    var importedAt = Date()
    var domains: [String] = []
    /// DR is supplied by the same referring-domain response, so it does not
    /// require one API call per donor merely to sort the comparison table.
    var domainRatings: [String: Double] = [:]
    var spamDomains: [String] = []
    var linkCount = 0
    /// Kept for compatibility with snapshots made before pagination.
    var limit = 100

    enum CodingKeys: String, CodingKey { case target, importedAt, domains, domainRatings, spamDomains, linkCount, limit }
    init(target: String = "", importedAt: Date = Date(), domains: [String] = [], domainRatings: [String: Double] = [:], spamDomains: [String] = [], linkCount: Int = 0, limit: Int = 100) {
        self.target = target; self.importedAt = importedAt; self.domains = domains; self.domainRatings = domainRatings; self.spamDomains = spamDomains; self.linkCount = linkCount; self.limit = limit
    }
    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        target = try values.decodeIfPresent(String.self, forKey: .target) ?? ""
        importedAt = try values.decodeIfPresent(Date.self, forKey: .importedAt) ?? Date()
        domains = try values.decodeIfPresent([String].self, forKey: .domains) ?? []
        domainRatings = try values.decodeIfPresent([String: Double].self, forKey: .domainRatings) ?? [:]
        spamDomains = try values.decodeIfPresent([String].self, forKey: .spamDomains) ?? []
        linkCount = try values.decodeIfPresent(Int.self, forKey: .linkCount) ?? domains.count
        limit = try values.decodeIfPresent(Int.self, forKey: .limit) ?? 100
    }
}

enum AhrefsBacklinkService {
    private static var directory: URL {
        let root = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("ShareSpider/ahrefs-backlinks", isDirectory: true)
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    static func load(target: String) -> AhrefsBacklinkImport? {
        guard let data = try? Data(contentsOf: cacheURL(target: target)) else { return nil }
        return try? JSONDecoder().decode(AhrefsBacklinkImport.self, from: data)
    }

    struct Progress: Sendable { var completed: Int; var total: Int; var message: String }

    /// Retrieve each available page instead of silently treating the first
    /// page as the complete donor profile. The documented endpoint defaults to
    /// 1,000 rows; the continuation offset is attempted only after a full page
    /// is returned and duplicate pages stop safely.
    static func referringDomains(target rawTarget: String, progress: @escaping @Sendable (Progress) async -> Void = { _ in }) async throws -> AhrefsBacklinkImport {
        guard AhrefsKeychain.isConfigured else { throw ServiceError.notConfigured }
        let target = normalizedTarget(rawTarget)
        guard !target.isEmpty else { throw ServiceError.invalidTarget }
        let ownDomain = GSCBacklinkImportService.normalizedDomain(target)
        var ratings: [String: Double] = [:]
        var domains = Set<String>()
        var spamDomains = Set<String>()
        var linkCount = 0
        var offset = 0
        let pageSize = 1_000

        while true {
            try Task.checkCancellation()
            let values = try await page(target: target, offset: offset, limit: pageSize)
            guard !values.isEmpty else { break }
            let before = domains.count
            for item in values {
                guard let raw = item["domain"] as? String else { continue }
                let domain = GSCBacklinkImportService.normalizedDomain(raw)
                guard !domain.isEmpty, domain != ownDomain else { continue }
                domains.insert(domain)
                let rating = (item["domain_rating"] as? NSNumber)?.doubleValue ?? (item["domain_rating"] as? String).flatMap(Double.init)
                if let rating { ratings[domain] = max(ratings[domain] ?? 0, rating) }
                if (item["is_spam"] as? Bool) == true || (item["is_spam"] as? NSNumber)?.boolValue == true { spamDomains.insert(domain) }
                linkCount += int(item["links_to_target"]) ?? 1
            }
            await progress(.init(completed: domains.count, total: max(domains.count, offset + values.count), message: "Loaded \\(domains.count) donor domains; requesting the next Ahrefs page…"))
            // Never require a full page. Ahrefs silently caps each response at
            // a plan-dependent row count (as low as 100 on limited tiers)
            // regardless of the requested `limit`, so `values.count ==
            // pageSize` falsely ended pagination after the very first page and
            // discarded the rest of the donor profile. Keep advancing by
            // offset until a page adds no new donors (a repeated page when a
            // server ignores offset) or returns nothing.
            guard domains.count > before else { break }
            offset += values.count
        }
        let orderedDomains = domains.sorted()
        guard !orderedDomains.isEmpty else { throw ServiceError.empty }
        await progress(.init(completed: orderedDomains.count, total: orderedDomains.count, message: "All available Ahrefs donor domains loaded."))
        let result = AhrefsBacklinkImport(target: target, importedAt: Date(), domains: orderedDomains, domainRatings: ratings, spamDomains: spamDomains.sorted(), linkCount: linkCount, limit: pageSize)
        if let cached = try? JSONEncoder().encode(result) { try? cached.write(to: cacheURL(target: target), options: .atomic) }
        return result
    }

    private static func page(target: String, offset: Int, limit: Int) async throws -> [[String: Any]] {
        var components = URLComponents(string: "https://api.ahrefs.com/v3/site-explorer/refdomains")!
        var items: [URLQueryItem] = [
            .init(name: "target", value: target), .init(name: "mode", value: "domain"), .init(name: "history", value: "live"),
            .init(name: "limit", value: String(limit)),
            .init(name: "select", value: "domain,domain_rating,is_spam,links_to_target"), .init(name: "output", value: "json")
        ]
        if offset > 0 { items.append(.init(name: "offset", value: String(offset))) }
        components.queryItems = items
        var request = URLRequest(url: components.url!)
        request.timeoutInterval = 45
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("Bearer \(AhrefsKeychain.load())", forHTTPHeaderField: "Authorization")
        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else { throw ServiceError.request(message(data), status: status) }
        let object = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        return (object?["refdomains"] as? [[String: Any]]) ?? []
    }

    private static func int(_ value: Any?) -> Int? {
        if let value = value as? Int { return value }
        if let value = value as? NSNumber { return value.intValue }
        if let value = value as? String { return Int(value) }
        return nil
    }

    private static func normalizedTarget(_ raw: String) -> String {
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: value.contains("://") ? value : "https://\(value)") else { return "" }
        return url.host ?? value
    }
    private static func cacheURL(target: String) -> URL {
        let name = GSCBacklinkImportService.normalizedDomain(target).replacingOccurrences(of: "[^a-z0-9.-]", with: "_", options: .regularExpression)
        return directory.appendingPathComponent("\(name).json")
    }
    private static func message(_ data: Data) -> String {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return "Ahrefs request failed." }
        return (object["message"] as? String) ?? (object["error"] as? String) ?? "Ahrefs request failed."
    }
    enum ServiceError: LocalizedError {
        case notConfigured, invalidTarget, empty, request(String, status: Int)
        var errorDescription: String? {
            switch self {
            case .notConfigured: "Configure an Ahrefs API key in Settings first."
            case .invalidTarget: "The project domain is invalid."
            case .empty: "Ahrefs returned no referring domains for this target."
            case .request(let message, let status): "Ahrefs referring-domain request failed (HTTP \(status)): \(message)"
            }
        }
    }
}
