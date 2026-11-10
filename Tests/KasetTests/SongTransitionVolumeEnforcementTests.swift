import JavaScriptCore
import Testing
@testable import Kaset

/// The observer's volume enforcement must enforce the transition-faded volume on
/// the element while keeping YouTube's player APIs at the user's volume, and must
/// behave exactly as before when no transition engine is present.
@Suite("Observer volume enforcement with song transitions", .tags(.service))
@MainActor
struct SongTransitionVolumeEnforcementTests {
    private static let apiCapture = """
    var apiVolumes = [];
    player.playerApi.setVolume = function(value) { apiVolumes.push(value); };
    moviePlayer.setVolume = function(value) { apiVolumes.push(value); };
    """

    @Test("Without a transition engine, enforcement restores the user's volume")
    func enforcesBaseVolumeWithoutEngine() throws {
        let context = try MusicPlaybackObserverTestContext.make(setup: Self.apiCapture)
        context.evaluateScript("window.__kasetTargetVolume = 0.8; video.volume = 0.3; dispatch('volumechange');")
        #expect(context.evaluateScript("video.volume")?.toDouble() == 0.8)
        #expect(context.evaluateScript("apiVolumes")?.toArray() as? [Int] == [80, 80])
        #expect(context.exception == nil)
    }

    @Test("A gain of 1 behaves exactly like no engine")
    func unitGainIsUnchanged() throws {
        let context = try MusicPlaybackObserverTestContext.make(setup: Self.apiCapture)
        context.evaluateScript("window.__kasetTransitionGain = function() { return 1; }; window.__kasetTargetVolume = 0.8; video.volume = 0.3; dispatch('volumechange');")
        #expect(context.evaluateScript("video.volume")?.toDouble() == 0.8)
        #expect(context.evaluateScript("apiVolumes")?.toArray() as? [Int] == [80, 80])
    }

    @Test("During a fade the element gets the faded volume, YouTube keeps the user's")
    func enforcesFadedVolume() throws {
        let context = try MusicPlaybackObserverTestContext.make(setup: Self.apiCapture)
        context.evaluateScript("window.__kasetTransitionGain = function() { return 0.5; }; window.__kasetTargetVolume = 0.8; video.volume = 0.8; dispatch('volumechange');")
        #expect(abs((context.evaluateScript("video.volume")?.toDouble() ?? 0) - 0.4) < 0.0001)
        #expect(context.evaluateScript("apiVolumes")?.toArray() as? [Int] == [80, 80])
        #expect(context.evaluateScript("window.__kasetTargetVolume")?.toDouble() == 0.8)
    }

    @Test("An element already at the faded volume is left alone")
    func fadedVolumeIsStable() throws {
        let context = try MusicPlaybackObserverTestContext.make(setup: Self.apiCapture)
        context.evaluateScript("window.__kasetTransitionGain = function() { return 0.25; }; window.__kasetTargetVolume = 0.8; video.volume = 0.2; apiVolumes = []; dispatch('volumechange');")
        #expect(context.evaluateScript("video.volume")?.toDouble() == 0.2)
        #expect(context.evaluateScript("apiVolumes.length")?.toInt32() == 0)
    }

    @Test("During a fade the element also gets YouTube's loudness trim")
    func fadedVolumeIncludesLoudnessTrim() throws {
        let context = try MusicPlaybackObserverTestContext.make(setup: Self.apiCapture)
        context.evaluateScript("window.__kasetTransitionGain = function() { return 0.5; }; window.__kasetLoudnessTrim = function() { return 0.77; }; window.__kasetTargetVolume = 0.8; video.volume = 0.8; dispatch('volumechange');")
        #expect(abs((context.evaluateScript("video.volume")?.toDouble() ?? 0) - 0.8 * 0.5 * 0.77) < 0.0001)
        #expect(context.evaluateScript("apiVolumes")?.toArray() as? [Int] == [80, 80])
    }

    @Test("Without a fade the trim is left to YouTube")
    func trimIgnoredWithoutFade() throws {
        let context = try MusicPlaybackObserverTestContext.make(setup: Self.apiCapture)
        context.evaluateScript("window.__kasetTransitionGain = function() { return 1; }; window.__kasetLoudnessTrim = function() { return 0.77; }; window.__kasetTargetVolume = 0.8; video.volume = 0.3; dispatch('volumechange');")
        #expect(context.evaluateScript("video.volume")?.toDouble() == 0.8)
    }
}
