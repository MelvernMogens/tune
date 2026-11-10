import SwiftUI

// MARK: - HomeHeroSection

/// C2 "Listen again": a big lead tile (16:9 for videos, art with type set beside
/// it for square covers) beside a 2×2 grid of squares, paged five items at a time from
/// the header's ‹ › controls or a horizontal trackpad swipe / Shift-scroll, sliding
/// between pages.
struct HomeHeroSection<Menu: View>: View {
    let section: HomeSection
    /// Width available to the section's content (inside the page gutters).
    let width: CGFloat
    /// Cap on the hero's height (lead = grid), from the visible page height.
    var maxHeight: CGFloat = .infinity
    let action: (HomeSectionItem, Int) -> Void
    @ViewBuilder let contextMenu: (HomeSectionItem, Int) -> Menu

    @State private var pager = HomeShelfPager()
    @State private var page = 0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var pageCount: Int {
        max(1, Int((Double(self.section.items.count) / Double(HomeHeroLayout.pageSize)).rounded(.up)))
    }

    private var clampedPage: Int {
        min(max(self.page, 0), self.pageCount - 1)
    }

    var body: some View {
        let layout = HomeHeroLayout(width: self.width, maxHeight: self.maxHeight)
        let pageCount = self.pageCount

        VStack(alignment: .leading, spacing: 24) {
            HomeSectionHeader(self.section.title, isHero: true, pager: self.pager)

            HomePagedStrip(pageCount: pageCount, page: self.clampedPage, width: self.width) { page in
                let start = page * HomeHeroLayout.pageSize
                let end = min(start + HomeHeroLayout.pageSize, self.section.items.count)
                self.tiles(indices: Array(start ..< max(start, end)), layout: layout)
            }
            .homeSwipePaging(isEnabled: pageCount > 1) { direction in
                self.pager.page(direction)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(self.section.title)
        .onAppear {
            self.publishPager()
        }
        .onChange(of: self.page) { _, _ in self.publishPager() }
        .onChange(of: self.section.id) { _, _ in
            self.page = 0
            self.publishPager()
        }
        .onChange(of: self.section.items.count) { _, _ in self.publishPager() }
        .onChange(of: self.reduceMotion) { _, _ in self.publishPager() }
    }

    /// Re-arms the header's page handler (it captures this view's current
    /// section and width) and publishes the visible range.
    private func publishPager() {
        let pageCount = self.pageCount
        let reduceMotion = self.reduceMotion
        self.pager.pageHandler = { [page = self.$page] direction in
            let current = min(max(page.wrappedValue, 0), pageCount - 1)
            let next = min(max(current + (direction == .trailing ? 1 : -1), 0), pageCount - 1)
            guard next != current else { return }
            withAnimation(reduceMotion ? nil : .homePageSlide) {
                page.wrappedValue = next
            }
        }
        let total = self.section.items.count
        let start = self.clampedPage * HomeHeroLayout.pageSize
        self.pager.update(
            first: total == 0 ? 0 : start + 1,
            last: min(start + HomeHeroLayout.pageSize, total),
            total: total,
            canPageLeading: self.clampedPage > 0,
            canPageTrailing: self.clampedPage < self.pageCount - 1
        )
    }

    @ViewBuilder
    private func tiles(indices: [Int], layout: HomeHeroLayout) -> some View {
        let items = self.section.items
        if let leadIndex = indices.first {
            let rest = Array(indices.dropFirst())
            if layout.isStacked {
                VStack(alignment: .leading, spacing: HomeHeroLayout.rowGap) {
                    self.lead(index: leadIndex, item: items[leadIndex], layout: layout)
                    HStack(alignment: .top, spacing: HomeHeroLayout.gap) {
                        ForEach(rest, id: \.self) { index in
                            self.tile(index: index, item: items[index], side: layout.tileSide)
                        }
                    }
                }
            } else {
                HStack(alignment: .top, spacing: HomeHeroLayout.gap) {
                    self.lead(index: leadIndex, item: items[leadIndex], layout: layout)
                    Grid(horizontalSpacing: HomeHeroLayout.gap, verticalSpacing: HomeHeroLayout.rowGap) {
                        ForEach(Array(stride(from: 0, to: rest.count, by: 2)), id: \.self) { row in
                            GridRow(alignment: .top) {
                                ForEach(rest[row ..< min(row + 2, rest.count)], id: \.self) { index in
                                    self.tile(index: index, item: items[index], side: layout.tileSide)
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    private func lead(index: Int, item: HomeSectionItem, layout: HomeHeroLayout) -> some View {
        HomeHeroLeadTile(item: item, layout: layout) {
            self.action(item, index)
        }
        .contextMenu { self.contextMenu(item, index) }
    }

    private func tile(index: Int, item: HomeSectionItem, side: CGFloat) -> some View {
        HomeHeroGridTile(item: item, side: side) {
            self.action(item, index)
        }
        .contextMenu { self.contextMenu(item, index) }
    }
}

// MARK: - HomeHeroLeadTile

/// The hero's lead. Video frames fill a 16:9 tile with the caption below;
/// square covers sit at full height with their type set beside them on the
/// page, so a cover is never cropped into a letterbox.
private struct HomeHeroLeadTile: View {
    let item: HomeSectionItem
    let layout: HomeHeroLayout
    let action: () -> Void

    @State private var isHovered = false

    private static let minimumPanelWidth: CGFloat = 180

    private var usesSplitLayout: Bool {
        !self.item.isVideoSong
            && self.layout.leadWidth - self.layout.leadHeight - Self.fieldPadding >= Self.minimumPanelWidth
    }

    var body: some View {
        let caption = HomeCardCaption.make(for: self.item)
        Button(action: self.action) {
            Group {
                if self.usesSplitLayout {
                    self.splitContent(caption: caption)
                } else {
                    self.wideContent(caption: caption)
                }
            }
            .frame(width: self.layout.leadWidth, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { self.isHovered = $0 }
        .accessibilityLabel(Self.accessibilityLabel(self.item, caption: caption))
    }

    private func wideContent(caption: HomeCardCaption) -> some View {
        let size = CGSize(width: self.layout.leadWidth, height: self.layout.leadArtworkHeight)
        return VStack(alignment: .leading, spacing: 0) {
            HomeHoverArtwork(item: self.item, size: size, isHovered: self.isHovered)
            Text(self.item.displayTitle)
                .font(TuneTheme.Typeface.section)
                .tracking(-0.2)
                .foregroundStyle(TuneTheme.Palette.ink)
                .lineLimit(1)
                .padding(.top, 8)
            HomeCaptionLine(caption: caption)
                .padding(.top, 2)
        }
        .frame(height: self.layout.leadHeight, alignment: .top)
    }

    private func splitContent(caption: HomeCardCaption) -> some View {
        let height = self.layout.leadHeight
        let inset = Self.fieldPadding
        let coverSide = max(0, height - 2 * inset)
        let typeWidth = self.layout.leadWidth - coverSide - 3 * inset
        // One art-forward block the size of a 16:9 lead: the cover blurred edge to edge, the
        // sharp cover floating on it, and the type set beside it — a mono kind tag on the
        // cover's top edge, the title and caption on its bottom edge — so the column reads
        // as one composed block, not type floating under an empty corner. The cover owns the
        // single hover play control.
        return HStack(alignment: .top, spacing: inset) {
            HomeHoverArtwork(item: self.item, size: CGSize(width: coverSide, height: coverSide), isHovered: self.isHovered, showsEdge: false)
                .shadow(color: .black.opacity(0.35), radius: 18, y: 8)
            VStack(alignment: .leading, spacing: 0) {
                Text(Self.kindLabel(self.item, caption: caption))
                    .font(TuneTheme.Typeface.data)
                    .tracking(0.6)
                    .textCase(.uppercase)
                    .foregroundStyle(TuneTheme.Palette.ink.opacity(0.72))
                    .lineLimit(1)

                // A short mono spec sheet (album, length, year, tracks, owner) under the tag,
                // so the column's top carries real data instead of an empty field.
                let specs = Self.specRows(self.item)
                if !specs.isEmpty {
                    Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 14, verticalSpacing: 6) {
                        ForEach(specs, id: \.key) { spec in
                            GridRow {
                                Text(spec.key)
                                    .font(TuneTheme.Typeface.data)
                                    .textCase(.uppercase)
                                    .foregroundStyle(TuneTheme.Palette.ink.opacity(0.5))
                                Text(spec.value)
                                    .font(TuneTheme.Typeface.body)
                                    .foregroundStyle(TuneTheme.Palette.ink.opacity(0.85))
                                    .lineLimit(1)
                            }
                        }
                    }
                    .padding(.top, 18)
                }

                Spacer(minLength: 16)

                // Headline size only where a long word still fits on a line; never split words.
                Text(self.item.displayTitle)
                    .font(typeWidth >= Self.headlineTypeWidth ? TuneTheme.Typeface.headline : TuneTheme.Typeface.display)
                    .tracking(typeWidth >= Self.headlineTypeWidth ? -1 : -0.4)
                    .foregroundStyle(TuneTheme.Palette.ink)
                    .minimumScaleFactor(0.75)
                    .lineLimit(4)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
                if !caption.text.isEmpty {
                    Text(caption.text)
                        .font(TuneTheme.Typeface.body)
                        .foregroundStyle(TuneTheme.Palette.ink.opacity(0.8))
                        .lineLimit(2)
                        .padding(.top, 8)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .padding(inset)
        .frame(width: self.layout.leadWidth, height: height, alignment: .bottomLeading)
        .background { self.blurredField }
        .clipShape(.tuneRounded(TuneTheme.Radius.hero))
        .overlay {
            RoundedRectangle.tuneRounded(TuneTheme.Radius.hero)
                .strokeBorder(self.isHovered ? TuneTheme.Palette.ink.opacity(0.7) : TuneTheme.Palette.artworkEdge, lineWidth: 1)
                .allowsHitTesting(false)
        }
    }

    /// Margin around the floating cover and the type.
    private static let fieldPadding: CGFloat = 28
    /// Type column width from which the title is set at headline size.
    private static let headlineTypeWidth: CGFloat = 360

    /// The cover filling the block, blurred past recognition and darkened toward the bottom so
    /// ink type reads on pale covers too.
    private var blurredField: some View {
        HomeBlurredArtworkFill(url: self.item.tuneArtworkURLs(side: 64).first, blurRadius: 44)
            .overlay {
                LinearGradient(
                    stops: [
                        .init(color: TuneTheme.Palette.background.opacity(0.15), location: 0),
                        .init(color: TuneTheme.Palette.background.opacity(0.65), location: 1),
                    ],
                    startPoint: .top,
                    endPoint: .bottom
                )
            }
            .accessibilityHidden(true)
    }

    struct SpecRow: Equatable {
        let key: String
        let value: String
    }

    /// The split lead's spec sheet, from data the item already carries. Skips anything
    /// that would repeat the title, the caption, or the kind tag.
    static func specRows(_ item: HomeSectionItem) -> [SpecRow] {
        var rows: [SpecRow] = []
        switch item {
        case let .song(song):
            if let album = song.album?.title.trimmingCharacters(in: .whitespacesAndNewlines), !album.isEmpty,
               album.caseInsensitiveCompare(song.displayText.title) != .orderedSame
            {
                rows.append(SpecRow(key: String(localized: "Album"), value: album))
            }
            if let duration = song.duration, duration.isFinite, duration > 0 {
                rows.append(SpecRow(key: String(localized: "Length"), value: song.durationDisplay))
            }
        case let .album(album):
            if let year = album.year, !year.isEmpty {
                rows.append(SpecRow(key: String(localized: "Year"), value: year))
            }
            if let count = album.trackCount, count > 0 {
                rows.append(SpecRow(key: String(localized: "Songs"), value: "\(count)"))
            }
        case let .playlist(playlist):
            if let count = playlist.trackCount, count > 0 {
                rows.append(SpecRow(key: String(localized: "Songs"), value: "\(count)"))
            }
        case .artist:
            break
        }
        return rows
    }

    /// Mono kind tag under the split lead's type: "SONG", "VIDEO", "ALBUM · EP".
    static func kindLabel(_ item: HomeSectionItem, caption: HomeCardCaption) -> String {
        let kind = switch item {
        case .song: item.isVideoSong ? String(localized: "Video") : String(localized: "Song")
        case .album: String(localized: "Album")
        case .playlist: String(localized: "Playlist")
        case .artist: String(localized: "Artist")
        }
        guard let meta = caption.meta, meta.caseInsensitiveCompare(kind) != .orderedSame else { return kind }
        return "\(kind) · \(meta)"
    }

    static func accessibilityLabel(_ item: HomeSectionItem, caption: HomeCardCaption) -> String {
        let label = caption.text.isEmpty ? item.title : "\(item.title), \(caption.text)"
        return item.isVideoSong ? "\(label), \(String(localized: "Video"))" : label
    }
}

// MARK: - HomeHeroGridTile

/// Square tile with a one-line title and a caption line.
private struct HomeHeroGridTile: View {
    let item: HomeSectionItem
    let side: CGFloat
    let action: () -> Void

    @State private var isHovered = false

    var body: some View {
        let caption = HomeCardCaption.make(for: self.item)
        Button(action: self.action) {
            VStack(alignment: .leading, spacing: 0) {
                HomeHoverArtwork(item: self.item, size: CGSize(width: self.side, height: self.side), isHovered: self.isHovered)
                Text(self.item.displayTitle)
                    .font(TuneTheme.Typeface.body.weight(.medium))
                    .foregroundStyle(TuneTheme.Palette.ink)
                    .lineLimit(1)
                    .padding(.top, 10)
                HomeCaptionLine(caption: caption)
                    .padding(.top, 3)
            }
            .frame(width: self.side, height: self.side + HomeHeroLayout.captionHeight, alignment: .topLeading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { self.isHovered = $0 }
        .accessibilityLabel(HomeHeroLeadTile.accessibilityLabel(self.item, caption: caption))
    }
}

// MARK: - Shared pieces

/// Artwork with the C2 hover treatment: the inset edge brightens and songs show
/// the small rounded play square in the bottom-leading corner, plus the like
/// control in the top-trailing corner (as on the shelf cards). Videos carry the
/// mono VIDEO tag top-leading; a video in a square slot keeps its whole 16:9
/// frame over a blurred fill of itself instead of being cropped into a square.
struct HomeHoverArtwork: View {
    let item: HomeSectionItem
    let size: CGSize
    let isHovered: Bool
    var showsLike = true
    /// Off when the artwork sits inside a larger block that draws its own edge.
    var showsEdge = true
    /// Off for row thumbnails too small to carry the tag.
    var showsVideoTag = true

    @Environment(AuthService.self) private var authService

    private var radius: CGFloat {
        TuneTheme.Radius.artwork(for: self.size)
    }

    /// A video whose slot is much narrower than its 16:9 frame.
    private var isLetterboxedVideo: Bool {
        self.item.isVideoSong && self.size.height > 0 && self.size.width / self.size.height < 1.5
    }

    var body: some View {
        let shape = RoundedRectangle.tuneRounded(self.radius)
        self.artwork
            .overlay {
                if self.isHovered, self.showsEdge {
                    shape
                        .strokeBorder(TuneTheme.Palette.ink.opacity(0.7), lineWidth: 1)
                        .allowsHitTesting(false)
                }
            }
            .overlay(alignment: .topLeading) {
                if self.showsVideoTag, self.item.isVideoSong {
                    TuneVideoTag()
                        .padding(HomeItemCell.playOverlayInset)
                }
            }
            .overlay(alignment: .bottomLeading) {
                if self.isHovered, case .song = self.item {
                    SongCoverPlayOverlay(size: CGSize(width: HomeItemCell.playOverlaySize, height: HomeItemCell.playOverlaySize))
                        .padding(HomeItemCell.playOverlayInset)
                }
            }
            .overlay(alignment: .topTrailing) {
                if self.showsLike, case let .song(song) = self.item {
                    LikeButton(song: song, isRowHovered: self.isHovered, allowsActions: self.authService.hasPersonalAccount)
                        .background(
                            self.isHovered ? TuneTheme.Palette.background.opacity(0.82) : Color.clear,
                            in: .tuneRounded(TuneTheme.Radius.small)
                        )
                        .padding(HomeItemCell.likeButtonInset)
                }
            }
    }

    @ViewBuilder
    private var artwork: some View {
        let urls = self.item.tuneArtworkURLs(side: max(self.size.width, self.size.height))
        if self.isLetterboxedVideo {
            let frameHeight = (self.size.width * 9 / 16).rounded()
            let shape = RoundedRectangle.tuneRounded(self.radius)
            ZStack {
                HomeBlurredArtworkFill(url: urls.first)
                TuneArtworkView(
                    urls: urls,
                    size: CGSize(width: self.size.width, height: frameHeight),
                    placeholderSymbol: self.item.tunePlaceholderSymbol,
                    showsEdge: false,
                    cornerRadius: 0
                )
                .shadow(color: .black.opacity(0.35), radius: 10, y: 4)
            }
            .frame(width: self.size.width, height: self.size.height)
            .clipShape(shape)
            .overlay {
                if self.showsEdge {
                    shape
                        .strokeBorder(TuneTheme.Palette.artworkEdge, lineWidth: 1)
                        .allowsHitTesting(false)
                }
            }
            .accessibilityHidden(true)
        } else {
            TuneArtworkView(
                urls: urls,
                size: self.size,
                placeholderSymbol: self.item.tunePlaceholderSymbol,
                showsEdge: self.showsEdge
            )
        }
    }
}

/// An image blurred past recognition and darkened, filling its frame: the
/// backdrop behind a letterboxed video frame and the hero's split lead.
struct HomeBlurredArtworkFill: View {
    let url: URL?
    var blurRadius: CGFloat = 28

    var body: some View {
        // Overlay on a greedy base so the aspect-filled image can't grow the block.
        Color.clear
            .overlay {
                if let url {
                    CachedAsyncImage(url: url, targetSize: CGSize(width: 64, height: 64)) { image in
                        image
                            .resizable()
                            .scaledToFill()
                    } placeholder: {
                        TuneTheme.Palette.raised
                    }
                } else {
                    TuneTheme.Palette.raised
                }
            }
            .clipped()
            .saturation(1.5)
            .colorMultiply(Color(white: 0.7))
            .blur(radius: self.blurRadius, opaque: true)
            .clipped()
            .accessibilityHidden(true)
    }
}

/// C2 `.cm`: muted caption text and a dim monospaced tag on the trailing edge.
struct HomeCaptionLine: View {
    let caption: HomeCardCaption

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(self.caption.text)
                .font(TuneTheme.Typeface.body)
                .foregroundStyle(TuneTheme.Palette.inkMuted)
                .lineLimit(1)
            Spacer(minLength: 0)
            if let meta = self.caption.meta {
                Text(meta)
                    .font(TuneTheme.Typeface.data)
                    .foregroundStyle(TuneTheme.Palette.inkDim)
                    .lineLimit(1)
                    .fixedSize()
            }
        }
    }
}
