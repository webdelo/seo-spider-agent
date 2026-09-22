import Foundation

/// Compatibility storage for older preferences. Donor-profile work is now
/// always initiated manually from Backlinks and never overlaps a site crawl.
struct BacklinkProfileSettings: Codable {
    var runWithCrawl = false
}

enum BacklinkProfileSettingsStore {
    private static var file: URL {
        let root = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("ShareSpider", isDirectory: true)
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root.appendingPathComponent("backlink-profile-settings.json")
    }
    static func load() -> BacklinkProfileSettings {
        guard let data = try? Data(contentsOf: file), var value = try? JSONDecoder().decode(BacklinkProfileSettings.self, from: data) else { return .init() }
        if value.runWithCrawl {
            value.runWithCrawl = false
            save(value)
        }
        return value
    }
    static func save(_ value: BacklinkProfileSettings) {
        guard let data = try? JSONEncoder().encode(value) else { return }
        try? data.write(to: file, options: .atomic)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
    }
}
