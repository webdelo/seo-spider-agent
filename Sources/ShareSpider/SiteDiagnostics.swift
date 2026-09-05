import Foundation
import Darwin

/// Legacy name retained so existing settings code continues to compile. Keys are
/// deliberately local files, not Keychain entries, because this desktop crawler
/// must never interrupt an unattended audit with a password dialog.
enum AhrefsKeychain {
    private static var keyURL: URL {
        let folder = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("ShareSpider", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder.appendingPathComponent("ahrefs-api-key.txt")
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

enum SiteDiagnostics {
    static func domainRating(host: String) async -> (value: Double?, error: String) {
        let key = AhrefsKeychain.load()
        guard !key.isEmpty else { return (nil, "Add a free Ahrefs API key in Settings → Integrations to retrieve DR.") }
        var components = URLComponents(string: "https://api.ahrefs.com/v3/public/domain-rating-free")!
        components.queryItems = [URLQueryItem(name: "target", value: host), URLQueryItem(name: "output", value: "json")]
        var request = URLRequest(url: components.url!); request.setValue("application/json", forHTTPHeaderField: "Accept"); request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            guard (200..<300).contains(status) else { return (nil, status == 401 ? "Ahrefs rejected the API key. Add a valid free API key in Settings → Integrations." : "Ahrefs DR request failed (HTTP \(status)).") }
            let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
            let rating = (json?["domain_rating"] as? [String: Any])?["domain_rating"] as? Double
            return rating.map { ($0, "") } ?? (nil, "Ahrefs did not return a Domain Rating value.")
        } catch { return (nil, error.localizedDescription) }
    }

    static func resolveIPs(host: String) -> [String] {
        var hints = addrinfo(); hints.ai_family = AF_UNSPEC; hints.ai_socktype = SOCK_STREAM
        var results: UnsafeMutablePointer<addrinfo>?
        guard getaddrinfo(host, nil, &hints, &results) == 0, let first = results else { return [] }
        defer { freeaddrinfo(first) }
        var values = Set<String>(); var cursor: UnsafeMutablePointer<addrinfo>? = first
        while let item = cursor {
            var buffer = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            if getnameinfo(item.pointee.ai_addr, item.pointee.ai_addrlen, &buffer, socklen_t(buffer.count), nil, 0, NI_NUMERICHOST) == 0 {
                values.insert(String(cString: buffer))
            }
            cursor = item.pointee.ai_next
        }
        // A host can resolve to a pool of IPv4 and IPv6 addresses behind a CDN.
        // Client audit needs one readable primary address, not the whole DNS pool.
        let sorted = values.sorted()
        let preferred = sorted.first { !$0.contains(":") } ?? sorted.first
        return preferred.map { [$0] } ?? []
    }
}
