// swift-tools-version:6.0
import PackageDescription

// The embedded Info.plist gives tincan its name, identifier and `--version`. macOS gives
// tincan the privacy permissions of the app that runs it, so this file doesn't decide them;
// macOS reads its purpose strings only when tincan is its own responsible process, as when
// a launchd job runs it directly. See docs/permissions.md.
let infoPlist = Context.packageDirectory + "/Support/Info.plist"
// The assistant guide and its topics, embedded so `tincan skill` works offline and always
// matches the installed version: one __TEXT section per file, each name at most 16
// characters. BundledSkill in Sources/TincanCLI/Commands/Skill.swift reads the same names.
let skillTopics = ["reading", "keeping-up", "sending", "identity", "contacts", "privacy", "setup", "json"]
let skillSections =
    [(section: "__tincan_skill", file: "skills/tincan/SKILL.md")]
    + skillTopics.map { (section: "__ts_" + String($0.map { $0 == "-" ? "_" : $0 }), file: "skills/tincan/references/\($0).md") }
// The phone number metadata PhoneNumberKit reads, embedded so an installed tincan needs no
// resource bundle beside it. PhoneMetadata in Sources/TincanKit/Identity reads the section.
let embeddedSections = skillSections + [(section: "__tincan_phones", file: "Support/PhoneNumberMetadata.json")]
let embedFlags = embeddedSections.flatMap { item in
    ["-Xlinker", "-sectcreate", "-Xlinker", "__TEXT", "-Xlinker", item.section, "-Xlinker", Context.packageDirectory + "/" + item.file]
}

let package = Package(
    name: "tincan",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "tincan", targets: ["tincan"]),
        .library(name: "TincanKit", targets: ["TincanKit"]),
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-argument-parser.git", from: "1.8.0"),
        .package(url: "https://github.com/PhoneNumberKit/PhoneNumberKit.git", exact: "5.0.11"),
    ],
    targets: [
        .executableTarget(
            name: "tincan",
            dependencies: ["TincanCLI"],
            linkerSettings: [
                .unsafeFlags(
                    [
                        "-Xlinker", "-sectcreate", "-Xlinker", "__TEXT", "-Xlinker", "__info_plist", "-Xlinker", infoPlist,
                    ] + embedFlags)
            ]
        ),
        .target(
            name: "TincanCLI",
            dependencies: [
                "TincanKit",
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
            ]
        ),
        .target(
            name: "TincanKit",
            dependencies: ["TincanObjC", .product(name: "PhoneNumberKit", package: "PhoneNumberKit")],
            linkerSettings: [.linkedLibrary("sqlite3")]
        ),
        .target(name: "TincanObjC"),
        .testTarget(
            name: "TincanKitTests",
            dependencies: ["TincanKit"]
        ),
        // Runs the built `tincan` binary against fixture databases (TINCAN_MESSAGES_DB and
        // friends) and checks output, exit codes and JSON shapes against Snapshots/.
        .testTarget(
            name: "TincanCLITests",
            dependencies: ["TincanCLI", "TincanKit"],
            exclude: ["Snapshots"]
        ),
    ]
)
