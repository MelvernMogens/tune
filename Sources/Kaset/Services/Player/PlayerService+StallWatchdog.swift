import Foundation

// MARK: - Playback Stall Watchdog

/// Wires ``PlaybackStallWatchdog`` into live playback.
///
/// While Kaset intends audible Music playback, a low-frequency tick samples native
/// playback state and performs the watchdog's bounded recovery actions through the
/// same APIs user commands use. Any user pause, stop, or newer playback intent
/// disarms or supersedes recovery, so the watchdog never resumes media the listener
/// paused. The loop and the App Nap activity token exist only while armed.
///
/// There is no deinit cleanup: `PlayerService` lives for the app's lifetime, both
/// tasks hold the service weakly and end with it, and unit tests never enable the loop.
@MainActor
extension PlayerService {
    static let playbackStallWatchdogTickInterval: Duration = .seconds(2)
    /// Refresh YouTube Music's page activity clock about once a minute from native code
    /// too, since hidden-page JavaScript timers can be throttled.
    static let playbackPageActivityRefreshTicks = 30
    /// While paused without a Kaset pause intent, check for a visible idle prompt every 10 s.
    static let playbackIdlePromptProbeTicks = 5
    /// Spacing of the two media-clock samples taken before any recovery runs.
    static let playbackStallLivenessProbeDelay: Duration = .milliseconds(750)

    /// Whether Kaset itself intends audible Music playback. Explicit pause, stop,
    /// end of queue, and deferred restores all disarm the watchdog.
    var isPlaybackStallWatchdogArmed: Bool {
        guard self.shouldResumeAfterInterruption,
              !self.isExplicitPauseIntentActive,
              !self.isStoppingPlayback,
              !self.isPendingRestoredLoadDeferred,
              self.currentTrack != nil || self.pendingPlayVideoId != nil
        else { return false }
        switch self.state {
        case .loading, .playing, .paused, .buffering:
            return true
        case .idle, .ended, .error:
            return false
        }
    }

    /// Identifies one playback attempt: queue entry, video, and native occurrence.
    /// Replays and reloads mint a new native generation and therefore a new key.
    var playbackStallTrackKey: String? {
        guard let videoId = self.currentTrack?.videoId ?? self.pendingPlayVideoId else { return nil }
        let entry = self.activePlaybackQueueEntryID?.uuidString ?? "detached"
        return "\(entry)|\(videoId)|\(self.currentNativeMusicPlaybackGeneration)"
    }

    /// Whether the queue can continue after the current track. Mirrors the
    /// track-end path, including repeat-one replay of detached playback.
    var playbackStallHasSuccessor: Bool {
        if self.repeatMode == .one, self.currentTrack != nil {
            return true
        }
        return self.canAdvanceNativeQueueAfterTrackEnd
    }

    func makePlaybackStallObservation(now: ContinuousClock.Instant) -> PlaybackStallWatchdog.Observation {
        PlaybackStallWatchdog.Observation(
            now: now,
            wantsPlayback: self.isPlaybackStallWatchdogArmed,
            trackKey: self.playbackStallTrackKey,
            isTransitioning: self.state == .loading
                || self.pendingNativeQueueAdvance != nil
                || self.isRestoringPlaybackSession,
            isPlaying: self.state == .playing,
            progress: self.progress.isFinite ? max(self.progress, 0) : 0,
            duration: self.duration.isFinite ? max(self.duration, 0) : 0,
            isShowingAd: self.isShowingAd,
            lastAdvertisementProgressAt: self.lastAdPlaybackProgressAt,
            hasSuccessor: self.playbackStallHasSuccessor,
            isAdvanceInFlight: self.isFetchingMoreMixSongs || self.nativeQueueMaintenanceTask != nil,
            isExternalPlaybackRoute: self.isAirPlayConnected,
            isMediaUserControllable: self.showVideo || self.showMiniPlayer || self.isNowPlayingVideoVisible,
            isNetworkAvailable: self.isNetworkAvailableForPlaybackRecovery()
        )
    }

    // MARK: Tick

    /// Samples playback once and starts a recovery if the watchdog asks for one.
    /// Ticks are skipped while a recovery is still running.
    @discardableResult
    func evaluatePlaybackStallWatchdog(now: ContinuousClock.Instant = .now) -> PlaybackStallWatchdog.Action {
        guard self.playbackStallRecoveryTask == nil else { return .none }
        let observation = self.makePlaybackStallObservation(now: now)
        let action = self.playbackStallWatchdog.evaluate(observation)
        guard action != .none else { return .none }

        let trackKey = observation.trackKey
        let intentGeneration = self.musicPlaybackIntentGeneration
        self.logger.warning(
            "Playback stall watchdog: \(String(describing: action)) for \(trackKey ?? "unknown") at \(observation.progress)/\(observation.duration)s"
        )
        self.playbackStallRecoveryTask = Task { @MainActor [weak self] in
            guard let self else { return }
            defer { self.playbackStallRecoveryTask = nil }
            // Stand down if the listener acted, or playback moved on, after the decision.
            let isStillCurrent: @MainActor () -> Bool = {
                self.isPlaybackStallWatchdogArmed
                    && self.playbackStallTrackKey == trackKey
                    && self.musicPlaybackIntentGeneration == intentGeneration
            }
            guard isStillCurrent() else {
                self.logger.debug("Playback stall watchdog: recovery superseded before it ran")
                return
            }
            // Native state can look stalled when the bridge is (rejected or throttled
            // observer updates) while the media itself plays. Never interrupt media
            // whose own clock is still moving.
            let isMediaAlive = await self.isCurrentMusicMediaClockAdvancing()
            guard isStillCurrent() else { return }
            if isMediaAlive {
                self.logger.info("Playback stall watchdog: media clock is moving; skipping recovery")
                return
            }
            if let performPlaybackStallRecovery = self.performPlaybackStallRecovery {
                await performPlaybackStallRecovery(action)
            } else {
                await self.performPlaybackStallAction(action)
            }
        }
        return action
    }

    /// Samples the live media clock twice. True only when the current target's
    /// media demonstrably advanced, so a missing WebView or snapshot never blocks recovery.
    func isCurrentMusicMediaClockAdvancing() async -> Bool {
        guard let videoId = self.currentTrack?.videoId ?? self.pendingPlayVideoId,
              let first = await self.currentMusicPlaybackSnapshot(),
              first.videoId == videoId
        else { return false }
        do {
            try await Task.sleep(for: Self.playbackStallLivenessProbeDelay)
        } catch {
            return false
        }
        guard let second = await self.currentMusicPlaybackSnapshot(),
              second.videoId == videoId
        else { return false }
        return second.progress - first.progress >= 0.25
    }

    // MARK: Lifecycle

    /// Starts or stops the tick loop and App Nap token as playback intent changes.
    func observePlaybackStallWatchdogActivity() {
        withObservationTracking {
            self.updatePlaybackStallWatchdogActivity()
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                self?.observePlaybackStallWatchdogActivity()
            }
        }
    }

    func updatePlaybackStallWatchdogActivity() {
        let isArmed = self.isPlaybackStallWatchdogArmed
        if isArmed {
            self.startPlaybackStallWatchdogLoop()
        } else {
            self.playbackStallWatchdogTask?.cancel()
            self.playbackStallWatchdogTask = nil
            self.playbackStallWatchdog.reset()
        }

        let isActivelyPlaying = switch self.state {
        case .loading, .playing, .buffering: true
        case .idle, .paused, .ended, .error: false
        }
        self.setPlaybackActivityHeld(isArmed && isActivelyPlaying)
    }

    private func startPlaybackStallWatchdogLoop() {
        guard self.playbackStallWatchdogTask == nil else { return }
        self.playbackStallWatchdogTask = Task { @MainActor [weak self] in
            var tick = 0
            while !Task.isCancelled {
                do {
                    try await Task.sleep(for: Self.playbackStallWatchdogTickInterval)
                } catch {
                    return
                }
                guard let self else { return }
                tick &+= 1
                if self.isPlaybackStallWatchdogArmed {
                    // A pause Kaset did not request may be YouTube Music's idle prompt.
                    // The page-side handler only acts when that prompt is visible, so
                    // probing more often here never resumes a pause from elsewhere.
                    let interval = self.state == .paused
                        ? Self.playbackIdlePromptProbeTicks
                        : Self.playbackPageActivityRefreshTicks
                    if tick % interval == 0 {
                        SingletonPlayerWebView.shared.refreshPageActivity()
                    }
                }
                self.evaluatePlaybackStallWatchdog()
            }
        }
    }

    /// Holds a user-initiated activity so App Nap and timer coalescing cannot starve
    /// track transitions. It deliberately allows idle system sleep.
    private func setPlaybackActivityHeld(_ isHeld: Bool) {
        if isHeld {
            guard self.playbackActivityToken == nil else { return }
            self.playbackActivityToken = ProcessInfo.processInfo.beginActivity(
                options: [.userInitiatedAllowingIdleSystemSleep],
                reason: "Tune music playback"
            )
        } else if let token = self.playbackActivityToken {
            ProcessInfo.processInfo.endActivity(token)
            self.playbackActivityToken = nil
        }
    }

    // MARK: Actions

    func performPlaybackStallAction(_ action: PlaybackStallWatchdog.Action) async {
        switch action {
        case .none:
            return
        case let .resumeMedia(kind):
            self.logger.info("Playback stall watchdog: resuming media (\(kind.rawValue))")
            SingletonPlayerWebView.shared.refreshPageActivity()
            await self.resume(intent: self.beginMusicPlaybackIntent())
        case let .retryViaRouter(kind):
            self.logger.info("Playback stall watchdog: retrying target via router (\(kind.rawValue))")
            await self.reloadPlaybackTargetAfterStall(strategy: .preferRouterWhenSameVideoId, kind: kind)
        case let .reloadFullPage(kind):
            self.logger.info("Playback stall watchdog: reloading target document (\(kind.rawValue))")
            await self.reloadPlaybackTargetAfterStall(strategy: .forceFullPageWhenSameVideoId, kind: kind)
        case let .advance(kind):
            self.logger.info("Playback stall watchdog: advancing queue (\(kind.rawValue))")
            await self.advancePastPlaybackStall(kind: kind)
        case let .giveUp(kind):
            self.logger.warning("Playback stall watchdog: giving up after repeated recoveries (\(kind.rawValue)); pausing")
            await self.pause(intent: self.beginMusicPlaybackIntent())
        }
    }

    /// Restores mid-track position on a reload so recovery does not restart the song.
    private func playbackStallRestoreClock() -> MusicPlaybackRestoreClock? {
        let configuration = self.playbackStallWatchdog.configuration
        guard !self.isShowingAd,
              self.progress.isFinite,
              self.progress > configuration.unstartedProgressCeiling,
              self.duration <= 0 || self.progress < self.duration - configuration.nearEndTolerance
        else { return nil }
        return MusicPlaybackRestoreClock(progress: self.progress, duration: self.duration)
    }

    private func reloadPlaybackTargetAfterStall(
        strategy: SingletonPlayerWebView.VideoLoadStrategy,
        kind: PlaybackStallWatchdog.StallKind,
        restoresPosition: Bool = true
    ) async {
        let restoreClock = restoresPosition ? self.playbackStallRestoreClock() : nil
        let intent = self.beginMusicPlaybackIntent()
        if self.pendingNativeQueueAdvance != nil {
            // A stuck native handoff falls back to deterministic loading of its target.
            await self.resolvePendingNativeQueueAdvanceForExplicitTerminal(
                intent: intent,
                reason: "playback stall watchdog (\(kind.rawValue))"
            )
            return
        }
        if self.activePlaybackOwnsCurrentQueueEntry, self.queueEntries.indices.contains(self.currentIndex) {
            await self.loadQueueSongForNavigation(
                at: self.currentIndex,
                webLoadStrategy: strategy,
                restoreClock: restoreClock,
                intent: intent
            )
            return
        }
        guard let song = self.currentTrack else {
            self.logger.debug("Playback stall watchdog: no reloadable target")
            return
        }
        await self.play(
            song: song,
            webLoadStrategy: strategy,
            episode: self.currentEpisode,
            queueEntryID: self.activePlaybackQueueEntryID,
            restoreClock: restoreClock,
            bypassesSamePlaybackFastPath: true,
            intent: intent
        )
    }

    private func advancePastPlaybackStall(kind: PlaybackStallWatchdog.StallKind) async {
        if self.pendingNativeQueueAdvance != nil || self.repeatMode == .one {
            // Repeat-one "advances" by replaying the current song from the start.
            await self.reloadPlaybackTargetAfterStall(
                strategy: .forceFullPageWhenSameVideoId,
                kind: kind,
                restoresPosition: false
            )
            return
        }
        self.invalidatePendingPlaybackSelectionRequests()
        let intent = self.beginMusicPlaybackIntent()
        let didAdvance = await self.performNextNavigation(intent: intent)
        guard !didAdvance, self.acceptsMusicPlaybackIntent(intent) else { return }
        if kind == .endedWithoutAdvance {
            await self.finishPlaybackAfterFailedQueueAdvance(
                reason: "playback stall watchdog could not advance"
            )
        }
    }
}
