import Foundation

// MARK: - Song Transitions (user transport fades)

/// Wraps user-initiated transport commands in the optional short fades from
/// Settings → Music → Song Transitions. Internal pauses and navigations (track
/// end, watchdog recovery, arbitration, queue corrections) never go through here.
@MainActor
extension PlayerService {
    /// One gate per process: there is exactly one music playback WebView.
    static let songTransitionGate = SongTransitionTransportGate { command in
        SingletonPlayerWebView.shared.sendSongTransitionCommand(command)
    }

    /// Whether transport fades are enabled and the page is in a state where a
    /// fade is audible and safe (not loading, restoring, in an ad, or on AirPlay).
    private var canApplyTransportFade: Bool {
        SettingsManager.shared.fadesTransportControls
            && SingletonPlayerWebView.shared.webView != nil
            && !self.isShowingAd
            && !self.isAirPlayConnected
            && !self.isRestoringPlaybackSession
            && !self.isPendingRestoredLoadDeferred
            && self.pendingRestoredSeek == nil
            && self.currentEpisode?.isLive != true
    }

    /// Music is audibly playing, so a fade-out before pause/skip is meaningful.
    var canFadeOutForUserTransport: Bool {
        self.canApplyTransportFade && self.state == .playing
    }

    /// Music is paused, so a resume can start from silence and ramp up.
    var canFadeInForUserResume: Bool {
        self.canApplyTransportFade && self.state == .paused && !self.isAwaitingPlaybackConfirmation
    }

    /// Runs `body` (a pause or skip) after the optional transport fade-out.
    func performUserTransport(
        _ kind: SongTransitionTransportGate.Kind,
        quickOverlap: SongTransitionTransportGate.QuickOverlap? = nil,
        _ body: @MainActor () async -> Void
    ) async {
        await Self.songTransitionGate.perform(
            kind,
            canFade: self.canFadeOutForUserTransport,
            quickOverlap: quickOverlap,
            intentGeneration: { [weak self] in self?.currentMusicPlaybackIntent.generation ?? 0 },
            body
        )
    }

    /// Runs `body` (a resume) after arming the optional transport fade-in.
    func performUserResume(_ body: @MainActor () async -> Void) async {
        Self.songTransitionGate.prepareResume(canFade: self.canFadeInForUserResume)
        await body()
    }

    /// Runs a play/pause toggle behind whichever fade matches what it will do.
    func performUserPlayPause(_ body: @MainActor () async -> Void) async {
        if self.canFadeInForUserResume {
            await self.performUserResume(body)
            return
        }
        // Mirrors `playPause(intent:)`: a playing, confirmed track pauses.
        let willPause = self.state == .playing && self.shouldResumeAfterInterruption
        if willPause {
            await self.performUserTransport(.pause, body)
        } else {
            await body()
        }
    }
}
