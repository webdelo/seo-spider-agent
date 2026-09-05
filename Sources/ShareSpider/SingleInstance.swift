import AppKit
import Darwin

/// `open -n` can otherwise start a second independent crawler. A process-held
/// advisory lock makes the first ShareSpider instance the only live instance.
@MainActor final class SingleInstance {
    static let shared = SingleInstance()
    private var descriptor: Int32 = -1
    private init() {}

    func acquire() -> Bool {
        guard descriptor == -1 else { return true }
        let directory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!.appendingPathComponent("ShareSpider", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        descriptor = open(directory.appendingPathComponent("app.lock").path, O_CREAT | O_RDWR, S_IRUSR | S_IWUSR)
        guard descriptor >= 0 else { return false }
        if flock(descriptor, LOCK_EX | LOCK_NB) == 0 { return true }
        close(descriptor); descriptor = -1
        return false
    }
}
