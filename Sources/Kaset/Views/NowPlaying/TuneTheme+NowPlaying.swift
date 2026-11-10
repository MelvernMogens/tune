import SwiftUI

// MARK: - TuneTheme.NowPlaying

/// Layout and motion tokens for the fullscreen Now Playing view (C2 `nowplaying.html`).
///
/// Lives beside the view (not in `TuneTheme.swift`) so the redesign lanes don't collide;
/// colors and the type scale still come from `TuneTheme.Palette` / `TuneTheme.Typeface`.
extension TuneTheme {
    enum NowPlaying {
        // MARK: Lyrics

        /// Point size of an inactive lyric line. Equals `Typeface.display` (28 pt); exposed as a
        /// number because the active line animates its size continuously.
        static let lyricSize: CGFloat = 28
        /// Active line size multiplier (28 → ~36 pt). Kept ≤ 1.4 so the jump reads as emphasis, not a zoom.
        static let activeLyricScale: CGFloat = 1.3
        /// Vertical gap between lyric lines.
        static let lyricLineGap: CGFloat = TuneTheme.Spacing.unit * 5
        /// Where the active line's center sits inside the lyrics field (0 = top, 1 = bottom)
        /// when the window-relative anchor isn't known yet.
        static let lyricFocusAnchor: CGFloat = 0.36
        /// Where the active line's center sits in the window (0 = top, 1 = bottom): a little
        /// above the middle, so sung lines fill the space under the title.
        static let lyricFocusWindowShare: CGFloat = 0.4
        /// Height of the soft fade at the top/bottom edge of the lyrics field.
        static let lyricEdgeFade: CGFloat = 96
        /// Line-change motion.
        static let lyricAnimation = Animation.spring(response: 0.55, dampingFraction: 0.86)

        /// Opacity of a line `distance` lines before the active one (1 = just sung): ~0.25,
        /// receding.
        static func pastLyricOpacity(distance: Int) -> Double {
            max(0.1, 0.25 - Double(max(distance, 1) - 1) * 0.04)
        }

        /// Opacity of a line `distance` lines after the active one (1 = next): ~0.5, receding.
        static func upcomingLyricOpacity(distance: Int) -> Double {
            max(0.22, 0.5 - Double(max(distance, 1) - 1) * 0.06)
        }

        // MARK: Layout

        /// Left edge of the text column (C2: 96 px at 1440 wide).
        static let columnLeading: CGFloat = 96
        /// Text column max width.
        static let columnMaxWidth: CGFloat = 580
        /// Text column width as a share of the window when narrower than the max.
        static let columnWidthShare: CGFloat = 0.44
        /// Text column width as a share of the area left of the Up Next pane.
        static let columnWidthShareBesideQueue: CGFloat = 0.5
        /// Top inset of the title block.
        static let headerTop: CGFloat = 72
        /// Bottom inset of the transport row.
        static let footerBottom: CGFloat = 56
        /// Transport row width in the no-lyrics composition (C2 `.foot`, widened for the
        /// QUEUE / REPEAT toggles).
        static let transportWidth: CGFloat = 640
        /// Artwork share of the window height in the no-lyrics composition.
        static let centeredArtworkShare: CGFloat = 0.56
        /// Smallest artwork worth showing beside lyrics; narrower windows drop it.
        static let minimumSideArtwork: CGFloat = 200

        // MARK: Video

        /// Narrowest 16:9 video worth showing beside the lyrics; below it the video stacks
        /// over the lyrics in the text column instead.
        static let minimumSideVideoWidth: CGFloat = 280
        /// Height cap of the stacked video, as a share of the window, so the lyrics keep room.
        static let stackedVideoHeightShare: CGFloat = 0.3
        /// A track that loses its video keeps the slot this long before the artwork returns,
        /// so a flickering availability report doesn't bounce the WebView out and back.
        static let videoFallbackDelay: Duration = .milliseconds(1500)
        /// Remembers SONG · VIDEO across tracks and openings (YouTube Music's switch sticks too).
        static let prefersVideoKey = "tune.nowPlaying.prefersVideo"

        // MARK: Queue

        /// Up Next pane width as a share of the window, clamped to `queueWidthRange`.
        static let queueWidthShare: CGFloat = 0.27
        static let queueWidthRange: ClosedRange<CGFloat> = 360 ... 400
        /// With the pane open, windows narrower than this drop the side artwork so the lyrics
        /// keep their column.
        static let queueArtworkMinimumWindowWidth: CGFloat = 1200
        /// Horizontal inset of the pane's header and rows.
        static let queueInset: CGFloat = TuneTheme.Spacing.unit * 6
        /// Gap between the floating pane's rounded panel and the window's top, bottom and
        /// trailing edges.
        static let queuePanelMargin: CGFloat = TuneTheme.Spacing.unit * 2
        /// Inset of a row's rounded hover fill (and the playing row's rule) inside the pane.
        static let queueRowFillInset: CGFloat = TuneTheme.Spacing.unit * 3
        /// Row height on the 4 pt grid: a 32 pt thumb plus 8 pt above and below.
        static let queueRowHeight: CGFloat = 48
        static let queueThumbEdge: CGFloat = 32
        /// 16:9 video thumb at the row's thumb height (57 × 32).
        static let videoThumbWidth: CGFloat = 57
        /// The pane's scrim: the field's own dark, laid over the field.
        static let queueScrimOpacity: Double = 0.55
        /// Pane edge and header rule.
        static let queueRuleOpacity: Double = 0.08
        static let queueHoverOpacity: Double = 0.05
        /// Already-played rows above the playing one: still readable, clearly behind.
        static let queuePlayedOpacity: Double = 0.45
        /// Soft fade where the list runs under the bottom edge.
        static let queueEdgeFade: CGFloat = 48
        /// Remembers whether the pane is open across openings.
        static let showsQueueKey = "tune.nowPlaying.showsQueue"

        // MARK: Search

        /// Underline search field at the top right.
        static let searchFieldWidth: CGFloat = 240
        static let searchFieldHeight: CGFloat = 28
        /// Top inset shared by the search field and the close hint.
        static let topBarTop: CGFloat = TuneTheme.Spacing.unit * 3
        /// Results panel width (hangs from the field's right edge).
        static let searchDropdownWidth: CGFloat = 400
        /// The results panel's scrim: the field's dark, near-opaque.
        static let searchScrimOpacity: Double = 0.94
        /// Fill of the keyboard-selected result.
        static let searchSelectionOpacity: Double = 0.08

        // MARK: Transport

        /// Glyph button hit target (glyph itself is `Typeface.body`).
        static let controlHitSize: CGFloat = 28
        /// Scrubber rail thickness.
        static let scrubberHeight: CGFloat = 2
        /// Scrubber playhead tick (the only accent on screen): slim, rising from the rail.
        static let playheadSize = CGSize(width: 2, height: 10)
        /// Scrubber hit height (taller than the drawn rail).
        static let scrubberHitHeight: CGFloat = 24
        /// Transport auto-hides after this long without pointer movement.
        static let controlsAutoHideDelay: Duration = .milliseconds(2500)
        /// Show/hide fade for the transport.
        static let controlsAnimation = Animation.easeOut(duration: 0.3)

        // MARK: Artwork

        /// Pixel edge requested from the YT image CDN for the sharp artwork.
        static let artworkRequestEdge = 1200
        /// Decode size for the blurred backdrop (blurred anyway; small keeps it cheap).
        static let backdropDecodeSize = CGSize(width: 96, height: 96)
        /// HSB brightness of the artwork-tinted field dark (C2 shade ≈ #0B1419 → 0.1).
        static let fieldBrightness: CGFloat = 0.1
        /// Multiplier on the blurred artwork before the field shade (C2 `.blur` brightness .3).
        static let backdropBrightness: Double = 0.34
        /// Backdrop blur radius.
        static let backdropBlur: CGFloat = 90
        /// Crossfade between tracks.
        static let trackChangeAnimation = Animation.easeInOut(duration: 0.5)
    }
}
