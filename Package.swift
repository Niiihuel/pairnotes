// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "PairNotes",
    platforms: [.iOS("26.0")],
    products: [.library(name: "PairNotesCore", targets: ["PairNotesCore"])],
    targets: [
        .target(name: "PairNotesCore", path: "PairNotes/Core"),
        .testTarget(
            name: "PairNotesCoreTests",
            dependencies: ["PairNotesCore"],
            path: "PairNotes/Tests/CoreTests"
        )
    ]
)
