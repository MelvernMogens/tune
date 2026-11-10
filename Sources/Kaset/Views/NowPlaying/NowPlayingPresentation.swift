import Observation
import SwiftUI

// MARK: - NowPlayingPresentation

/// Shared toggle for Tune's fullscreen immersive Now Playing view.
///
/// Owned jointly by the redesign lanes: the player status line toggles
/// `isPresented`; `MainWindow` applies `.tuneNowPlayingOverlay()` once at the root.
/// The overlay content itself lives in `TuneNowPlayingView` (Views/NowPlaying/).
@MainActor
@Observable
final class NowPlayingPresentation {
    static let shared = NowPlayingPresentation()

    /// Whether the fullscreen Now Playing view covers the main window.
    var isPresented = false

    /// Bumped to focus the view's search field (⌘K / ⌘F while it's up).
    private(set) var searchFocusRequest = 0

    func requestSearchFocus() {
        self.searchFocusRequest &+= 1
    }

    /// Whether the search field has focus or text: Esc clears it before closing the view.
    /// Mirrored by the view for the Esc key monitor.
    var isSearchEngaged = false

    /// Bumped by the Esc monitor: clear and leave the search field.
    private(set) var searchDismissalRequest = 0

    func requestSearchDismissal() {
        self.searchDismissalRequest &+= 1
    }

    /// Whether the search field has focus and a query: Tab flips SONGS · VIDEOS then.
    var isSearchFocusedWithQuery = false

    /// Bumped by the key monitor's Tab: flip the search filter.
    private(set) var searchFilterToggleRequest = 0

    func requestSearchFilterToggle() {
        self.searchFilterToggleRequest &+= 1
    }

    func toggle() {
        self.isPresented.toggle()
    }
}

extension View {
    /// Hosts the fullscreen Now Playing overlay. Apply once, at the main window root.
    func tuneNowPlayingOverlay() -> some View {
        self.modifier(TuneNowPlayingOverlayModifier())
    }
}

private struct TuneNowPlayingOverlayModifier: ViewModifier {
    @Environment(PlayerService.self) private var playerService
    @State private var presentation = NowPlayingPresentation.shared

    func body(content: Content) -> some View {
        content.overlay {
            if self.presentation.isPresented {
                TuneNowPlayingHost()
                    .transition(.opacity)
            }
        }
        .animation(.easeOut(duration: 0.2), value: self.presentation.isPresented)
        .onChange(of: self.presentation.isPresented) { _, isPresented in
            // Hand the playback WebView back the moment the view closes, not after its fade.
            if !isPresented {
                TuneNowPlayingVideoHosting.setVisible(false, playerService: self.playerService)
            }
        }
    }
}

/// Binds `TuneNowPlayingView` to the live player and lyrics services.
/// Owned by the Now Playing lane; other lanes must not edit it.
struct TuneNowPlayingHost: View {
    @Environment(PlayerService.self) private var playerService
    @Environment(SyncedLyricsService.self) private var syncedLyricsService
    @Environment(AuthService.self) private var authService

    @State private var lyricsController = TuneNowPlayingLyricsController()
    @AppStorage(TuneTheme.NowPlaying.showsQueueKey) private var showsQueue = false
    @AppStorage(TuneTheme.NowPlaying.prefersVideoKey) private var prefersVideo = false
    @State private var presentation = NowPlayingPresentation.shared
    /// The app's own search model (Songs / Videos filter); created on the first query.
    @State private var searchModel: SearchViewModel?
    /// The dropdown's filter, applied to the model when it's created.
    @State private var searchFilter = TuneNowPlayingSearchFilter.songs

    var body: some View {
        Group {
            if let track = self.playerService.currentTrack {
                TuneNowPlayingView(
                    track: TuneNowPlayingTrack(
                        videoId: track.videoId,
                        title: track.displayText.title,
                        artist: track.displayText.artist,
                        thumbnailURL: track.thumbnailURL
                    ),
                    lyrics: self.lyricsController.displayState(
                        for: track.videoId,
                        service: self.syncedLyricsService,
                        playerService: self.playerService
                    ),
                    playback: self.playback,
                    actions: self.actions,
                    queue: self.queue,
                    showsQueue: self.showsQueue,
                    search: self.searchResults,
                    searchFocusRequest: self.presentation.searchFocusRequest,
                    searchDismissalRequest: self.presentation.searchDismissalRequest,
                    searchFilterToggleRequest: self.presentation.searchFilterToggleRequest,
                    onSearchEngagedChange: { NowPlayingPresentation.shared.isSearchEngaged = $0 },
                    onSearchFocusedWithQueryChange: { NowPlayingPresentation.shared.isSearchFocusedWithQuery = $0 },
                    video: TuneNowPlayingVideo(
                        toggle: self.videoToggle,
                        showsVideo: self.playerService.isNowPlayingVideoVisible
                    )
                )
            } else {
                TuneTheme.Palette.background
                    .ignoresSafeArea()
            }
        }
        // Esc belongs to the overlay while it's up — even in native full screen, where an
        // unclaimed Esc would exit full screen instead of closing the view.
        .background {
            TuneNowPlayingEscapeKeyCatcher()
                .frame(width: 0, height: 0)
                .accessibilityHidden(true)
        }
        // No track → nothing to show: close.
        .onChange(of: self.playerService.currentTrack == nil, initial: true) { _, hasNoTrack in
            if hasNoTrack {
                Self.close()
            }
        }
        .task(id: self.playerService.currentTrack?.videoId) {
            guard let track = self.playerService.currentTrack else { return }
            await self.lyricsController.load(
                track: track,
                service: self.syncedLyricsService,
                client: self.playerService.ytMusicClient,
                playerService: self.playerService
            )
        }
        .onChange(of: self.syncedLyricsService.currentLyrics, initial: true) { _, lyrics in
            self.lyricsController.updatePolling(for: lyrics, playerService: self.playerService)
        }
        .onChange(of: self.playerService.showLyrics) { _, isShown in
            // Closing the sidebar stops the shared poll in `LyricsView.onDisappear`; take it back
            // right after instead of waiting for the once-a-second check below.
            guard !isShown else { return }
            Task {
                try? await Task.sleep(for: .milliseconds(100))
                guard NowPlayingPresentation.shared.isPresented else { return }
                self.lyricsController.ensurePolling(for: self.syncedLyricsService.currentLyrics)
            }
        }
        .task {
            // Keeps the shared line poll alive if the lyrics sidebar closes underneath us.
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                self.lyricsController.ensurePolling(for: self.syncedLyricsService.currentLyrics)
            }
        }
        .task(id: self.wantsVideoSlot) {
            await self.syncVideoSlot()
        }
        .onDisappear {
            self.presentation.isSearchEngaged = false
            self.presentation.isSearchFocusedWithQuery = false
            self.lyricsController.stopPolling(playerService: self.playerService)
            TuneNowPlayingVideoHosting.setVisible(false, playerService: self.playerService)
        }
    }

    // MARK: Video

    private var videoToggle: TuneNowPlayingVideoToggle {
        TuneNowPlayingVideoToggle(
            prefersVideo: self.prefersVideo,
            isAvailable: self.playerService.canShowCurrentTrackVideo
        )
    }

    private var wantsVideoSlot: Bool {
        TuneNowPlayingVideoToggle.wantsVideoSlot(
            toggle: self.videoToggle,
            isPresented: self.presentation.isPresented,
            isMiniPlayerOnScreen: self.playerService.isMiniPlayerOnScreen
        )
    }

    /// Shows the video at once; gives the slot up at once when asked to (SONG, closing, the
    /// mini player taking the WebView), but only after a beat when the track lost its video.
    private func syncVideoSlot() async {
        let player = self.playerService
        if self.wantsVideoSlot {
            TuneNowPlayingVideoHosting.setVisible(true, playerService: player)
            return
        }
        guard player.isNowPlayingVideoVisible else { return }
        let immediately = TuneNowPlayingVideoToggle.hidesVideoImmediately(
            toggle: self.videoToggle,
            isPresented: self.presentation.isPresented,
            isMiniPlayerOnScreen: player.isMiniPlayerOnScreen
        )
        if !immediately {
            try? await Task.sleep(for: TuneTheme.NowPlaying.videoFallbackDelay)
            guard !Task.isCancelled else { return }
        }
        TuneNowPlayingVideoHosting.setVisible(false, playerService: player)
    }

    private var playback: TuneNowPlayingPlayback {
        let player = self.playerService
        return TuneNowPlayingPlayback(
            isPlaying: player.isPlaying,
            progress: player.progress,
            duration: player.duration,
            isLiked: player.currentTrackLikeStatus == .like,
            canLike: self.authService.hasPersonalAccount,
            canSeek: player.currentTrack != nil
                && player.duration > 0
                && !player.isCurrentItemLive
                && !player.isShowingAd,
            repeatMode: player.repeatMode
        )
    }

    private var queue: TuneNowPlayingQueue {
        TuneNowPlayingQueue(
            items: self.playerService.queueEntries.map { entry in
                TuneNowPlayingQueue.Item(
                    id: entry.id,
                    title: entry.song.displayText.title,
                    artist: entry.song.displayText.artist,
                    thumbnailURL: entry.song.thumbnailURL,
                    duration: entry.song.duration
                )
            },
            currentIndex: self.playerService.activePlaybackQueueIndex
        )
    }

    private var actions: TuneNowPlayingActions {
        let player = self.playerService
        let queue = self.queue
        return TuneNowPlayingActions(
            previous: { Task { await player.previous() } },
            playPause: { Task { await player.playPause() } },
            next: { Task { await player.next() } },
            seek: { time in Task { await player.seek(to: time) } },
            toggleLike: { player.likeCurrentTrack() },
            close: { Self.close() },
            cycleRepeat: { player.cycleRepeatMode() },
            toggleQueue: { Self.toggleQueue() },
            playQueueEntry: { entryID in
                // Same intent handshake as the Up Next side panel, so a stale click can't
                // override a newer playback request.
                let reservation = player.reserveMusicPlaybackIntent()
                Task { @MainActor in
                    guard let intent = player.claimMusicPlaybackIntent(reservation, queueEntryID: entryID) else {
                        return
                    }
                    await player.playFromQueue(entryID: entryID, intent: intent)
                }
            },
            playQueueEntryNext: { entryID in
                guard let anchor = queue.playNextAnchor(moving: entryID) else { return }
                player.reorderQueue(entryID: entryID, before: anchor)
            },
            removeQueueEntry: { entryID in
                player.removeFromQueue(entryIDs: [entryID])
            },
            moveQueueEntry: { entryID, beforeEntryID in
                guard let anchor = queue.dropAnchor(moving: entryID, onto: beforeEntryID) else { return }
                player.reorderQueue(entryID: entryID, before: anchor)
            },
            search: { query in self.updateSearch(query) },
            playSearchResult: { videoID in
                guard let song = self.searchSong(videoID) else { return }
                // Same path as the Search page: play it and build its radio queue.
                Task { await player.playWithRadio(song: song) }
            },
            playSearchResultNext: { videoID in
                guard let song = self.searchSong(videoID) else { return }
                SongActionsHelper.addToQueueNext(song, playerService: player)
            },
            addSearchResultToQueue: { videoID in
                guard let song = self.searchSong(videoID) else { return }
                SongActionsHelper.addToQueueLast(song, playerService: player)
            },
            selectSearchFilter: { filter in self.selectSearchFilter(filter) },
            setPrefersVideo: { prefersVideo in Self.setPrefersVideo(prefersVideo) }
        )
    }

    // MARK: Search

    private var searchResults: TuneNowPlayingSearchResults {
        guard let model = self.searchModel, !model.query.isEmpty else {
            return TuneNowPlayingSearchResults(filter: self.searchFilter)
        }
        let filter = TuneNowPlayingSearchFilter(model.selectedFilter) ?? .songs
        let source = filter == .videos ? model.results.videos : model.results.songs
        let items = source.prefix(TuneNowPlayingSearchResults.maximumItems).map { song in
            TuneNowPlayingSearchResults.Item(
                id: song.videoId,
                title: song.displayText.title,
                artist: song.displayText.artist,
                thumbnailURL: song.thumbnailURL,
                duration: song.duration
            )
        }
        let phase: TuneNowPlayingSearchResults.Phase = switch model.loadingState {
        // `search()` debounces before the model leaves idle; a typed query is already in flight.
        case .idle, .loading, .loadingMore: items.isEmpty ? .searching : .loaded
        case .loaded: .loaded
        case .error: .failed
        }
        return TuneNowPlayingSearchResults(items: Array(items), phase: phase, filter: filter)
    }

    private func selectSearchFilter(_ filter: TuneNowPlayingSearchFilter) {
        self.searchFilter = filter
        // Re-runs the current query against the new filter (the model's own filter path).
        self.searchModel?.selectedFilter = filter.searchFilter
    }

    private func updateSearch(_ text: String) {
        let query = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let model = self.searchModel ?? self.makeSearchModel() else { return }
        guard !query.isEmpty else {
            model.clear()
            return
        }
        guard query != model.query else { return }
        model.query = query
        model.search()
    }

    private func makeSearchModel() -> SearchViewModel? {
        guard let client = self.playerService.ytMusicClient else { return nil }
        let model = SearchViewModel(client: client)
        model.selectedFilter = self.searchFilter.searchFilter
        self.searchModel = model
        return model
    }

    /// A song or video result; both play through the music player like the Search page.
    private func searchSong(_ videoID: String) -> Song? {
        guard let results = self.searchModel?.results else { return nil }
        return results.songs.first { $0.videoId == videoID }
            ?? results.videos.first { $0.videoId == videoID }
    }

    /// Opens or closes the Up Next pane (QUEUE toggle, ⌥⌘U).
    static func toggleQueue() {
        let defaults = UserDefaults.standard
        let key = TuneTheme.NowPlaying.showsQueueKey
        defaults.set(!defaults.bool(forKey: key), forKey: key)
    }

    /// SONG · VIDEO from the menu shortcut (⇧⌘V while the view is up).
    static func toggleVideoPreference() {
        let key = TuneTheme.NowPlaying.prefersVideoKey
        Self.setPrefersVideo(!UserDefaults.standard.bool(forKey: key))
    }

    static func setPrefersVideo(_ prefersVideo: Bool) {
        UserDefaults.standard.set(prefersVideo, forKey: TuneTheme.NowPlaying.prefersVideoKey)
    }

    private static func close() {
        NowPlayingPresentation.shared.isPresented = false
    }
}
