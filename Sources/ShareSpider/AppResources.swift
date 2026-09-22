import Foundation

/// Resource lookup for both the SwiftPM development executable and the app
/// bundle installed in /Applications.  Do not use Bundle.module here: SwiftPM
/// generates an accessor that assumes the resource bundle sits next to the
/// executable, while a macOS .app correctly keeps it in Contents/Resources.
enum AppResources {
    private static let bundleNames = [
        "SEOSpiderAgent_ShareSpider.bundle",
        "ShareSpider_ShareSpider.bundle"
    ]

    private static var containers: [URL] {
        let executableDirectory = URL(fileURLWithPath: CommandLine.arguments.first ?? "")
            .deletingLastPathComponent()
        return [Bundle.main.resourceURL, Bundle.main.bundleURL, executableDirectory]
            .compactMap { $0 }
    }

    private static var bundleRoots: [URL] {
        containers.flatMap { container in
            bundleNames.map { container.appendingPathComponent($0, isDirectory: true) }
        }
    }

    static func url(forResource name: String, withExtension ext: String) -> URL? {
        let fileName = "\(name).\(ext)"
        let candidates = bundleRoots.map { $0.appendingPathComponent(fileName) }
            + containers.map { $0.appendingPathComponent(fileName) }
        return candidates.first(where: { FileManager.default.fileExists(atPath: $0.path) })
    }

    static func runtimeURL(path: String) -> URL? {
        let candidates = bundleRoots.map { $0.appendingPathComponent("Runtime", isDirectory: true).appendingPathComponent(path) }
        return candidates.first(where: { FileManager.default.fileExists(atPath: $0.path) })
    }
}
