import Foundation
import Observation

// MARK: - TuneNowPlayingLyricsController

/// Loads lyrics for the fullscreen Now Playing view and keeps the WebView's line-boundary
/// poll running while it shows synced lyrics.
///
/// Mirrors `LyricsView`'s load path (synced providers first, then the plain-lyrics API) so the
/// overlay works when the lyrics sidebar is closed. Shares `SyncedLyricsService` with the sidebar;
/// the service's own request generation drops stale fetches when both ask at once.
@MainActor
@Observable
final class TuneNowPlayingLyricsController {
    /// Video whose lyrics `SyncedLyricsService.currentLyrics` currently describes, per this controller.
    private(set) var loadedVideoId: String?
    private(set) var isLoadingFallback = false

    /// Fetches lyrics for `track` unless they're already loaded for it.
    func load(
        track: Song,
        service: SyncedLyricsService,
        client: (any YTMusicClientProtocol)?,
        playerService: PlayerService
    ) async {
        let videoId = track.videoId
        guard self.loadedVideoId != videoId else { return }
        self.loadedVideoId = videoId
        self.isLoadingFallback = false

        let info = LyricsSearchInfo(
            title: track.title,
            artist: track.artistsDisplay,
            album: track.album?.title,
            duration: track.duration,
            videoId: videoId
        )

        if SettingsManager.shared.syncedLyricsEnabled {
            await service.fetchLyrics(for: info)
        } else {
            service.currentLyrics = .unavailable
            service.activeProvider = nil
        }

        guard self.isCurrent(videoId, playerService: playerService) else { return }
        guard case .unavailable = service.currentLyrics, let client else { return }

        self.isLoadingFallback = true
        defer {
            if self.loadedVideoId == videoId {
                self.isLoadingFallback = false
            }
        }
        do {
            let plain = try await client.getLyrics(videoId: videoId)
            if self.isCurrent(videoId, playerService: playerService) {
                service.fallbackToPlainLyrics(plain, videoId: videoId)
            }
        } catch {
            DiagnosticsLogger.api.error("Now Playing: plain lyrics fallback failed: \(error.localizedDescription)")
        }
    }

    /// The lyrics state to render for `videoId`.
    func displayState(
        for videoId: String,
        service: SyncedLyricsService,
        playerService: PlayerService
    ) -> TuneNowPlayingLyrics {
        guard self.loadedVideoId == videoId, !service.isLoading, !self.isLoadingFallback else {
            return .loading
        }
        switch service.currentLyrics {
        case let .synced(synced) where !synced.isEmpty:
            let position = Self.linePosition(
                in: synced,
                bridgeLineIndex: playerService.currentLyricsLineIndex,
                bridgeTimeMs: playerService.currentLyricsDisplayTimeMs,
                progress: playerService.progress,
                isPlaying: playerService.isPlaying
            )
            return .synced(synced, currentLineIndex: position.lineIndex, displayTimeMs: position.timeMs)
        case let .plain(plain) where plain.isAvailable:
            return .plain(plain.lines)
        default:
            return .unavailable
        }
    }

    /// The current line and time to render.
    ///
    /// While playing, the WebView bridge's line-boundary updates are authoritative (they're
    /// precise to the line edge). The bridge only reports *changes*, though: paused, just
    /// opened, or right after the poll restarts it has nothing to say, and a seek while
    /// paused crosses no boundary it watches. In those cases the line comes from the
    /// player's own position, so the line at the playhead is lit even while paused.
    /// A nil `lineIndex` with a time means a real gap between lines.
    static func linePosition(
        in lyrics: SyncedLyrics,
        bridgeLineIndex: Int?,
        bridgeTimeMs: Int?,
        progress: TimeInterval,
        isPlaying: Bool
    ) -> (lineIndex: Int?, timeMs: Int?) {
        let bridgeKnows = bridgeLineIndex.map { lyrics.lines.indices.contains($0) } ?? (bridgeTimeMs != nil)
        if isPlaying, bridgeKnows {
            return (bridgeLineIndex, bridgeTimeMs)
        }
        guard progress.isFinite, progress >= 0 else {
            return bridgeKnows ? (bridgeLineIndex, bridgeTimeMs) : (nil, nil)
        }
        let timeMs = Int((progress * 1000).rounded())
        return (lyrics.currentLineIndex(at: timeMs), timeMs)
    }

    // MARK: Line-boundary poll

    /// Starts or stops the WebView line poll to match `result` (same contract as `LyricsView`).
    func updatePolling(for result: LyricResult, playerService: PlayerService) {
        if case let .synced(synced) = result {
            playerService.currentLyricsLineIndex = nil
            playerService.currentLyricsDisplayTimeMs = nil
            SingletonPlayerWebView.shared.startLyricsPoll(lineRanges: synced.bridgeLineRanges)
        } else {
            SingletonPlayerWebView.shared.stopLyricsPoll()
            playerService.currentLyricsLineIndex = nil
            playerService.currentLyricsDisplayTimeMs = nil
        }
    }

    /// Restarts the poll if something else stopped it while synced lyrics are on screen
    /// (closing the lyrics sidebar stops the shared poll in `LyricsView.onDisappear`).
    func ensurePolling(for result: LyricResult) {
        guard case let .synced(synced) = result, !SingletonPlayerWebView.shared.isLyricsPollActive else { return }
        SingletonPlayerWebView.shared.startLyricsPoll(lineRanges: synced.bridgeLineRanges)
    }

    /// Stops the poll when the overlay goes away, unless the lyrics sidebar still needs it.
    func stopPolling(playerService: PlayerService) {
        guard !playerService.showLyrics else { return }
        SingletonPlayerWebView.shared.stopLyricsPoll()
    }

    private func isCurrent(_ videoId: String, playerService: PlayerService) -> Bool {
        self.loadedVideoId == videoId && playerService.currentTrack?.videoId == videoId
    }
}
