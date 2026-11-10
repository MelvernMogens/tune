import Foundation
import Testing
@testable import Kaset

// MARK: - HomeShelfLayoutTests

@Suite(.tags(.model))
@MainActor
struct HomeShelfLayoutTests {
    private static func song(_ id: String, artists: String = "Artist", album: String? = nil, duration: TimeInterval? = nil, video: MusicVideoType? = nil) -> HomeSectionItem {
        .song(Song(
            id: id,
            title: "Song \(id)",
            artists: [Artist(id: "a-\(id)", name: artists)],
            album: album.map { Album(id: "al-\(id)", title: $0, artists: nil, thumbnailURL: nil, year: nil, trackCount: nil) },
            duration: duration,
            videoId: id,
            musicVideoType: video
        ))
    }

    private static func album(_ id: String) -> HomeSectionItem {
        .album(Album(id: id, title: "Album \(id)", artists: nil, thumbnailURL: nil, year: nil, trackCount: nil))
    }

    // MARK: Style

    @Test("The first sizeable shelf is the hero")
    func heroIsFirstShelf() {
        let section = HomeSection(id: "s", title: "Listen again", items: (0 ..< 20).map { Self.album("\($0)") })
        #expect(HomeShelfStyle.style(for: section, at: 0) == .hero)
        #expect(HomeShelfStyle.style(for: section, at: 3) == .hero)
        let other = HomeSection(id: "o", title: "Albums for you", items: (0 ..< 20).map { Self.album("\($0)") })
        #expect(HomeShelfStyle.style(for: other, at: 2) == .shelf)
        let short = HomeSection(id: "t", title: "Recaps", items: (0 ..< 2).map { Self.album("\($0)") })
        #expect(HomeShelfStyle.style(for: short, at: 0) == .shelf)
    }

    @Test("Song lists become row grids by title or by list-row metadata")
    func songGridDetection() {
        let byTitle = HomeSection(id: "q", title: "Quick picks", items: (0 ..< 20).map { Self.song("\($0)") })
        #expect(HomeShelfStyle.style(for: byTitle, at: 0) == .songGrid)
        let byShape = HomeSection(id: "x", title: "Something new", items: (0 ..< 8).map { Self.song("\($0)", album: "LP") })
        #expect(HomeShelfStyle.style(for: byShape, at: 4) == .songGrid)
        let twoRowSongs = HomeSection(id: "y", title: "Forgotten favorites", items: (0 ..< 10).map { Self.song("\($0)") })
        #expect(HomeShelfStyle.style(for: twoRowSongs, at: 4) == .shelf)
        let chart = HomeSection(id: "c", title: "Quick picks", items: (0 ..< 20).map { Self.song("\($0)") }, isChart: true)
        #expect(HomeShelfStyle.style(for: chart, at: 0) == .shelf)
    }

    // MARK: Geometry

    @Test("Hero lead and 2×2 grid share one height at the mockup width")
    func heroGeometry() {
        let layout = HomeHeroLayout(width: 1140)
        #expect(!layout.isStacked)
        #expect(layout.tileSide == 170)
        #expect(layout.leadWidth == 752)
        let gridHeight = 2 * (layout.tileSide + HomeHeroLayout.captionHeight) + HomeHeroLayout.rowGap
        #expect(layout.leadHeight == gridHeight)
        #expect(abs(layout.leadArtworkHeight - layout.leadWidth * 9 / 16) < 2)
        #expect(layout.leadWidth + 2 * layout.tileSide + 2 * HomeHeroLayout.gap <= 1140)
    }

    @Test("A height cap shrinks the grid, keeps lead = grid height and the full width")
    func heroHeightCap() {
        let uncapped = HomeHeroLayout(width: 1600)
        let capped = HomeHeroLayout(width: 1600, maxHeight: 420)
        #expect(capped.leadHeight < uncapped.leadHeight)
        #expect(capped.leadHeight == 2 * (capped.tileSide + HomeHeroLayout.captionHeight) + HomeHeroLayout.rowGap)
        #expect(capped.leadWidth + 2 * capped.tileSide + 2 * HomeHeroLayout.gap == 1600)
        // The lead's artwork never gets wider than 2:1.
        #expect(capped.leadWidth / capped.leadArtworkHeight <= HomeHeroLayout.maximumLeadAspect + 0.01)
        // A generous cap changes nothing.
        #expect(HomeHeroLayout(width: 1060, maxHeight: 2000) == HomeHeroLayout(width: 1060))
        #expect(HomeHeroLayout.maxHeight(forVisibleHeight: 0) == .infinity)
    }

    @Test("Narrow heroes stack the four tiles under the lead")
    func heroStacksWhenNarrow() {
        let layout = HomeHeroLayout(width: 600)
        #expect(layout.isStacked)
        #expect(layout.leadWidth == 600)
        #expect(4 * layout.tileSide + 3 * HomeHeroLayout.gap <= 600)
    }

    @Test("Song grid columns follow the width, clamped to 1…4")
    func songGridColumns() {
        #expect(HomeSongGridLayout.columns(for: 200) == 1)
        #expect(HomeSongGridLayout.columns(for: 1140) == 3)
        #expect(HomeSongGridLayout.columns(for: 4000) == 4)
        #expect(HomeSongGridLayout.pageSize(for: 1140) == 12)
    }

    @Test("Range labels are zero-padded to the total's width")
    func rangeLabel() {
        #expect(HomeShelfRange.label(first: 1, last: 5, total: 20) == "01—05 / 20")
        #expect(HomeShelfRange.label(first: 1, last: 2, total: 2) == "01—02 / 02")
        #expect(HomeShelfRange.label(first: 98, last: 140, total: 120) == "098—120 / 120")
    }

    // MARK: Captions

    @Test("Captions move type and counts into the mono tag")
    func captions() {
        #expect(HomeCardCaption.make(subtitle: "EP • asumuh", isVideo: false) == HomeCardCaption(text: "asumuh", meta: "EP"))
        #expect(HomeCardCaption.make(subtitle: "Single • keshi", isVideo: false) == HomeCardCaption(text: "keshi", meta: nil))
        #expect(HomeCardCaption.make(subtitle: "Annisa Shabira • 1.4M views", isVideo: false) == HomeCardCaption(text: "Annisa Shabira", meta: "1.4M"))
        #expect(HomeCardCaption.make(subtitle: "Playlist • Made for You • 50 songs", isVideo: false) == HomeCardCaption(text: "Made for You", meta: "50 SONGS"))
        #expect(HomeCardCaption.make(subtitle: "plyxium • 1:41:29", isVideo: true) == HomeCardCaption(text: "plyxium", meta: "1:41:29"))
        #expect(HomeCardCaption.make(subtitle: "CHILL PILL TV", isVideo: true) == HomeCardCaption(text: "CHILL PILL TV", meta: "VIDEO"))
    }

    @Test("Comma lists keep their artists; only edge components become tags")
    func commaCaptions() {
        #expect(
            HomeCardCaption.make(subtitle: "James Arthur, Anggi Marito, Joseph Vincent", isVideo: false)
                == HomeCardCaption(text: "James Arthur, Anggi Marito, Joseph Vincent", meta: nil)
        )
        #expect(HomeCardCaption.make(subtitle: "Album, Joji", isVideo: false) == HomeCardCaption(text: "Joji", meta: nil))
        #expect(HomeCardCaption.make(subtitle: "Steve Lacy, 1.81M subscribers", isVideo: false) == HomeCardCaption(text: "Steve Lacy", meta: "1.81M"))
        #expect(HomeCardCaption.make(subtitle: nil, isVideo: false) == HomeCardCaption(text: "", meta: nil))
    }

    // MARK: Artwork URLs

    @Test("Google-hosted artwork is re-requested at the tile's 2× size")
    func artworkURLs() throws {
        let url = try #require(URL(string: "https://yt3.googleusercontent.com/abc=w226-h226-l90-rj"))
        #expect(url.tuneArtworkURL(side: 170).absoluteString == "https://yt3.googleusercontent.com/abc=w340-h340-l90-rj")
        let sized = try #require(URL(string: "https://yt3.googleusercontent.com/abc=s544"))
        #expect(sized.tuneArtworkURL(side: 300).absoluteString == "https://yt3.googleusercontent.com/abc=s600")
        let other = try #require(URL(string: "https://i.ytimg.com/vi/x/hq720.jpg"))
        #expect(other.tuneArtworkURL(side: 300) == other)
    }

    // MARK: Shelf range

    @Test("Visible range counts cards at least half in view")
    func visibleRange() {
        let frames = (0 ..< 6).map { NSRect(x: 24 + CGFloat($0) * 176, y: 0, width: 160, height: 220) }
        let range = HomeItemShelfView.visibleRange(of: frames, in: NSRect(x: 0, y: 0, width: 600, height: 220))
        #expect(range == 0 ... 2)
        let scrolled = HomeItemShelfView.visibleRange(of: frames, in: NSRect(x: 300, y: 0, width: 600, height: 220))
        #expect(scrolled == 2 ... 4)
        #expect(HomeItemShelfView.visibleRange(of: [], in: .zero) == nil)
    }
}

// MARK: - PlaylistLayoutTests

@Suite(.tags(.model))
struct PlaylistLayoutTests {
    private static func track(_ id: String, artist: String, album: String?) -> Song {
        Song(
            id: id,
            title: id,
            artists: [Artist(id: "", name: artist)],
            album: album.map { Album(id: "al", title: $0, artists: nil, thumbnailURL: nil, year: nil, trackCount: nil) },
            videoId: id
        )
    }

    @Test("Breakdown ranks artists and albums case-insensitively")
    func breakdown() {
        let tracks = [
            Self.track("1", artist: "Ada Band", album: nil),
            Self.track("2", artist: "Ada band", album: "Metamorphosis"),
            Self.track("3", artist: "NaFF", album: "Isyarat Hati"),
            Self.track("4", artist: "Ada Band", album: "Heaven Of Love"),
            Self.track("5", artist: "SAMSONS", album: "Heaven Of Love"),
            Self.track("6", artist: "Kerispatih", album: " "),
        ]
        let breakdown = PlaylistBreakdown.make(tracks: tracks, artistLimit: 2, albumLimit: 1)
        #expect(breakdown.artists == [.init(name: "Ada Band", count: 3), .init(name: "NaFF", count: 1)])
        #expect(breakdown.remainingArtists == 2)
        #expect(breakdown.uniqueArtistCount == 4)
        #expect(breakdown.albums == [.init(name: "Heaven Of Love", count: 2)])
        #expect(breakdown.remainingAlbums == 2)
    }

    @Test("Track columns fill the table width and fold the album column when narrow")
    func columns() {
        let wide = PlaylistTrackColumns(width: 900, showsThumbnail: true, wantsAlbumColumn: true)
        #expect(wide.showsAlbum)
        let used = PlaylistTrackColumns.numberWidth + PlaylistTrackColumns.thumbnailSide + wide.title + wide.artist + wide.album
            + PlaylistTrackColumns.likeWidth + PlaylistTrackColumns.durationWidth + 6 * PlaylistTrackColumns.gap
        #expect(used <= 900)
        #expect(900 - used < 4)
        #expect(wide.title > wide.album && wide.album > wide.artist)

        let narrow = PlaylistTrackColumns(width: 500, showsThumbnail: true, wantsAlbumColumn: true)
        #expect(!narrow.showsAlbum)
        #expect(narrow.album == 0)

        let album = PlaylistTrackColumns(width: 900, showsThumbnail: false, wantsAlbumColumn: false)
        #expect(!album.showsThumbnail && !album.showsAlbum)
    }

    @Test("Chart ranks number songs and artists, never a shelf of chart playlists")
    func chartRanks() {
        let song = HomeSectionItem.song(Song(id: "s", title: "Song", artists: [], album: nil, duration: nil, videoId: "s"))
        let album = HomeSectionItem.album(Album(id: "a", title: "Album", artists: nil, thumbnailURL: nil, year: nil, trackCount: nil))
        #expect(HomeItemShelfView.chartRank(for: song, at: 0, isChart: true) == 1)
        #expect(HomeItemShelfView.chartRank(for: album, at: 1, isChart: true) == nil)
        #expect(HomeItemShelfView.chartRank(for: song, at: 2, isChart: false) == nil)
    }

    @Test("The status line gives the track column its natural width, never starving the scrubber")
    func statusLineSplit() {
        let short = PlayerBarTrackTimeLayout.widths(
            available: 500, trackNatural: 120, spacing: 20, trackFloor: 240, timeMinimum: 180, timeMaximum: 440
        )
        #expect(short.track == 240)
        #expect(short.time == 240)

        let long = PlayerBarTrackTimeLayout.widths(
            available: 500, trackNatural: 290, spacing: 20, trackFloor: 240, timeMinimum: 180, timeMaximum: 440
        )
        #expect(long.track == 290)
        #expect(long.time == 190)

        let huge = PlayerBarTrackTimeLayout.widths(
            available: 500, trackNatural: 900, spacing: 20, trackFloor: 240, timeMinimum: 180, timeMaximum: 440
        )
        #expect(huge.track == 300)
        #expect(huge.time == 180)

        let wide = PlayerBarTrackTimeLayout.widths(
            available: 1200, trackNatural: 100, spacing: 20, trackFloor: 240, timeMinimum: 180, timeMaximum: 440
        )
        #expect(wide.track == 240)
        #expect(wide.time == 440)
    }
}
