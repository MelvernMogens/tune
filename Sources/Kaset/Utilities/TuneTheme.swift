import SwiftUI

// MARK: - TuneTheme

/// Design tokens for the Tune redesign (direction C2, see docs/fork/design/c2/).
///
/// Editorial, type-led, art-forward. Near-black surfaces, off-white ink, one orange
/// accent reserved for "now playing" state only. Hard edges: artwork and rows use no
/// corner radius; only keycaps get `Radius.keycap`.
///
/// Every redesigned view reads colors, type, and spacing from here — never hard-code
/// hex values or font sizes in views.
enum TuneTheme {
    // MARK: Color

    enum Palette {
        /// Window background.
        static let background = Color(hex: 0x0B0B0A)
        /// Sidebar / secondary panels.
        static let panel = Color(hex: 0x0F0F0E)
        /// Raised rows, hover and selection fills.
        static let raised = Color(hex: 0x1A1A18)
        /// Stronger raised fill (pressed / selected-and-hovered).
        static let raisedStrong = Color(hex: 0x232220)
        /// Hairline dividers.
        static let hairline = Color(hex: 0x1F1F1C)
        /// Strong rules (section rules, keycap borders).
        static let rule = Color(hex: 0x34332F)

        /// Primary text.
        static let ink = Color(hex: 0xF3F1EA)
        /// Secondary text (artists, subtitles).
        static let inkSecondary = Color(hex: 0xC4C1B8)
        /// Muted text (metadata, labels).
        static let inkMuted = Color(hex: 0x9A978F)
        /// Dim text (disabled, past lyric lines).
        static let inkDim = Color(hex: 0x77746C)

        /// The single accent. Use ONLY for now-playing / active-playback state.
        static let accent = Color(hex: 0xFF5A1F)
    }

    // MARK: Type

    /// Six-step scale. Views must not introduce other sizes.
    enum Typeface {
        /// 11 pt monospaced tabular data: durations, plays, timestamps, keycaps.
        static let data = Font.system(size: 11, weight: .regular, design: .monospaced).monospacedDigit()
        /// 11 pt uppercase section labels (apply `.tuneCapsLabel()` for tracking + case).
        static let label = Font.system(size: 11, weight: .semibold)
        /// 13 pt body and rows.
        static let body = Font.system(size: 13, weight: .regular)
        /// 13 pt emphasized row titles.
        static let bodyEmphasis = Font.system(size: 13, weight: .semibold)
        /// 20 pt section headings.
        static let section = Font.system(size: 20, weight: .semibold)
        /// 28 pt lyric lines / secondary display.
        static let display = Font.system(size: 28, weight: .semibold)
        /// 44 pt page titles and hero headlines.
        static let headline = Font.system(size: 44, weight: .bold)
    }

    // MARK: Layout

    enum Spacing {
        /// Base unit.
        static let unit: CGFloat = 4
        /// Shared row pitch so columns line up across lists.
        static let rowPitch: CGFloat = 26
        /// Content gutters and column gaps.
        static let gutter: CGFloat = 40
        /// Gap between shelf items.
        static let itemGap: CGFloat = 16
        /// Sidebar width.
        static let sidebarWidth: CGFloat = 220
        /// Thin status-line player height.
        static let statusLineHeight: CGFloat = 36
        /// Bottom inset of a scrolling page's content: scrolled to the end, the last row
        /// rests a status line plus a gutter above the status line, never against it.
        static let scrollEndInset: CGFloat = statusLineHeight + gutter
    }

    /// Soft, continuous corners ("too boxy" otherwise). Rounded rectangles only — never
    /// circles or capsules for buttons. Pick by element size:
    enum Radius {
        /// Hairline separators and rules only.
        static let none: CGFloat = 0
        /// Keycaps, small thumbnails (≤ 40 pt), mono tags.
        static let small: CGFloat = 6
        /// Rows' hover/selection fills, text fields, compact controls, dropdown items.
        static let control: CGFloat = 8
        /// Shelf artwork, cards, video frames (≈ 120–300 pt).
        static let artwork: CGFloat = 12
        /// Large artwork / hero tiles / Now Playing artwork and video (> 300 pt).
        static let hero: CGFloat = 18
        /// Floating panels: queue pane, search dropdown, menus, popovers.
        static let panel: CGFloat = 14
        /// Keycaps (alias of small).
        static let keycap: CGFloat = 6
    }
}

// MARK: - Helpers

extension Color {
    /// sRGB color from a 0xRRGGBB literal.
    init(hex: UInt32, opacity: Double = 1) {
        self.init(
            .sRGB,
            red: Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255,
            opacity: opacity
        )
    }
}

extension View {
    /// Uppercase, tracked, muted section label (C2 `.cap`).
    func tuneCapsLabel() -> some View {
        self
            .font(TuneTheme.Typeface.label)
            .tracking(0.9)
            .textCase(.uppercase)
            .foregroundStyle(TuneTheme.Palette.inkMuted)
    }
}
