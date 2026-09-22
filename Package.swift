// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "SEOSpiderAgent",
    platforms: [.macOS(.v14)],
    products: [.executable(name: "SEOSpiderAgent", targets: ["ShareSpider"])],
    dependencies: [.package(url: "https://github.com/scinfu/SwiftSoup.git", from: "2.6.0")],
    targets: [
        .executableTarget(
            name: "ShareSpider",
            dependencies: ["SwiftSoup"],
            resources: [
                .process("Resources"),
                // Node.js and playwright-core are bundled so colleagues do not
                // have to install either dependency just to use GSC features.
                .copy("Runtime")
            ]
        )
    ]
)
