import AppKit

// Stand-in for MediaEngine.swift's ArtworkPalette (the harness compiles the
// lab's pure files only).
enum ArtworkPalette {
    static func glowColor(for image: CGImage) -> NSColor? { nil }
}

// Stand-in for IslandInteraction's settings store (the outline spring).
enum IslandInteractionStore {
    struct Motion { var coreAnimationBounce: Double = 0.1; var coreAnimationResponse: Double? = 0.4 }
    struct Snapshot { var motion = Motion() }
    static var current: Snapshot { Snapshot() }
}
