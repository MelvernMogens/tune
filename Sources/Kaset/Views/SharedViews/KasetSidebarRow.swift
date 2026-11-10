import SwiftUI

// MARK: - KasetSidebarRow

/// A C2 sidebar row (docs/fork/design/c2/home.html `.nav`): text-only, 26-point pitch.
///
/// Kaset drives detail content from explicit selection state, so rows are plain buttons
/// rather than source-list `NavigationLink`s, whose chrome switches to the system accent
/// fill when the list becomes active.
///
/// - Selected: ink, semibold, on a raised fill with soft control-radius corners, inset from
///   the sidebar edges.
/// - Hovered: ink text on a fainter raised fill.
/// - Now playing (`isNowPlaying`): a 4-point orange mark in the left gutter — the only
///   accent in the sidebar.
/// - Optional leading 20-point square artwork (playlists) and a trailing monospaced hint
///   (keyboard shortcut or track count).
struct KasetSidebarRow: View {
    let title: String
    /// SF Symbol name for the destination. Kept for API compatibility; C2 rows are text-only.
    let systemImage: String
    let isSelected: Bool
    /// Trailing monospaced hint, such as `⌘1` or a playlist's track count.
    var trailingText: String?
    /// Shows `trailingText` only while hovered, drawn over the title's tail, so long
    /// playlist names get the row's full width at rest (no reflow on hover).
    var showsTrailingTextOnHover = false
    /// Leading square artwork; when set the row reserves a 20-point thumbnail slot.
    var artwork: KasetSidebarRowArtwork?
    /// Whether this destination is the source of the current playback.
    var isNowPlaying = false
    let action: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: self.action) {
            HStack(spacing: 8) {
                if let artwork = self.artwork {
                    KasetSidebarArtworkView(url: artwork.url)
                }

                Text(self.title)
                    .font(self.isSelected ? TuneTheme.Typeface.bodyEmphasis : TuneTheme.Typeface.body)
                    .foregroundStyle(self.isSelected || self.isHovering ? TuneTheme.Palette.ink : TuneTheme.Palette.inkSecondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .frame(maxWidth: .infinity, alignment: .leading)

                if !self.showsTrailingTextOnHover, let trailingText = self.trailingText, !trailingText.isEmpty {
                    Self.trailingLabel(trailingText)
                }
            }
            .overlay(alignment: .trailing) {
                if self.showsTrailingTextOnHover, self.isHovering, let trailingText = self.trailingText, !trailingText.isEmpty {
                    Self.trailingLabel(trailingText)
                        .padding(.leading, 8)
                        .background {
                            // Opaque copy of the row's fill, so the count covers the title's tail.
                            ZStack {
                                TuneTheme.Palette.panel
                                self.fill
                            }
                        }
                        .accessibilityHidden(true)
                }
            }
            .padding(.leading, KasetSidebarMetrics.leadingInset)
            // Playlist rows (artwork, no trailing hint at rest) run their names closer to
            // the fill's edge so long names keep more of the row.
            .padding(.trailing, self.showsTrailingTextOnHover ? KasetSidebarMetrics.fillTrailingInset + 4 : KasetSidebarMetrics.trailingInset)
            .frame(maxWidth: .infinity, minHeight: TuneTheme.Spacing.rowPitch, maxHeight: TuneTheme.Spacing.rowPitch)
            .background {
                RoundedRectangle(cornerRadius: TuneTheme.Radius.control, style: .continuous)
                    .fill(self.fill)
                    .padding(.vertical, 1)
                    .padding(.leading, KasetSidebarMetrics.fillLeadingInset)
                    .padding(.trailing, KasetSidebarMetrics.fillTrailingInset)
                    .accessibilityHidden(true)
            }
            .overlay(alignment: .leading) {
                if self.isNowPlaying {
                    RoundedRectangle(cornerRadius: KasetSidebarMetrics.markerSize / 4, style: .continuous)
                        .fill(TuneTheme.Palette.accent)
                        .frame(width: KasetSidebarMetrics.markerSize, height: KasetSidebarMetrics.markerSize)
                        .padding(.leading, KasetSidebarMetrics.markerInset)
                        .accessibilityHidden(true)
                }
            }
            .contentShape(.rect(cornerRadius: TuneTheme.Radius.control, style: .continuous))
        }
        .buttonStyle(.plain)
        .onHover { self.isHovering = $0 }
        .help(self.artwork == nil ? "" : self.title)
        .listRowInsets(EdgeInsets())
        .listRowSeparator(.hidden)
        .listRowBackground(Color.clear)
        .accessibilityLabel(self.title)
        .accessibilityValue(self.isNowPlaying ? String(localized: "Now Playing") : "")
        .accessibilityAddTraits(self.isSelected ? .isSelected : [])
    }

    private var fill: Color {
        KasetSidebarMetrics.fill(isSelected: self.isSelected, isHovering: self.isHovering)
    }

    private static func trailingLabel(_ text: String) -> some View {
        Text(text)
            .font(TuneTheme.Typeface.data)
            .foregroundStyle(TuneTheme.Palette.inkDim)
            .lineLimit(1)
            .fixedSize()
    }
}

// MARK: - KasetSidebarRowArtwork

/// Artwork slot for a sidebar row. A nil URL still reserves the slot with a flat placeholder,
/// so playlist titles stay aligned while thumbnails load or when a playlist has none.
struct KasetSidebarRowArtwork: Equatable {
    let url: URL?
}

// MARK: - KasetSidebarArtworkView

/// 20-point square cover with small rounded corners and C2's 1-point inset hairline.
struct KasetSidebarArtworkView: View {
    let url: URL?

    var body: some View {
        ZStack {
            TuneTheme.Palette.raised

            if let url = self.url {
                CachedAsyncImage(
                    url: url,
                    targetSize: CGSize(
                        width: KasetSidebarMetrics.artworkSize,
                        height: KasetSidebarMetrics.artworkSize
                    )
                ) { image in
                    image
                        .resizable()
                        .scaledToFill()
                } placeholder: {
                    TuneTheme.Palette.raised
                }
            }
        }
        .frame(width: KasetSidebarMetrics.artworkSize, height: KasetSidebarMetrics.artworkSize)
        .clipShape(.rect(cornerRadius: TuneTheme.Radius.small, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: TuneTheme.Radius.small, style: .continuous)
                .strokeBorder(TuneTheme.Palette.artworkEdge, lineWidth: 1)
        }
        .accessibilityHidden(true)
    }
}

// MARK: - KasetSidebarSectionHeader

/// C2 sidebar group label: 11-point uppercase tracked caps in `inkDim`, 24 points tall.
struct KasetSidebarSectionHeader<Accessory: View>: View {
    let title: String
    @ViewBuilder var accessory: () -> Accessory

    var body: some View {
        HStack(spacing: 8) {
            Text(self.title)
                .font(TuneTheme.Typeface.label)
                .tracking(0.9)
                .textCase(.uppercase)
                .foregroundStyle(TuneTheme.Palette.inkDim)
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityAddTraits(.isHeader)

            self.accessory()
        }
        .padding(.leading, KasetSidebarMetrics.leadingInset)
        .padding(.trailing, KasetSidebarMetrics.trailingInset)
        .frame(height: 24)
        .listRowInsets(EdgeInsets())
        .listRowSeparator(.hidden)
        .listRowBackground(Color.clear)
    }
}

extension KasetSidebarSectionHeader where Accessory == EmptyView {
    init(title: String) {
        self.init(title: title) { EmptyView() }
    }
}

// MARK: - KasetSidebarMetrics

enum KasetSidebarMetrics {
    /// C2 `.side .grp` padding: 20 leading, 16 trailing.
    static let leadingInset: CGFloat = 20
    static let trailingInset: CGFloat = 16
    /// Space between sidebar groups.
    static let groupGap: CGFloat = 16
    /// Playlist cover thumbnail edge.
    static let artworkSize: CGFloat = 20
    /// Now-playing marker square and its distance from the sidebar edge.
    static let markerSize: CGFloat = 4
    static let markerInset: CGFloat = 4
    /// Selected / hovered fill: starts 10 points before the label (clear of the now-playing
    /// mark) and stops 8 points short of the divider.
    static let fillLeadingInset: CGFloat = leadingInset - 10
    static let fillTrailingInset: CGFloat = 8

    static func fill(isSelected: Bool, isHovering: Bool) -> Color {
        switch (isSelected, isHovering) {
        case (true, true): TuneTheme.Palette.raisedStrong
        case (true, false): TuneTheme.Palette.raised
        case (false, true): TuneTheme.Palette.raised.opacity(0.6)
        case (false, false): .clear
        }
    }
}

#Preview {
    List {
        KasetSidebarSectionHeader(title: "Browse")
        KasetSidebarRow(
            title: "Home",
            systemImage: "house",
            isSelected: true,
            trailingText: "⌘1",
            action: {}
        )
        KasetSidebarRow(
            title: "Search",
            systemImage: "magnifyingglass",
            isSelected: false,
            trailingText: "⌘K",
            action: {}
        )
        KasetSidebarRow(
            title: "favs",
            systemImage: "music.note.list",
            isSelected: false,
            trailingText: "505",
            artwork: KasetSidebarRowArtwork(url: nil),
            isNowPlaying: true,
            action: {}
        )
    }
    .listStyle(.plain)
    .scrollContentBackground(.hidden)
    .background(TuneTheme.Palette.panel)
    .frame(width: 220)
    .preferredColorScheme(.dark)
}
