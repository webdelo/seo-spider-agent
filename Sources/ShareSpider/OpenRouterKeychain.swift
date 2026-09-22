import Foundation

/// Local file-based storage for the OpenRouter API key. Same pattern as
/// AhrefsKeychain / PSIKeychain: keys live in Application Support, never
/// in Keychain, so an unattended audit is never interrupted by a password
/// dialog.
enum OpenRouterKeychain {
    private static var keyURL: URL {
        let folder = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("ShareSpider", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder.appendingPathComponent("openrouter-api-key.txt")
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
