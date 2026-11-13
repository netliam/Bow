import SwiftUI

/// Reading progress as a small ring, as Books shows it. Tinted by `.tint`; the track uses the current foreground.
struct ProgressRing: View {
    let fraction: Double
    var lineWidth: CGFloat = 3

    var body: some View {
        let value = min(max(fraction, 0), 1)
        ZStack {
            Circle().stroke(.foreground.opacity(0.22), lineWidth: lineWidth)
            Circle()
                .trim(from: 0, to: value)
                .stroke(.tint, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                .rotationEffect(.degrees(-90))  // Start at 12 o'clock.
        }
        .padding(lineWidth / 2)
        .accessibilityElement()
        .accessibilityLabel("\(Int((value * 100).rounded()))% read")
    }
}
