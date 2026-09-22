import AppKit
import Foundation

/// Collects output from the short-lived `pgrep` process without ever blocking
/// the main actor. A synchronous `ps` call can fill its stdout pipe and leave
/// the Start button waiting before the crawler itself has been created.
private final class PageIndexingPIDOutput: @unchecked Sendable {
    private let lock = NSLock()
    private var data = Data()

    func append(_ newData: Data) {
        lock.lock()
        data.append(newData)
        lock.unlock()
    }

    func text() -> String {
        lock.lock()
        defer { lock.unlock() }
        return String(data: data, encoding: .utf8) ?? ""
    }
}

/// Imports the Page Indexing report from the signed-in local Chrome profile.
/// This deliberately stays separate from URL Inspection API records: coverage
/// reports can include Google-known URLs that ShareSpider never crawled.
@MainActor
final class ChromeGSCPageIndexingSync {
    static let shared = ChromeGSCPageIndexingSync()
    private init() {}
    private var statusTask: Task<Void, Never>?
    /// Retain the active exporter and the short-lived cleanup process. This
    /// prevents an exporter left by a previous app instance from overwriting
    /// the current run's CSV and status file.
    private var exportProcess: Process?
    private var staleHelperStopProcess: Process?
    /// Keep short-lived child processes alive without ever waiting for them on
    /// the UI actor. This mirrors the non-blocking Links synchronisation.
    private var profileTerminationProcesses: [Process] = []
    private var profilePIDLookupProcess: Process?

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
            .appendingPathComponent("SEOSpiderAgent_ShareSpider.bundle", isDirectory: true)
            .appendingPathComponent(name)
        return FileManager.default.fileExists(atPath: candidate.path) ? candidate : nil
    }

    func start(target: String, progress: @escaping @MainActor (_ message: String, _ completed: Int, _ total: Int) -> Void = { _, _, _ in }, completion: @escaping @MainActor (Result<String, Error>) -> Void) {
        guard let helper = installedHelper(named: "gsc-chrome-page-indexing-export.mjs")
                ?? AppResources.url(forResource: "gsc-chrome-page-indexing-export", withExtension: "mjs") else {
            completion(.failure(SyncError.helperUnavailable)); return
        }
        // Quitting the app does not necessarily terminate a child Node
        // process. Stop only this exact helper before reusing its shared CSV.
        stopStaleHelper { [weak self] in
            self?.begin(target: target, helper: helper, progress: progress, completion: completion)
        }
    }

    private func begin(target: String, helper: URL, progress: @escaping @MainActor (_ message: String, _ completed: Int, _ total: Int) -> Void, completion: @escaping @MainActor (Result<String, Error>) -> Void) {
        try? FileManager.default.createDirectory(at: profileURL, withIntermediateDirectories: true)
        try? FileManager.default.removeItem(at: exportURL)
        try? FileManager.default.removeItem(at: statusURL)

        progress("Opening a fresh ShareSpider Chrome window", 0, 3)
        restartChrome(helper: helper, target: target, progress: progress, completion: completion)
    }

    private func stopStaleHelper(completion: @escaping @MainActor () -> Void) {
        let stop = Process()
        stop.executableURL = URL(fileURLWithPath: "/usr/bin/pkill")
        stop.arguments = ["-f", "gsc-chrome-page-indexing-export.mjs"]
        stop.terminationHandler = { [weak self] finished in
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                if self?.staleHelperStopProcess === finished { self?.staleHelperStopProcess = nil }
                completion()
            }
        }
        do {
            try stop.run()
            staleHelperStopProcess = stop
        } catch {
            completion()
        }
    }

    private func restartChrome(helper: URL, target: String, progress: @escaping @MainActor (_ message: String, _ completed: Int, _ total: Int) -> Void, completion: @escaping @MainActor (Result<String, Error>) -> Void) {
        terminateChromeProfileProcesses(signal: "-TERM") { [weak self] in
            self?.waitForChromeToClose(helper: helper, target: target, progress: progress, completion: completion)
        }
    }

    /// `ps -axo` can produce more output than a pipe buffer holds. Waiting for
    /// its exit before reading stdout deadlocks the main actor, which used to
    /// stop a crawl at the instant the Page Indexing task was launched.
    private func chromeProfileProcessIDs(completion: @escaping @MainActor ([String]) -> Void) {
        let listing = Process()
        let output = Pipe()
        let outputData = PageIndexingPIDOutput()
        listing.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
        listing.arguments = ["-f", "gsc-chrome/ChromeProfile"]
        listing.standardOutput = output
        output.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            guard !data.isEmpty else {
                handle.readabilityHandler = nil
                return
            }
            outputData.append(data)
        }
        listing.terminationHandler = { finished in
            output.fileHandleForReading.readabilityHandler = nil
            outputData.append(output.fileHandleForReading.readDataToEndOfFile())
            let pids = outputData.text()
                .split(whereSeparator: { $0 == "\n" || $0 == "\r" })
                .compactMap { line -> String? in
                    let pid = String(line).trimmingCharacters(in: .whitespaces)
                    return pid.allSatisfy(\.isNumber) && !pid.isEmpty && pid != String(finished.processIdentifier) ? pid : nil
                }
            DispatchQueue.main.async {
                if self.profilePIDLookupProcess === finished { self.profilePIDLookupProcess = nil }
                completion(pids)
            }
        }
        do {
            try listing.run()
            profilePIDLookupProcess = listing
        } catch {
            output.fileHandleForReading.readabilityHandler = nil
            completion([])
            return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak listing] in
            guard let listing, listing.isRunning else { return }
            listing.terminate()
        }
    }

    private func terminateChromeProfileProcesses(signal: String, completion: @escaping @MainActor () -> Void) {
        chromeProfileProcessIDs { [weak self] pids in
            guard let self else { return }
            for pid in pids {
                let terminate = Process()
                terminate.executableURL = URL(fileURLWithPath: "/bin/kill")
                terminate.arguments = [signal, pid]
                do {
                    try terminate.run()
                    let processID = terminate.processIdentifier
                    self.profileTerminationProcesses.append(terminate)
                    terminate.terminationHandler = { [weak self] _ in
                        DispatchQueue.main.async {
                            self?.profileTerminationProcesses.removeAll { $0.processIdentifier == processID }
                        }
                    }
                } catch {
                    continue
                }
            }
            completion()
        }
    }

    private func waitForChromeToClose(helper: URL, target: String, progress: @escaping @MainActor (_ message: String, _ completed: Int, _ total: Int) -> Void, completion: @escaping @MainActor (Result<String, Error>) -> Void, attempts: Int = 0) {
        debuggerIsAvailable { [weak self] available in
            guard let self else { return }
            self.chromeProfileProcessIDs { profilePIDs in
                guard available || !profilePIDs.isEmpty else {
                    self.launchFreshChrome(helper: helper, target: target, progress: progress, completion: completion)
                    return
                }
                if attempts == 2, !profilePIDs.isEmpty {
                    self.terminateChromeProfileProcesses(signal: "-KILL") { [weak self] in
                        self?.scheduleChromeCloseCheck(helper: helper, target: target, progress: progress, completion: completion, attempts: attempts)
                    }
                    return
                }
                guard attempts < 15 else {
                    let message = profilePIDs.isEmpty
                        ? "Port 9222 is still in use by another process. Close that process and try again."
                        : "Could not stop the previous ShareSpider Chrome session. Quit its Chrome process and try again."
                    completion(.failure(SyncError.exportFailed(message)))
                    return
                }
                self.scheduleChromeCloseCheck(helper: helper, target: target, progress: progress, completion: completion, attempts: attempts)
            }
        }
    }

    private func scheduleChromeCloseCheck(helper: URL, target: String, progress: @escaping @MainActor (_ message: String, _ completed: Int, _ total: Int) -> Void, completion: @escaping @MainActor (Result<String, Error>) -> Void, attempts: Int) {
        progress("Closing the previous ShareSpider Chrome session", 0, 3)
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
            self.waitForChromeToClose(helper: helper, target: target, progress: progress, completion: completion, attempts: attempts + 1)
        }
    }

    private func launchFreshChrome(helper: URL, target: String, progress: @escaping @MainActor (_ message: String, _ completed: Int, _ total: Int) -> Void, completion: @escaping @MainActor (Result<String, Error>) -> Void) {
        guard let chrome = Self.chromeExecutable() else {
            completion(.failure(SyncError.exportFailed("Google Chrome was not found. Install Google Chrome, then try again.")))
            return
        }
        let launch = Process()
        launch.executableURL = chrome
        launch.arguments = ["--remote-debugging-port=9222", "--user-data-dir=\(profileURL.path)", "--new-window", "--no-first-run", "--no-default-browser-check"]
        do { try launch.run() } catch { completion(.failure(error)); return }
        waitForDebugger(helper: helper, target: target, progress: progress, completion: completion)
    }

    private func waitForDebugger(helper: URL, target: String, progress: @escaping @MainActor (_ message: String, _ completed: Int, _ total: Int) -> Void, completion: @escaping @MainActor (Result<String, Error>) -> Void, attempts: Int = 0) {
        debuggerIsAvailable { [weak self] available in
            guard let self else { return }
            if available { self.runHelper(helper: helper, target: target, progress: progress, completion: completion); return }
            guard attempts < 20 else { completion(.failure(SyncError.exportFailed("Chrome did not become ready within 20 seconds. Keep the ShareSpider Chrome window open and try again."))); return }
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
        let node = Self.nodeLaunch()
        process.executableURL = node.executableURL
        process.arguments = node.argumentsPrefix + [helper.path, "--target", target, "--output", exportURL.path, "--status", statusURL.path]
        process.environment = Self.playwrightEnvironment()
        let stderr = Pipe(); process.standardError = stderr
        do {
            try process.run()
            exportProcess = process
        } catch { completion(.failure(error)); return }
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
                if self.exportProcess === finished { self.exportProcess = nil }
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
                self.archiveRawExport(for: target)
                progress("Page Indexing report received and imported", 3, 3)
                completion(.success(csv))
            }
        }
    }

    /// Preserve the exact CSV used for import in a user-visible folder. The
    /// browser automation consumes the download directly, so Chrome itself
    /// does not place it in Downloads.
    private func archiveRawExport(for target: String) {
        let folder = ReportFileNaming.downloadsDirectory.appendingPathComponent("GSC Raw Exports", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let filename = ReportFileNaming.stem(for: target, report: "GSC-Page-Indexing") + ".csv"
        try? FileManager.default.copyItem(at: exportURL, to: folder.appendingPathComponent(filename))
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

    /// Resolves resources both in the SwiftPM development bundle and in the
    /// final app bundle. The shipped app never relies on a developer machine's
    /// Node.js or `node_modules` installation.
    nonisolated static func bundledRuntimeURL(path: String) -> URL? {
        AppResources.runtimeURL(path: path)
    }

    /// Chrome is deliberately not bundled. Look it up through macOS first so
    /// the usual /Applications location is not the only supported setup.
    nonisolated static func chromeExecutable() -> URL? {
        let fileManager = FileManager.default
        let candidates: [URL] = [
            NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.google.Chrome"),
            URL(fileURLWithPath: "/Applications/Google Chrome.app"),
            fileManager.urls(for: .applicationDirectory, in: .userDomainMask).first?.appendingPathComponent("Google Chrome.app")
        ].compactMap { $0 }

        return candidates
            .map { $0.appendingPathComponent("Contents/MacOS/Google Chrome") }
            .first(where: { fileManager.isExecutableFile(atPath: $0.path) })
    }

    nonisolated static func playwrightEnvironment() -> [String: String] {
        var environment = ProcessInfo.processInfo.environment
        if let core = bundledRuntimeURL(path: "node_modules/playwright-core/index.mjs") {
            environment["SHARESPIDER_PLAYWRIGHT_CORE"] = core.path
        }
        if let chrome = chromeExecutable() {
            environment["SHARESPIDER_CHROME_EXECUTABLE"] = chrome.path
        }
        return environment
    }

    /// GUI apps do not inherit a shell PATH, so resolve Node explicitly before
    /// falling back to `/usr/bin/env node` for less common installations.
    nonisolated static func nodeLaunch() -> NodeLaunch {
        let fileManager = FileManager.default
        if let bundledNode = bundledRuntimeURL(path: "node"),
           fileManager.isExecutableFile(atPath: bundledNode.path) {
            return NodeLaunch(executableURL: bundledNode, argumentsPrefix: [])
        }
        let standardPaths = ["/usr/local/bin/node", "/opt/homebrew/bin/node", "/usr/bin/node"]
        if let path = standardPaths.first(where: { fileManager.isExecutableFile(atPath: $0) }) {
            return NodeLaunch(executableURL: URL(fileURLWithPath: path), argumentsPrefix: [])
        }

        let which = Process()
        let output = Pipe()
        which.executableURL = URL(fileURLWithPath: "/usr/bin/which")
        which.arguments = ["node"]
        which.standardOutput = output
        do {
            try which.run()
            which.waitUntilExit()
            let path = String(data: output.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if which.terminationStatus == 0, fileManager.isExecutableFile(atPath: path) {
                return NodeLaunch(executableURL: URL(fileURLWithPath: path), argumentsPrefix: [])
            }
        } catch {
            // Use the environment fallback below if `which` itself is unavailable.
        }

        return NodeLaunch(executableURL: URL(fileURLWithPath: "/usr/bin/env"), argumentsPrefix: ["node"])
    }

    struct NodeLaunch {
        let executableURL: URL
        let argumentsPrefix: [String]
    }
}
