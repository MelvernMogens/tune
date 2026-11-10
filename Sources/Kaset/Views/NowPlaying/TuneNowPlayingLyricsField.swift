import SwiftUI

// MARK: - TuneNowPlayingLyrics

/// What the lyrics field shows. Built by `TuneNowPlayingHost` from `SyncedLyricsService`.
enum TuneNowPlayingLyrics: Equatable {
    /// A fetch for the current track is in flight.
    case loading
    /// Time-synced lines plus the bridge's line-boundary state.
    case synced(SyncedLyrics, currentLineIndex: Int?, displayTimeMs: Int?)
    /// Unsynced lyrics, one entry per line.
    case plain([String])
    /// Nothing to show.
    case unavailable

    /// Whether the split (lyrics + artwork) composition applies.
    var usesLyricsLayout: Bool {
        switch self {
        case .loading, .synced, .plain: true
        case .unavailable: false
        }
    }
}

// MARK: - TuneSyncedLyricsField

/// Synced lyrics, left-aligned, with the active line held near the top third of the field.
///
/// The column is not a scroll view: `TuneLyricsStackLayout` pins the focus line to a fixed
/// anchor, so a line change animates the whole column's position, the old line's shrink, and
/// the new line's growth in one transaction keyed to the bridge's line-boundary updates.
struct TuneSyncedLyricsField: View {
    let lyrics: SyncedLyrics
    let currentLineIndex: Int?
    let displayTimeMs: Int?
    /// Seeks to a line start (ms); nil when seeking isn't possible (ads, live).
    let onSeek: ((Int) -> Void)?
    /// Where the focus line's center sits, in the field's own coordinates; nil falls back to
    /// `lyricFocusAnchor` of the field's height.
    var focusAnchorY: CGFloat?

    @State private var hoveredIndex: Int?

    /// Line the column is centred on: the active line, else the last line already sung.
    var focusIndex: Int {
        Self.focusIndex(in: self.lyrics, currentLineIndex: self.currentLineIndex, displayTimeMs: self.displayTimeMs)
    }

    var body: some View {
        let focus = self.focusIndex
        TuneLyricsStackLayout(focusIndex: focus, focusAnchorY: self.focusAnchorY) {
            ForEach(self.lyrics.lines.indices, id: \.self) { index in
                self.line(at: index, focus: focus)
            }
        }
        .animation(TuneTheme.NowPlaying.lyricAnimation, value: focus)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .clipped()
        .mask(TuneLyricsEdgeFade())
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text("Lyrics"))
    }

    private func line(at index: Int, focus: Int) -> some View {
        let line = self.lyrics.lines[index]
        let isActive = index == focus && self.isFocusLineActive
        return TuneLyricLine(
            line: line,
            isActive: isActive,
            opacity: self.opacity(for: index, focus: focus, isActive: isActive),
            isHovered: self.hoveredIndex == index && self.onSeek != nil
        )
        .contentShape(.rect)
        .onHover { hovering in
            if hovering {
                self.hoveredIndex = index
            } else if self.hoveredIndex == index {
                self.hoveredIndex = nil
            }
        }
        .onTapGesture {
            self.onSeek?(line.timeInMs)
        }
        .accessibilityAddTraits(isActive ? [.isSelected] : [])
        .accessibilityAction {
            self.onSeek?(line.timeInMs)
        }
    }

    /// The focus line is "active" only while the bridge reports it as the current line
    /// (or, without bridge state yet, while display time sits inside it).
    private var isFocusLineActive: Bool {
        if let currentLineIndex, self.lyrics.lines.indices.contains(currentLineIndex) {
            return true
        }
        guard let displayTimeMs else { return false }
        return self.lyrics.currentLineIndex(at: displayTimeMs) != nil
    }

    private func opacity(for index: Int, focus: Int, isActive: Bool) -> Double {
        if isActive { return 1 }
        // Before the first line (an intro) the focus line hasn't been sung yet: it's next.
        if let displayTimeMs, self.lyrics.lines.indices.contains(focus), displayTimeMs < self.lyrics.lines[focus].timeInMs {
            return index < focus
                ? TuneTheme.NowPlaying.pastLyricOpacity(distance: focus - index)
                : TuneTheme.NowPlaying.upcomingLyricOpacity(distance: index - focus + 1)
        }
        if index <= focus {
            // The focus line itself, when inactive (instrumental gap after it), reads as just sung.
            return TuneTheme.NowPlaying.pastLyricOpacity(distance: max(focus - index, 1))
        }
        return TuneTheme.NowPlaying.upcomingLyricOpacity(distance: index - focus)
    }

    static func focusIndex(in lyrics: SyncedLyrics, currentLineIndex: Int?, displayTimeMs: Int?) -> Int {
        if let currentLineIndex, lyrics.lines.indices.contains(currentLineIndex) {
            return currentLineIndex
        }
        guard let displayTimeMs else { return 0 }
        return lyrics.lines.lastIndex { $0.timeInMs <= displayTimeMs } ?? 0
    }
}

// MARK: - TuneLyricLine

private struct TuneLyricLine: View {
    let line: SyncedLyricLine
    let isActive: Bool
    let opacity: Double
    let isHovered: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: TuneTheme.Spacing.unit) {
            if self.isInstrumental {
                Text(verbatim: "· · ·")
                    .font(TuneTheme.Typeface.data)
                    .tracking(3)
                    .padding(.vertical, TuneTheme.Spacing.unit * 2)
            } else {
                Text(self.line.text)
                    .modifier(TuneLyricFont(size: TuneTheme.NowPlaying.lyricSize * (self.isActive ? TuneTheme.NowPlaying.activeLyricScale : 1)))
                    .tracking(-0.5)
                    .lineSpacing(0)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if let romanized = self.line.romanizedText, !self.isInstrumental {
                Text(romanized)
                    .font(TuneTheme.Typeface.body)
                    .foregroundStyle(TuneTheme.Palette.inkSecondary)
            }
        }
        .foregroundStyle(TuneTheme.Palette.ink)
        .opacity(self.isHovered && !self.isActive ? max(self.opacity, 0.9) : self.opacity)
        .frame(maxWidth: .infinity, alignment: .leading)
        .animation(TuneTheme.NowPlaying.lyricAnimation, value: self.isActive)
        .animation(TuneTheme.NowPlaying.lyricAnimation, value: self.opacity)
        .animation(.easeOut(duration: 0.15), value: self.isHovered)
    }

    private var isInstrumental: Bool {
        self.line.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}

// MARK: - TuneLyricFont

/// Animates the lyric point size so the active line re-wraps as it grows (a scale effect
/// would overflow the column).
private struct TuneLyricFont: ViewModifier, Animatable {
    var size: CGFloat

    nonisolated var animatableData: CGFloat {
        get { self.size }
        set { self.size = newValue }
    }

    func body(content: Content) -> some View {
        content.font(.system(size: self.size, weight: .semibold))
    }
}

// MARK: - TuneLyricsStackLayout

/// Stacks lyric lines top to bottom and shifts the stack so the focus line's center sits at
/// `lyricFocusAnchor` of the field. A layout (not a scroll view) so a line change animates the
/// column's position together with the old line shrinking and the new one growing.
private struct TuneLyricsStackLayout: Layout {
    let focusIndex: Int
    /// Focus line center in the field's coordinates; nil uses `lyricFocusAnchor`.
    let focusAnchorY: CGFloat?

    func sizeThatFits(proposal: ProposedViewSize, subviews _: Subviews, cache _: inout Void) -> CGSize {
        // Fill what's offered but never report an infinite size from a stack's flexibility
        // probe (that would push the title and transport off-screen); the caller's
        // `.frame(maxWidth: .infinity, maxHeight: .infinity)` makes the field greedy.
        func finite(_ value: CGFloat?) -> CGFloat {
            guard let value, value.isFinite else { return 0 }
            return value
        }
        return CGSize(width: finite(proposal.width), height: finite(proposal.height))
    }

    func placeSubviews(in bounds: CGRect, proposal _: ProposedViewSize, subviews: Subviews, cache _: inout Void) {
        guard !subviews.isEmpty else { return }
        let lineProposal = ProposedViewSize(width: bounds.width, height: nil)
        let heights = subviews.map { $0.sizeThatFits(lineProposal).height }
        let gap = TuneTheme.NowPlaying.lyricLineGap

        let focus = min(max(self.focusIndex, 0), subviews.count - 1)
        let focusTop = heights[..<focus].reduce(0) { $0 + $1 + gap }
        let anchor = self.focusAnchorY.map { min(max($0, 0), bounds.height) }
            ?? bounds.height * TuneTheme.NowPlaying.lyricFocusAnchor
        var y = bounds.minY + anchor - focusTop - heights[focus] / 2

        for (subview, height) in zip(subviews, heights) {
            subview.place(at: CGPoint(x: bounds.minX, y: y), anchor: .topLeading, proposal: lineProposal)
            y += height + gap
        }
    }
}

// MARK: - TuneLyricsEdgeFade

/// Soft top and bottom edges for the lyrics field (C2 `.ly` mask).
struct TuneLyricsEdgeFade: View {
    var body: some View {
        VStack(spacing: 0) {
            // Fully clear for the first quarter so no half-cut glyphs sit under the header.
            LinearGradient(
                stops: [.init(color: .clear, location: 0), .init(color: .clear, location: 0.25), .init(color: .black, location: 1)],
                startPoint: .top,
                endPoint: .bottom
            )
            .frame(height: TuneTheme.NowPlaying.lyricEdgeFade)
            Color.black
            LinearGradient(colors: [.black, .clear], startPoint: .top, endPoint: .bottom)
                .frame(height: TuneTheme.NowPlaying.lyricEdgeFade)
        }
    }
}

// MARK: - TunePlainLyricsField

/// Unsynced lyrics: a quiet scrollable column, no active line.
struct TunePlainLyricsField: View {
    let lines: [String]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: TuneTheme.Spacing.unit * 2) {
                ForEach(self.lines.indices, id: \.self) { index in
                    let text = self.lines[index]
                    Text(text.isEmpty ? " " : text)
                        .font(TuneTheme.Typeface.section)
                        .foregroundStyle(TuneTheme.Palette.inkSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, TuneTheme.NowPlaying.lyricEdgeFade)
            .textSelection(.enabled)
        }
        .scrollIndicators(.hidden)
        .mask(TuneLyricsEdgeFade())
    }
}
