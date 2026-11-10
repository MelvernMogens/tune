import SwiftUI

// MARK: - PlayerBarGlyph

/// Hairline 12-point glyphs for the C2 status line (docs/fork/design/c2/home.html `.status`).
///
/// Drawn as paths in a 12×12 design space rather than SF Symbols so the transport reads as
/// thin, crisp line work instead of filled pictograms.
enum PlayerBarGlyph {
    case previous
    case next
    case play
    case pause
    case heart
    case heartFilled
    case airplay

    /// Side length of the glyph's design space, in points.
    static let size: CGFloat = 12

    @MainActor
    @ViewBuilder
    var view: some View {
        switch self {
        case .previous:
            PlayerBarGlyphShape(kind: self)
                .stroke(style: StrokeStyle(lineWidth: 1.2, lineJoin: .round))
        case .next:
            PlayerBarGlyphShape(kind: self)
                .stroke(style: StrokeStyle(lineWidth: 1.2, lineJoin: .round))
        case .play:
            PlayerBarGlyphShape(kind: self)
                .stroke(style: StrokeStyle(lineWidth: 1.2, lineJoin: .round))
        case .pause:
            PlayerBarGlyphShape(kind: self)
                .stroke(style: StrokeStyle(lineWidth: 1.6))
        case .heart, .airplay:
            PlayerBarGlyphShape(kind: self)
                .stroke(style: StrokeStyle(lineWidth: 1.1, lineJoin: .round))
        case .heartFilled:
            PlayerBarGlyphShape(kind: .heart)
                .fill()
        }
    }
}

// MARK: - PlayerBarGlyphShape

struct PlayerBarGlyphShape: Shape {
    let kind: PlayerBarGlyph

    func path(in rect: CGRect) -> Path {
        let scale = min(rect.width, rect.height) / PlayerBarGlyph.size
        var path = Path()
        func point(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
            CGPoint(x: rect.minX + x * scale, y: rect.minY + y * scale)
        }

        switch self.kind {
        case .previous:
            // M2 2v8 M10 2.5 4 6l6 3.5z
            path.move(to: point(2, 2))
            path.addLine(to: point(2, 10))
            path.move(to: point(10, 2.5))
            path.addLine(to: point(4, 6))
            path.addLine(to: point(10, 9.5))
            path.closeSubpath()
        case .next:
            // M10 2v8 M2 2.5 8 6l-6 3.5z
            path.move(to: point(10, 2))
            path.addLine(to: point(10, 10))
            path.move(to: point(2, 2.5))
            path.addLine(to: point(8, 6))
            path.addLine(to: point(2, 9.5))
            path.closeSubpath()
        case .play:
            path.move(to: point(3, 2))
            path.addLine(to: point(10, 6))
            path.addLine(to: point(3, 10))
            path.closeSubpath()
        case .pause:
            // M3.5 2v8 M8.5 2v8
            path.move(to: point(3.5, 2))
            path.addLine(to: point(3.5, 10))
            path.move(to: point(8.5, 2))
            path.addLine(to: point(8.5, 10))
        case .heart, .heartFilled:
            // M6 10.2 1.9 6.1a2.4 2.4 0 0 1 3.4-3.4l.7.7.7-.7a2.4 2.4 0 0 1 3.4 3.4z
            path.move(to: point(6, 10.2))
            path.addLine(to: point(1.9, 6.1))
            path.addArc(
                center: point(3.6, 4.4),
                radius: 2.4 * scale,
                startAngle: .degrees(135),
                endAngle: .degrees(-45),
                clockwise: false
            )
            path.addLine(to: point(6, 3.4))
            path.addLine(to: point(6.7, 2.7))
            path.addArc(
                center: point(8.4, 4.4),
                radius: 2.4 * scale,
                startAngle: .degrees(-135),
                endAngle: .degrees(45),
                clockwise: false
            )
            path.closeSubpath()
        case .airplay:
            // M3 8.5H1.5v-6h9v6H9 M6 7.5 3.5 10.5h5z
            path.move(to: point(3, 8.5))
            path.addLine(to: point(1.5, 8.5))
            path.addLine(to: point(1.5, 2.5))
            path.addLine(to: point(10.5, 2.5))
            path.addLine(to: point(10.5, 8.5))
            path.addLine(to: point(9, 8.5))
            path.move(to: point(6, 7.5))
            path.addLine(to: point(3.5, 10.5))
            path.addLine(to: point(8.5, 10.5))
            path.closeSubpath()
        }
        return path
    }
}

// MARK: - PlayerBarStatusGlyphButton

/// A borderless glyph button: no fill, no capsule. Hover brightens the ink.
struct PlayerBarStatusGlyphButton<Glyph: View>: View {
    var accessibilityID: String?
    let accessibilityLabel: String
    var accessibilityValue: String?
    var isActive = false
    var hitSize: CGFloat = 24
    let action: () -> Void
    @ViewBuilder var glyph: () -> Glyph

    @Environment(\.isEnabled) private var isEnabled
    @State private var isHovering = false

    var body: some View {
        Button(action: self.action) {
            self.glyph()
                .frame(width: PlayerBarGlyph.size, height: PlayerBarGlyph.size)
                .frame(width: self.hitSize, height: self.hitSize)
                .foregroundStyle(self.inkColor)
                .contentShape(Rectangle())
        }
        .buttonStyle(PlayerBarStatusPressStyle())
        .accessibilityLabel(self.accessibilityLabel)
        .modifier(PlayerBarOptionalAccessibility(identifier: self.accessibilityID, value: self.accessibilityValue))
        .onHover { self.isHovering = $0 }
    }

    /// Disabled glyphs drop to `inkDim` — never lower, or they read as rendering glitches.
    private var inkColor: Color {
        guard self.isEnabled else { return TuneTheme.Palette.inkDim }
        if self.isActive || self.isHovering {
            return TuneTheme.Palette.ink
        }
        return TuneTheme.Palette.inkSecondary
    }
}

// MARK: - PlayerBarStatusToggle

/// C2 `.tog`: an uppercase tracked text toggle. On = ink with a 1-point ink underline.
///
/// In narrow windows (`compactSystemImage` set) the label collapses to a 12-point glyph with the
/// same on/off treatment, so the scrubber keeps its room.
struct PlayerBarStatusToggle: View {
    let title: String
    let isOn: Bool
    var accessibilityID: String?
    let accessibilityLabel: String
    var accessibilityValue: String?
    var compactSystemImage: String?
    let action: () -> Void

    @Environment(\.isEnabled) private var isEnabled
    @State private var isHovering = false

    var body: some View {
        Button(action: self.action) {
            self.label
                .foregroundStyle(self.inkColor)
                .padding(.bottom, 1)
                .overlay(alignment: .bottom) {
                    if self.isOn {
                        Rectangle()
                            .fill(TuneTheme.Palette.ink)
                            .frame(height: 1)
                            .offset(y: 1)
                    }
                }
                .padding(.vertical, 6)
                .contentShape(Rectangle())
        }
        .buttonStyle(PlayerBarStatusPressStyle())
        .accessibilityLabel(self.accessibilityLabel)
        .modifier(PlayerBarOptionalAccessibility(identifier: self.accessibilityID, value: self.accessibilityValue))
        .accessibilityAddTraits(self.isOn ? .isSelected : [])
        .onHover { self.isHovering = $0 }
    }

    @ViewBuilder
    private var label: some View {
        if let compactSystemImage {
            Image(systemName: compactSystemImage)
                .font(TuneTheme.Typeface.label)
                .frame(width: PlayerBarGlyph.size, height: PlayerBarGlyph.size)
                .help(self.title)
        } else {
            Text(self.title)
                .font(TuneTheme.Typeface.label)
                .tracking(PlayerBarStatusMetrics.capsTracking)
                .textCase(.uppercase)
                .lineLimit(1)
                .fixedSize()
        }
    }

    /// Off and disabled toggles share `inkDim`; nothing in the line goes dimmer.
    private var inkColor: Color {
        guard self.isEnabled else { return TuneTheme.Palette.inkDim }
        if self.isOn {
            return TuneTheme.Palette.ink
        }
        if self.compactSystemImage != nil {
            return self.isHovering && self.isEnabled ? TuneTheme.Palette.ink : TuneTheme.Palette.inkMuted
        }
        return self.isHovering && self.isEnabled ? TuneTheme.Palette.inkSecondary : TuneTheme.Palette.inkDim
    }
}

// MARK: - PlayerBarVolumeMeter

/// C2 `.vol`: ten 3×9 segments with softened ends, lit in ink up to the current level.
struct PlayerBarVolumeMeter: View {
    let level: Double

    static let segmentCount = 10

    /// Number of lit segments for a 0...1 volume. Any audible volume lights at least one.
    static func litSegments(for level: Double) -> Int {
        guard level.isFinite, level > 0 else { return 0 }
        let clamped = min(level, 1)
        return max(1, Int((clamped * Double(self.segmentCount)).rounded()))
    }

    var body: some View {
        let lit = Self.litSegments(for: self.level)
        HStack(spacing: 2) {
            ForEach(0 ..< Self.segmentCount, id: \.self) { index in
                RoundedRectangle(cornerRadius: 1, style: .continuous)
                    .fill(index < lit ? TuneTheme.Palette.inkSecondary : TuneTheme.Palette.rule)
                    .frame(width: 3, height: 9)
            }
        }
        .accessibilityHidden(true)
    }
}

// MARK: - PlayerBarStatusSeparator

/// C2 `.sep`: a 1×14 rule between toggle groups.
struct PlayerBarStatusSeparator: View {
    var body: some View {
        Rectangle()
            .fill(TuneTheme.Palette.rule)
            .frame(width: 1, height: 14)
            .accessibilityHidden(true)
    }
}

// MARK: - PlayerBarStatusMetrics

enum PlayerBarStatusMetrics {
    /// `.08em` at 11 pt, matching `tuneCapsLabel()`.
    static let capsTracking: CGFloat = 0.9
    /// Track artwork edge in the status line.
    static let artworkSize: CGFloat = 24
    /// Inset hairline that keeps dark covers off the black background (C2 `.art::after`).
    static let artworkEdgeOpacity = 0.15
    /// Track column width below which the scrubber never moves (short titles).
    static let trackColumnFloor: CGFloat = 240
    /// Narrowest track column in the compact layout.
    static let compactTrackColumnWidth: CGFloat = 150
    /// Longest scrubber, per the mockup.
    static let scrubberMaxWidth: CGFloat = 360
    /// Narrowest time section (`0:00 ── scrubber ── 0:00`) before the track column yields.
    static let timeSectionMinWidth: CGFloat = 180
}

// MARK: - PlayerBarStatusPressStyle

struct PlayerBarStatusPressStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .opacity(configuration.isPressed ? 0.6 : 1)
    }
}

// MARK: - PlayerBarOptionalAccessibility

struct PlayerBarOptionalAccessibility: ViewModifier {
    let identifier: String?
    let value: String?

    func body(content: Content) -> some View {
        switch (self.identifier, self.value) {
        case let (identifier?, value?):
            content.accessibilityIdentifier(identifier).accessibilityValue(value)
        case let (identifier?, nil):
            content.accessibilityIdentifier(identifier)
        case let (nil, value?):
            content.accessibilityValue(value)
        case (nil, nil):
            content
        }
    }
}

// MARK: - PlayerBarTrackTimeLayout

/// Lays out the status line's track column and time section side by side: the track
/// column gets its natural width clamped to `trackFloor ... (room − timeMinimum)`, the time
/// section gets the rest up to `timeMaximum`, and any remainder stays empty on the right.
/// A short title keeps the scrubber where it always is; a long one pushes it instead of
/// truncating next to free space.
struct PlayerBarTrackTimeLayout: Layout {
    let spacing: CGFloat
    let trackFloor: CGFloat
    let timeMinimum: CGFloat
    let timeMaximum: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache _: inout ()) -> CGSize {
        let height = subviews.map { $0.sizeThatFits(.unspecified).height }.max() ?? 0
        guard let width = proposal.width, width.isFinite else {
            // Ideal: both at their natural widths.
            let ideal = subviews.reduce(CGFloat(0)) { $0 + $1.sizeThatFits(.unspecified).width }
            return CGSize(width: ideal + self.spacing, height: proposal.height ?? height)
        }
        return CGSize(width: width, height: proposal.height ?? height)
    }

    func placeSubviews(in bounds: CGRect, proposal _: ProposedViewSize, subviews: Subviews, cache _: inout ()) {
        guard subviews.count == 2 else { return }
        let widths = Self.widths(
            available: bounds.width,
            trackNatural: subviews[0].sizeThatFits(.unspecified).width,
            spacing: self.spacing,
            trackFloor: self.trackFloor,
            timeMinimum: self.timeMinimum,
            timeMaximum: self.timeMaximum
        )
        subviews[0].place(
            at: CGPoint(x: bounds.minX, y: bounds.midY),
            anchor: .leading,
            proposal: ProposedViewSize(width: widths.track, height: bounds.height)
        )
        subviews[1].place(
            at: CGPoint(x: bounds.minX + widths.track + self.spacing, y: bounds.midY),
            anchor: .leading,
            proposal: ProposedViewSize(width: widths.time, height: bounds.height)
        )
    }

    /// Pure split, unit-tested.
    static func widths(
        available: CGFloat,
        trackNatural: CGFloat,
        spacing: CGFloat,
        trackFloor: CGFloat,
        timeMinimum: CGFloat,
        timeMaximum: CGFloat
    ) -> (track: CGFloat, time: CGFloat) {
        let room = max(0, available - spacing)
        // In a cramped bar the two halves share the room rather than the track vanishing.
        let trackCeiling = max(room - timeMinimum, min(trackFloor, room / 2))
        let track = min(max(trackNatural.rounded(.up), trackFloor), trackCeiling)
        let time = min(max(0, room - track), timeMaximum)
        return (track, time)
    }
}
