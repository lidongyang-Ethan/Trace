// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Trace",
    defaultLocalization: "en",
    platforms: [.iOS(.v16), .macOS(.v13)],
    products: [
        .library(name: "TraceCore", targets: ["TraceCore"]),
        .library(name: "TraceAlamofire", targets: ["TraceAlamofire"]),
        .library(name: "TraceUI", targets: ["TraceUI"])
    ],
    dependencies: [
        .package(url: "https://github.com/Alamofire/Alamofire.git", exact: "5.12.2")
    ],
    targets: [
        .target(name: "TraceCore", resources: [.process("Resources")]),
        .target(name: "TraceAlamofire", dependencies: ["TraceCore", .product(name: "Alamofire", package: "Alamofire")]),
        .target(name: "TraceUI", dependencies: ["TraceCore"]),
        .testTarget(name: "TraceCoreTests", dependencies: ["TraceCore"]),
        .testTarget(name: "TraceAlamofireTests", dependencies: ["TraceAlamofire", .product(name: "Alamofire", package: "Alamofire")])
    ]
)
