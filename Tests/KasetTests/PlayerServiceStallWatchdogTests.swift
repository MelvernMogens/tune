import Foundation
import Testing
@testable import Kaset

// MARK: - PlayerServiceStallWatchdogTests

/// Integration of ``PlaybackStallWatchdog`` with live ``PlayerService`` state.
@Suite(.serialized, .tags(.service))
@MainActor
struct PlayerServiceStallWatchdogTests {
    var playerService: PlayerService
    let recorder = ActionRecorder()

    init() {
        UserDefaults.standard.removeObject(forKey: "playerVolume")
        UserDefaults.standard.removeObject(forKey: "playerVolumeBeforeMute")
        self.playerService = PlayerService()
        // Keep queue persistence out of the shared keys other suites assert on.
        self.playerService.useQueuePersistenceNamespaceForTesting("PlayerServiceStallWatchdogTests-\(UUID().uuidString)")
        self.playerService.isNetworkAvailableForPlaybackRecovery = { true }
        let recorder = self.recorder
        self.playerService.performPlaybackStallRecovery = { action in
            recorder.actions.append(action)
        }
    }

    private static let songs = [
        Song(id: "1", title: "Song 1", artists: [], duration: 180, videoId: "v1"),
        Song(id: "2", title: "Song 2", artists: [], duration: 200, videoId: "v2"),
    ]

    private func drainRecovery() async {
        await self.playerService.playbackStallRecoveryTask?.value
    }

    @Test("Watchdog is disabled under unit tests so no loop or activity token leaks")
    func watchdogLoopIsDisabledInTests() {
        #expect(!self.playerService.isPlaybackStallWatchdogEnabled)
        #expect(self.playerService.playbackStallWatchdogTask == nil)
        #expect(self.playerService.playbackActivityToken == nil)
    }

    @Test("A finished track that never advanced triggers an advance")
    func endedWithoutAdvanceTriggersAdvance() async {
        await self.playerService.playQueue(Self.songs, startingAt: 0)
        self.playerService.state = .playing
        self.playerService.progress = 179.6
        self.playerService.duration = 180
        let start = ContinuousClock.now

        #expect(self.playerService.isPlaybackStallWatchdogArmed)
        #expect(self.playerService.playbackStallHasSuccessor)
        #expect(self.playerService.evaluatePlaybackStallWatchdog(now: start) == .none)
        let action = self.playerService.evaluatePlaybackStallWatchdog(now: start.advanced(by: .seconds(6)))
        await self.drainRecovery()

        #expect(action == .advance(.endedWithoutAdvance))
        #expect(self.recorder.actions == [.advance(.endedWithoutAdvance)])
    }

    @Test("The default advance action moves the queue to the next song")
    func advanceActionUsesNextNavigation() async {
        await self.playerService.playQueue(Self.songs, startingAt: 0)
        self.playerService.state = .playing
        self.playerService.progress = 180
        self.playerService.duration = 180

        await self.playerService.performPlaybackStallAction(.advance(.endedWithoutAdvance))

        #expect(self.playerService.currentIndex == 1)
        #expect(self.playerService.currentTrack?.videoId == "v2")
        #expect(self.playerService.pendingPlayVideoId == "v2")
    }

    @Test("Repeat-one advance replays the current song instead of skipping")
    func repeatOneAdvanceReplaysCurrentSong() async {
        await self.playerService.playQueue(Self.songs, startingAt: 0)
        self.playerService.advanceRepeatMode()
        self.playerService.advanceRepeatMode()
        #expect(self.playerService.repeatMode == .one)
        self.playerService.state = .playing
        self.playerService.progress = 180
        self.playerService.duration = 180
        #expect(self.playerService.playbackStallHasSuccessor)

        await self.playerService.performPlaybackStallAction(.advance(.endedWithoutAdvance))

        #expect(self.playerService.currentIndex == 0)
        #expect(self.playerService.currentTrack?.videoId == "v1")
        #expect(self.playerService.progress == 0)
        self.playerService.advanceRepeatMode()
    }

    @Test("A user pause disarms the watchdog and resets its state")
    func userPauseDisarms() async {
        await self.playerService.playQueue(Self.songs, startingAt: 0)
        self.playerService.state = .playing
        self.playerService.progress = 179.6
        self.playerService.duration = 180
        let start = ContinuousClock.now
        _ = self.playerService.evaluatePlaybackStallWatchdog(now: start)

        await self.playerService.pause()

        #expect(!self.playerService.isPlaybackStallWatchdogArmed)
        for seconds in stride(from: 2, through: 120, by: 2) {
            let action = self.playerService.evaluatePlaybackStallWatchdog(now: start.advanced(by: .seconds(seconds)))
            #expect(action == .none)
        }
        #expect(self.playerService.playbackStallWatchdog.stallKind == nil)
        #expect(self.recorder.actions.isEmpty)
    }

    @Test("A recovery decided before a user pause stands down")
    func recoverySupersededByUserPause() async {
        await self.playerService.playQueue(Self.songs, startingAt: 0)
        self.playerService.state = .playing
        self.playerService.progress = 179.6
        self.playerService.duration = 180
        let start = ContinuousClock.now
        _ = self.playerService.evaluatePlaybackStallWatchdog(now: start)
        let action = self.playerService.evaluatePlaybackStallWatchdog(now: start.advanced(by: .seconds(6)))
        #expect(action == .advance(.endedWithoutAdvance))

        // The listener pauses before the recovery task gets to run.
        self.playerService.isExplicitPauseIntentActive = true
        self.playerService.shouldResumeAfterInterruption = false
        await self.drainRecovery()

        #expect(self.recorder.actions.isEmpty)
    }

    @Test("A frozen native clock does not reload media whose own clock is moving")
    func frozenClockSkipsWhenMediaAdvances() async {
        await self.playerService.playQueue(Self.songs, startingAt: 0)
        self.playerService.state = .playing
        self.playerService.progress = 42
        self.playerService.duration = 180
        let mediaClock = MediaClock()
        self.playerService.currentMusicPlaybackSnapshot = {
            mediaClock.progress += 1
            return SingletonPlayerWebView.PlaybackSnapshot(progress: mediaClock.progress, duration: 180, videoId: "v1")
        }
        let start = ContinuousClock.now
        _ = self.playerService.evaluatePlaybackStallWatchdog(now: start)

        let action = self.playerService.evaluatePlaybackStallWatchdog(now: start.advanced(by: .seconds(25)))
        await self.drainRecovery()

        #expect(action == .resumeMedia(.frozenProgress))
        #expect(self.recorder.actions.isEmpty)

        // When the media clock is stuck too, the recovery runs.
        self.playerService.currentMusicPlaybackSnapshot = {
            SingletonPlayerWebView.PlaybackSnapshot(progress: 42, duration: 180, videoId: "v1")
        }
        let next = self.playerService.evaluatePlaybackStallWatchdog(now: start.advanced(by: .seconds(70)))
        await self.drainRecovery()
        #expect(next == .reloadFullPage(.frozenProgress))
        #expect(self.recorder.actions == [.reloadFullPage(.frozenProgress)])
    }

    @Test("Ticks never overlap a running recovery")
    func ticksSkipWhileRecoveryRuns() async {
        await self.playerService.playQueue(Self.songs, startingAt: 0)
        self.playerService.state = .playing
        self.playerService.progress = 179.6
        self.playerService.duration = 180
        self.playerService.playbackStallRecoveryTask = Task {}
        let start = ContinuousClock.now

        _ = self.playerService.evaluatePlaybackStallWatchdog(now: start)
        let action = self.playerService.evaluatePlaybackStallWatchdog(now: start.advanced(by: .seconds(60)))

        #expect(action == .none)
        #expect(self.playerService.playbackStallWatchdog.stallKind == nil)
        self.playerService.playbackStallRecoveryTask = nil
    }

    @Test("Video window ownership and AirPlay are reported to the watchdog")
    func observationReflectsExternalOwnership() async {
        await self.playerService.playQueue(Self.songs, startingAt: 0)
        self.playerService.state = .playing
        self.playerService.showVideo = true
        self.playerService.updateAirPlayStatus(isConnected: true)

        let observation = self.playerService.makePlaybackStallObservation(now: .now)

        #expect(observation.isMediaUserControllable)
        #expect(observation.isExternalPlaybackRoute)
        #expect(observation.wantsPlayback)
        #expect(!observation.isTransitioning)
        self.playerService.showVideo = false
    }

    @Test("End of a non-repeating queue has no successor")
    func lastSongHasNoSuccessor() async {
        await self.playerService.playQueue(Self.songs, startingAt: 1)
        self.playerService.state = .playing
        #expect(!self.playerService.playbackStallHasSuccessor)
    }
}

// MARK: - MediaClock

@MainActor
final class MediaClock {
    var progress: TimeInterval = 60
}

// MARK: - ActionRecorder

@MainActor
final class ActionRecorder {
    var actions: [PlaybackStallWatchdog.Action] = []
}
