import AppKit
import Foundation
import JavaScriptCore
import Testing
@testable import Kaset

// MARK: - PlaybackDocumentFreshenPolicyTests

@Suite(.tags(.model))
struct PlaybackDocumentFreshenPolicyTests {
    private static let policy = PlaybackDocumentFreshenPolicy(
        minimumDocumentAge: .seconds(3600),
        minimumPausedDuration: .seconds(900)
    )

    private static func snapshot(
        isExplicitlyPaused: Bool = true,
        pausedDuration: Duration = .seconds(900),
        documentAge: Duration? = .seconds(7200),
        hasCurrentTrack: Bool = true,
        isLoadDeferred: Bool = false,
        isTransitioning: Bool = false,
        isVideoVisible: Bool = false,
        isAirPlayConnected: Bool = false,
        isShowingAd: Bool = false
    ) -> PlaybackDocumentFreshenPolicy.Snapshot {
        PlaybackDocumentFreshenPolicy.Snapshot(
            isExplicitlyPaused: isExplicitlyPaused,
            pausedDuration: pausedDuration,
            documentAge: documentAge,
            hasCurrentTrack: hasCurrentTrack,
            isLoadDeferred: isLoadDeferred,
            isTransitioning: isTransitioning,
            isVideoVisible: isVideoVisible,
            isAirPlayConnected: isAirPlayConnected,
            isShowingAd: isShowingAd
        )
    }

    @Test("An old page after a long explicit pause is freshened")
    func freshensOldPageAfterLongPause() {
        #expect(Self.policy.decide(Self.snapshot()) == .freshen)
    }

    @Test("Never while playing, or for a pause Kaset or the system made")
    func neverWithoutExplicitPause() {
        #expect(Self.policy.decide(Self.snapshot(isExplicitlyPaused: false)) == .ineligible)
    }

    @Test("Never while anything could be visibly or audibly interrupted", arguments: [
        "video", "airplay", "ad", "transition", "deferred", "no-track", "no-webview",
    ])
    func neverWhenInterruptible(blocker: String) {
        let snapshot = switch blocker {
        case "video": Self.snapshot(isVideoVisible: true)
        case "airplay": Self.snapshot(isAirPlayConnected: true)
        case "ad": Self.snapshot(isShowingAd: true)
        case "transition": Self.snapshot(isTransitioning: true)
        case "deferred": Self.snapshot(isLoadDeferred: true)
        case "no-track": Self.snapshot(hasCurrentTrack: false)
        default: Self.snapshot(documentAge: nil)
        }
        #expect(Self.policy.decide(snapshot) == .ineligible)
    }

    @Test("Waits out the longer of the pause and page-age thresholds")
    func waitsForRemainingTime() {
        #expect(Self.policy.decide(Self.snapshot(pausedDuration: .seconds(600))) == .wait(.seconds(300)))
        #expect(Self.policy.decide(Self.snapshot(documentAge: .seconds(1800))) == .wait(.seconds(1800)))
        #expect(Self.policy.decide(Self.snapshot(
            pausedDuration: .seconds(800),
            documentAge: .seconds(3000)
        )) == .wait(.seconds(600)))
    }
}

// MARK: - PlayerServiceDocumentFreshenTests

@Suite(.serialized, .tags(.service))
@MainActor
struct PlayerServiceDocumentFreshenTests {
    private static func pausedService(rebuildCount: LockedFreshenCounter, canRebuild: Bool = true) -> PlayerService {
        let service = PlayerService()
        service.playbackDocumentAge = { .seconds(4 * 3600) }
        service.canRebuildPlaybackDocument = { canRebuild }
        service.rebuildPlaybackDocument = { rebuildCount.value += 1 }
        let song = TestFixtures.makeSong(id: "freshen-video")
        service.currentTrack = song
        service.state = .paused
        service.isExplicitPauseIntentActive = true
        service.progress = 95
        service.duration = 200
        return service
    }

    @Test("Freshen defers the paused session at its position and rebuilds the page")
    func freshenDefersSessionAndRebuilds() {
        let rebuildCount = LockedFreshenCounter()
        let service = Self.pausedService(rebuildCount: rebuildCount)
        defer { service.clearRestoredPlaybackSessionState() }

        #expect(service.freshenPlaybackDocument())

        #expect(rebuildCount.value == 1)
        #expect(service.isPendingRestoredLoadDeferred)
        #expect(service.shouldForcePendingRestoredLoad)
        #expect(service.pendingPlayVideoId == "freshen-video")
        #expect(service.pendingRestoredSeek == 95)
        #expect(service.state == .paused)
        #expect(service.shouldLoadPendingVideoBeforePlayback)
        #expect(!service.isPlaybackDocumentFreshenCandidate)
    }

    @Test("Freshen never runs during playback or without the user's pause")
    func freshenRefusesWhilePlaying() {
        let rebuildCount = LockedFreshenCounter()
        let service = Self.pausedService(rebuildCount: rebuildCount)
        service.state = .playing
        #expect(!service.freshenPlaybackDocument())

        service.state = .paused
        service.isExplicitPauseIntentActive = false
        #expect(!service.freshenPlaybackDocument())

        #expect(rebuildCount.value == 0)
        #expect(!service.isPendingRestoredLoadDeferred)
    }

    @Test("Freshen leaves state untouched when the page cannot be rebuilt (video mode)")
    func freshenRequiresRebuildablePage() {
        let rebuildCount = LockedFreshenCounter()
        let service = Self.pausedService(rebuildCount: rebuildCount, canRebuild: false)

        #expect(!service.freshenPlaybackDocument())
        #expect(rebuildCount.value == 0)
        #expect(!service.isPendingRestoredLoadDeferred)
        #expect(service.pendingRestoredSeek == nil)
    }

    @Test("The freshen task is armed only while explicitly paused and cancelled on play")
    func scheduleFollowsExplicitPause() {
        let rebuildCount = LockedFreshenCounter()
        let service = Self.pausedService(rebuildCount: rebuildCount)
        defer {
            service.playbackDocumentFreshenTask?.cancel()
            service.playbackDocumentFreshenTask = nil
        }

        service.updatePlaybackDocumentFreshenSchedule()
        #expect(service.playbackDocumentFreshenTask != nil)

        service.state = .playing
        service.updatePlaybackDocumentFreshenSchedule()
        #expect(service.playbackDocumentFreshenTask == nil)
        #expect(rebuildCount.value == 0)
    }
}

// MARK: - SingletonPlayerFreshenRebuildTests

@Suite(.serialized, .tags(.service))
@MainActor
struct SingletonPlayerFreshenRebuildTests {
    @Test("Rebuild swaps in an inert WebView in the same container and data store")
    func rebuildSwapsInInertWebView() throws {
        let singleton = SingletonPlayerWebView.shared
        singleton.tearDown()
        singleton.currentVideoId = nil
        defer {
            singleton.tearDown()
            singleton.currentVideoId = nil
        }

        let playerService = PlayerService()
        playerService.setYTMusicClient(MockYTMusicClient())
        let webKitManager = WebKitManager.makeTestInstance()
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 1, height: 1))
        let original = singleton.getWebView(
            webKitManager: webKitManager,
            playerService: playerService,
            usesCookieFreeDataStore: true
        )
        singleton.ensureInHierarchy(container: container)
        singleton.currentVideoId = "playing-video"
        #expect(singleton.canRebuildForMemoryFreshen)
        #expect(singleton.playbackWebViewAge != nil)

        // Not deferred yet: the rebuild must refuse rather than strand playback.
        singleton.rebuildForMemoryFreshen()
        #expect(singleton.webView === original)

        playerService.currentTrack = TestFixtures.makeSong(id: "playing-video")
        playerService.state = .paused
        playerService.deferRestoredPlaybackAfterNavigationFailure()
        singleton.rebuildForMemoryFreshen()

        let replacement = try #require(singleton.webView)
        #expect(replacement !== original)
        #expect(original.superview == nil)
        #expect(replacement.superview === container)
        #expect(singleton.currentVideoId == nil)
        #expect(singleton.isHomePreloadSuppressedForDeferredRestore)
        #expect(playerService.shouldLoadPendingVideoBeforePlayback)
    }
}

/// Main-actor counter for the injected rebuild closure.
@MainActor
final class LockedFreshenCounter {
    var value = 0
}

// MARK: - PlaybackAudioQualityMutationTests

@Suite(.tags(.model))
@MainActor
struct PlaybackAudioQualityMutationTests {
    @Test("DOM mutations re-apply audio quality only when the player object changes")
    func mutationsReapplyOnlyOnPlayerChange() throws {
        let context = try #require(JSContext())
        context.evaluateScript(
            """
            var pendingRafCallbacks = [];
            function requestAnimationFrame(callback) {
                pendingRafCallbacks.push(callback);
                return pendingRafCallbacks.length;
            }
            var localStorage = { getItem: function() { return 'high'; }, setItem: function() {} };
            var statsCalls = 0;
            function makePlayerApi() {
                return {
                    setAudioQuality: function() {},
                    getStatsForNerds: function() { statsCalls += 1; return {}; }
                };
            }
            var ytmusicPlayer = { playerApi: makePlayerApi() };
            var video = { addEventListener: function() {} };
            var document = {
                documentElement: {},
                querySelector: function(selector) {
                    if (selector === 'ytmusic-player') return ytmusicPlayer;
                    if (selector === 'video') return video;
                    return null;
                },
                getElementById: function() { return null; }
            };
            var window = {};
            var mutationCallback = null;
            function MutationObserver(callback) { mutationCallback = callback; }
            MutationObserver.prototype.observe = function() {};
            """
        )
        context.evaluateScript(SingletonPlayerWebView.playbackAudioQualityOverrideScript)
        let statsAfterInstall = context.evaluateScript("statsCalls")?.toInt32() ?? -1

        // A burst of unrelated DOM churn (lyrics, queue rows, menus).
        context.evaluateScript("for (var i = 0; i < 50; i += 1) { mutationCallback(); }")
        #expect(context.evaluateScript("pendingRafCallbacks.length")?.toInt32() == 0)
        #expect(context.evaluateScript("statsCalls")?.toInt32() == statsAfterInstall)

        // YouTube replaces the player API: re-apply once on the next frame.
        context.evaluateScript("ytmusicPlayer.playerApi = makePlayerApi(); mutationCallback(); mutationCallback();")
        #expect(context.evaluateScript("pendingRafCallbacks.length")?.toInt32() == 1)
    }
}
