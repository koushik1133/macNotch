import AppKit

// Stand-in for MediaEngine.swift's ArtworkPalette (the harness compiles the
// lab's pure files only).
enum ArtworkPalette {
    static func glowColor(for image: CGImage) -> NSColor? { nil }
}
