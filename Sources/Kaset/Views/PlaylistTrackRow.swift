import SwiftUI

// MARK: - PlaylistTrackColumns

/// Column geometry shared by the playlist table header and every row, so the
/// columns line up (C2 `.th` / `.tr`): `#`, thumbnail, title, artist, album,
/// like, time. Computed once per table width rather than per row.
struct PlaylistTrackColumns: Equatable {
    static let numberWidth: CGFloat = 24
    static let thumbnailSide: CGFloat = 32
    static let likeWidth: CGFloat = 22
    static let durationWidth: CGFloat = 44
    static let gap: CGFloat = 14
    static let rowHeight: CGFloat = 40
    static let headerHeight: CGFloat = 28
    /// How far a row's hover fill extends past the table on each side.
    static let hoverBleed: CGFloat = 8
    /// Below this table width the album column folds away.
    static let albumColumnBreakpoint: CGFloat = 620

    let showsThumbnail: Bool
    let showsAlbum: Bool
    let title: CGFloat
    let artist: CGFloat
    let album: CGFloat

    init(width: CGFloat, showsThumbnail: Bool, wantsAlbumColumn: Bool) {
        self.showsThumbnail = showsThumbnail
        self.showsAlbum = wantsAlbumColumn && width >= Self.albumColumnBreakpoint
        var fixed = Self.numberWidth + Self.likeWidth + Self.durationWidth
        var columnCount = 5 // number, title, artist, like, duration
        if showsThumbnail {
            fixed += Self.thumbnailSide
            columnCount += 1
        }
        if self.showsAlbum {
            columnCount += 1
        }
        let flexible = max(0, width - fixed - CGFloat(columnCount - 1) * Self.gap)
        // Title leads (it's what truncates first and matters most); artist and album
        // share the rest evenly.
        let shares: (title: CGFloat, artist: CGFloat, album: CGFloat) = self.showsAlbum ? (1.8, 0.8, 0.9) : (1.8, 1, 0)
        let total = shares.title + shares.artist + shares.album
        self.title = (flexible * shares.title / total).rounded(.down)
        self.artist = (flexible * shares.artist / total).rounded(.down)
        self.album = (flexible * shares.album / total).rounded(.down)
    }
}

// MARK: - PlaylistTrackHeader

/// Uppercase column labels over a rule.
struct PlaylistTrackHeader: View {
    let columns: PlaylistTrackColumns

    var body: some View {
        HStack(spacing: PlaylistTrackColumns.gap) {
            // Mono like the numbers below it, so the glyph sits on their left edge.
            Text(verbatim: "#")
                .font(TuneTheme.Typeface.data)
                .frame(width: PlaylistTrackColumns.numberWidth, alignment: .leading)
            if self.columns.showsThumbnail {
                Color.clear.frame(width: PlaylistTrackColumns.thumbnailSide, height: 1)
            }
            Text(String(localized: "Title"))
                .frame(width: self.columns.title, alignment: .leading)
            Text(String(localized: "Artist"))
                .frame(width: self.columns.artist, alignment: .leading)
            if self.columns.showsAlbum {
                Text(String(localized: "Album"))
                    .frame(width: self.columns.album, alignment: .leading)
            }
            Color.clear.frame(width: PlaylistTrackColumns.likeWidth, height: 1)
            Image(systemName: "clock")
                .frame(width: PlaylistTrackColumns.durationWidth, alignment: .trailing)
                .accessibilityHidden(true)
        }
        .tuneCapsLabel()
        .lineLimit(1)
        .frame(height: PlaylistTrackColumns.headerHeight)
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(TuneTheme.Palette.rule)
                .frame(height: 1)
        }
        .accessibilityHidden(true)
    }
}

// MARK: - PlaylistTrackRow

/// A single track row in a playlist or album detail view, on the C2 table grid:
/// zero-padded number (an orange marker when it is the current track), 32 pt
/// rounded thumbnail (playlists only), title, artist links, album, like, and
/// a monospaced duration. Artist names are clickable navigation links when they
/// have navigable IDs; non-navigable artists fall back to plain text.
@available(macOS 26.0, *)
struct PlaylistTrackRow<Menu: View>: View {
    let track: Song
    let index: Int
    let isAlbum: Bool
    let subtitle: String?
    let artists: [Artist]?
    let allowsLikeActions: Bool
    let columns: PlaylistTrackColumns
    let onPlay: () -> Void
    @ViewBuilder let menu: () -> Menu

    @State private var isHovered: Bool = false
    @Environment(PlayerService.self) private var playerService

    var body: some View {
        self.rowContent
            .background { self.playbackButton }
            .onHover { hovering in self.isHovered = hovering }
            .contextMenu { self.menu() }
    }

    private var rowContent: some View {
        let isCurrent = self.playerService.currentTrack?.videoId == self.track.videoId

        return HStack(spacing: PlaylistTrackColumns.gap) {
            self.numberCell(isCurrent: isCurrent)
                .frame(width: PlaylistTrackColumns.numberWidth, alignment: .leading)
                .allowsHitTesting(false)

            if self.columns.showsThumbnail {
                SongThumbnailView(song: self.track, size: PlaylistTrackColumns.thumbnailSide)
                    .overlay {
                        RoundedRectangle.tuneRounded(TuneTheme.Radius.artwork(side: PlaylistTrackColumns.thumbnailSide))
                            .strokeBorder(TuneTheme.Palette.artworkEdge, lineWidth: 1)
                    }
                    .allowsHitTesting(false)
            }

            HStack(spacing: 6) {
                // Noise removal only: this row's artist column has its own fallbacks, so the
                // title keeps any "Artist - " prefix rather than losing it.
                Text(self.track.artistsDisplay.isEmpty ? TrackDisplayText.cleanTitle(self.track.title) : self.track.displayText.title)
                    .font(TuneTheme.Typeface.body)
                    .foregroundStyle(isCurrent ? TuneTheme.Palette.accent : TuneTheme.Palette.ink)
                    .lineLimit(1)
                    .accessibilityHidden(true)
                if self.track.isExplicit == true {
                    ExplicitBadge()
                }
            }
            .frame(width: self.columns.title, alignment: .leading)
            .allowsHitTesting(false)

            self.artistCell
                .frame(width: self.columns.artist, alignment: .leading)

            if self.columns.showsAlbum {
                Text(self.albumTitle)
                    .font(TuneTheme.Typeface.body)
                    .foregroundStyle(TuneTheme.Palette.inkMuted)
                    .lineLimit(1)
                    .frame(width: self.columns.album, alignment: .leading)
                    .allowsHitTesting(false)
            }

            // Not nested: the row's play button sits in `.background`, not around this.
            LikeButton(
                song: self.track,
                isRowHovered: self.isHovered,
                allowsActions: self.allowsLikeActions,
                isNestedInButton: false
            )
            .frame(width: PlaylistTrackColumns.likeWidth)
            .disabled(!self.track.isPlayable)
            .allowsHitTesting(self.allowsLikeActions && self.track.isPlayable)

            Text(self.track.durationDisplay)
                .font(TuneTheme.Typeface.data)
                .foregroundStyle(TuneTheme.Palette.inkSecondary)
                .frame(width: PlaylistTrackColumns.durationWidth, alignment: .trailing)
                .allowsHitTesting(false)
        }
        .frame(height: PlaylistTrackColumns.rowHeight)
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(TuneTheme.Palette.hairline)
                .frame(height: 1)
                .allowsHitTesting(false)
        }
        .opacity(self.track.isPlayable ? 1 : 0.5)
    }

    @ViewBuilder
    private func numberCell(isCurrent: Bool) -> some View {
        if isCurrent {
            Image(systemName: self.playerService.isPlaying ? "waveform" : "pause.fill")
                .font(TuneTheme.Typeface.label)
                .foregroundStyle(TuneTheme.Palette.accent)
                .symbolEffect(.variableColor.iterative, isActive: self.playerService.isPlaying)
                .accessibilityHidden(true)
        } else {
            Text(verbatim: self.index < 9 ? "0\(self.index + 1)" : "\(self.index + 1)")
                .font(TuneTheme.Typeface.data)
                .foregroundStyle(TuneTheme.Palette.inkDim)
        }
    }

    private var albumTitle: String {
        guard let title = self.track.album?.title.trimmingCharacters(in: .whitespacesAndNewlines),
              !title.isEmpty
        else { return "—" }
        return title
    }

    @ViewBuilder
    private var artistCell: some View {
        if let subtitle = self.subtitle {
            if self.hasNavigableArtists {
                self.artistLinksView
            } else {
                Text(subtitle)
                    .font(TuneTheme.Typeface.body)
                    .foregroundStyle(TuneTheme.Palette.inkMuted)
                    .lineLimit(1)
                    .allowsHitTesting(false)
            }
        } else {
            Text(verbatim: "—")
                .font(TuneTheme.Typeface.body)
                .foregroundStyle(TuneTheme.Palette.inkDim)
                .allowsHitTesting(false)
        }
    }

    private var playbackButton: some View {
        Button(action: self.onPlay) {
            RoundedRectangle.tuneRounded(TuneTheme.Radius.control)
                // The row's own `.onHover` drives the highlight: a second hover tracker per row
                // is enough to push long playlists past the frame budget while scrolling.
                // Unplayable rows never highlight, since their button is disabled.
                .fill(self.isHovered && self.track.isPlayable ? TuneTheme.Palette.raised : Color.clear)
                // Bleed past the columns so the number and duration don't touch the fill's edge.
                .padding(.horizontal, -PlaylistTrackColumns.hoverBleed)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!self.track.isPlayable)
        .accessibilityLabel(Text(verbatim: self.playbackAccessibilityLabel))
        .accessibilityHint(Text(String(localized: "Play")))
    }

    private var playbackAccessibilityLabel: String {
        guard let subtitle = self.subtitle?.trimmingCharacters(in: .whitespacesAndNewlines),
              !subtitle.isEmpty
        else { return self.track.title }

        return "\(self.track.title), \(subtitle)"
    }

    private var hasNavigableArtists: Bool {
        self.artists?.contains(where: \.hasNavigableId) ?? false
    }

    @ViewBuilder
    private var artistLinksView: some View {
        let artists = self.artists ?? []

        HStack(spacing: 0) {
            ForEach(Array(artists.enumerated()), id: \.offset) { index, artist in
                if artist.hasNavigableId {
                    HoverUnderlineNavigationLink(
                        value: artist,
                        title: artist.name,
                        font: TuneTheme.Typeface.body,
                        foregroundStyle: TuneTheme.Palette.inkMuted
                    )
                } else {
                    Text(artist.name)
                        .font(TuneTheme.Typeface.body)
                        .foregroundStyle(TuneTheme.Palette.inkMuted)
                        .lineLimit(1)
                        .allowsHitTesting(false)
                }

                if index < artists.count - 1 {
                    Text(verbatim: ", ")
                        .font(TuneTheme.Typeface.body)
                        .foregroundStyle(TuneTheme.Palette.inkMuted)
                        .lineLimit(1)
                        .allowsHitTesting(false)
                }
            }

            Spacer(minLength: 0)
        }
    }
}
