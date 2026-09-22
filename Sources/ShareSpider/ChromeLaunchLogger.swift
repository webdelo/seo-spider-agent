import Foundation

/// Small, intentionally dependency-free trace for the visible Chrome GSC flow.
/// It remains available after a GUI run, where stdout is otherwise invisible.
enum ChromeLaunchLogger {
    private static let lock = NSLock()

    static let url: URL = {
        let directory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("ShareSpider", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory.appendingPathComponent("chrome-launch.log")
    }()

    static func write(_ message: String) {
        let timestamp = ISO8601DateFormatter().string(from: Date())
        let line = "[\(timestamp)] \(message)\n"
        lock.lock()
        defer { lock.unlock() }
        guard let data = line.data(using: .utf8) else { return }
        if FileManager.default.fileExists(atPath: url.path),
           let handle = try? FileHandle(forWritingTo: url) {
            defer { try? handle.close() }
            try? handle.seekToEnd()
            try? handle.write(contentsOf: data)
        } else {
            try? data.write(to: url, options: .atomic)
        }
    }

    static func capture(_ handle: FileHandle, label: String) {
        handle.readabilityHandler = { source in
            let data = source.availableData
            guard !data.isEmpty else { return }
            let text = String(data: data, encoding: .utf8) ?? "<\(data.count) non-UTF8 bytes>"
            for line in text.split(whereSeparator: \.isNewline) {
                write("\(label): \(line)")
            }
        }
    }
}
