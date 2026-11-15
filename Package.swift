// swift-tools-version: 6.2
import PackageDescription

// CalendarKit — the shared-calendar client as a self-contained SPM: Connect
// transport, a SwiftData cache with offline writes, the recurrence expander,
// and the calendar UI (no reminders or notifications: MVCALE-15). Talks to mvCalendar. A host app (or
// CalendarLab) adds a thin wrapper that supplies identity + a token.
//
// Mirrors GarageKit's shape: the kit never owns login — the host injects a
// `tokenProvider`. Swift 6 strict concurrency from line one.
let package = Package(
    name: "CalendarKit",
    platforms: [.iOS(.v26)], // iOS-only
    products: [
        .library(name: "CalendarKit", targets: ["CalendarKit"]),
    ],
    dependencies: [
        .package(url: "https://github.com/connectrpc/connect-swift", from: "1.0.0"),
        .package(url: "https://github.com/apple/swift-protobuf", from: "1.27.0"),
    ],
    targets: [
        .target(
            name: "CalendarKit",
            dependencies: [
                .product(name: "Connect", package: "connect-swift"),
                .product(name: "SwiftProtobuf", package: "swift-protobuf"),
            ],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "CalendarKitTests",
            dependencies: ["CalendarKit"],
            resources: [.copy("Resources/recurrence-cases.json")],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
    ]
)
