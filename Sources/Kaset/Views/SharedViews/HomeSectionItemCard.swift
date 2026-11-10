import SwiftUI

// MARK: - HomeSectionItemCard

/// Reusable card view for home section items (songs, playlists, albums, artists).
struct HomeSectionItemCard: View, Equatable {
    let item: HomeSectionItem
    let rank: Int?
    let playAction: (() -> Void)?
    let action: () -> Void
    private let hasPlayAction: Bool
    @Environment(AuthService.self) private var authService

    /// Card dimensions.
    private static let squareThumbnailSize = CGSize(width: 160, height: 160)
    private static let videoThumbnailSize = CGSize(width: 284, height: 160)
    private static let playButtonSize = CGSize(width: HomeItemCell.playOverlaySize, height: HomeItemCell.playOverlaySize)

    /// Hover state for play overlay.
    @State private var isHovering = false
    @State private var failedThumbnailURLs: Set<URL> = []

    init(
        item: HomeSectionItem,
        rank: Int? = nil,
        playAction: (() -> Void)? = nil,
        action: @escaping () -> Void
    ) {
        self.item = item
        self.rank = rank
        self.playAction = playAction
        self.action = action
        self.hasPlayAction = playAction != nil
    }

    /// Lets SwiftUI skip re-evaluating unchanged cards when a shelf or its
    /// parent re-renders (measured: this is what made Home scrolling hitch).
    ///
    /// Contract for callers: `action`/`playAction` must depend only on `item`
    /// (and `rank`). If two cards compare equal, the old closures are kept, so
    /// an action that captured section membership or index would go stale.
    nonisolated static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.item.hasSameCardContent(as: rhs.item)
            && lhs.rank == rhs.rank
            && lhs.hasPlayAction == rhs.hasPlayAction
    }

    var body: some View {
        if self.supportsPlaylistPlayAction {
            self.cardContent
                .accessibilityAction(named: Text("Play \(self.item.title)")) {
                    self.playAction?()
                }
        } else {
            self.cardContent
        }
    }

    private var cardContent: some View {
        ZStack(alignment: .topLeading) {
            Button(action: self.action) {
                if let rank {
                    self.chartContent(rank: rank)
                } else {
                    self.regularContent
                }
            }
            // Hover feedback lives on the thumbnail (see `thumbnail`), so the
            // button style only contributes press feedback and registers no
            // hover responder.
            .buttonStyle(.interactiveCard(showShadow: false, hoverScale: 1))
        }
        .onHover { hovering in
            withAnimation(AppAnimation.quick) {
                self.isHovering = hovering
            }
        }
        .onChange(of: self.item.id) { _, _ in
            self.failedThumbnailURLs = []
        }
    }

    // MARK: - Regular Card Content

    private var regularContent: some View {
        VStack(alignment: .leading, spacing: 8) {
            self.thumbnail
            self.titleAndSubtitle
        }
    }

    // MARK: - Chart Card Content

    private func chartContent(rank: Int) -> some View {
        ZStack(alignment: .bottomLeading) {
            VStack(alignment: .leading, spacing: 8) {
                self.thumbnail
                self.titleAndSubtitle
            }

            // C2 rank: zero-padded mono digits on a rounded solid block inset
            // from the artwork's bottom-leading corner.
            Text(verbatim: rank < 10 ? "0\(rank)" : "\(rank)")
                .font(TuneTheme.Typeface.display.monospacedDigit())
                .foregroundStyle(TuneTheme.Palette.ink)
                .padding(.horizontal, 8)
                .padding(.vertical, 2)
                .background(TuneTheme.Palette.background, in: .tuneRounded(TuneTheme.Radius.control))
                .padding(HomeItemCell.playOverlayInset)
                .padding(.bottom, HomeItemCell.height - HomeItemCell.artworkHeight)
        }
    }

    // MARK: - Shared Components

    private var thumbnail: some View {
        let thumbnailURLs = self.thumbnailURLs
        let thumbnailURL = thumbnailURLs.first { !self.failedThumbnailURLs.contains($0) }

        return ZStack {
            self.thumbnailBackground

            if let thumbnailURL {
                CachedAsyncImage(
                    url: thumbnailURL,
                    targetSize: self.thumbnailSize,
                    onFailure: self.thumbnailFailureHandler(for: thumbnailURL, in: thumbnailURLs)
                ) { image in
                    image
                        .resizable()
                        .aspectRatio(contentMode: self.thumbnailContentMode)
                } placeholder: {
                    self.placeholderView
                }
            } else {
                self.placeholderView
            }
        }
        .frame(width: self.thumbnailSize.width, height: self.thumbnailSize.height)
        .clipShape(.tuneRounded(HomeItemCell.cornerRadius))
        // Hover brightens the rounded inset edge instead of lifting.
        .modifier(ThumbnailHoverLift(isHovering: self.isHovering))
        .overlay(alignment: .topLeading) {
            if self.isVideoSong {
                TuneVideoTag()
                    .padding(HomeItemCell.playOverlayInset)
            }
        }
        .overlay(alignment: .bottomLeading) {
            // Play overlay on hover (for songs)
            if case .song = self.item, self.isHovering {
                SongCoverPlayOverlay(size: Self.playButtonSize)
                    .padding(HomeItemCell.playOverlayInset)
                    .transition(.opacity)
            }
        }
        .overlay(alignment: .topTrailing) {
            // Favorite heart in the corner for songs
            if case let .song(song) = self.item {
                LikeButton(song: song, isRowHovered: self.isHovering, allowsActions: self.authService.hasPersonalAccount)
                    .padding(HomeItemCell.likeButtonInset)
            }
        }
    }

    private var supportsPlaylistPlayAction: Bool {
        guard case .playlist = self.item else { return false }
        return self.hasPlayAction
    }

    @ViewBuilder
    private var thumbnailBackground: some View {
        Rectangle()
            .fill(TuneTheme.Palette.raised)
    }

    private var thumbnailURLs: [URL] {
        if self.isVideoSong {
            return Self.uniqueURLs([
                self.videoThumbnailURL,
                self.item.thumbnailURL?.highQualityThumbnailURL,
                self.videoFallbackThumbnailURL,
            ])
        }

        return Self.uniqueURLs([self.item.thumbnailURL?.highQualityThumbnailURL])
    }

    private func thumbnailFailureHandler(for thumbnailURL: URL, in thumbnailURLs: [URL]) -> (@MainActor () -> Void)? {
        guard self.hasFallback(after: thumbnailURL, in: thumbnailURLs) else {
            return nil
        }

        return {
            self.failedThumbnailURLs.insert(thumbnailURL)
        }
    }

    private var videoThumbnailURL: URL? {
        guard case let .song(song) = self.item else { return nil }
        return song.wideHighQualityThumbnailURL
    }

    private var videoFallbackThumbnailURL: URL? {
        guard case let .song(song) = self.item else { return nil }
        return song.fallbackThumbnailURL
    }

    /// C2 crops every tile, including 16:9 video frames.
    private var thumbnailContentMode: ContentMode {
        .fill
    }

    private func hasFallback(after url: URL, in thumbnailURLs: [URL]) -> Bool {
        guard let index = thumbnailURLs.firstIndex(of: url) else { return false }
        let fallbackURLs = thumbnailURLs.dropFirst(index + 1)
        return fallbackURLs.contains { !self.failedThumbnailURLs.contains($0) }
    }

    private static func uniqueURLs(_ urls: [URL?]) -> [URL] {
        var seen = Set<URL>()
        return urls.compactMap { url in
            guard let url, seen.insert(url).inserted else { return nil }
            return url
        }
    }

    /// Placeholder view for items without thumbnails.
    /// Uses the API-provided color for mood/genre cards, or a gradient based on the title.
    private var placeholderView: some View {
        let gradient = self.gradientForItem
        return Rectangle()
            .fill(gradient)
            .overlay {
                // Show a contextual icon based on item type
                Image(systemName: self.placeholderIcon)
                    .font(TuneTheme.Typeface.display.weight(.light))
                    .foregroundStyle(TuneTheme.Palette.inkDim)
            }
    }

    /// Returns appropriate icon for the placeholder based on item type.
    private var placeholderIcon: String {
        switch self.item {
        case .song: self.isVideoSong ? "play.rectangle" : "music.note"
        case .album: "square.stack"
        case .playlist: "music.note.list"
        case .artist: "person.fill"
        }
    }

    /// Placeholder fill: the API color for mood cards (their only artwork),
    /// the flat raised fill for everything else.
    private var gradientForItem: Color {
        if case let .playlist(playlist) = item,
           let colorHex = playlist.description,
           colorHex.hasPrefix("#"),
           let color = Color(hex: colorHex)
        {
            return color
        }
        return TuneTheme.Palette.raised
    }

    private var titleAndSubtitle: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Text(self.item.displayTitle)
                    .font(TuneTheme.Typeface.body.weight(.medium))
                    .foregroundStyle(TuneTheme.Palette.ink)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)

                if case let .song(song) = self.item, song.isExplicit == true {
                    ExplicitBadge()
                }
            }
            .frame(width: self.cardWidth, alignment: .leading)

            let caption = HomeCardCaption.make(for: self.item)
            if !caption.text.isEmpty || caption.meta != nil {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(caption.text)
                        .font(TuneTheme.Typeface.body)
                        .foregroundStyle(TuneTheme.Palette.inkMuted)
                        .lineLimit(1)
                    Spacer(minLength: 0)
                    if let meta = caption.meta {
                        Text(meta)
                            .font(TuneTheme.Typeface.data)
                            .foregroundStyle(TuneTheme.Palette.inkDim)
                            .lineLimit(1)
                            .fixedSize()
                    }
                }
                .frame(width: self.cardWidth, alignment: .leading)
            }
        }
    }

    private var cardWidth: CGFloat {
        self.thumbnailSize.width
    }

    private var thumbnailSize: CGSize {
        self.isVideoSong ? Self.videoThumbnailSize : Self.squareThumbnailSize
    }

    private var isVideoSong: Bool {
        self.item.isVideoSong
    }
}

// MARK: - ThumbnailHoverLift

/// Hover: the artwork's 1 px rounded inset edge brightens. No scale, no shadow.
private struct ThumbnailHoverLift: ViewModifier {
    let isHovering: Bool

    func body(content: Content) -> some View {
        content
            .overlay {
                RoundedRectangle.tuneRounded(HomeItemCell.cornerRadius)
                    .strokeBorder(
                        self.isHovering ? TuneTheme.Palette.ink.opacity(0.7) : TuneTheme.Palette.artworkEdge,
                        lineWidth: 1
                    )
                    .allowsHitTesting(false)
            }
            .animation(AppAnimation.quick, value: self.isHovering)
    }
}

// MARK: - FlatPlayIcon

/// Play affordance: a small rounded ink square (never a circle) with a dark glyph.
private struct FlatPlayIcon: View {
    let size: CGSize

    var body: some View {
        Image(systemName: "play.fill")
            .font(TuneTheme.Typeface.label)
            .foregroundStyle(TuneTheme.Palette.background)
            .frame(width: self.size.width, height: self.size.height)
            .background(TuneTheme.Palette.ink, in: .tuneRounded(TuneTheme.Radius.small))
    }
}

// MARK: - SongCoverPlayOverlay

struct SongCoverPlayOverlay: View {
    let size: CGSize

    var body: some View {
        FlatPlayIcon(size: self.size)
            .allowsHitTesting(false)
    }
}

#Preview {
    let song = Song(
        id: "test",
        title: "Test Song with a Very Long Title That Should Wrap",
        artists: [Artist(id: "artist1", name: "Test Artist")],
        videoId: "testVideo"
    )
    HStack {
        HomeSectionItemCard(item: .song(song)) {
            // No-op for preview
        }
        HomeSectionItemCard(item: .song(song), rank: 1) {
            // No-op for preview
        }
    }
    .padding()
    .environment(AuthService())
    .environment(SongLikeStatusManager.shared)
}
