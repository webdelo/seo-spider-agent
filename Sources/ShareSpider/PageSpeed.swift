import Foundation

struct PageSpeedResult: Identifiable, Codable {
    var id: String { "\(url)#\(strategy)" }
    var url: String
    var strategy = "mobile"
    var score: Int?
    var lcp: String = "—"
    var cls: String = "—"
    var error: String = ""
}
/// PageSpeed credentials are kept in ShareSpider's private Application Support
/// folder instead of Keychain. This deliberately avoids a macOS keychain prompt
/// during every automatic PageSpeed check. The file is owner-readable only.
enum PSIKeychain {
    private static var keyURL: URL {
        let folder = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("ShareSpider", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder.appendingPathComponent("pagespeed-api-key.txt")
    }
    static func load() -> String {
        (try? String(contentsOf: keyURL, encoding: .utf8))?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }
    static func save(_ key: String) {
        let value = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { try? FileManager.default.removeItem(at: keyURL); return }
        try? value.write(to: keyURL, atomically: true, encoding: .utf8)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: keyURL.path)
    }
}
enum PageSpeedService {
    /// Default lightweight site-speed check: the homepage once for mobile and once for desktop.
    static func checkHomepage(_ url: URL) async -> [PageSpeedResult] {
        var results: [PageSpeedResult] = []
        for strategy in ["mobile", "desktop"] {
            results.append(await check(url, strategy: strategy))
            try? await Task.sleep(for: .seconds(2))
        }
        return results
    }

    static func check(_ urls: [URL]) async -> [PageSpeedResult] {
        var results: [PageSpeedResult] = []
        for url in urls.prefix(2) {
            results.append(await check(url, strategy: "mobile"))
            try? await Task.sleep(for: .seconds(2))
        }
        return results
    }

    private static func check(_ url: URL, strategy: String) async -> PageSpeedResult {
        let key = PSIKeychain.load()
        // Do not reuse a 429 result received without a key after the user has
        // added one. The credential mode is part of the cache identity.
        let cacheKey = "psi-\(strategy)-\(key.isEmpty ? "anonymous" : "authenticated")-" + url.absoluteString
        if let data = UserDefaults.standard.data(forKey: cacheKey), let cached = try? JSONDecoder().decode(PageSpeedResult.self, from: data) { return cached }
        var components = URLComponents(string: "https://www.googleapis.com/pagespeedonline/v5/runPagespeed")!
        components.queryItems = [URLQueryItem(name: "url", value: url.absoluteString), URLQueryItem(name: "strategy", value: strategy)] + (key.isEmpty ? [] : [URLQueryItem(name: "key", value: key)])
        do {
            var request = URLRequest(url: components.url!)
            request.timeoutInterval = 45
            let (data, response) = try await URLSession.shared.data(for: request)
            if (response as? HTTPURLResponse)?.statusCode == 429 { return PageSpeedResult(url: url.absoluteString, strategy: strategy, score: nil, error: "Quota exceeded (429). Add a personal Google API key in Settings → Integrations, or retry later.") }
            let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
            let lighthouse = json?["lighthouseResult"] as? [String: Any]
            let categories = lighthouse?["categories"] as? [String: Any]
            let performance = categories?["performance"] as? [String: Any]
            let score = (performance?["score"] as? Double).map { Int($0 * 100) }
            let audits = lighthouse?["audits"] as? [String: Any]
            let lcp = ((audits?["largest-contentful-paint"] as? [String: Any])?["displayValue"] as? String) ?? "—"
            let cls = ((audits?["cumulative-layout-shift"] as? [String: Any])?["displayValue"] as? String) ?? "—"
            let result = PageSpeedResult(url: url.absoluteString, strategy: strategy, score: score, lcp: lcp, cls: cls)
            UserDefaults.standard.set(try? JSONEncoder().encode(result), forKey: cacheKey)
            return result
        } catch { return PageSpeedResult(url: url.absoluteString, strategy: strategy, score: nil, error: error.localizedDescription) }
    }
}
