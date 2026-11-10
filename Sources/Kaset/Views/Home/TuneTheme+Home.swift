import AppKit
import SwiftUI

// MARK: - TuneTheme home / playlist extensions

// Tokens the Home and playlist pages need beyond `TuneTheme.swift`. Kept in
// their own file so parallel redesign lanes don't conflict on the token file;
// fold them into `TuneTheme.swift` once the lanes have merged.

extension TuneTheme.Palette {
    /// 1 px inset edge drawn over artwork so dark covers don't dissolve into the
    /// near-black background (C2 `.art::after`).
    static let artworkEdge = Color(hex: 0xFFFFFF, opacity: 0.15)
}

extension TuneTheme.Radius {
    /// The scale step for a piece of artwork whose longer side is `side`
    /// points: small thumbnails (≤ 40), shelf artwork, then hero artwork (> 300).
    static func artwork(side: CGFloat) -> CGFloat {
        guard side.isFinite else { return Self.artwork }
        if side <= 40 {
            return Self.small
        }
        return side > 300 ? Self.hero : Self.artwork
    }

    /// The scale step for artwork of `size`.
    static func artwork(for size: CGSize) -> CGFloat {
        self.artwork(side: max(size.width, size.height))
    }
}

extension Shape where Self == RoundedRectangle {
    /// A continuous-corner rounded rectangle on the Tune radius scale, usable
    /// wherever a shape is expected (`.clipShape(.tuneRounded(12))`).
    static func tuneRounded(_ radius: CGFloat) -> RoundedRectangle {
        RoundedRectangle(cornerRadius: radius, style: .continuous)
    }
}

// MARK: - TuneVideoTag

/// The small mono "VIDEO" tag that marks a video on its artwork.
struct TuneVideoTag: View {
    static var text: String {
        String(localized: "Video").uppercased()
    }

    var body: some View {
        Text(verbatim: Self.text)
            .font(TuneTheme.Typeface.data)
            .tracking(0.6)
            .foregroundStyle(TuneTheme.Palette.ink)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(TuneTheme.Palette.background.opacity(0.82), in: .tuneRounded(TuneTheme.Radius.small))
            .fixedSize()
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }
}

extension TuneTheme {
    /// AppKit mirrors of the SwiftUI tokens, for the layer-drawn shelf cards.
    /// Same six-step scale as `TuneTheme.Typeface`; never add sizes here.
    @MainActor
    enum AppKit {
        static let ink = NSColor(TuneTheme.Palette.ink)
        static let inkSecondary = NSColor(TuneTheme.Palette.inkSecondary)
        static let inkMuted = NSColor(TuneTheme.Palette.inkMuted)
        static let inkDim = NSColor(TuneTheme.Palette.inkDim)
        static let background = NSColor(TuneTheme.Palette.background)
        static let raised = NSColor(TuneTheme.Palette.raised)
        static let rule = NSColor(TuneTheme.Palette.rule)
        static let artworkEdge = NSColor(TuneTheme.Palette.artworkEdge)

        /// 13 pt body (subtitles under cards).
        static let body = NSFont.systemFont(ofSize: 13, weight: .regular)
        /// 13 pt card titles (C2 `.ct`, weight 500).
        static let bodyMedium = NSFont.systemFont(ofSize: 13, weight: .medium)
        /// 11 pt monospaced data (meta tags, ranks' digits).
        static let data = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
        /// 28 pt display, used for chart ranks over artwork.
        static let display = NSFont.monospacedDigitSystemFont(ofSize: 28, weight: .semibold)
    }
}
