import SwiftUI

enum Palette {
    static let accent = Color(red: 0.26, green: 0.52, blue: 0.96)   // Better Together blue
    static let good = Color(red: 0.20, green: 0.78, blue: 0.35)
    static let warn = Color.orange
    static let bg = Color.black.opacity(0.04)
}

extension View {
    /// A translucent, rounded "glass" card. Uses the system glass effect on
    /// macOS 26+ and falls back to an ultra-thin material elsewhere.
    @ViewBuilder func glassCard(cornerRadius: CGFloat = 14) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        self.background {
            shape.fill(.ultraThinMaterial)
            shape.strokeBorder(.white.opacity(0.08), lineWidth: 0.5)
        }
        .clipShape(shape)
    }

    func sectionLabelStyle() -> some View {
        self.font(.caption.weight(.semibold))
            .foregroundStyle(.secondary)
            .textCase(.uppercase)
            .kerning(0.5)
    }
}

/// A battery / signal pill used in the header.
struct StatPill: View {
    let systemImage: String
    let text: String
    var tint: Color = .secondary
    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: systemImage).font(.caption2)
            Text(text).font(.caption.monospacedDigit())
        }
        .foregroundStyle(tint)
        .padding(.horizontal, 8).padding(.vertical, 3)
        .glassCard(cornerRadius: 8)
    }
}
