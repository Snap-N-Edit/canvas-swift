// swift-tools-version: 5.9
//
// SnapneditCanvas — the official Swift wrapper for the snapnedit embeddable
// editor (https://snapnedit.com/docs/embed-native).
//
// Tools version 5.9 (rather than 6.x) on purpose: it keeps the package usable
// from Xcode 15 onward, and it keeps the Swift 5 language mode, under which
// the ergonomic `[String: Any]` overloads on the handle are legal. The library
// is nevertheless written to be strict-concurrency clean — every public value
// type is `Sendable`, and everything stateful is `@MainActor`.

import PackageDescription

let package = Package(
    name: "SnapneditCanvas",
    platforms: [.macOS(.v13), .iOS(.v16)],
    products: [
        .library(name: "SnapneditCanvas", targets: ["SnapneditCanvas"]),
    ],
    targets: [
        .target(name: "SnapneditCanvas"),
        .testTarget(
            name: "SnapneditCanvasTests",
            dependencies: ["SnapneditCanvas"],
            // A verbatim copy of the monorepo's `packages/embed/protocol.json`,
            // so `ProtocolConformanceTests` can hold the Swift surface against
            // the contract itself rather than a hand-maintained list.
            resources: [.process("Resources")]
        ),
        // A REAL WKWebView against a running snapnedit stack. Skips itself
        // with a clear message unless SNAPNEDIT_E2E_URL is set.
        .testTarget(name: "SnapneditCanvasIntegrationTests", dependencies: ["SnapneditCanvas"]),
    ]
)
