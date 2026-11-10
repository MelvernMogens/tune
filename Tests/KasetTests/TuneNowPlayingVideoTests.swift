import Foundation
import Testing
@testable import Kaset

@Suite("Tune Now Playing video and search filter")
@MainActor
struct TuneNowPlayingVideoTests {
    private typealias Tokens = TuneTheme.NowPlaying

    // MARK: Availability

    private static func song(type: MusicVideoType? = nil, hasVideo: Bool? = nil) -> Song {
        var song = TestFixtures.makeSong()
        song.musicVideoType = type
        song.hasVideo = hasVideo
        return song
    }

    @Test("Video availability: page switch, OMV, video items and hasVideo; never without a track")
    func videoAvailability() {
        #expect(!PlayerService.canShowVideo(track: nil, currentTrackHasVideo: true))
        #expect(!PlayerService.canShowVideo(track: Self.song(), currentTrackHasVideo: false))
        #expect(!PlayerService.canShowVideo(track: Self.song(type: .atv), currentTrackHasVideo: false))
        #expect(!PlayerService.canShowVideo(track: Self.song(type: .podcastEpisode), currentTrackHasVideo: false))
        // The page's Song/Video switch was seen.
        #expect(PlayerService.canShowVideo(track: Self.song(type: .atv), currentTrackHasVideo: true))
        #expect(PlayerService.canShowVideo(track: Self.song(type: .omv), currentTrackHasVideo: false))
        // Items that are videos themselves (Videos search results).
        #expect(PlayerService.canShowVideo(track: Self.song(type: .ugc), currentTrackHasVideo: false))
        #expect(PlayerService.canShowVideo(track: Self.song(type: .officialSourceMusic), currentTrackHasVideo: false))
        #expect(PlayerService.canShowVideo(track: Self.song(hasVideo: true), currentTrackHasVideo: false))
        #expect(PlayerService.canShowVideo(track: Self.song(), currentTrackHasVideo: false, forcesVideoForUITests: true))
    }

    @Test("The overlay video counts as attended media for the stall watchdog")
    func watchdogStandsDownWhileOverlayShowsVideo() {
        let player = PlayerService()
        #expect(!player.makePlaybackStallObservation(now: .now).isMediaUserControllable)
        player.isNowPlayingVideoVisible = true
        #expect(player.makePlaybackStallObservation(now: .now).isMediaUserControllable)
    }

    @Test("The hidden anchor stands aside while the overlay or the video window owns the WebView")
    func persistentPlayerYieldsToOverlayVideo() {
        #expect(MainWindow.shouldMountPersistentPlayer(
            isLoggedIn: true, pendingVideoId: nil, isPendingRestoredLoadDeferred: false,
            showVideo: false, showsNowPlayingVideo: false
        ))
        #expect(!MainWindow.shouldMountPersistentPlayer(
            isLoggedIn: true, pendingVideoId: nil, isPendingRestoredLoadDeferred: false,
            showVideo: false, showsNowPlayingVideo: true
        ))
        #expect(!MainWindow.shouldMountPersistentPlayer(
            isLoggedIn: true, pendingVideoId: nil, isPendingRestoredLoadDeferred: false,
            showVideo: true, showsNowPlayingVideo: false
        ))
    }

    // MARK: SONG · VIDEO

    @Test("SONG · VIDEO: the preference picks the side; no video dims both and keeps the preference")
    func videoToggleState() {
        #expect(TuneNowPlayingVideoToggle(prefersVideo: false, isAvailable: true).activeMode == .song)
        #expect(TuneNowPlayingVideoToggle(prefersVideo: true, isAvailable: true).activeMode == .video)
        let fallback = TuneNowPlayingVideoToggle(prefersVideo: true, isAvailable: false)
        #expect(fallback.activeMode == nil)
        #expect(fallback.prefersVideo)
    }

    @Test("The slot shows video only when presented, preferred, available, and the mini player is away")
    func videoSlotDecision() {
        let on = TuneNowPlayingVideoToggle(prefersVideo: true, isAvailable: true)
        #expect(TuneNowPlayingVideoToggle.wantsVideoSlot(toggle: on, isPresented: true, isMiniPlayerOnScreen: false))
        #expect(!TuneNowPlayingVideoToggle.wantsVideoSlot(toggle: on, isPresented: false, isMiniPlayerOnScreen: false))
        #expect(!TuneNowPlayingVideoToggle.wantsVideoSlot(toggle: on, isPresented: true, isMiniPlayerOnScreen: true))
        let song = TuneNowPlayingVideoToggle(prefersVideo: false, isAvailable: true)
        #expect(!TuneNowPlayingVideoToggle.wantsVideoSlot(toggle: song, isPresented: true, isMiniPlayerOnScreen: false))
        let noVideo = TuneNowPlayingVideoToggle(prefersVideo: true, isAvailable: false)
        #expect(!TuneNowPlayingVideoToggle.wantsVideoSlot(toggle: noVideo, isPresented: true, isMiniPlayerOnScreen: false))
    }

    @Test("Only a lost video waits before the artwork returns; SONG, closing and the mini player are immediate")
    func videoFallbackTiming() {
        let lost = TuneNowPlayingVideoToggle(prefersVideo: true, isAvailable: false)
        #expect(!TuneNowPlayingVideoToggle.hidesVideoImmediately(toggle: lost, isPresented: true, isMiniPlayerOnScreen: false))
        let song = TuneNowPlayingVideoToggle(prefersVideo: false, isAvailable: true)
        #expect(TuneNowPlayingVideoToggle.hidesVideoImmediately(toggle: song, isPresented: true, isMiniPlayerOnScreen: false))
        #expect(TuneNowPlayingVideoToggle.hidesVideoImmediately(toggle: lost, isPresented: false, isMiniPlayerOnScreen: false))
        #expect(TuneNowPlayingVideoToggle.hidesVideoImmediately(toggle: lost, isPresented: true, isMiniPlayerOnScreen: true))
    }

    // MARK: Video slot layout

    @Test("16:9 fit: whole points, inside the bounds, empty for bad input")
    func videoFit() {
        let wide = TuneNowPlayingMetrics.videoSize(fitting: CGSize(width: 640, height: 1000))
        #expect(wide == CGSize(width: 640, height: 360))
        let tall = TuneNowPlayingMetrics.videoSize(fitting: CGSize(width: 2000, height: 360))
        #expect(tall == CGSize(width: 640, height: 360))
        #expect(TuneNowPlayingMetrics.videoSize(fitting: .zero) == .zero)
        #expect(TuneNowPlayingMetrics.videoSize(fitting: CGSize(width: CGFloat.infinity, height: 200)) == .zero)
        #expect(TuneNowPlayingMetrics.videoSize(fitting: CGSize(width: CGFloat.nan, height: 200)) == .zero)
    }

    @Test("Wide windows put the video beside the lyrics, filling the artwork region's width")
    func sideVideo() {
        let metrics = TuneNowPlayingMetrics(size: CGSize(width: 1440, height: 900))
        guard case let .side(size) = metrics.videoPlacement(showsVideo: true) else {
            Issue.record("expected a side video")
            return
        }
        #expect(size.width >= Tokens.minimumSideVideoWidth)
        #expect(abs(size.width / size.height - 16 / 9) < 0.02)
        #expect(size.width >= metrics.sideArtworkEdge - 1)
        let center = metrics.sideSlotCenter(height: size.height, lyricsViewport: CGRect(x: 96, y: 160, width: 580, height: 600))
        #expect(center.x - size.width / 2 >= metrics.columnLeading + metrics.columnWidth)
        #expect(center.x + size.width / 2 <= 1440 - metrics.columnLeading + 0.5)
        #expect(center.y - size.height / 2 >= Tokens.headerTop)
        #expect(metrics.videoPlacement(showsVideo: false) == .none)
    }

    @Test("With Up Next open the video shares the narrowed region; under 1200 pt it stacks over the lyrics")
    func videoWithQueue() {
        let wide = TuneNowPlayingMetrics(size: CGSize(width: 1440, height: 900), showsQueue: true)
        guard case let .side(size) = wide.videoPlacement(showsVideo: true) else {
            Issue.record("expected a side video beside the open queue")
            return
        }
        #expect(wide.sideArtworkCenter.x + size.width / 2 <= wide.contentWidth - TuneTheme.Spacing.gutter + 0.5)

        let narrow = TuneNowPlayingMetrics(size: CGSize(width: 1100, height: 720), showsQueue: true)
        guard case let .stacked(stacked) = narrow.videoPlacement(showsVideo: true) else {
            Issue.record("expected a stacked video")
            return
        }
        #expect(stacked.width <= narrow.columnWidth)
        #expect(stacked.height <= 720 * Tokens.stackedVideoHeightShare)
        #expect(stacked.height > 0)
    }

    @Test("The no-lyrics composition's video stays inside the content area")
    func centeredVideo() {
        let metrics = TuneNowPlayingMetrics(size: CGSize(width: 1360, height: 840), showsQueue: true)
        let size = metrics.centeredVideoSize
        #expect(size.width <= metrics.contentWidth - metrics.columnLeading * 2)
        #expect(size.height <= 840 * Tokens.centeredArtworkShare)
        #expect(size.width > 0)
    }

    // MARK: Search filter

    @Test("SONGS · VIDEOS maps onto the search model's filters and Tab flips it")
    func searchFilterMapping() {
        #expect(TuneNowPlayingSearchFilter.songs.searchFilter == .songs)
        #expect(TuneNowPlayingSearchFilter.videos.searchFilter == .videos)
        #expect(TuneNowPlayingSearchFilter(.videos) == .videos)
        #expect(TuneNowPlayingSearchFilter(.albums) == nil)
        #expect(TuneNowPlayingSearchFilter.songs.toggled == .videos)
        #expect(TuneNowPlayingSearchFilter.videos.toggled == .songs)
    }

    @Test("In-flight results keep the shown rows only within the same filter")
    func searchRowsAcrossFilters() {
        let item = TuneNowPlayingSearchResults.Item(id: "a", title: "A", artist: "B")
        let shownSongs = TuneNowPlayingSearchResults(items: [item], phase: .loaded, filter: .songs)
        let pendingSongs = TuneNowPlayingSearchResults(items: [], phase: .searching, filter: .songs)
        let pendingVideos = TuneNowPlayingSearchResults(items: [], phase: .searching, filter: .videos)
        #expect(TuneNowPlayingSearchResults.keepsShownRows(shown: shownSongs, incoming: pendingSongs))
        #expect(!TuneNowPlayingSearchResults.keepsShownRows(shown: shownSongs, incoming: pendingVideos))
        let loadedEmpty = TuneNowPlayingSearchResults(items: [], phase: .loaded, filter: .songs)
        #expect(!TuneNowPlayingSearchResults.keepsShownRows(shown: shownSongs, incoming: loadedEmpty))
    }

    @Test("Switching filter puts the selection back on the top result")
    func selectionResetsOnFilterSwitch() {
        var selection = TuneNowPlayingSearchSelection()
        selection.moveDown(count: 5)
        selection.moveDown(count: 5)
        #expect(selection.resolved(count: 5) == 2)
        selection.reset()
        #expect(selection.resolved(count: 3) == 0)
    }
}

// MARK: - Esc routing

@Suite("Tune Now Playing Esc routing")
struct TuneNowPlayingEscapeRoutingTests {
    private static func route(
        isPresented: Bool = true,
        isOverlayWindow: Bool = true,
        hasAttachedSheet: Bool = false,
        hasModifiers: Bool = false,
        isComposingText: Bool = false,
        isSearchEngaged: Bool = false
    ) -> TuneNowPlayingEscape? {
        TuneNowPlayingEscape.route(
            isPresented: isPresented,
            isOverlayWindow: isOverlayWindow,
            hasAttachedSheet: hasAttachedSheet,
            hasModifiers: hasModifiers,
            isComposingText: isComposingText,
            isSearchEngaged: isSearchEngaged
        )
    }

    @Test("Search focused or holding text: Esc clears it first")
    func clearsSearchFirst() {
        #expect(Self.route(isSearchEngaged: true) == .dismissSearch)
    }

    @Test("Overlay open: Esc closes it (and never reaches the full-screen exit)")
    func closesOverlay() {
        #expect(Self.route() == .close)
    }

    @Test("No overlay, another window, a sheet, a modifier or IME composition: Esc passes through")
    func passesThrough() {
        #expect(Self.route(isPresented: false) == nil)
        #expect(Self.route(isPresented: false, isSearchEngaged: true) == nil)
        #expect(Self.route(isOverlayWindow: false) == nil)
        #expect(Self.route(hasAttachedSheet: true) == nil)
        #expect(Self.route(hasModifiers: true) == nil)
        #expect(Self.route(isComposingText: true, isSearchEngaged: true) == nil)
    }
}

@Suite("Tune Now Playing Tab routing")
struct TuneNowPlayingTabRoutingTests {
    @Test("Tab flips the filter only in the overlay's search field with a query")
    func tabRouting() {
        func route(
            isPresented: Bool = true, isOverlayWindow: Bool = true, hasSheet: Bool = false,
            modifiers: Bool = false, composing: Bool = false, focusedWithQuery: Bool = true
        ) -> Bool {
            TuneNowPlayingSearchFilter.tabSwitchesFilter(
                isPresented: isPresented,
                isOverlayWindow: isOverlayWindow,
                hasAttachedSheet: hasSheet,
                hasNonShiftModifiers: modifiers,
                isComposingText: composing,
                isSearchFocusedWithQuery: focusedWithQuery
            )
        }
        #expect(route())
        #expect(!route(focusedWithQuery: false))
        #expect(!route(isPresented: false))
        #expect(!route(isOverlayWindow: false))
        #expect(!route(hasSheet: true))
        #expect(!route(modifiers: true))
        #expect(!route(composing: true))
    }
}

@Suite("Tune Now Playing video ownership")
@MainActor
struct TuneNowPlayingVideoOwnershipTests {
    @Test("The mini player waits for the overlay to give the video slot up before hosting")
    func miniPlayerWaitsForOverlay() {
        let player = PlayerService()
        player.isMiniPlayerVisible = true
        #expect(player.shouldHostPlaybackInMiniPlayer)
        player.isNowPlayingVideoVisible = true
        #expect(!player.shouldHostPlaybackInMiniPlayer)
        #expect(player.isMiniPlayerOnScreen)
    }
}
