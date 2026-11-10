import Foundation
import Testing
@testable import Kaset

// MARK: - PlaybackStallWatchdogTests

@Suite(.tags(.service))
struct PlaybackStallWatchdogTests {
    private let start = ContinuousClock.now

    private func at(_ seconds: Double) -> ContinuousClock.Instant {
        self.start.advanced(by: .milliseconds(Int(seconds * 1000)))
    }

    private func observation(
        at seconds: Double,
        wantsPlayback: Bool = true,
        trackKey: String? = "entry|v1|1",
        isTransitioning: Bool = false,
        isPlaying: Bool = false,
        progress: TimeInterval = 0,
        duration: TimeInterval = 180,
        isShowingAd: Bool = false,
        lastAdvertisementProgressAt: Double? = nil,
        hasSuccessor: Bool = true,
        isAdvanceInFlight: Bool = false,
        isExternalPlaybackRoute: Bool = false,
        isMediaUserControllable: Bool = false,
        isNetworkAvailable: Bool = true
    ) -> PlaybackStallWatchdog.Observation {
        PlaybackStallWatchdog.Observation(
            now: self.at(seconds),
            wantsPlayback: wantsPlayback,
            trackKey: trackKey,
            isTransitioning: isTransitioning,
            isPlaying: isPlaying,
            progress: progress,
            duration: duration,
            isShowingAd: isShowingAd,
            lastAdvertisementProgressAt: lastAdvertisementProgressAt.map { self.at($0) },
            hasSuccessor: hasSuccessor,
            isAdvanceInFlight: isAdvanceInFlight,
            isExternalPlaybackRoute: isExternalPlaybackRoute,
            isMediaUserControllable: isMediaUserControllable,
            isNetworkAvailable: isNetworkAvailable
        )
    }

    // MARK: Stall kinds

    @Test("Transition stall retries via the router only after its timeout")
    func transitionTimesOutToRouterRetry() {
        var watchdog = PlaybackStallWatchdog()
        #expect(watchdog.evaluate(self.observation(at: 0, isTransitioning: true)) == .none)
        #expect(watchdog.evaluate(self.observation(at: 29, isTransitioning: true)) == .none)
        #expect(watchdog.evaluate(self.observation(at: 30, isTransitioning: true)) == .retryViaRouter(.transition))
        #expect(watchdog.recoveriesWithoutProgress == 1)
    }

    @Test("Unstarted target is resumed after its timeout")
    func unstartedTimesOutToResume() {
        var watchdog = PlaybackStallWatchdog()
        #expect(watchdog.evaluate(self.observation(at: 0)) == .none)
        #expect(watchdog.evaluate(self.observation(at: 9)) == .none)
        #expect(watchdog.evaluate(self.observation(at: 10)) == .resumeMedia(.unstarted))
    }

    @Test("A paused track past its opening seconds is never resumed")
    func midTrackPauseIsLeftAlone() {
        var watchdog = PlaybackStallWatchdog()
        for second in stride(from: 0.0, through: 120, by: 2) {
            #expect(watchdog.evaluate(self.observation(at: second, progress: 60)) == .none)
        }
    }

    @Test("Finished track with a successor advances after its timeout")
    func endedWithoutAdvanceAdvances() {
        var watchdog = PlaybackStallWatchdog()
        #expect(watchdog.evaluate(self.observation(at: 0, isPlaying: true, progress: 179.5)) == .none)
        #expect(watchdog.evaluate(self.observation(at: 5, isPlaying: true, progress: 179.5)) == .none)
        #expect(watchdog.evaluate(self.observation(at: 6, isPlaying: true, progress: 179.5)) == .advance(.endedWithoutAdvance))
    }

    @Test("Finished track at the end of a non-repeating queue is left alone")
    func endedWithoutSuccessorIsLeftAlone() {
        var watchdog = PlaybackStallWatchdog()
        for second in stride(from: 0.0, through: 120, by: 2) {
            #expect(watchdog.evaluate(self.observation(at: second, progress: 180, hasSuccessor: false)) == .none)
        }
    }

    @Test("Kaset's own in-flight advance gets the longer transition budget")
    func advanceInFlightWaitsLonger() {
        var watchdog = PlaybackStallWatchdog()
        _ = watchdog.evaluate(self.observation(at: 0, progress: 180, isAdvanceInFlight: true))
        #expect(watchdog.evaluate(self.observation(at: 10, progress: 180, isAdvanceInFlight: true)) == .none)
        #expect(watchdog.evaluate(self.observation(at: 30, progress: 180, isAdvanceInFlight: true)) == .advance(.endedWithoutAdvance))
    }

    @Test("Playing with a frozen clock resumes, and never on an external route")
    func frozenProgressResumesUnlessExternal() {
        var watchdog = PlaybackStallWatchdog()
        _ = watchdog.evaluate(self.observation(at: 0, isPlaying: true, progress: 42))
        #expect(watchdog.evaluate(self.observation(at: 24, isPlaying: true, progress: 42)) == .none)
        #expect(watchdog.evaluate(self.observation(at: 25, isPlaying: true, progress: 42)) == .resumeMedia(.frozenProgress))

        var airPlay = PlaybackStallWatchdog()
        for second in stride(from: 0.0, through: 120, by: 2) {
            let sample = self.observation(at: second, isPlaying: true, progress: 42, isExternalPlaybackRoute: true)
            #expect(airPlay.evaluate(sample) == .none)
        }
    }

    @Test("Visible page media controls (video window) suppress every recovery")
    func userControllableMediaIsLeftAlone() {
        let samples: [(Double) -> PlaybackStallWatchdog.Observation] = [
            { self.observation(at: $0, isMediaUserControllable: true) },
            { self.observation(at: $0, isPlaying: true, progress: 10, isMediaUserControllable: true) },
            { self.observation(at: $0, isTransitioning: true, isMediaUserControllable: true) },
            { self.observation(at: $0, progress: 179.5, isMediaUserControllable: true) },
        ]
        for sample in samples {
            var watchdog = PlaybackStallWatchdog()
            for second in stride(from: 0.0, through: 120, by: 2) {
                #expect(watchdog.evaluate(sample(second)) == .none)
            }
            #expect(watchdog.recoveriesWithoutProgress == 0)
        }
    }

    @Test("AirPlay only trusts the transition budget and finished tracks")
    func externalRouteLimitsRecovery() {
        var unstarted = PlaybackStallWatchdog()
        for second in stride(from: 0.0, through: 120, by: 2) {
            #expect(unstarted.evaluate(self.observation(at: second, isExternalPlaybackRoute: true)) == .none)
        }
        var ended = PlaybackStallWatchdog()
        _ = ended.evaluate(self.observation(at: 0, progress: 179.5, isExternalPlaybackRoute: true))
        let action = ended.evaluate(self.observation(at: 6, progress: 179.5, isExternalPlaybackRoute: true))
        #expect(action == .advance(.endedWithoutAdvance))
    }

    // MARK: Budget, cooldown, reset

    @Test("Forward progress resets the recovery budget")
    func progressResetsBudget() {
        var watchdog = PlaybackStallWatchdog()
        _ = watchdog.evaluate(self.observation(at: 0))
        #expect(watchdog.evaluate(self.observation(at: 10)) == .resumeMedia(.unstarted))
        #expect(watchdog.recoveriesWithoutProgress == 1)

        _ = watchdog.evaluate(self.observation(at: 12, isPlaying: true, progress: 1))
        #expect(watchdog.evaluate(self.observation(at: 14, isPlaying: true, progress: 3)) == .none)
        #expect(watchdog.recoveriesWithoutProgress == 0)
        #expect(watchdog.trackHasStarted)
        #expect(watchdog.cooldownUntil == nil)
    }

    @Test("Losing playback intent (user pause) disarms and resets all state")
    func userPauseResets() {
        var watchdog = PlaybackStallWatchdog()
        _ = watchdog.evaluate(self.observation(at: 0))
        _ = watchdog.evaluate(self.observation(at: 10))
        #expect(watchdog.recoveriesWithoutProgress == 1)

        #expect(watchdog.evaluate(self.observation(at: 11, wantsPlayback: false)) == .none)
        #expect(watchdog.recoveriesWithoutProgress == 0)
        #expect(watchdog.stallKind == nil)
        #expect(watchdog.cooldownUntil == nil)
        #expect(watchdog.trackKey == nil)

        for second in stride(from: 12.0, through: 200, by: 2) {
            #expect(watchdog.evaluate(self.observation(at: second, wantsPlayback: false)) == .none)
        }
    }

    @Test("Recovery cooldown spaces consecutive actions")
    func cooldownRespected() {
        var watchdog = PlaybackStallWatchdog()
        _ = watchdog.evaluate(self.observation(at: 0))
        #expect(watchdog.evaluate(self.observation(at: 10)) == .resumeMedia(.unstarted))
        // The unstarted timeout (10 s) elapses again before the 20 s cooldown.
        #expect(watchdog.evaluate(self.observation(at: 20)) == .none)
        #expect(watchdog.evaluate(self.observation(at: 29)) == .none)
        #expect(watchdog.evaluate(self.observation(at: 30)) == .retryViaRouter(.unstarted))
    }

    @Test("Gives up once the recovery budget is spent, then stays quiet")
    func givesUpAfterMaxRecoveries() {
        var watchdog = PlaybackStallWatchdog()
        var actions: [PlaybackStallWatchdog.Action] = []
        for second in stride(from: 0.0, through: 400, by: 1) {
            let action = watchdog.evaluate(self.observation(at: second, isPlaying: true, progress: 42))
            if action != .none { actions.append(action) }
        }
        #expect(actions == [
            .resumeMedia(.frozenProgress),
            .reloadFullPage(.frozenProgress),
            .reloadFullPage(.frozenProgress),
            .reloadFullPage(.frozenProgress),
            .reloadFullPage(.frozenProgress),
            .giveUp(.frozenProgress),
        ])
        #expect(watchdog.hasGivenUp)
    }

    @Test("A live advertisement is not a stall; a stuck one is")
    func advertisementGrace() {
        var watchdog = PlaybackStallWatchdog()
        for second in stride(from: 0.0, through: 120, by: 2) {
            let sample = self.observation(
                at: second,
                isTransitioning: true,
                isShowingAd: true,
                lastAdvertisementProgressAt: second - 1
            )
            #expect(watchdog.evaluate(sample) == .none)
        }

        var stuck = PlaybackStallWatchdog()
        _ = stuck.evaluate(self.observation(at: 0, isTransitioning: true, isShowingAd: true, lastAdvertisementProgressAt: -30))
        let action = stuck.evaluate(
            self.observation(at: 30, isTransitioning: true, isShowingAd: true, lastAdvertisementProgressAt: -30)
        )
        #expect(action == .retryViaRouter(.transition))
    }

    @Test("A new target restarts the stall window but keeps the recovery level")
    func newTrackKeyKeepsRecoveryLevel() {
        var watchdog = PlaybackStallWatchdog()
        _ = watchdog.evaluate(self.observation(at: 0, isTransitioning: true))
        #expect(watchdog.evaluate(self.observation(at: 30, isTransitioning: true)) == .retryViaRouter(.transition))

        _ = watchdog.evaluate(self.observation(at: 31, trackKey: "entry|v1|2", isTransitioning: true))
        #expect(watchdog.recoveriesWithoutProgress == 1)
        #expect(watchdog.evaluate(self.observation(at: 60, trackKey: "entry|v1|2", isTransitioning: true)) == .none)
        #expect(
            watchdog.evaluate(self.observation(at: 61, trackKey: "entry|v1|2", isTransitioning: true))
                == .reloadFullPage(.transition)
        )
    }

    @Test("No recovery is attempted while offline; the window restarts on reconnect")
    func offlineDefersRecovery() {
        var watchdog = PlaybackStallWatchdog()
        for second in stride(from: 0.0, through: 120, by: 2) {
            let sample = self.observation(at: second, isTransitioning: true, isNetworkAvailable: false)
            #expect(watchdog.evaluate(sample) == .none)
        }
        #expect(watchdog.recoveriesWithoutProgress == 0)
        _ = watchdog.evaluate(self.observation(at: 122, isTransitioning: true))
        #expect(watchdog.evaluate(self.observation(at: 140, isTransitioning: true)) == .none)
        #expect(watchdog.evaluate(self.observation(at: 152, isTransitioning: true)) == .retryViaRouter(.transition))
    }

    // MARK: Ladder

    @Test("Load-failure ladders skip at most once per no-progress streak")
    func loadFailureLadders() {
        let transition = (0 ..< 6).map {
            PlaybackStallWatchdog.recoveryAction(for: .transition, level: $0, hasSuccessor: true)
        }
        #expect(transition == [
            .retryViaRouter(.transition),
            .reloadFullPage(.transition),
            .advance(.transition),
            .reloadFullPage(.transition),
            .reloadFullPage(.transition),
            .reloadFullPage(.transition),
        ])
        let unstarted = (0 ..< 5).map {
            PlaybackStallWatchdog.recoveryAction(for: .unstarted, level: $0, hasSuccessor: false)
        }
        #expect(unstarted == [
            .resumeMedia(.unstarted),
            .retryViaRouter(.unstarted),
            .reloadFullPage(.unstarted),
            .reloadFullPage(.unstarted),
            .reloadFullPage(.unstarted),
        ])
    }

    @Test("Finished tracks only advance; frozen clocks never skip")
    func endedAndFrozenLadders() {
        for level in 0 ..< 6 {
            #expect(
                PlaybackStallWatchdog.recoveryAction(for: .endedWithoutAdvance, level: level, hasSuccessor: true)
                    == .advance(.endedWithoutAdvance)
            )
            let frozen = PlaybackStallWatchdog.recoveryAction(for: .frozenProgress, level: level, hasSuccessor: true)
            #expect(frozen != .advance(.frozenProgress))
        }
    }
}
