import Foundation

/// Imports the Page Indexing report from the signed-in local Chrome profile.
/// This deliberately stays separate from URL Inspection API records: coverage
/// reports can include Google-known URLs that ShareSpider never crawled.
@MainActor
final class ChromeGSCPageIndexingSync {
    static let shared = ChromeGSCPageIndexingSync()
    private init() {}
    private var statusTask: Task<Void, Never>?

    private var root: URL {
        let folder = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("ShareSpider/gsc-chrome", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }
    private var profileURL: URL { root.appendingPathComponent("ChromeProfile", isDirectory: true) }
    private var exportURL: URL { root.appendingPathComponent("gsc-page-indexing-export.csv") }
    private var statusURL: URL { root.appendingPathComponent("gsc-page-indexing-status.json") }

    /// Prefer the installed resource directory: it includes node_modules
    /// required by the local Playwright helper, unlike SwiftPM's temporary
    /// `.build` resource bundle.
    private func installedHelper(named name: String) -> URL? {
        guard let resources = Bundle.main.resourceURL else { return nil }
        let candidate = resources
            .appendingPathComponent("ShareSpider_ShareSpider.bundle", isDirectory: true)
            .appendingPathComponent(name)
        return FileManager.default.fileExists(atPath: candidate.path) ? candidate : nil
    }

    func start(target: String, progress: @escaping @MainActor (_ message: String, _ completed: Int, _ total: Int) -> Void = { _, _, _ in }, completion: @escaping @MainActor (Result<String, Error>) -> Void) {
        guard let helper = installedHelper(named: "gsc-chrome-page-indexing-export.mjs")
                ?? Bundle.module.url(forResource: "gsc-chrome-page-indexing-export", withExtension: "mjs") else {
            completion(.failure(SyncError.helperUnavailable)); return
        }
        try? FileManager.default.createDirectory(at: profileURL, withIntermediateDirectories: true)
        try? FileManager.default.removeItem(at: exportURL)
        try? FileManager.default.removeItem(at: statusURL)

        progress("Opening the ShareSpider Chrome profile", 0, 3)
        debuggerIsAvailable { [weak self] available in
            guard let self else { return }
            if available {
                self.runHelper(helper: helper, target: target, progress: progress, completion: completion)
                return
            }
            let launch = Process()
            launch.executableURL = URL(fileURLWithPath: "/usr/bin/open")
            launch.arguments = ["-g", "-n", "-a", "Google Chrome", "--args", "--remote-debugging-port=9222", "--user-data-dir=\(self.profileURL.path)"]
            do { try launch.run() } catch { completion(.failure(error)); return }
            self.waitForDebugger(helper: helper, target: target, progress: progress, completion: completion)
        }
    }

    private func waitForDebugger(helper: URL, target: String, progress: @escaping @MainActor (_ message: String, _ completed: Int, _ total: Int) -> Void, completion: @escaping @MainActor (Result<String, Error>) -> Void, attempts: Int = 0) {
        debuggerIsAvailable { [weak self] available in
            guard let self else { return }
            if available { self.runHelper(helper: helper, target: target, progress: progress, completion: completion); return }
            guard attempts < 30 else { completion(.failure(SyncError.exportFailed("Chrome did not become ready. Keep the ShareSpider Chrome window open and try again."))); return }
            progress("Waiting for Chrome to become ready", 0, 3)
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { self.waitForDebugger(helper: helper, target: target, progress: progress, completion: completion, attempts: attempts + 1) }
        }
    }

    private func debuggerIsAvailable(completion: @escaping @MainActor (Bool) -> Void) {
        URLSession.shared.dataTask(with: URL(string: "http://127.0.0.1:9222/json/version")!) { data, response, _ in
            let available = data != nil && (response as? HTTPURLResponse)?.statusCode == 200
            DispatchQueue.main.async { completion(available) }
        }.resume()
    }

    private func runHelper(helper: URL, target: String, progress: @escaping @MainActor (_ message: String, _ completed: Int, _ total: Int) -> Void, completion: @escaping @MainActor (Result<String, Error>) -> Void, signInAttempts: Int = 0) {
        progress("Opening Page Indexing and preparing the coverage report export", 1, 3)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["node", helper.path, "--target", target, "--output", exportURL.path, "--status", statusURL.path]
        process.environment = Self.playwrightEnvironment()
        let stderr = Pipe(); process.standardError = stderr
        do { try process.run() } catch { completion(.failure(error)); return }
        // The helper writes its current report/category to a small status file.
        // Poll it while Chrome is working so the app does not look frozen.
        statusTask?.cancel()
        statusTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                if let status = self?.readStatus() {
                    progress(status.message, status.state == "completed" ? 3 : 2, 3)
                }
                try? await Task.sleep(for: .milliseconds(450))
            }
        }
        process.terminationHandler = { [weak self] finished in
            let errorText = String(data: stderr.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            DispatchQueue.main.async {
                guard let self else { return }
                self.statusTask?.cancel()
                self.statusTask = nil
                guard finished.terminationStatus == 0,
                      let csv = try? String(contentsOf: self.exportURL, encoding: .utf8),
                      !csv.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                    let status = self.statusMessage
                    if status.localizedCaseInsensitiveContains("sign in"), signInAttempts < 100 {
                        progress("Waiting for Google sign-in in Chrome", 1, 3)
                        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { self.runHelper(helper: helper, target: target, progress: progress, completion: completion, signInAttempts: signInAttempts + 1) }
                        return
                    }
                    completion(.failure(SyncError.exportFailed(errorText.isEmpty ? status : errorText)))
                    return
                }
                progress("Page Indexing report received and imported", 3, 3)
                completion(.success(csv))
            }
        }
    }

    private var statusMessage: String {
        readStatus()?.message ?? "Chrome did not return a Page Indexing export."
    }

    private func readStatus() -> (state: String, message: String)? {
        guard let data = try? Data(contentsOf: statusURL),
              let result = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let message = result["message"] as? String else { return nil }
        return (result["state"] as? String ?? "running", message)
    }

    enum SyncError: LocalizedError {
        case helperUnavailable
        case exportFailed(String)
        var errorDescription: String? {
            switch self {
            case .helperUnavailable: "The local Chrome Page Indexing helper is unavailable."
            case .exportFailed(let message): message
            }
        }
    }

    static func playwrightEnvironment() -> [String: String] {
        var environment = ProcessInfo.processInfo.environment
        let candidates = [
            "/Users/daniilspara/Documents/App/ShareSpider/MCP/node_modules/playwright-core/index.mjs",
            "/usr/local/lib/node_modules/playwright-core/index.mjs"
        ]
        if let path = candidates.first(where: { FileManager.default.fileExists(atPath: $0) }) {
            environment["SHARESPIDER_PLAYWRIGHT_CORE"] = path
        }
        return environment
    }
}
