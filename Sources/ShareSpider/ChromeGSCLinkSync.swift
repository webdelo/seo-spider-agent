import Foundation

/// Runs the locally packaged Playwright helper against a dedicated Chrome
/// profile.  This is deliberately separate from the Search Console API: the
/// public API has no endpoint for the Links report.  The helper exports a CSV
/// locally, then the existing importer merges it as a comparison dataset.
@MainActor
final class ChromeGSCLinkSync {
    static let shared = ChromeGSCLinkSync()
    private init() {}

    private var root: URL {
        let root = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("ShareSpider/gsc-chrome", isDirectory: true)
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private var chromeProfile: URL { root.appendingPathComponent("ChromeProfile", isDirectory: true) }
    private var exportURL: URL { root.appendingPathComponent("gsc-links-export.csv") }
    private var statusURL: URL { root.appendingPathComponent("gsc-links-status.json") }

    /// SwiftPM's Bundle.module can resolve to `.build` even after the binary is
    /// copied into the macOS app. The resource directory is not itself an
    /// Apple bundle, so resolve its helper file directly.
    private func installedHelper(named name: String) -> URL? {
        guard let resources = Bundle.main.resourceURL else { return nil }
        let candidate = resources
            .appendingPathComponent("ShareSpider_ShareSpider.bundle", isDirectory: true)
            .appendingPathComponent(name)
        return FileManager.default.fileExists(atPath: candidate.path) ? candidate : nil
    }

    func start(target: String, progress: @escaping @MainActor (_ message: String, _ completed: Int, _ total: Int) -> Void = { _, _, _ in }, completion: @escaping @MainActor (Result<String, Error>) -> Void) {
        guard let helper = installedHelper(named: "gsc-chrome-links-export.mjs")
                ?? Bundle.module.url(forResource: "gsc-chrome-links-export", withExtension: "mjs") else {
            completion(.failure(SyncError.helperUnavailable)); return
        }
        try? FileManager.default.createDirectory(at: chromeProfile, withIntermediateDirectories: true)
        try? FileManager.default.removeItem(at: exportURL)
        try? FileManager.default.removeItem(at: statusURL)
        progress("Opening the ShareSpider Chrome profile", 0, 3)
        debuggerIsAvailable { [weak self] available in
            guard let self else { return }
            if available {
                self.runHelper(helper: helper, target: target, progress: progress, completion: completion)
                return
            }

            // A dedicated profile retains the Google sign-in, but a running
            // debugger is reused so repeated syncs never create another Chrome.
            let launch = Process()
            launch.executableURL = URL(fileURLWithPath: "/usr/bin/open")
            launch.arguments = ["-g", "-n", "-a", "Google Chrome", "--args", "--remote-debugging-port=9222", "--user-data-dir=\(self.chromeProfile.path)"]
            do {
                try launch.run()
            } catch {
                completion(.failure(error)); return
            }
            self.waitForDebugger(helper: helper, target: target, progress: progress, completion: completion)
        }
    }

    /// Chrome may need a few seconds to open. More importantly, the first
    /// connection can pause on Google's sign-in screen. The helper below will
    /// retry after the user completes that one-time sign-in instead of making
    /// them press the ShareSpider button a second time.
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
        let endpoint = URL(string: "http://127.0.0.1:9222/json/version")!
        URLSession.shared.dataTask(with: endpoint) { data, response, _ in
            let available = data != nil && (response as? HTTPURLResponse)?.statusCode == 200
            DispatchQueue.main.async { completion(available) }
        }.resume()
    }

    private func runHelper(helper: URL, target: String, progress: @escaping @MainActor (_ message: String, _ completed: Int, _ total: Int) -> Void, completion: @escaping @MainActor (Result<String, Error>) -> Void, signInAttempts: Int = 0) {
        progress("Opening the GSC Links report and preparing its CSV export", 1, 3)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["node", helper.path, "--target", target, "--output", exportURL.path, "--status", statusURL.path]
        let errorPipe = Pipe(); process.standardError = errorPipe
        do {
            try process.run()
        } catch {
            completion(.failure(error)); return
        }
        process.terminationHandler = { [weak self] finished in
            let errorText = String(data: errorPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            DispatchQueue.main.async {
                guard let self else { return }
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
                progress("GSC Links CSV received and imported", 3, 3)
                completion(.success(csv))
            }
        }
    }

    private var statusMessage: String {
        guard let data = try? Data(contentsOf: statusURL),
              let value = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let message = value["message"] as? String else { return "Chrome export did not return a CSV." }
        return message
    }

    enum SyncError: LocalizedError {
        case helperUnavailable
        case exportFailed(String)
        var errorDescription: String? {
            switch self {
            case .helperUnavailable: return "The local Chrome export helper is unavailable."
            case .exportFailed(let message): return message
            }
        }
    }
}
