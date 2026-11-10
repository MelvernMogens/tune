import SwiftUI

// MARK: - HomeSongGridSection

/// C2 "Quick picks": songs as compact rows in a column-major grid (four rows
/// per column), each row led by a rounded thumbnail. Paged from the header or a
/// horizontal trackpad swipe / Shift-scroll, sliding between pages.
struct HomeSongGridSection<Menu: View>: View {
    let section: HomeSection
    /// Width available to the section's content (inside the page gutters).
    let width: CGFloat
    let action: (HomeSectionItem, Int) -> Void
    @ViewBuilder let contextMenu: (HomeSectionItem, Int) -> Menu

    @State private var pager = HomeShelfPager()
    @State private var page = 0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var columns: Int {
        HomeSongGridLayout.columns(for: self.width)
    }

    private var pageSize: Int {
        HomeSongGridLayout.pageSize(for: self.width)
    }

    private var pageCount: Int {
        max(1, Int((Double(self.section.items.count) / Double(self.pageSize)).rounded(.up)))
    }

    private var clampedPage: Int {
        min(max(self.page, 0), self.pageCount - 1)
    }

    var body: some View {
        let columns = self.columns
        let gap = HomeSongGridLayout.columnGap
        let columnWidth = max(0, (self.width - CGFloat(columns - 1) * gap) / CGFloat(columns))
        let usesVideoThumbnails = HomeSongGridLayout.usesVideoThumbnails(self.section.items)

        VStack(alignment: .leading, spacing: 14) {
            HomeSectionHeader(self.section.title, pager: self.pager)

            HomePagedStrip(pageCount: self.pageCount, page: self.clampedPage, width: self.width) { page in
                let start = page * self.pageSize
                let end = min(start + self.pageSize, self.section.items.count)
                let indices = Array(start ..< max(start, end))
                HStack(alignment: .top, spacing: gap) {
                    ForEach(0 ..< columns, id: \.self) { column in
                        let rows = HomeSongGridLayout.rowsPerColumn
                        let lower = column * rows
                        let slice = indices.dropFirst(lower).prefix(rows)
                        VStack(spacing: 0) {
                            ForEach(Array(slice), id: \.self) { index in
                                let item = self.section.items[index]
                                HomeSongRow(item: item, usesVideoThumbnails: usesVideoThumbnails) {
                                    self.action(item, index)
                                }
                                .contextMenu { self.contextMenu(item, index) }
                            }
                        }
                        .frame(width: columnWidth, alignment: .top)
                    }
                }
            }
            .homeSwipePaging(isEnabled: self.pageCount > 1) { direction in
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
        .onChange(of: self.pageSize) { _, _ in self.publishPager() }
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
        let start = self.clampedPage * self.pageSize
        self.pager.update(
            first: total == 0 ? 0 : start + 1,
            last: min(start + self.pageSize, total),
            total: total,
            canPageLeading: self.clampedPage > 0,
            canPageTrailing: self.clampedPage < self.pageCount - 1
        )
    }
}

// MARK: - HomeSongRow

/// One C2 song row: rounded thumb (16:9 for videos in a mostly-video list),
/// title over artist, a mono VIDEO tag and dim mono meta on the trailing edge,
/// hairline underneath, a rounded hover fill. The now-playing row's title turns orange.
private struct HomeSongRow: View {
    let item: HomeSectionItem
    var usesVideoThumbnails = false
    let action: () -> Void

    @Environment(PlayerService.self) private var playerService
    @Environment(AuthService.self) private var authService
    @State private var isHovered = false

    private var song: Song? {
        if case let .song(song) = self.item {
            return song
        }
        return nil
    }

    private var isCurrent: Bool {
        guard let song, let current = self.playerService.currentTrack else { return false }
        return current.videoId == song.videoId
    }

    var body: some View {
        let caption = HomeCardCaption.make(for: self.item)
        let side = HomeSongGridLayout.thumbnailSide
        let isVideo = self.item.isVideoSong
        let slotWidth = self.usesVideoThumbnails ? HomeSongGridLayout.videoThumbnailWidth : side
        let thumbnailSize = CGSize(width: isVideo ? slotWidth : side, height: side)
        let isCurrent = self.isCurrent
        Button(action: self.action) {
            HStack(spacing: 12) {
                HomeHoverArtwork(item: self.item, size: thumbnailSize, isHovered: false, showsLike: false, showsVideoTag: false)
                    .overlay {
                        if self.isHovered || isCurrent {
                            Image(systemName: isCurrent && self.playerService.isPlaying ? "waveform" : "play.fill")
                                .font(TuneTheme.Typeface.label)
                                .foregroundStyle(isCurrent ? TuneTheme.Palette.accent : TuneTheme.Palette.ink)
                                .frame(width: thumbnailSize.width, height: thumbnailSize.height)
                                .background(TuneTheme.Palette.background.opacity(0.72), in: .tuneRounded(TuneTheme.Radius.artwork(for: thumbnailSize)))
                        }
                    }
                    .frame(width: slotWidth, alignment: .leading)

                VStack(alignment: .leading, spacing: 2) {
                    Text(self.item.displayTitle)
                        .font(TuneTheme.Typeface.body.weight(.medium))
                        .foregroundStyle(isCurrent ? TuneTheme.Palette.accent : TuneTheme.Palette.ink)
                        .lineLimit(1)
                    if !caption.text.isEmpty {
                        Text(caption.text)
                            .font(TuneTheme.Typeface.body)
                            .foregroundStyle(TuneTheme.Palette.inkMuted)
                            .lineLimit(1)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                if let song {
                    LikeButton(song: song, isRowHovered: self.isHovered, allowsActions: self.authService.hasPersonalAccount)
                }

                if isVideo {
                    HomeRowVideoTag()
                }

                if let meta = self.meta(caption: caption) {
                    Text(meta)
                        .font(TuneTheme.Typeface.data)
                        .foregroundStyle(TuneTheme.Palette.inkDim)
                        .lineLimit(1)
                        .fixedSize()
                }
            }
            .padding(.trailing, 4)
            .frame(height: HomeSongGridLayout.rowHeight)
            .background {
                // The fill bleeds past the thumbnail so it sits inside soft corners.
                RoundedRectangle.tuneRounded(TuneTheme.Radius.control)
                    .fill(self.isHovered ? TuneTheme.Palette.raised : Color.clear)
                    .padding(.horizontal, -Self.hoverBleed)
                    .padding(.vertical, 2)
            }
            .overlay(alignment: .bottom) {
                Rectangle()
                    .fill(TuneTheme.Palette.hairline)
                    .frame(height: 1)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { self.isHovered = $0 }
        .accessibilityLabel(self.accessibilityLabel(caption: caption))
        .accessibilityAddTraits(isCurrent ? .isSelected : [])
    }

    private func accessibilityLabel(caption: HomeCardCaption) -> String {
        var label = caption.text.isEmpty ? self.item.title : "\(self.item.title), \(caption.text)"
        if self.item.isVideoSong {
            label += ", \(String(localized: "Video"))"
        }
        return label
    }

    /// How far the rounded hover fill reaches past the row's edges.
    private static let hoverBleed: CGFloat = 6

    /// The caption's tag (counts, durations), else the song's duration. Video
    /// rows show their VIDEO tag beside it, never as the meta itself.
    private func meta(caption: HomeCardCaption) -> String? {
        if let meta = caption.meta {
            return meta
        }
        if let song, song.duration != nil {
            return song.durationDisplay
        }
        return nil
    }
}

// MARK: - HomeRowVideoTag

/// Inline mono VIDEO tag for list rows: a hairline-edged rounded chip.
private struct HomeRowVideoTag: View {
    var body: some View {
        Text(verbatim: TuneVideoTag.text)
            .font(TuneTheme.Typeface.data)
            .tracking(0.6)
            .foregroundStyle(TuneTheme.Palette.inkMuted)
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .overlay {
                RoundedRectangle.tuneRounded(TuneTheme.Radius.small)
                    .strokeBorder(TuneTheme.Palette.rule, lineWidth: 1)
            }
            .fixedSize()
            .accessibilityHidden(true)
    }
}
