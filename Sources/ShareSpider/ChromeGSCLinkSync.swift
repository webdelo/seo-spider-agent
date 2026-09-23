import Foundation

/// Serializes the pipe reader and Process termination handler. FileHandle's
/// readability callback is delivered off the main actor.
private final class ProfilePIDOutput: @unchecked Sendable {
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

/// Process termination and the hard deadline arrive on different queues. This
/// tiny gate makes exactly one of them complete the UI operation.
private final class LinkExportCompletionGate: @unchecked Sendable {
    private let lock = NSLock()
    private var finished = false

    func claim() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard !finished else { return false }
        finished = true
        return true
    }

    func isFinished() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return finished
    }
}

/// Runs the locally packaged Playwright helper against a dedicated Chrome
/// profile.  This is deliberately separate from the Search Console API: the
/// public API has no endpoint for the Links report.  The helper exports a CSV
/// locally, then the existing importer merges it as a comparison dataset.
@MainActor
final class ChromeGSCLinkSync {
    static let shared = ChromeGSCLinkSync()
    private init() {}
    /// A Process must outlive `launchFreshChrome`. Retaining it also lets us
    /// record Chrome's eventual exit status and diagnostic streams.
    private var chromeLaunchProcess: Process?
    /// The Node helper is retained so a closed Chrome window or a stalled GSC
    /// page can be stopped promptly instead of remaining tied to unrelated
    /// donor classification work.
    private var linkExportProcess: Process?
    /// Keep short-lived `kill` children alive until their termination handlers
    /// have recorded the result.  None of these processes is waited on from
    /// the main actor.
    private var profileTerminationProcesses: [Process] = []
    /// Retain the `pgrep` child until its termination handler fires. Without
    /// this strong reference the lookup can be released immediately after
    /// `run()`, which leaves a Links sync frozen at “Opening Chrome” before
    /// the visible browser launch is ever attempted.
    private var profilePIDLookupProcess: Process?

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
            .appendingPathComponent("SEOSpiderAgent_ShareSpider.bundle", isDirectory: true)
            .appendingPathComponent(name)
        return FileManager.default.fileExists(atPath: candidate.path) ? candidate : nil
    }

    func start(target: String, progress: @escaping @MainActor (_ message: String, _ completed: Int, _ total: Int) -> Void = { _, _, _ in }, completion: @escaping @MainActor (Result<String, Error>) -> Void) {
        ChromeLaunchLogger.write("Links start(target=\(target)); bundle=\(Bundle.main.bundleURL.path)")
        guard let helper = installedHelper(named: "gsc-chrome-links-export.mjs")
                ?? AppResources.url(forResource: "gsc-chrome-links-export", withExtension: "mjs") else {
            ChromeLaunchLogger.write("Links start: helper found=false")
            completion(.failure(SyncError.helperUnavailable)); return
        }
        ChromeLaunchLogger.write("Links start: helper found=true path=\(helper.path)")
        try? FileManager.default.createDirectory(at: chromeProfile, withIntermediateDirectories: true)
        try? FileManager.default.removeItem(at: exportURL)
        try? FileManager.default.removeItem(at: statusURL)
        // A closed Chrome window can leave its dedicated profile's process and
        // CDP port alive in the background.  Reusing that port makes the next
        // sync invisible to the user, so each Links sync deliberately starts
        // one fresh, visible instance of this profile.
        progress("Opening a fresh ShareSpider Chrome window", 0, 3)
        restartChrome(helper: helper, target: target, progress: progress, completion: completion)
    }

    /// An access-denied screen is definitive for this GSC property.  Close
    /// only the isolated ShareSpider profile, never the user's regular Chrome,
    /// so no helper can keep retrying or leave an alarming browser window open.
    func closeDedicatedChromeAfterAccessDenied() {
        ChromeLaunchLogger.write("Links access denied: closing dedicated ShareSpider Chrome profile")
        terminateChromeProfileProcesses(signal: "-TERM") { [weak self] in
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                guard let self else { return }
                self.chromeProfileProcessIDs { pids in
                    guard !pids.isEmpty else { return }
                    ChromeLaunchLogger.write("Links access denied: forcing close for remaining profile PIDs [\(pids.joined(separator: ","))]")
                    self.terminateChromeProfileProcesses(signal: "-KILL") {}
                }
            }
        }
    }

    private func restartChrome(helper: URL, target: String, progress: @escaping @MainActor (_ message: String, _ completed: Int, _ total: Int) -> Void, completion: @escaping @MainActor (Result<String, Error>) -> Void) {
        ChromeLaunchLogger.write("Links restartChrome: entering terminate")
        terminateChromeProfileProcesses(signal: "-TERM") { [weak self] in
            guard let self else { return }
            self.waitForDebuggerToClose(helper: helper, target: target, progress: progress, completion: completion)
        }
    }

    /// Only processes launched with ShareSpider's dedicated profile are
    /// targeted. This leaves the user's normal Chrome profile untouched.
    ///
    /// `ps -axo pid=,command=` can be larger than a pipe buffer.  Waiting for
    /// that process before draining stdout deadlocks when the buffer fills.
    /// `pgrep -f` returns only PID lines and uses the dedicated profile path as
    /// its match, while the readability handler continuously drains even that
    /// small output.  A timeout ensures a stuck child cannot stall a sync.
    private func chromeProfileProcessIDs(completion: @escaping @MainActor ([String]) -> Void) {
        let listing = Process()
        let output = Pipe()
        let outputData = ProfilePIDOutput()
        listing.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
        // This fragment is unique to ShareSpider's GSC Chrome profile; normal
        // Chrome and the Crawler's 9223 profile have different user-data-dir
        // paths and cannot match it.
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
            // The child has exited, so EOF is guaranteed and this final drain
            // cannot block. It only contains newline-separated PID values.
            let trailingData = output.fileHandleForReading.readDataToEndOfFile()
            outputData.append(trailingData)
            let text = outputData.text()
            let pids = text.split(whereSeparator: { $0 == "\n" || $0 == "\r" }).compactMap { line -> String? in
                let pid = String(line).trimmingCharacters(in: .whitespaces)
                // BSD pgrep can include its own command because its search
                // expression is present in argv. Never treat that transient
                // lookup process as a Chrome profile process.
                return pid.allSatisfy(\.isNumber) && pid != String(finished.processIdentifier) && !pid.isEmpty ? pid : nil
            }
            DispatchQueue.main.async {
                ChromeLaunchLogger.write("Links profile PID lookup status=\(finished.terminationStatus) matchedPIDs=\(pids.count) [\(pids.joined(separator: ","))]")
                if self.profilePIDLookupProcess === finished { self.profilePIDLookupProcess = nil }
                completion(pids)
            }
        }
        do {
            try listing.run()
            profilePIDLookupProcess = listing
        } catch {
            output.fileHandleForReading.readabilityHandler = nil
            ChromeLaunchLogger.write("Links profile PID lookup run error=\(error.localizedDescription)")
            profilePIDLookupProcess = nil
            completion([])
            return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak listing] in
            guard let listing, listing.isRunning else { return }
            ChromeLaunchLogger.write("Links profile PID lookup timed out; terminating pgrep pid=\(listing.processIdentifier)")
            listing.terminate()
        }
    }

    private func terminateChromeProfileProcesses(signal: String, completion: @escaping @MainActor () -> Void) {
        // Match the full dedicated user-data-dir, never the debugger port.
        // This leaves normal Chrome and Crawler's separate 9223 profile alone.
        chromeProfileProcessIDs { [weak self] pids in
            guard let self else { return }
            ChromeLaunchLogger.write("Links terminate signal=\(signal) matchedPIDs=\(pids.count) [\(pids.joined(separator: ","))]")
            for pid in pids {
                let terminate = Process()
                terminate.executableURL = URL(fileURLWithPath: "/bin/kill")
                terminate.arguments = [signal, pid]
                do {
                    try terminate.run()
                    let processID = terminate.processIdentifier
                    self.profileTerminationProcesses.append(terminate)
                    terminate.terminationHandler = { [weak self] finished in
                        ChromeLaunchLogger.write("Links terminate pid=\(pid) signal=\(signal) status=\(finished.terminationStatus)")
                        DispatchQueue.main.async {
                            self?.profileTerminationProcesses.removeAll { $0.processIdentifier == processID }
                        }
                    }
                } catch {
                    ChromeLaunchLogger.write("Links terminate pid=\(pid) signal=\(signal) run error=\(error.localizedDescription)")
                }
            }
            completion()
        }
    }

    private func waitForDebuggerToClose(helper: URL, target: String, progress: @escaping @MainActor (_ message: String, _ completed: Int, _ total: Int) -> Void, completion: @escaping @MainActor (Result<String, Error>) -> Void, attempts: Int = 0) {
        debuggerIsAvailable { [weak self] available in
            guard let self else { return }
            self.chromeProfileProcessIDs { profilePIDs in
                guard available || !profilePIDs.isEmpty else {
                    self.launchFreshChrome(helper: helper, target: target, progress: progress, completion: completion)
                    return
                }
                // Chrome normally honours TERM. If this profile is still alive two
                // seconds later, force only its remaining PID(s) with SIGKILL.
                if attempts == 2, !profilePIDs.isEmpty {
                    self.terminateChromeProfileProcesses(signal: "-KILL") { [weak self] in
                        guard let self else { return }
                        self.scheduleDebuggerCloseCheck(helper: helper, target: target, progress: progress, completion: completion, attempts: attempts)
                    }
                    return
                }
                guard attempts < 15 else {
                    let reason = profilePIDs.isEmpty
                        ? "Port 9222 is still in use by another process. Close that process and try again."
                        : "Could not stop the previous ShareSpider Chrome session. Quit its Chrome process and try again."
                    completion(.failure(SyncError.exportFailed(reason)))
                    return
                }
                self.scheduleDebuggerCloseCheck(helper: helper, target: target, progress: progress, completion: completion, attempts: attempts)
            }
        }
    }

    private func scheduleDebuggerCloseCheck(helper: URL, target: String, progress: @escaping @MainActor (_ message: String, _ completed: Int, _ total: Int) -> Void, completion: @escaping @MainActor (Result<String, Error>) -> Void, attempts: Int) {
        progress("Closing the previous ShareSpider Chrome session", 0, 3)
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
            self.waitForDebuggerToClose(helper: helper, target: target, progress: progress, completion: completion, attempts: attempts + 1)
        }
    }

    private func launchFreshChrome(helper: URL, target: String, progress: @escaping @MainActor (_ message: String, _ completed: Int, _ total: Int) -> Void, completion: @escaping @MainActor (Result<String, Error>) -> Void) {
        // `open -a` can focus an existing Chrome and discard these arguments.
        // Launching the executable directly creates a visible isolated window.
        let launch = Process()
        guard let chrome = ChromeGSCPageIndexingSync.chromeExecutable() else {
            ChromeLaunchLogger.write("Links launchFreshChrome: Google Chrome not found")
            completion(.failure(SyncError.exportFailed("Google Chrome was not found. Install Google Chrome, then try again.")))
            return
        }
        ChromeLaunchLogger.write("Links launchFreshChrome: chrome path=\(chrome.path)")
        // Use the same explicit environment pattern as the working Node helper.
        // `/usr/bin/env` execs Chrome with a shell-quality PATH while keeping
        // every path as a separate argv item (including Chrome's space).
        let stdout = Pipe()
        let stderr = Pipe()
        launch.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        launch.currentDirectoryURL = chrome.deletingLastPathComponent()
        launch.environment = ChromeGSCPageIndexingSync.playwrightEnvironment()
        let path = launch.environment?["PATH"] ?? "/usr/local/bin:/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin"
        launch.arguments = ["PATH=\(path)", "HOME=\(NSHomeDirectory())", chrome.path,
                            "--remote-debugging-port=9222", "--user-data-dir=\(chromeProfile.path)",
                            "--new-window", "--no-first-run", "--no-default-browser-check"]
        launch.standardOutput = stdout
        launch.standardError = stderr
        ChromeLaunchLogger.capture(stdout.fileHandleForReading, label: "Links Chrome stdout")
        ChromeLaunchLogger.capture(stderr.fileHandleForReading, label: "Links Chrome stderr")
        do {
            ChromeLaunchLogger.write("Links launchFreshChrome: Process.run() calling executable=/usr/bin/env argv=\(launch.arguments?.joined(separator: " | ") ?? "")")
            try launch.run()
            chromeLaunchProcess = launch
            ChromeLaunchLogger.write("Links launchFreshChrome: Process.run() returned pid=\(launch.processIdentifier)")
            launch.terminationHandler = { [weak self] process in
                ChromeLaunchLogger.write("Links Chrome terminationStatus=\(process.terminationStatus) reason=\(process.terminationReason.rawValue)")
                stdout.fileHandleForReading.readabilityHandler = nil
                stderr.fileHandleForReading.readabilityHandler = nil
                DispatchQueue.main.async { if self?.chromeLaunchProcess === process { self?.chromeLaunchProcess = nil } }
            }
        } catch {
            ChromeLaunchLogger.write("Links launchFreshChrome: Process.run() error=\(error.localizedDescription)")
            completion(.failure(error)); return
        }
        waitForDebugger(helper: helper, target: target, progress: progress, completion: completion)
    }

    /// Chrome may need a few seconds to open. More importantly, the first
    /// connection can pause on Google's sign-in screen. The helper below will
    /// retry after the user completes that one-time sign-in instead of making
    /// them press the ShareSpider button a second time.
    private func waitForDebugger(helper: URL, target: String, progress: @escaping @MainActor (_ message: String, _ completed: Int, _ total: Int) -> Void, completion: @escaping @MainActor (Result<String, Error>) -> Void, attempts: Int = 0) {
        debuggerIsAvailable { [weak self] available in
            guard let self else { return }
            ChromeLaunchLogger.write("Links waitForDebugger attempt=\(attempts + 1) available=\(available)")
            if available { self.runHelper(helper: helper, target: target, progress: progress, completion: completion); return }
            guard attempts < 20 else {
                ChromeLaunchLogger.write("Links waitForDebugger: unavailable after \(attempts + 1) attempts")
                completion(.failure(SyncError.exportFailed("Chrome did not become ready within 20 seconds. Keep the ShareSpider Chrome window open and try again."))); return
            }
            progress("Waiting for Chrome to become ready", 0, 3)
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { self.waitForDebugger(helper: helper, target: target, progress: progress, completion: completion, attempts: attempts + 1) }
        }
    }

    private func debuggerIsAvailable(completion: @escaping @MainActor (Bool) -> Void) {
        let endpoint = URL(string: "http://127.0.0.1:9222/json/version")!
        var request = URLRequest(url: endpoint)
        // Keep each close-port probe bounded as well as the outer retry loop.
        // URLSession runs this off the main actor; two seconds is ample for a
        // local CDP endpoint and prevents a stalled socket from delaying it.
        request.timeoutInterval = 2
        URLSession.shared.dataTask(with: request) { data, response, _ in
            let available = data != nil && (response as? HTTPURLResponse)?.statusCode == 200
            DispatchQueue.main.async { completion(available) }
        }.resume()
    }

    private func runHelper(helper: URL, target: String, progress: @escaping @MainActor (_ message: String, _ completed: Int, _ total: Int) -> Void, completion: @escaping @MainActor (Result<String, Error>) -> Void, signInAttempts: Int = 0) {
        ChromeLaunchLogger.write("Links runHelper entering attempt=\(signInAttempts + 1) helper=\(helper.path) status=\(statusURL.path)")
        progress("Opening the GSC Links report and preparing its CSV export", 1, 3)
        let process = Process()
        let node = ChromeGSCPageIndexingSync.nodeLaunch()
        process.executableURL = node.executableURL
        process.arguments = node.argumentsPrefix + [helper.path, "--target", target, "--output", exportURL.path, "--status", statusURL.path]
        process.environment = ChromeGSCPageIndexingSync.playwrightEnvironment()
        let outputPipe = Pipe(); let errorPipe = Pipe()
        process.standardOutput = outputPipe; process.standardError = errorPipe
        ChromeLaunchLogger.capture(outputPipe.fileHandleForReading, label: "Links helper stdout")
        ChromeLaunchLogger.capture(errorPipe.fileHandleForReading, label: "Links helper stderr")
        let completionGate = LinkExportCompletionGate()
        var deadlineWorkItem: DispatchWorkItem?
        func finish(_ result: Result<String, Error>) {
            guard completionGate.claim() else { return }
            deadlineWorkItem?.cancel()
            if self.linkExportProcess === process { self.linkExportProcess = nil }
            completion(result)
        }
        do {
            try process.run()
            linkExportProcess = process
            ChromeLaunchLogger.write("Links runHelper Process.run() returned pid=\(process.processIdentifier)")
        } catch {
            ChromeLaunchLogger.write("Links runHelper Process.run() error=\(error.localizedDescription)")
            completion(.failure(error)); return
        }
        // A Links export must never sit behind a long donor classification.
        // The helper has its own short element waits; this is a hard ceiling
        // for the whole attempt, including a GSC page that stops responding.
        let deadline = DispatchWorkItem { [weak process] in
            guard let process, process.isRunning else { return }
            ChromeLaunchLogger.write("Links helper timed out after 35 seconds; terminating pid=\(process.processIdentifier)")
            process.terminate()
            guard completionGate.claim() else { return }
            if self.linkExportProcess === process { self.linkExportProcess = nil }
            completion(.failure(SyncError.exportTimedOut))
        }
        deadlineWorkItem = deadline
        DispatchQueue.main.asyncAfter(deadline: .now() + 35, execute: deadline)
        process.terminationHandler = { [weak self] finished in
            let errorText = String(data: errorPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            ChromeLaunchLogger.write("Links helper terminationStatus=\(finished.terminationStatus); stderrRemaining=\(errorText)")
            outputPipe.fileHandleForReading.readabilityHandler = nil
            errorPipe.fileHandleForReading.readabilityHandler = nil
            DispatchQueue.main.async {
                guard let self else { return }
                guard !completionGate.isFinished() else { return }
                guard finished.terminationStatus == 0,
                      let csv = try? String(contentsOf: self.exportURL, encoding: .utf8),
                      !csv.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                    let status = self.status
                    if self.isAccessDenied(status: status, errorText: errorText) {
                        guard completionGate.claim() else { return }
                        if self.linkExportProcess === finished { self.linkExportProcess = nil }
                        completion(.failure(SyncError.accessDenied))
                        return
                    }
                    if self.requiresSignIn(status: status), signInAttempts < 10 {
                        progress("Waiting for Google sign-in in Chrome", 1, 3)
                        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { self.runHelper(helper: helper, target: target, progress: progress, completion: completion, signInAttempts: signInAttempts + 1) }
                        return
                    }
                    let failure = self.requiresSignIn(status: status)
                        ? SyncError.exportFailed("Google sign-in was not completed within 30 seconds — stopped.")
                        : SyncError.exportFailed(errorText.isEmpty ? status.message : errorText)
                    guard completionGate.claim() else { return }
                    if self.linkExportProcess === finished { self.linkExportProcess = nil }
                    completion(.failure(failure))
                    return
                }
                progress("GSC Links CSV received and imported", 3, 3)
                guard completionGate.claim() else { return }
                if self.linkExportProcess === finished { self.linkExportProcess = nil }
                completion(.success(csv))
            }
        }
    }

    private var status: (state: String, message: String) {
        guard let data = try? Data(contentsOf: statusURL),
              let value = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let message = value["message"] as? String else { return ("failed", "Chrome export did not return a CSV.") }
        let result = (value["state"] as? String ?? "running", message)
        ChromeLaunchLogger.write("Links helper.writeStatus observed state=\(result.0) message=\(result.1)")
        return result
    }

    private func isAccessDenied(status: (state: String, message: String), errorText: String) -> Bool {
        status.state.localizedCaseInsensitiveCompare("access-denied") == .orderedSame ||
            Self.isAccessDeniedMessage(status.message) || Self.isAccessDeniedMessage(errorText)
    }

    private func requiresSignIn(status: (state: String, message: String)) -> Bool {
        status.state.localizedCaseInsensitiveCompare("needs-sign-in") == .orderedSame ||
            status.message.localizedCaseInsensitiveContains("sign in")
    }

    static func isAccessDeniedMessage(_ message: String) -> Bool {
        let text = message.lowercased()
        return text.contains("access-denied") || text.contains("access denied") ||
            text.contains("no access") || text.contains("нет доступа")
    }

    enum SyncError: LocalizedError {
        case helperUnavailable, exportTimedOut
        case accessDenied
        case exportFailed(String)
        var errorDescription: String? {
            switch self {
            case .helperUnavailable: return "The local Chrome export helper is unavailable."
            case .exportTimedOut: return "Google Search Console Links did not respond within 35 seconds — stopped."
            case .accessDenied: return "No access to this Search Console property — stopped."
            case .exportFailed(let message): return message
            }
        }
    }
}
