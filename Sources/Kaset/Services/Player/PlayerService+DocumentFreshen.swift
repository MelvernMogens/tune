import Foundation

// MARK: - Playback Document Freshen

/// Wires ``PlaybackDocumentFreshenPolicy`` into live playback.
///
/// While the listener keeps playback explicitly paused, a single sleeping task waits out
/// the policy's pause and page-age thresholds. If nothing could be interrupted by then,
/// playback is moved into the deferred-restore state a cold launch uses (track selected,
/// position saved, nothing loaded) and the playback WebView is rebuilt inert. That
/// releases the long-lived YouTube Music page — typically the whole WebContent process —
/// while it is silent. The next Play loads the track into a fresh page and seeks back
/// through the existing restored-session path.
///
/// Any change that ends the explicit pause (play, track change, video, deferral)
/// cancels the task, so a freshen can never land during playback. There is no deinit
/// cleanup: the task holds the service weakly and unit tests never enable the loop.
@MainActor
extension PlayerService {
    /// Observable state that makes a freshen possible; time is handled by the task.
    var isPlaybackDocumentFreshenCandidate: Bool {
        self.state == .paused
            && self.isExplicitPauseIntentActive
            && self.currentTrack != nil
            && !self.isPendingRestoredLoadDeferred
    }

    func makePlaybackDocumentFreshenSnapshot(
        pausedDuration: Duration
    ) -> PlaybackDocumentFreshenPolicy.Snapshot {
        PlaybackDocumentFreshenPolicy.Snapshot(
            isExplicitlyPaused: self.state == .paused && self.isExplicitPauseIntentActive,
            pausedDuration: pausedDuration,
            documentAge: self.playbackDocumentAge(),
            hasCurrentTrack: self.currentTrack != nil,
            isLoadDeferred: self.isPendingRestoredLoadDeferred,
            isTransitioning: self.isRestoringPlaybackSession
                || self.pendingNativeQueueAdvance != nil
                || self.nativeQueueMaintenanceTask != nil
                || self.isFetchingMoreMixSongs
                || self.playbackStallRecoveryTask != nil,
            isVideoVisible: self.showVideo || self.showMiniPlayer || self.isNowPlayingVideoVisible,
            isAirPlayConnected: self.isAirPlayConnected,
            isShowingAd: self.isShowingAd
        )
    }

    // MARK: Lifecycle

    /// Starts or cancels the freshen task as the explicit-pause state changes.
    func observePlaybackDocumentFreshening() {
        withObservationTracking {
            self.updatePlaybackDocumentFreshenSchedule()
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                self?.observePlaybackDocumentFreshening()
            }
        }
    }

    func updatePlaybackDocumentFreshenSchedule() {
        guard self.isPlaybackDocumentFreshenCandidate else {
            self.playbackDocumentFreshenTask?.cancel()
            self.playbackDocumentFreshenTask = nil
            return
        }
        guard self.playbackDocumentFreshenTask == nil else { return }

        let pausedAt = ContinuousClock.now
        let initialDelay = self.playbackDocumentFreshenPolicy.minimumPausedDuration
        self.playbackDocumentFreshenTask = Task { @MainActor [weak self] in
            var delay = initialDelay
            while !Task.isCancelled {
                do {
                    try await Task.sleep(for: delay)
                } catch {
                    return
                }
                guard let self, !Task.isCancelled else { return }
                let snapshot = self.makePlaybackDocumentFreshenSnapshot(pausedDuration: .now - pausedAt)
                switch self.playbackDocumentFreshenPolicy.decide(snapshot) {
                case .freshen:
                    self.playbackDocumentFreshenTask = nil
                    self.freshenPlaybackDocument()
                    return
                case let .wait(remaining):
                    delay = max(remaining, .seconds(30))
                case .ineligible:
                    // Transient blockers (an ad sample, a queue handoff) clear on their own.
                    delay = .seconds(60)
                }
            }
        }
    }

    // MARK: Freshen

    /// Moves an explicitly paused session into the deferred-restore state and rebuilds
    /// the playback WebView inert. Returns whether it did.
    @discardableResult
    func freshenPlaybackDocument() -> Bool {
        guard self.isPlaybackDocumentFreshenCandidate,
              self.canRebuildPlaybackDocument()
        else { return false }

        let pageAge = self.playbackDocumentAge().map { Int($0.components.seconds / 60) } ?? -1
        self.logger.info("Freshening playback page after a long pause (page age \(pageAge) min)")

        // State tied to the old document: YouTube Music's native Up Next injection,
        // pending handoffs and navigation recovery. Kaset's own queue is untouched.
        self.clearQueueNavigationRecovery()
        self.clearWebQueueInjectionState()
        self.clearPendingNativeQueueAdvance()
        // Same paused, retryable state a cold launch restores: the next explicit Play
        // full-loads the current track and seeks back to the saved position.
        self.deferRestoredPlaybackAfterNavigationFailure()
        self.rebuildPlaybackDocument()
        return true
    }
}
