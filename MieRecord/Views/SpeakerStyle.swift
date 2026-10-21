import SwiftUI

/// Stable per-recording speaker colors, assigned by first appearance.
enum SpeakerStyle {
    private static let palette: [Color] = [.blue, .orange, .green, .purple, .pink, .teal, .brown, .indigo]

    static func color(forIndex index: Int) -> Color {
        palette[index % palette.count]
    }
}
