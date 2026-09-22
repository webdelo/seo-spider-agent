import SwiftUI

@main
struct ShareSpiderApp: App {
    @StateObject private var licence = LicenseManager()
    init() {
        if !SingleInstance.shared.acquire() {
            DispatchQueue.main.async { NSApp.terminate(nil) }
        }
    }
    // This is intentionally a `Window`, not a `WindowGroup`: ShareSpider is a
    // single-workspace app.  `WindowGroup` lets macOS create another crawler
    // window whenever the app is opened again or receives a URL command.
    var body: some Scene {
        Window("SEOSpiderAgent", id: "main") {
            Group {
                if licence.state == .licensed || licence.state == .offlineGrace {
                    ContentView().environmentObject(licence).frame(minWidth: 1100, minHeight: 700)
                } else {
                    LicenseGateView(licence: licence).frame(minWidth: 560, minHeight: 520)
                }
            }
        }
        .windowStyle(.automatic)
    }
}
