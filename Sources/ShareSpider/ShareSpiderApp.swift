import SwiftUI

@main
struct ShareSpiderApp: App {
    init() {
        if !SingleInstance.shared.acquire() {
            DispatchQueue.main.async { NSApp.terminate(nil) }
        }
    }
    // This is intentionally a `Window`, not a `WindowGroup`: ShareSpider is a
    // single-workspace app.  `WindowGroup` lets macOS create another crawler
    // window whenever the app is opened again or receives a URL command.
    var body: some Scene {
        Window("ShareSpider", id: "main") {
            ContentView().frame(minWidth: 1100, minHeight: 700)
        }
        .windowStyle(.automatic)
    }
}
