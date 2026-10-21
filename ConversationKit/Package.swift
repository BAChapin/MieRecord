// swift-tools-version: 6.2
import PackageDescription

// ConversationKit groups the non-UI engine of MieRecord into logical modules.
// The SwiftUI app target (MieRecord.xcodeproj) depends on these products; the
// package itself never imports SwiftUI so the engine stays UI-independent.
let package = Package(
    name: "ConversationKit",
    platforms: [
        .iOS(.v26),
        // macOS is listed only so `swift build` / `swift test` run on the host
        // for the pure-logic modules. The product ships on iOS.
        .macOS(.v26),
    ],
    products: [
        .library(name: "ConversationCore", targets: ["ConversationCore"]),
        .library(name: "ConversationAudio", targets: ["ConversationAudio"]),
        .library(name: "ConversationML", targets: ["ConversationML"]),
        .library(name: "ConversationPipeline", targets: ["ConversationPipeline"]),
        .library(name: "ConversationStorage", targets: ["ConversationStorage"]),
    ],
    targets: [
        // Domain entities, processing states, speaker policy, repository protocols.
        .target(name: "ConversationCore"),
        // AVAudioEngine capture, durable file writing, session interruptions.
        .target(name: "ConversationAudio", dependencies: ["ConversationCore"]),
        // Transcription / diarization / identity engine protocols and the Apple
        // Speech framework streaming transcription implementation.
        .target(name: "ConversationML", dependencies: ["ConversationCore", "ConversationAudio"]),
        // Orchestration of a live recording session and live transcript assembly.
        .target(
            name: "ConversationPipeline",
            dependencies: ["ConversationCore", "ConversationAudio", "ConversationML"]
        ),
        // SwiftData persistence and on-disk audio file management.
        .target(name: "ConversationStorage", dependencies: ["ConversationCore"]),

        .testTarget(name: "ConversationCoreTests", dependencies: ["ConversationCore"]),
        .testTarget(
            name: "ConversationPipelineTests",
            dependencies: ["ConversationPipeline", "ConversationCore", "ConversationAudio", "ConversationML"]
        ),
        .testTarget(name: "ConversationMLTests", dependencies: ["ConversationML"]),
        .testTarget(name: "ConversationStorageTests", dependencies: ["ConversationStorage", "ConversationCore"]),
    ],
    swiftLanguageModes: [.v6]
)
