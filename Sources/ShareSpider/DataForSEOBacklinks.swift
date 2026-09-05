import Foundation

/// DataForSEO credentials deliberately follow the same local-storage policy as
/// the existing PageSpeed and Ahrefs integrations.  They are kept outside the
/// app bundle, never exported, and can be changed in Settings.
enum DataForSEOCredentials {
    private struct Stored: Codable { var login: String; var password: String }
    private static var file: URL {
        let root = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("ShareSpider", isDirectory: true)
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root.appendingPathComponent("dataforseo-credentials.json")
    }
    static func load() -> (login: String, password: String) {
        guard let data = try? Data(contentsOf: file), let value = try? JSONDecoder().decode(Stored.self, from: data) else { return ("", "") }
        return (value.login, value.password)
    }
    static func save(login: String, password: String) {
        let value = Stored(login: login.trimmingCharacters(in: .whitespacesAndNewlines), password: password)
        guard let data = try? JSONEncoder().encode(value) else { return }
        try? data.write(to: file, options: [.atomic])
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
    }
    static var isConfigured: Bool { let value = load(); return !value.login.isEmpty && !value.password.isEmpty }
}

enum DataForSEOBacklinks {
    struct Progress: Sendable { var completed: Int; var total: Int; var message: String }
    enum ServiceError: LocalizedError { case notConfigured, invalidResponse, api(String)
        var errorDescription: String? { switch self { case .notConfigured: "Add your DataForSEO login and password in Settings → Integrations."; case .invalidResponse: "DataForSEO returned an unreadable response."; case .api(let message): message } }
    }

    private static var cacheDirectory: URL {
        let root = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("ShareSpider/backlinks-cache", isDirectory: true)
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }
    private static func cacheFile(target: String) -> URL {
        let name = target.lowercased().replacingOccurrences(of: "[^a-z0-9.-]", with: "_", options: .regularExpression)
        return cacheDirectory.appendingPathComponent(name + ".json")
    }
    static func cached(target: String) -> BacklinkReport? {
        guard let data = try? Data(contentsOf: cacheFile(target: target)), let report = try? JSONDecoder().decode(BacklinkReport.self, from: data), report.isFresh else { return nil }
        return report
    }
    static func clearCache(target: String) { try? FileManager.default.removeItem(at: cacheFile(target: target)) }

    static func enrich(target rawTarget: String, expectedURLs: [String], force: Bool = false, progress: @escaping @Sendable (Progress) async -> Void) async throws -> BacklinkReport {
        let target = normalizedTarget(rawTarget)
        guard !target.isEmpty else { throw ServiceError.invalidResponse }
        if !force, let cached = cached(target: target) {
            await progress(.init(completed: cached.pages.count, total: max(expectedURLs.count, cached.pages.count), message: "Using backlink cache from \(cached.fetchedAt.formatted(date: .abbreviated, time: .shortened))"))
            return cached
        }
        guard DataForSEOCredentials.isConfigured else { throw ServiceError.notConfigured }
        await progress(.init(completed: 0, total: max(expectedURLs.count, 1), message: "Backlink analysis started"))
        let summaryObject = try await request(path: "backlinks/summary/live", body: [["target": target]])
        var report = BacklinkReport(target: target, domain: parseDomainProfile(summaryObject, target: target), apiRequests: 1)
        await progress(.init(completed: 0, total: max(expectedURLs.count, 1), message: "Domain summary loaded"))

        // Domain Pages returns many targets in one response. Paginate only when
        // necessary; this avoids the expensive and rate-limited per-URL pattern.
        let goal = max(expectedURLs.count, 1)
        let pageLimit = 1_000
        var offset = 0
        var pageItems: [[String: Any]] = []
        repeat {
            let payload: [[String: Any]] = [["target": target, "limit": pageLimit, "offset": offset]]
            let object = try await request(path: "backlinks/domain_pages/live", body: payload)
            report.apiRequests += 1
            let batch = collectItems(object)
            pageItems.append(contentsOf: batch)
            await progress(.init(completed: min(pageItems.count, goal), total: goal, message: "Domain pages loaded: \(pageItems.count)"))
            guard batch.count == pageLimit, pageItems.count < max(goal, pageLimit) * 2 else { break }
            offset += batch.count
        } while true
        for item in pageItems {
            let metric = parsePageMetric(item)
            guard !metric.url.isEmpty else { continue }
            report.pages[urlKey(metric.url)] = metric
        }
        report.fetchedAt = Date()
        if let data = try? JSONEncoder().encode(report) { try? data.write(to: cacheFile(target: target), options: .atomic) }
        await progress(.init(completed: min(report.pages.count, goal), total: goal, message: "Backlink analysis completed · \(report.pages.count) pages enriched · \(report.apiRequests) API requests"))
        return report
    }

    /// Detailed sources are intentionally loaded only after the user clicks a
    /// Backlinks metric. This keeps routine enrichment cheap and fast.
    static func referringDomains(target rawTarget: String, limit: Int = 100) async throws -> [ReferringDomainDetail] {
        let target = normalizedTarget(rawTarget)
        guard DataForSEOCredentials.isConfigured else { throw ServiceError.notConfigured }
        let object = try await request(path: "backlinks/referring_domains/live", body: [["target": target, "limit": min(max(1, limit), 1_000)]])
        return collectItems(object).compactMap { item in
            let domain = (item["domain"] as? String) ?? ""
            guard !domain.isEmpty else { return nil }
            return ReferringDomainDetail(domain: domain, rank: value(item, "rank"), backlinks: value(item, "backlinks"), spamScore: value(item, "backlinks_spam_score"), referringPages: value(item, "referring_pages"), firstSeen: (item["first_seen"] as? String) ?? "")
        }
    }

    /// Loads every backlink record reported by DataForSEO. The service accepts
    /// no more than 1,000 rows per response, so we page through responses; this
    /// is not an application-level limit.
    static func backlinks(target rawTarget: String, progress: @escaping @Sendable (Progress) async -> Void) async throws -> [BacklinkSourceDetail] {
        let target = normalizedTarget(rawTarget)
        guard DataForSEOCredentials.isConfigured else { throw ServiceError.notConfigured }
        let batchSize = 1_000
        var offset = 0
        var expectedTotal: Int?
        var all: [BacklinkSourceDetail] = []

        while true {
            try Task.checkCancellation()
            // `all` contains both currently active links and records which
            // DataForSEO explicitly marks as lost.  We keep both in storage,
            // but the UI treats only `is_lost == false` as an active backlink.
            let object = try await request(path: "backlinks/backlinks/live", body: [["target": target, "limit": batchSize, "offset": offset, "backlinks_status_type": "all"]])
            if expectedTotal == nil { expectedTotal = totalCount(object) }
            let items = collectItems(object)
            all.append(contentsOf: items.compactMap(parseBacklink))
            let total = max(expectedTotal ?? all.count, all.count)
            await progress(.init(completed: all.count, total: total, message: "Loading donor links: \(all.count) / \(total)"))
            guard !items.isEmpty, items.count == batchSize, all.count < total else { break }
            offset += items.count
        }
        return all
    }

    static func backlinks(target rawTarget: String) async throws -> [BacklinkSourceDetail] {
        try await backlinks(target: rawTarget) { _ in }
    }

    /// Monthly backlink history made available by DataForSEO.  This is a
    /// separate aggregate endpoint, so it adds useful history without making
    /// thousands of extra requests for individual donor pages.
    static func history(target rawTarget: String) async throws -> [BacklinkHistoryPoint] {
        let target = normalizedTarget(rawTarget)
        guard !target.isEmpty, DataForSEOCredentials.isConfigured else { throw ServiceError.notConfigured }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        let object = try await request(path: "backlinks/history/live", body: [[
            "target": target,
            "date_from": "2019-01-01",
            "date_to": formatter.string(from: Date())
        ]])
        return collectItems(object).compactMap { item in
            let date = (item["date"] as? String) ?? ""
            guard !date.isEmpty else { return nil }
            return BacklinkHistoryPoint(
                date: date,
                backlinks: value(item, "backlinks"),
                newBacklinks: value(item, "new_backlinks"),
                lostBacklinks: value(item, "lost_backlinks"),
                referringDomains: value(item, "referring_domains"),
                newReferringDomains: value(item, "new_referring_domains"),
                lostReferringDomains: value(item, "lost_referring_domains")
            )
        }.sorted { $0.date < $1.date }
    }

    private static func request(path: String, body: [[String: Any]]) async throws -> [String: Any] {
        let credentials = DataForSEOCredentials.load()
        guard let url = URL(string: "https://api.dataforseo.com/v3/\(path)") else { throw ServiceError.invalidResponse }
        var request = URLRequest(url: url); request.httpMethod = "POST"; request.timeoutInterval = 60
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let token = Data("\(credentials.login):\(credentials.password)".utf8).base64EncodedString()
        request.setValue("Basic \(token)", forHTTPHeaderField: "Authorization")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw ServiceError.invalidResponse }
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw ServiceError.invalidResponse }
        if http.statusCode >= 300 { throw ServiceError.api(readableError(from: json, fallback: "DataForSEO HTTP \(http.statusCode)")) }
        if let code = int(json["status_code"]), code != 20000 { throw ServiceError.api(readableError(from: json, fallback: "DataForSEO status \(code)")) }
        if let task = (json["tasks"] as? [[String: Any]])?.first, let code = int(task["status_code"]), code != 20000 { throw ServiceError.api(readableError(from: task, fallback: "DataForSEO task status \(code)")) }
        return json
    }
    private static func message(from object: [String: Any]) -> String? { (object["status_message"] as? String) ?? (object["message"] as? String) }
    private static func readableError(from object: [String: Any], fallback: String) -> String {
        let raw = message(from: object) ?? fallback
        if raw.localizedCaseInsensitiveContains("verify your account") {
            return "DataForSEO account verification is required. Complete it in the DataForSEO user panel, then run Refresh Backlink Data again."
        }
        return raw
    }
    private static func collectItems(_ object: [String: Any]) -> [[String: Any]] {
        guard let task = (object["tasks"] as? [[String: Any]])?.first else { return [] }
        let result = task["result"] as? [[String: Any]] ?? []
        return result.flatMap { $0["items"] as? [[String: Any]] ?? [] }
    }
    private static func totalCount(_ object: [String: Any]) -> Int? {
        guard let task = (object["tasks"] as? [[String: Any]])?.first,
              let result = (task["result"] as? [[String: Any]])?.first else { return nil }
        return int(result["total_count"])
    }
    private static func parseBacklink(_ item: [String: Any]) -> BacklinkSourceDetail? {
        let sourceURL = (item["url_from"] as? String) ?? ""
        guard !sourceURL.isEmpty else { return nil }
        let platform = (item["domain_from_platform_type"] as? [String]) ?? []
        return BacklinkSourceDetail(
            sourceURL: sourceURL,
            targetURL: (item["url_to"] as? String) ?? "",
            sourceDomain: (item["domain_from"] as? String) ?? "",
            domainRank: value(item, "domain_from_rank"),
            pageRank: value(item, "page_from_rank"),
            anchor: (item["anchor"] as? String) ?? "",
            dofollow: bool(item["dofollow"]),
            firstSeen: (item["first_seen"] as? String) ?? "",
            previousSeen: (item["prev_seen"] as? String) ?? "",
            lastSeen: (item["last_seen"] as? String) ?? "",
            isLost: bool(item["is_lost"]),
            broken: bool(item["is_broken"]),
            sourceTitle: (item["page_from_title"] as? String) ?? "",
            sourceStatusCode: value(item, "page_from_status_code"),
            spamScore: value(item, "backlink_spam_score"),
            platformTypes: platform,
            semanticLocation: (item["semantic_location"] as? String) ?? "",
            linkType: (item["item_type"] as? String) ?? ""
        )
    }
    private static func parseDomainProfile(_ object: [String: Any], target: String) -> BacklinkDomainProfile {
        let root = ((object["tasks"] as? [[String: Any]])?.first?["result"] as? [[String: Any]])?.first ?? [:]
        let total = value(root, "backlinks")
        let nofollow = value(root, "referring_pages_nofollow")
        return BacklinkDomainProfile(target: target, rank: value(root, "rank"), backlinks: total, referringDomains: value(root, "referring_domains"), referringMainDomains: value(root, "referring_main_domains"), referringPages: value(root, "referring_pages"), referringIPs: value(root, "referring_ips"), referringSubnets: value(root, "referring_subnets"), dofollowBacklinks: max(0, total - nofollow), nofollowBacklinks: nofollow, brokenBacklinks: value(root, "broken_backlinks"), spamScore: value(root, "backlinks_spam_score"))
    }
    private static func parsePageMetric(_ item: [String: Any]) -> BacklinkPageMetric {
        let summary = item["page_summary"] as? [String: Any] ?? item
        let total = value(summary, "backlinks")
        let nofollow = value(summary, "referring_pages_nofollow")
        return BacklinkPageMetric(url: (item["page"] as? String) ?? (item["url"] as? String) ?? (item["target"] as? String) ?? "", backlinks: total, referringDomains: value(summary, "referring_domains"), referringMainDomains: value(summary, "referring_main_domains"), referringPages: value(summary, "referring_pages"), rank: value(summary, "rank"), spamScore: value(summary, "backlinks_spam_score"), brokenBacklinks: value(summary, "broken_backlinks"), dofollowBacklinks: max(0, total - nofollow), nofollowBacklinks: nofollow, referringIPs: value(summary, "referring_ips"), referringSubnets: value(summary, "referring_subnets"))
    }
    private static func value(_ item: [String: Any], _ key: String) -> Int { int(item[key]) ?? 0 }
    private static func int(_ value: Any?) -> Int? { if let value = value as? Int { return value }; if let value = value as? Double { return Int(value) }; if let value = value as? String { return Int(value) }; return nil }
    private static func bool(_ value: Any?) -> Bool {
        if let value = value as? Bool { return value }
        if let value = value as? NSNumber { return value.boolValue }
        if let value = value as? String { return ["true", "1", "yes"].contains(value.lowercased()) }
        return false
    }
    static func urlKey(_ raw: String) -> String { raw.trimmingCharacters(in: CharacterSet(charactersIn: "/")).lowercased() }
    private static func normalizedTarget(_ raw: String) -> String { (URL(string: raw)?.host ?? raw).lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "/")) }
}
