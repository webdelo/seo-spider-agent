// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "ShareSpider",
    platforms: [.macOS(.v14)],
    products: [.executable(name: "ShareSpider", targets: ["ShareSpider"])],
    dependencies: [.package(url: "https://github.com/scinfu/SwiftSoup.git", from: "2.6.0")],
    targets: [.executableTarget(name: "ShareSpider", dependencies: ["SwiftSoup"], resources: [.process("Resources")])]
)
