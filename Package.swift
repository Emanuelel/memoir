// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Memoir",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "MemoirKit", targets: ["MemoirKit"]),
        .executable(name: "MemoirApp", targets: ["MemoirApp"]),
        .executable(name: "memoir-mcp", targets: ["MemoirMCP"]),
        .executable(name: "memoir-ask", targets: ["MemoirAsk"]),
        .executable(name: "memoir-eval-seed", targets: ["MemoirEvalSeed"]),
    ],
    targets: [
        .target(
            name: "MemoirKit",
            linkerSettings: [.linkedLibrary("sqlite3")]
        ),
        // Seeded worlds, shared by the integration suite and the eval seeder.
        //
        // A module rather than a file in the test target because `memoir-eval-seed` needs the
        // same captures, the same clock and the same derived ids, and cannot import `Tests/`.
        // The alternative was a second copy, which is the one silent-corruption risk here:
        // both compile, the names are identical, and they drift.
        //
        // Deliberately not a product. It is a development target, not something anyone should
        // link into a shipped app.
        .target(
            name: "MemoirFixtures",
            dependencies: ["MemoirKit"]
        ),
        .executableTarget(
            name: "MemoirApp",
            dependencies: ["MemoirKit"]
        ),
        .executableTarget(
            name: "MemoirMCP",
            dependencies: ["MemoirKit"]
        ),
        .executableTarget(
            name: "MemoirAsk",
            dependencies: ["MemoirKit"]
        ),
        // Builds the fixture memory the answer evals are graded against. It is a product so
        // that `swift run memoir-eval-seed` works from a clean clone, which is what the eval
        // script needs; nothing in the shipped app links it.
        .executableTarget(
            name: "MemoirEvalSeed",
            dependencies: ["MemoirKit", "MemoirFixtures"]
        ),
        .testTarget(
            name: "MemoirAppTests",
            dependencies: ["MemoirApp"]
        ),
        .testTarget(
            name: "MemoirKitTests",
            dependencies: ["MemoirKit", "MemoirFixtures"]
        ),
    ]
)
