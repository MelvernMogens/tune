import Foundation
import Testing
@testable import Kaset

/// Logic behind Tune's C2 chrome: status-line routing, sidebar playlists, scrubber, meter.
@MainActor
@Suite(.serialized, .tags(.model))
struct TuneChromeTests {
    private static func playlist(_ id: String, title: String = "P", trackCount: Int? = nil) -> Playlist {
        Playlist(id: id, title: title, description: nil, thumbnailURL: nil, trackCount: trackCount)
    }

    private static func route(albumIDs: Set<String> = [], artistID: String? = nil) -> PlayerBarRouteCenter.Route {
        PlayerBarRouteCenter.Route(navigationAction: .disabled, albumIDs: albumIDs, artistID: artistID)
    }

    // MARK: - PlayerBarRouteCenter

    @Test("The most recently registered page anchor owns the status line route")
    func latestRegistrationWins() {
        let center = PlayerBarRouteCenter()
        let root = UUID()
        let pushed = UUID()

        #expect(center.current == nil)

        center.register(root, route: Self.route(artistID: "root"))
        center.register(pushed, route: Self.route(albumIDs: ["MPRE_album"]))
        #expect(center.current?.albumIDs == ["MPRE_album"])
        #expect(center.currentToken == pushed)

        center.unregister(pushed)
        #expect(center.current?.artistID == "root")
        #expect(center.currentToken == root)

        center.unregister(root)
        #expect(center.current == nil)
    }

    @Test("Re-registering moves an anchor to the top; updates keep its position")
    func reRegistrationAndUpdate() {
        let center = PlayerBarRouteCenter()
        let first = UUID()
        let second = UUID()

        center.register(first, route: Self.route(artistID: "a"))
        center.register(second, route: Self.route(artistID: "b"))

        center.update(first, route: Self.route(artistID: "a2"))
        #expect(center.current?.artistID == "b")

        center.register(first, route: Self.route(artistID: "a3"))
        #expect(center.current?.artistID == "a3")

        center.update(UUID(), route: Self.route(artistID: "ghost"))
        #expect(center.current?.artistID == "a3")
    }

    @Test("Route keys reflect whether the page can open artists and albums")
    func routeKeyTracksNavigationAvailability() {
        let disabled = Self.route().key
        let enabled = PlayerBarRouteCenter.Route(
            navigationAction: PlayerBarNavigationAction(openArtist: { _ in }, openAlbum: { _ in }),
            albumIDs: [],
            artistID: nil
        ).key

        #expect(disabled != enabled)
        #expect(enabled.canOpenArtist)
        #expect(enabled.canOpenAlbum)
    }

    // MARK: - Sidebar playlists

    @Test("Sidebar playlists skip generated collections, duplicates, and pinned items")
    func sidebarLibraryPlaylistsFilter() {
        let playlists = [
            Self.playlist("LM", title: "Liked Music"),
            Self.playlist("SE", title: "Episodes for Later"),
            Self.playlist("PLfavs", title: "favs", trackCount: 505),
            Self.playlist("VLPLfavs", title: "favs duplicate"),
            Self.playlist("PLpinned", title: "pinned"),
            Self.playlist("PLren", title: "ren", trackCount: 113),
        ]
        let pinned = [SidebarPinnedItem.from(Self.playlist("VLPLpinned", title: "pinned"))]

        let result = Sidebar.sidebarLibraryPlaylists(from: playlists, excludingPinned: pinned)

        #expect(result.map(\.id) == ["PLfavs", "PLren"])
    }

    // MARK: - Scrubber

    @Test("Inline playhead centres on progress and stays inside the track")
    func inlinePlayheadClamps() {
        let width: CGFloat = 360
        let half = PlayerBarProgressLane.inlinePlayheadWidth / 2

        #expect(PlayerBarProgressLane.inlinePlayheadX(fraction: 0.5, trackWidth: width) == 180 - half)
        #expect(PlayerBarProgressLane.inlinePlayheadX(fraction: 0, trackWidth: width) == 0)
        #expect(
            PlayerBarProgressLane.inlinePlayheadX(fraction: 1, trackWidth: width)
                == width - PlayerBarProgressLane.inlinePlayheadWidth
        )
        #expect(PlayerBarProgressLane.inlinePlayheadX(fraction: .nan, trackWidth: width) == 0)
        #expect(PlayerBarProgressLane.inlinePlayheadX(fraction: 0.5, trackWidth: 0) == 0)
    }

    // MARK: - Volume meter

    @Test("Volume meter lights segments by level; any audible volume shows one")
    func volumeMeterSegments() {
        #expect(PlayerBarVolumeMeter.litSegments(for: 0) == 0)
        #expect(PlayerBarVolumeMeter.litSegments(for: 0.01) == 1)
        #expect(PlayerBarVolumeMeter.litSegments(for: 0.7) == 7)
        #expect(PlayerBarVolumeMeter.litSegments(for: 1) == 10)
        #expect(PlayerBarVolumeMeter.litSegments(for: 3) == 10)
        #expect(PlayerBarVolumeMeter.litSegments(for: .nan) == 0)
        #expect(PlayerBarVolumeMeter.litSegments(for: -1) == 0)
    }

    // MARK: - Source toggle

    @Test("Source toggle uses short C2 labels")
    func sourceToggleTitles() {
        #expect(SidebarSourceModeToggle.title(for: .music) == String(localized: "Music"))
        #expect(SidebarSourceModeToggle.title(for: .video) == String(localized: "Video"))
    }
}
