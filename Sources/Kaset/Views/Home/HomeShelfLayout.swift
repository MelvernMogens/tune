import Foundation

// MARK: - HomeShelfStyle

/// How a Home section is laid out in the C2 design.
enum HomeShelfStyle: Equatable {
    /// "Listen again": a big 16:9 lead plus a 2×2 grid of squares, paged.
    case hero
    /// Song lists ("Quick picks" and friends): a grid of compact rows with a
    /// square thumbnail on every row.
    case songGrid
    /// Everything else: a horizontal shelf of hard-edged cards.
    case shelf

    /// YouTube Music renders these shelves as list rows (musicResponsiveListItem
    /// carousels). Titles are matched because the parsed model does not keep the
    /// renderer type; the album/duration test below catches the rest.
    private static let songGridTitles: Set<String> = [
        "quick picks",
        "covers and remixes",
        "heard in shorts",
        "long listens",
        "trending songs",
        "trending in shorts",
    ]

    static func style(for section: HomeSection, at index: Int) -> HomeShelfStyle {
        if section.isChart {
            return .shelf
        }
        let normalizedTitle = section.title.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let allSongs = !section.items.isEmpty && section.items.allSatisfy {
            if case .song = $0 { return true }
            return false
        }
        if allSongs, Self.songGridTitles.contains(normalizedTitle) || Self.looksLikeListRows(section.items) {
            return .songGrid
        }
        if index == 0, section.items.count >= HomeHeroLayout.pageSize {
            return .hero
        }
        if normalizedTitle == "listen again", section.items.count >= HomeHeroLayout.pageSize {
            return .hero
        }
        return .shelf
    }

    /// Two-row cards never carry album or duration; list rows usually do.
    private static func looksLikeListRows(_ items: [HomeSectionItem]) -> Bool {
        guard items.count >= 4 else { return false }
        let listLike = items.count { item in
            guard case let .song(song) = item else { return false }
            return song.album != nil || song.duration != nil
        }
        return listLike * 2 >= items.count
    }
}

// MARK: - HomeSectionRow

/// One row of the Home page: a section on its own, or a shelf sharing the row
/// with a short shelf after it (C2 puts "Recaps" beside "Albums for you").
/// Identity comes from the member sections' ids, so a refresh that replaces the
/// sections also replaces the rows (and re-runs their prefetch tasks).
struct HomeSectionRow: Identifiable, Equatable {
    let id: String
    let leading: Int
    /// The paired short section, if any.
    let trailing: Int?
    /// The trailing shelf's width when paired.
    let trailingWidth: CGFloat

    static let pairGap: CGFloat = 24
    /// The most items a trailing shelf may have to share a row.
    static let maximumPairedItems = 3
    /// The leading shelf keeps room for at least this many square cards.
    static let minimumLeadingCards = 3

    var indices: [Int] {
        [self.leading] + (self.trailing.map { [$0] } ?? [])
    }

    @MainActor
    static func rows(for sections: [HomeSection], width: CGFloat) -> [HomeSectionRow] {
        var rows: [HomeSectionRow] = []
        var index = 0
        while index < sections.count {
            let next = index + 1
            if next < sections.count,
               let trailingWidth = Self.pairedWidth(leading: sections[index], at: index, trailing: sections[next], at: next, width: width)
            {
                rows.append(HomeSectionRow(
                    id: "\(sections[index].id)+\(sections[next].id)",
                    leading: index,
                    trailing: next,
                    trailingWidth: trailingWidth
                ))
                index += 2
            } else {
                rows.append(HomeSectionRow(id: sections[index].id, leading: index, trailing: nil, trailingWidth: 0))
                index += 1
            }
        }
        return rows
    }

    /// The trailing shelf's width when the two sections can share a row.
    @MainActor
    private static func pairedWidth(
        leading: HomeSection, at leadingIndex: Int,
        trailing: HomeSection, at trailingIndex: Int,
        width: CGFloat
    ) -> CGFloat? {
        guard HomeShelfStyle.style(for: leading, at: leadingIndex) == .shelf,
              HomeShelfStyle.style(for: trailing, at: trailingIndex) == .shelf,
              !leading.isChart, !trailing.isChart,
              (1 ... Self.maximumPairedItems).contains(trailing.items.count),
              leading.items.count > trailing.items.count
        else { return nil }
        let spacing = HomeItemShelfView.itemSpacing
        let trailingWidth = trailing.items.map { HomeItemCell.width(for: $0) }.reduce(0, +)
            + CGFloat(trailing.items.count - 1) * spacing
        let leadingMinimum = CGFloat(Self.minimumLeadingCards) * HomeItemCell.squareWidth
            + CGFloat(Self.minimumLeadingCards - 1) * spacing
        guard trailingWidth + Self.pairGap + leadingMinimum <= width else { return nil }
        return trailingWidth
    }
}

// MARK: - HomeHeroLayout

/// Geometry for the "Listen again" hero: a lead tile spanning most of the width
/// and a 2×2 grid of square tiles whose total height matches the lead's.
struct HomeHeroLayout: Equatable {
    static let pageSize = 5
    /// Column gap and grid gaps (C2 `.row` / `.mg` column gap).
    static let gap: CGFloat = 24
    /// Vertical gap between the grid's two rows (C2 `.mg` row gap).
    static let rowGap: CGFloat = 32
    /// Caption block under a tile: 10 pt gap + title line + 3 pt + subtitle line.
    static let captionHeight: CGFloat = 50
    /// Below this width the grid moves under the lead as a single row of four.
    static let stackedBreakpoint: CGFloat = 760

    private(set) var leadWidth: CGFloat
    private(set) var leadArtworkHeight: CGFloat
    private(set) var tileSide: CGFloat
    let isStacked: Bool

    /// Total height of the lead (artwork + caption), equal to the grid's height
    /// in the side-by-side layout.
    var leadHeight: CGFloat {
        self.leadArtworkHeight + Self.captionHeight
    }

    /// Visible page height kept free below the hero on the first screen: the
    /// page's top inset (32), the hero header (~94), the section gap (48), the
    /// next shelf's header (~50) and ~40 pt of its first row, so the next shelf
    /// always reads above the status line.
    static let nextShelfReveal: CGFloat = 264
    /// The widest the lead's artwork may get when the cap shrinks the grid:
    /// past 2:1 a 16:9 video frame loses too much to the crop.
    static let maximumLeadAspect: CGFloat = 2

    /// Height cap for a page whose visible height is `visibleHeight`.
    static func maxHeight(forVisibleHeight visibleHeight: CGFloat) -> CGFloat {
        guard visibleHeight.isFinite, visibleHeight > 0 else { return .infinity }
        return max(0, visibleHeight - self.nextShelfReveal)
    }
    /// Never shrink the grid tiles below this, however short the window.
    static let minimumTileSide: CGFloat = 120

    /// - Parameter maxHeight: cap on the side-by-side hero's total height
    ///   (lead = grid). Wide windows otherwise grow the hero until it fills
    ///   the first screen and hides the next shelf.
    init(width: CGFloat, maxHeight: CGFloat) {
        self.init(width: width)
        guard !self.isStacked, maxHeight.isFinite, maxHeight > 0, self.leadHeight > maxHeight else { return }
        let width = max(width, 0)
        // leadWidth / leadArtworkHeight ≤ maximumLeadAspect, solved for the tile side.
        let aspectFloor = ((width - 2 * Self.gap - Self.maximumLeadAspect * (Self.captionHeight + Self.rowGap))
            / (2 + 2 * Self.maximumLeadAspect)).rounded(.up)
        let capped = ((maxHeight - Self.rowGap) / 2 - Self.captionHeight).rounded(.down)
        let tile = max(Self.minimumTileSide, aspectFloor, capped)
        guard tile < self.tileSide else { return }
        self.tileSide = tile
        self.leadWidth = max(0, width - 2 * Self.gap - 2 * tile)
        self.leadArtworkHeight = 2 * (tile + Self.captionHeight) + Self.rowGap - Self.captionHeight
    }

    init(width: CGFloat) {
        let width = max(width, 0)
        if width < Self.stackedBreakpoint {
            self.isStacked = true
            self.leadWidth = width
            self.leadArtworkHeight = (width * 9 / 16).rounded()
            self.tileSide = max(0, ((width - 3 * Self.gap) / 4).rounded(.down))
            return
        }
        self.isStacked = false
        // width = lead + gap + 2·tile + gap, and the lead (16:9 art + caption)
        // is as tall as two tile rows: 2·(tile + caption) + rowGap.
        let caption = Self.captionHeight
        let ratio: CGFloat = 16 / 9
        let constant = (caption + Self.rowGap) * ratio
        let tile = ((width - 2 * Self.gap - constant) / (2 * ratio + 2)).rounded(.down)
        self.tileSide = max(0, tile)
        self.leadWidth = max(0, width - 2 * Self.gap - 2 * self.tileSide)
        self.leadArtworkHeight = 2 * (self.tileSide + caption) + Self.rowGap - caption
    }
}

// MARK: - HomeSongGridLayout

/// Column count for the song-row grid.
enum HomeSongGridLayout {
    static let rowsPerColumn = 4
    static let minimumColumnWidth: CGFloat = 280
    static let maximumColumns = 4
    static let columnGap: CGFloat = 24
    /// Row height (C2 `.q`).
    static let rowHeight: CGFloat = 56
    /// Thumbnail side on each row.
    static let thumbnailSide: CGFloat = 40
    /// Width of a video row's 16:9 thumbnail (same height as the square).
    static let videoThumbnailWidth: CGFloat = (thumbnailSide * 16 / 9).rounded()

    /// Mostly-video lists ("Long listens") give every row a 16:9 thumbnail slot,
    /// so their frames aren't cropped to squares and titles stay aligned.
    static func usesVideoThumbnails(_ items: [HomeSectionItem]) -> Bool {
        guard !items.isEmpty else { return false }
        return items.count(where: \.isVideoSong) * 2 >= items.count
    }

    static func columns(for width: CGFloat) -> Int {
        let fitting = Int(((width + self.columnGap) / (self.minimumColumnWidth + self.columnGap)).rounded(.down))
        return min(max(fitting, 1), self.maximumColumns)
    }

    static func pageSize(for width: CGFloat) -> Int {
        self.columns(for: width) * self.rowsPerColumn
    }
}

// MARK: - HomeShelfRange

/// The "01—05 / 20" range label used by every C2 section header.
enum HomeShelfRange {
    static func label(first: Int, last: Int, total: Int) -> String {
        let width = max(2, String(total).count)
        func pad(_ value: Int) -> String {
            let text = String(value)
            return String(repeating: "0", count: max(0, width - text.count)) + text
        }
        guard total > 0 else { return pad(0) }
        let first = min(max(first, 1), total)
        let last = min(max(last, first), total)
        return "\(pad(first))—\(pad(last)) / \(pad(total))"
    }
}

// MARK: - HomeCardCaption

/// A card's caption split the C2 way: readable text on the left, a short
/// monospaced tag on the right ("EP", "VIDEO", "1.4M", "50 SONGS").
struct HomeCardCaption: Equatable {
    let text: String
    let meta: String?

    static func make(for item: HomeSectionItem) -> HomeCardCaption {
        switch item {
        case let .song(song):
            // Videos carry the mono VIDEO tag on their artwork, so the caption
            // doesn't repeat it.
            return self.make(subtitle: song.displayText.artist, isVideo: false)
        case let .album(album):
            return self.make(subtitle: album.artistsDisplay, isVideo: false)
        case let .playlist(playlist):
            return self.make(subtitle: playlist.author?.name, isVideo: false)
        case let .artist(artist):
            let caption = self.make(subtitle: artist.subtitle, isVideo: false)
            return HomeCardCaption(text: caption.text.isEmpty ? String(localized: "Artist") : caption.text, meta: caption.meta)
        }
    }

    static func make(subtitle: String?, isVideo: Bool) -> HomeCardCaption {
        let subtitle = subtitle?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        var parts = subtitle
            .components(separatedBy: " • ")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        // Without bullets, YouTube joins type and counts with commas: only the
        // first and last components can be metadata; artist lists stay intact.
        if parts.count == 1, let only = parts.first {
            var components = only
                .split(separator: ",")
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
            if components.count > 1 {
                var head: [String] = []
                var tail: [String] = []
                if let first = components.first, Self.classify(first) != nil {
                    head = [first]
                    components.removeFirst()
                }
                if components.count > 1, let last = components.last, Self.classify(last) != nil {
                    tail = [last]
                    components.removeLast()
                }
                parts = head + [components.joined(separator: ", ")] + tail
            }
        }

        var text: [String] = []
        var meta: String?
        for part in parts {
            switch Self.classify(part) {
            case let .tag(tag):
                meta = meta ?? tag
            case .drop:
                continue
            case nil:
                text.append(part)
            }
        }
        if meta == nil, isVideo {
            meta = String(localized: "Video").uppercased()
        }
        return HomeCardCaption(text: text.joined(separator: " · "), meta: meta)
    }

    private enum Classification: Equatable {
        case tag(String)
        case drop
    }

    private static let droppedTypes: Set<String> = [
        "album", "single", "song", "playlist", "video", "artist", "podcast", "episode", "profile",
    ]
    private static let shortCountUnits: Set<String> = ["views", "view", "plays", "play", "subscribers", "subscriber"]
    private static let longCountUnits: Set<String> = ["songs", "song", "tracks", "track", "episodes", "episode", "videos"]

    private static func classify(_ part: String) -> Classification? {
        let lower = part.lowercased()
        if lower == "ep" {
            return .tag("EP")
        }
        if Self.droppedTypes.contains(lower) {
            return .drop
        }
        let words = lower.split(separator: " ")
        if words.count == 2, let number = words.first, Self.isCount(number) {
            let unit = String(words[1])
            if Self.shortCountUnits.contains(unit) {
                return .tag(String(part.split(separator: " ")[0]).uppercased())
            }
            if Self.longCountUnits.contains(unit) {
                return .tag(part.uppercased())
            }
        }
        if Self.isDuration(lower) {
            return .tag(part)
        }
        return nil
    }

    /// "1.4M", "223K", "19", "1,234".
    private static func isCount(_ token: Substring) -> Bool {
        guard let first = token.first, first.isNumber else { return false }
        return token.allSatisfy { $0.isNumber || $0 == "." || $0 == "," || "kmb".contains($0) }
    }

    /// "4:39", "1:41:29".
    private static func isDuration(_ text: String) -> Bool {
        let pieces = text.split(separator: ":", omittingEmptySubsequences: false)
        guard (2 ... 3).contains(pieces.count) else { return false }
        return pieces.allSatisfy { !$0.isEmpty && $0.count <= 2 && $0.allSatisfy(\.isNumber) }
    }
}
