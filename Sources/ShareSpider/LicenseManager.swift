import Foundation
import SwiftUI
import CryptoKit
import IOKit

/// Local client for the ShareSpider licence Worker. The Worker is the source
/// of truth: this file holds only the signed, time-limited session token. A
/// SHA-256 hash of the Mac serial number identifies the device; the serial
/// number itself never leaves this machine. No Worker secret is in the app.
@MainActor
final class LicenseManager: ObservableObject {
    static let endpoint = URL(string: "https://seospider.daniilwebdelo.workers.dev")!
    private static let offlineGrace: TimeInterval = 7 * 24 * 60 * 60

    @Published private(set) var state: State = .checking
    @Published private(set) var message = "Checking licence…"
    @Published private(set) var accountEmail = ""

    enum State: Equatable { case checking, signedOut, licensed, offlineGrace }

    private struct StoredSession: Codable {
        var email: String
        var token: String
        var expiresAt: Date
        var lastValidatedAt: Date
    }
    private struct ActivationRequest: Encodable { var email: String; var code: String; var deviceId: String; var deviceName: String }
    private struct ValidateRequest: Encodable { var deviceId: String }
    private struct TokenResponse: Decodable { var token: String; var expiresIn: TimeInterval }
    /// Validation deliberately rotates the bearer token.  The Mac can only
    /// receive a replacement after the Worker has checked the email, device
    /// hash and revocation state server-side.
    private struct ValidationResponse: Decodable { var valid: Bool; var token: String; var expiresIn: TimeInterval }
    private struct ServiceError: Decodable { var error: String }

    private var session: StoredSession?

    private static var directory: URL {
        let url = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("ShareSpider", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
    private static var sessionFile: URL { directory.appendingPathComponent("license-session.json") }

    init() {
        session = Self.loadSession()
        accountEmail = session?.email ?? ""
    }

    func restoreSession() async {
        guard let session else { state = .signedOut; message = "Sign in to activate ShareSpider."; return }
        accountEmail = session.email
        await validateExistingSession(session)
    }

    /// The crawler calls this immediately before every new crawl.  Unlike the
    /// launch check it does not permit the offline grace period: a new site
    /// analysis must have a current, server-confirmed licence.
    func validateForNewCrawl() async -> Bool {
        guard let session else {
            state = .signedOut; message = "Activate ShareSpider before starting a crawl."; return false
        }
        do {
            let reply: ValidationResponse = try await post("/v1/validate", payload: ValidateRequest(deviceId: try Self.deviceID()), bearer: session.token)
            var updated = session
            updated.token = reply.token
            updated.expiresAt = Date().addingTimeInterval(reply.expiresIn)
            updated.lastValidatedAt = Date()
            save(updated); self.session = updated
            state = .licensed; message = "Licence active"; return true
        } catch {
            signOut(message: "The licence could not be confirmed. Connect to the internet and activate ShareSpider again.")
            return false
        }
    }

    func activate(email: String, code: String) async {
        state = .checking
        message = "Activating ShareSpider…"
        do {
            let reply: TokenResponse = try await post("/v1/activate", payload: ActivationRequest(email: email, code: code, deviceId: try Self.deviceID(), deviceName: Host.current().localizedName ?? "Mac"))
            let fresh = StoredSession(email: email.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(), token: reply.token, expiresAt: Date().addingTimeInterval(reply.expiresIn), lastValidatedAt: Date())
            save(fresh)
            session = fresh; accountEmail = fresh.email; state = .licensed; message = "Licence active"
        } catch {
            state = .signedOut; message = error.localizedDescription
        }
    }

    func signOut(message: String = "Signed out.") {
        try? FileManager.default.removeItem(at: Self.sessionFile)
        session = nil; accountEmail = ""; state = .signedOut; self.message = message
    }

    private func validateExistingSession(_ current: StoredSession) async {
        do {
            let reply: ValidationResponse = try await post("/v1/validate", payload: ValidateRequest(deviceId: try Self.deviceID()), bearer: current.token)
            var updated = current
            updated.token = reply.token
            updated.expiresAt = Date().addingTimeInterval(reply.expiresIn)
            updated.lastValidatedAt = Date()
            save(updated); session = updated
            state = .licensed; message = "Licence active"
        } catch {
            if Date().timeIntervalSince(current.lastValidatedAt) <= Self.offlineGrace {
                state = .offlineGrace; message = "Offline: licence remains active for up to 7 days."
            } else {
                signOut(message: "We could not verify this licence. Connect to the internet and sign in again.")
            }
        }
    }

    private func post<Response: Decodable, Payload: Encodable>(_ path: String, payload: Payload, bearer: String? = nil) async throws -> Response {
        var request = URLRequest(url: Self.endpoint.appendingPathComponent(path))
        request.httpMethod = "POST"; request.timeoutInterval = 20
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let bearer { request.setValue("Bearer \(bearer)", forHTTPHeaderField: "Authorization") }
        request.httpBody = try JSONEncoder().encode(payload)
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw LicenseError.connection }
        if !(200..<300).contains(http.statusCode) {
            throw LicenseError.service((try? JSONDecoder().decode(ServiceError.self, from: data).error) ?? "Licence service returned HTTP \(http.statusCode).")
        }
        do { return try JSONDecoder().decode(Response.self, from: data) }
        catch { throw LicenseError.service("Licence service returned an unreadable response.") }
    }

    private func save(_ value: StoredSession) {
        guard let data = try? JSONEncoder().encode(value) else { return }
        try? data.write(to: Self.sessionFile, options: [.atomic])
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: Self.sessionFile.path)
    }
    private static func loadSession() -> StoredSession? {
        guard let data = try? Data(contentsOf: sessionFile) else { return nil }
        return try? JSONDecoder().decode(StoredSession.self, from: data)
    }
    /// Stable, irreversible device identifier. This deliberately has no UUID
    /// fallback: a licence is bound exclusively to this Mac's hardware serial.
    private static func deviceID() throws -> String {
        guard let serial = hardwareSerialNumber(), !serial.isEmpty else { throw LicenseError.deviceUnavailable }
        let digest = SHA256.hash(data: Data(serial.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    private static func hardwareSerialNumber() -> String? {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOPlatformExpertDevice"))
        guard service != 0 else { return nil }
        defer { IOObjectRelease(service) }
        guard let property = IORegistryEntryCreateCFProperty(service, kIOPlatformSerialNumberKey as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() as? String else { return nil }
        return property.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

private enum LicenseError: LocalizedError {
    case connection, deviceUnavailable, service(String)
    var errorDescription: String? {
        switch self {
        case .connection: "Could not connect to the licence service."
        case .deviceUnavailable: "ShareSpider could not read this Mac’s hardware serial number."
        case .service(let message): message
        }
    }
}

struct LicenseGateView: View {
    @ObservedObject var licence: LicenseManager
    @State private var email = ""
    @State private var activationCode = ""

    var body: some View {
        VStack(spacing: 18) {
            BrandLogo(width: 360, height: 78)
            VStack(spacing: 12) {
                Text("Activate ShareSpider").font(.title2.weight(.semibold))
                Text("Enter the email that received the licence and its one-time activation code.")
                    .multilineTextAlignment(.center).foregroundStyle(.secondary).frame(maxWidth: 370)
                TextField("Email", text: $email).textFieldStyle(.roundedBorder).frame(width: 360)
                TextField("Activation code", text: $activationCode).textFieldStyle(.roundedBorder).frame(width: 360)
                Button("Activate this Mac") {
                    Task { await licence.activate(email: email, code: activationCode) }
                }
                .buttonStyle(.borderedProminent)
                .disabled(email.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || activationCode.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || licence.state == .checking)
                Text(licence.message).font(.caption).foregroundStyle(licence.state == .signedOut ? .red : .secondary).multilineTextAlignment(.center).frame(maxWidth: 380)
            }
            .padding(24).background(.quaternary, in: RoundedRectangle(cornerRadius: 16))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(36)
        .task { await licence.restoreSession() }
    }
}
