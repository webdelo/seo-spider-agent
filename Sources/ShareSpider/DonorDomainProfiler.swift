import Foundation

/// Ahrefs, Ubersuggest and the GSC "Top linking sites" export provide a donor
/// domain, but not the exact page containing the backlink.  This performs a
/// bounded homepage check and reports classifications as domain-level signals.
/// It never presents them as a verified type of a particular backlink page.
enum DonorDomainProfiler {
    private enum Signal: Sendable, Equatable {
        case profile
        case catalog
        case article
        case spam
        case unknown
    }

    static func profile(
        domains rawDomains: [String],
        links: Int,
        knownSpam rawKnownSpam: Set<String> = [],
        onProgress: @escaping @Sendable (_ completed: Int, _ total: Int) async -> Void
    ) async -> BacklinkSourceStats {
        let domains = Array(Set(rawDomains.map(GSCBacklinkImportService.normalizedDomain).filter { !$0.isEmpty })).sorted()
        let knownSpam = Set(rawKnownSpam.map(GSCBacklinkImportService.normalizedDomain))
        guard !domains.isEmpty else { return BacklinkSourceStats(links: links) }

        let limiter = DonorProfileLimiter(limit: 4)
        var signals: [Signal] = []
        // A domain-only provider can contain thousands of rows. Publishing a
        // SwiftUI update for every completed homepage check makes the
        // Backlinks view repeatedly rebuild its charts and comparison table.
        // Keep feedback smooth without turning progress reporting into the
        // dominant workload (about 20 updates for a complete profile).
        let progressStep = max(1, Int(ceil(Double(domains.count) / 20.0)))
        await withTaskGroup(of: Signal.self) { group in
            for domain in domains {
                group.addTask {
                    await limiter.acquire()
                    let signal = await classify(domain: domain, knownSpam: knownSpam)
                    await limiter.release()
                    return signal
                }
            }
            var completed = 0
            for await signal in group {
                signals.append(signal)
                completed += 1
                if completed == domains.count || completed % progressStep == 0 {
                    await onProgress(completed, domains.count)
                }
            }
        }

        return BacklinkSourceStats(
            links: links,
            donors: domains.count,
            profiles: signals.filter { $0 == .profile }.count,
            catalogs: signals.filter { $0 == .catalog }.count,
            articles: signals.filter { $0 == .article }.count,
            hreflang: 0,
            broken: 0,
            spam: signals.filter { $0 == .spam }.count,
            unclassified: signals.filter { $0 == .unknown }.count
        )
    }

    private static func classify(domain: String, knownSpam: Set<String>) async -> Signal {
        if knownSpam.contains(domain) || matchesSpam(domain) { return .spam }
        guard let url = URL(string: "https://\(domain)/") else { return heuristic(domain) }
        var request = URLRequest(url: url)
        request.timeoutInterval = 7
        request.setValue("ShareSpider/1.4 (+https://github.com/ShareSpider)", forHTTPHeaderField: "User-Agent")
        request.setValue("text/html,application/xhtml+xml;q=0.9,*/*;q=0.5", forHTTPHeaderField: "Accept")
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              let http = response as? HTTPURLResponse,
              (200..<400).contains(http.statusCode) else {
            return heuristic(domain)
        }
        let text = String(decoding: data.prefix(250_000), as: UTF8.self).lowercased()
        return heuristic("\(domain) \(text)")
    }

    private static func heuristic(_ text: String) -> Signal {
        let value = text.lowercased()
        if matchesSpam(value) { return .spam }
        if contains(value, [
            "business directory", "business listings", "add your business",
            "claim your listing", "local directory", "company directory",
            "каталог компаний", "добавить компанию", "справочник компаний"
        ]) { return .catalog }
        if contains(value, [
            "user profile", "member profile", "view profile", "public profile",
            "профиль пользователя", "страница пользователя"
        ]) { return .profile }
        if contains(value, [
            "<article", "blog", "news", "magazine", "journal", "editorial",
            "новости", "статьи", "блог"
        ]) { return .article }
        return .unknown
    }

    private static func matchesSpam(_ value: String) -> Bool {
        contains(value.lowercased(), [
            "viagra", "cialis", "porn", "xxx", "online casino",
            "казино онлайн", "порно", "быстрый займ"
        ])
    }

    private static func contains(_ value: String, _ phrases: [String]) -> Bool {
        phrases.contains { value.contains($0) }
    }
}

private actor DonorProfileLimiter {
    private let limit: Int
    private var active = 0
    private var waiting: [CheckedContinuation<Void, Never>] = []
    init(limit: Int) { self.limit = max(1, limit) }

    func acquire() async {
        if active < limit {
            active += 1
            return
        }
        // Suspending is essential here. The previous 50 ms polling loop woke
        // every queued domain over and over (hundreds of actor turns per
        // second) while only four network checks could make progress.
        await withCheckedContinuation { continuation in
            waiting.append(continuation)
        }
    }

    func release() {
        if !waiting.isEmpty {
            let next = waiting.removeFirst()
            // Hand the just-freed slot directly to the next waiter; `active`
            // remains unchanged because the number of active workers does.
            next.resume()
            return
        }
        active = max(0, active - 1)
    }
}
