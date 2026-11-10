import Foundation
import JavaScriptCore
import Testing
@testable import Kaset

// MARK: - Harness

/// Runs the page-side song transition engine in JavaScriptCore against a fake
/// `document`, `<video>` and clock, so the real shipped script is what's tested.
@MainActor
private struct TransitionPage {
    let context: JSContext

    init(crossfadeSeconds: Int = 5, fadesTransportControls: Bool = true, targetVolume: Double = 0.6) throws {
        self.context = try #require(JSContext())
        self.context.exceptionHandler = { _, exception in
            Issue.record("JavaScript exception: \(exception?.toString() ?? "unknown")")
        }
        self.context.evaluateScript(Self.harness)
        self.context.evaluateScript("window.__kasetTargetVolume = \(targetVolume);")
        self.context.evaluateScript(WebPlaybackSongTransitions.script(settings: SongTransitionSettings(
            crossfadeSeconds: crossfadeSeconds,
            fadesTransportControls: fadesTransportControls
        )))
    }

    @discardableResult
    func run(_ script: String) -> JSValue? {
        self.context.evaluateScript(script)
    }

    func number(_ expression: String) -> Double {
        self.run(expression)?.toDouble() ?? .nan
    }

    var volume: Double {
        self.number("video.volume")
    }

    /// Sets the clock, applies `media` changes and dispatches `event`.
    func event(_ type: String, at milliseconds: Double? = nil, _ media: String = "") {
        if let milliseconds {
            self.run("clock = \(milliseconds);")
        }
        self.run("\(media); dispatch('\(type)');")
    }

    func send(_ command: SongTransitionCommand) {
        self.run(command.script)
    }

    static let harness = """
    var window = globalThis;
    var clock = 0;
    var performance = { now: function() { return clock; } };
    var listeners = {};
    var intervals = 0;
    var moviePlayer = null;
    var getElementByIdCalls = 0;
    function setInterval() { intervals += 1; return intervals; }
    function clearInterval() {}
    function setTimeout() { return 0; }
    var video = {
        tagName: 'VIDEO',
        paused: false,
        ended: false,
        currentTime: 0,
        duration: 200,
        currentSrc: 'blob:track-1',
        volume: 0.6,
        webkitCurrentPlaybackTargetIsWireless: false
    };
    var document = {
        addEventListener: function(type, listener) {
            (listeners[type] = listeners[type] || []).push(listener);
        },
        querySelector: function(selector) { return selector === 'video' ? video : null; },
        getElementById: function(id) {
            getElementByIdCalls += 1;
            return id === 'movie_player' ? moviePlayer : null;
        }
    };
    function dispatch(type) {
        (listeners[type] || []).forEach(function(listener) { listener({ type: type, target: video }); });
    }
    """
}

private func near(_ lhs: Double, _ rhs: Double, tolerance: Double = 0.002) -> Bool {
    abs(lhs - rhs) <= tolerance
}

// MARK: - Curve and scheduling math

@Suite("Song transition curves and scheduling", .tags(.service))
@MainActor
struct SongTransitionMathTests {
    private func math() throws -> JSContext {
        let context = try #require(JSContext())
        context.evaluateScript(WebPlaybackSongTransitions.mathFunctions)
        return context
    }

    @Test("Equal-power curves start, end and cross at constant power")
    func equalPowerCurves() throws {
        let context = try self.math()
        func value(_ script: String) -> Double {
            context.evaluateScript(script)?.toDouble() ?? .nan
        }
        #expect(near(value("__kasetEqualPowerOut(0)"), 1))
        #expect(near(value("__kasetEqualPowerOut(1)"), 0))
        #expect(near(value("__kasetEqualPowerIn(0)"), 0))
        #expect(near(value("__kasetEqualPowerIn(1)"), 1))
        #expect(near(value("__kasetEqualPowerOut(0.5)"), 0.5.squareRoot()))
        for progress in stride(from: 0.0, through: 1.0, by: 0.1) {
            let fadeOut = value("__kasetEqualPowerOut(\(progress))")
            let fadeIn = value("__kasetEqualPowerIn(\(progress))")
            #expect(near(fadeOut * fadeOut + fadeIn * fadeIn, 1))
        }
    }

    @Test("Curves clamp out-of-range and non-finite progress")
    func curvesClamp() throws {
        let context = try self.math()
        #expect(near(context.evaluateScript("__kasetEqualPowerOut(-3)")?.toDouble() ?? .nan, 1))
        #expect(near(context.evaluateScript("__kasetEqualPowerIn(7)")?.toDouble() ?? .nan, 1))
        // Unknown progress counts as finished, never as a silent midpoint.
        #expect(near(context.evaluateScript("__kasetEqualPowerIn(NaN)")?.toDouble() ?? .nan, 1))
    }

    @Test("The end-of-song window is skipped when off, unknown, live or too short")
    func tailWindowSkipConditions() throws {
        let context = try self.math()
        func window(_ duration: String, _ crossfade: String) -> Double {
            context.evaluateScript("__kasetTailWindowSeconds(\(duration), \(crossfade))")?.toDouble() ?? .nan
        }
        #expect(window("200", "0") == 0)
        #expect(window("200", "-4") == 0)
        #expect(window("NaN", "5") == 0)
        #expect(window("Infinity", "5") == 0)
        #expect(window("undefined", "5") == 0)
        #expect(window("15", "5") == 0)
        #expect(window("36", "12") == 0)
        #expect(window("15.5", "5") == 5)
        #expect(window("200", "12") == 12)
    }

    @Test("The tail gain fades from full to silent over the last N seconds")
    func tailGain() throws {
        let context = try self.math()
        func gain(_ time: Double) -> Double {
            context.evaluateScript("__kasetTailGain(\(time), 200, 4)")?.toDouble() ?? .nan
        }
        #expect(gain(100) == 1)
        #expect(gain(196) == 1)
        #expect(near(gain(198), 0.5.squareRoot()))
        #expect(near(gain(200), 0))
        #expect(near(gain(205), 0))
        #expect(context.evaluateScript("__kasetTailGain(NaN, 200, 4)")?.toDouble() == 1)
    }

    @Test("The next song's fade-in is capped at one and a half seconds")
    func fadeInCap() throws {
        let context = try self.math()
        #expect(context.evaluateScript("__kasetFadeInSeconds(1)")?.toDouble() == 1)
        #expect(context.evaluateScript("__kasetFadeInSeconds(12)")?.toDouble() == 1.5)
        #expect(context.evaluateScript("__kasetFadeInSeconds(NaN)")?.toDouble() == 0)
    }
}

// MARK: - Page engine

@Suite("Song transition page engine", .tags(.service))
@MainActor
struct SongTransitionEngineTests {
    @Test("Track end fades out as a multiplier over the user's volume")
    func trackEndFadesOut() throws {
        let page = try TransitionPage(crossfadeSeconds: 5)
        page.event("timeupdate", at: 0, "video.currentTime = 100")
        #expect(page.volume == 0.6)

        page.event("timeupdate", at: 1000, "video.currentTime = 197.5")
        #expect(near(page.volume, 0.6 * 0.5.squareRoot()))
        #expect(page.number("window.__kasetTargetVolume") == 0.6)
        #expect(near(page.number("window.__kasetTransitionGain()"), 0.5.squareRoot()))

        page.event("timeupdate", at: 2000, "video.currentTime = 200")
        #expect(near(page.volume, 0))
    }

    @Test("The next song fades in on the media clock, capped at one and a half seconds")
    func nextSongFadesIn() throws {
        let page = try TransitionPage(crossfadeSeconds: 8)
        page.event("timeupdate", at: 0, "video.currentTime = 199.9")
        page.event("pause", at: 100, "video.currentTime = 200; video.paused = true; video.ended = true")
        page.event("ended")
        #expect(near(page.volume, 0, tolerance: 0.01))

        page.event("loadstart", at: 400, "video.currentSrc = 'blob:track-2'; video.ended = false; video.currentTime = 0; video.duration = NaN")
        #expect(near(page.volume, 0))
        page.event("playing", at: 900, "video.paused = false")
        #expect(near(page.volume, 0))

        page.event("timeupdate", at: 1650, "video.currentTime = 0.75; video.duration = 180")
        #expect(near(page.volume, 0.6 * 0.5.squareRoot()))
        page.event("timeupdate", at: 2450, "video.currentTime = 1.55")
        #expect(page.volume == 0.6)
        #expect(near(page.number("window.__kasetTransitionGain()"), 1))
    }

    @Test("Short songs, crossfade off and podcasts keep the volume untouched")
    func skipConditions() throws {
        let short = try TransitionPage(crossfadeSeconds: 5)
        short.event("timeupdate", at: 0, "video.duration = 14; video.currentTime = 13")
        #expect(short.volume == 0.6)

        let off = try TransitionPage(crossfadeSeconds: 0)
        off.event("timeupdate", at: 0, "video.currentTime = 199.5")
        #expect(off.volume == 0.6)

        let podcast = try TransitionPage(crossfadeSeconds: 5)
        podcast.run("""
        moviePlayer = { getPlayerResponse: function() {
            return { videoDetails: { musicVideoType: 'MUSIC_VIDEO_TYPE_PODCAST_EPISODE' } };
        } };
        """)
        podcast.event("timeupdate", at: 0, "video.currentTime = 199")
        #expect(podcast.volume == 0.6)
    }

    @Test("Ads and AirPlay restore the exact user volume")
    func adsAndAirPlayRestore() throws {
        let page = try TransitionPage(crossfadeSeconds: 5)
        page.event("timeupdate", at: 0, "video.currentTime = 198")
        #expect(page.volume < 0.6)
        page.run("moviePlayer = { classList: { contains: function(name) { return name === 'ad-showing'; } } };")
        // A momentary ad signal (YouTube flags one while loading) is ignored;
        // a real ad restores the volume as soon as it is confirmed.
        page.event("timeupdate", at: 250)
        page.event("timeupdate", at: 600)
        #expect(page.volume == 0.6)

        let airPlay = try TransitionPage(crossfadeSeconds: 5)
        airPlay.event("timeupdate", at: 0, "video.currentTime = 198")
        airPlay.event("webkitcurrentplaybacktargetiswirelesschanged", at: 100, "video.webkitCurrentPlaybackTargetIsWireless = true")
        #expect(airPlay.volume == 0.6)
    }

    @Test("Seeking into the last seconds fades from full over the time that is left")
    func seekIntoTailFadesOverRemaining() throws {
        let page = try TransitionPage(crossfadeSeconds: 6)
        page.event("timeupdate", at: 0, "video.currentTime = 90")
        page.event("seeking", at: 100, "video.currentTime = 197")
        page.event("seeked", at: 150)
        #expect(near(page.volume, 0.6))
        // 3 s were left at the landing: 0.3 s in is 10 % of that fade.
        page.event("timeupdate", at: 400, "video.currentTime = 197.3")
        #expect(near(page.volume, 0.6 * cos(0.1 * .pi / 2)))
        page.event("timeupdate", at: 3200, "video.currentTime = 200")
        #expect(near(page.volume, 0))
    }

    @Test("Seeking back out of a fade ramps up from where it was, never from silence")
    func seekOutOfTailRampsUp() throws {
        let page = try TransitionPage(crossfadeSeconds: 6)
        page.event("timeupdate", at: 0, "video.currentTime = 199")
        let faded = page.volume
        #expect(faded < 0.2)
        page.event("seeking", at: 100, "video.currentTime = 60")
        page.event("seeked", at: 150)
        #expect(near(page.volume, faded))
        page.event("timeupdate", at: 275, "video.currentTime = 60.1")
        #expect(page.volume > faded && page.volume < 0.6)
        page.event("timeupdate", at: 450, "video.currentTime = 60.3")
        #expect(page.volume == 0.6)
    }

    @Test("Scrubbing back from the very start of a fade causes no dip")
    func scrubBackFromFadeStartNoDip() throws {
        let page = try TransitionPage(crossfadeSeconds: 5)
        page.event("timeupdate", at: 0, "video.currentTime = 195.1")
        #expect(page.volume > 0.59)
        page.event("seeking", at: 100, "video.currentTime = 60")
        page.event("seeked", at: 150)
        #expect(page.volume > 0.59)
        page.event("timeupdate", at: 400, "video.currentTime = 60.25")
        #expect(page.volume == 0.6)
    }

    @Test("Repeat restarts a faded-out song with a fade-in")
    func repeatRestartFadesIn() throws {
        let page = try TransitionPage(crossfadeSeconds: 4)
        page.event("timeupdate", at: 0, "video.currentTime = 199.9")
        page.event("seeked", at: 100, "video.currentTime = 0")
        #expect(near(page.volume, 0))
        page.event("timeupdate", at: 850, "video.currentTime = 0.75")
        #expect(near(page.volume, 0.6 * 0.5.squareRoot()))
        page.event("timeupdate", at: 1700, "video.currentTime = 1.6")
        #expect(page.volume == 0.6)
    }

    @Test("Turning crossfade off mid-fade restores the volume")
    func disablingRestores() throws {
        let page = try TransitionPage(crossfadeSeconds: 5)
        page.event("timeupdate", at: 0, "video.currentTime = 198")
        #expect(page.volume < 0.6)
        page.send(.configure(.off))
        #expect(page.volume == 0.6)
    }

    @Test("A base-volume write during a fade is rescaled, never left at full")
    func volumeChangeDuringFade() throws {
        let page = try TransitionPage(crossfadeSeconds: 4)
        page.event("timeupdate", at: 0, "video.currentTime = 198")
        page.event("volumechange", at: 10, "window.__kasetTargetVolume = 0.8; video.volume = 0.8")
        #expect(near(page.volume, 0.8 * 0.5.squareRoot()))
    }

    @Test("While idle the engine never writes the element volume")
    func idleNeverWrites() throws {
        let page = try TransitionPage(crossfadeSeconds: 5)
        page.event("timeupdate", at: 0, "video.currentTime = 50; video.volume = 0.42")
        page.event("volumechange", at: 10)
        page.event("seeked", at: 20)
        #expect(page.volume == 0.42)
    }

    @Test("Pause fade ramps to silence, then the paused element is restored")
    func pauseFade() throws {
        let page = try TransitionPage()
        page.event("timeupdate", at: 0, "video.currentTime = 40")
        page.send(.fadeOut(token: 1, milliseconds: 300, fadeInMilliseconds: 0))
        page.event("timeupdate", at: 150)
        #expect(near(page.volume, 0.6 * 0.5.squareRoot()))
        page.event("timeupdate", at: 300)
        #expect(near(page.volume, 0))
        page.event("pause", at: 320, "video.paused = true")
        #expect(page.volume == 0.6)
        page.send(.release(token: 1, superseded: false))
        #expect(page.volume == 0.6)
    }

    @Test("A fade-out whose command never happened recovers after release")
    func releaseRecovers() throws {
        let page = try TransitionPage()
        page.event("timeupdate", at: 0, "video.currentTime = 40")
        page.send(.fadeOut(token: 7, milliseconds: 300, fadeInMilliseconds: 450))
        page.event("timeupdate", at: 300)
        page.send(.release(token: 7, superseded: false))
        page.event("timeupdate", at: 900)
        #expect(near(page.volume, 0))
        page.event("timeupdate", at: 1225)
        #expect(near(page.volume, 0.6 * 0.5.squareRoot()))
        page.event("timeupdate", at: 1400)
        #expect(page.volume == 0.6)
        // Same media keeps playing: the armed skip fade-in must not dip it again.
        page.event("timeupdate", at: 1650, "video.currentTime = 41.6")
        #expect(page.volume == 0.6)
    }

    @Test("An unreleased fade-out recovers on its own")
    func holdExpires() throws {
        let page = try TransitionPage()
        page.event("timeupdate", at: 0, "video.currentTime = 40")
        page.send(.fadeOut(token: 2, milliseconds: 300, fadeInMilliseconds: 0))
        page.event("timeupdate", at: 3200)
        #expect(near(page.volume, 0))
        page.event("timeupdate", at: 3400)
        page.event("timeupdate", at: 3700)
        #expect(page.volume == 0.6)
    }

    @Test("A stale release token does not cut another fade short")
    func staleReleaseIgnored() throws {
        let page = try TransitionPage()
        page.event("timeupdate", at: 0, "video.currentTime = 40")
        page.send(.fadeOut(token: 3, milliseconds: 300, fadeInMilliseconds: 0))
        page.send(.release(token: 2, superseded: false))
        page.event("timeupdate", at: 1500)
        #expect(near(page.volume, 0))
    }

    @Test("Skip fade-out arms a short fade-in of the next song")
    func skipFadesNextSongIn() throws {
        let page = try TransitionPage(crossfadeSeconds: 0)
        page.event("timeupdate", at: 0, "video.currentTime = 60")
        page.send(.fadeOut(token: 4, milliseconds: 300, fadeInMilliseconds: 450))
        page.event("timeupdate", at: 300)
        #expect(near(page.volume, 0))
        page.event("pause", at: 310, "video.paused = true")
        page.event("loadstart", at: 320, "video.currentSrc = 'blob:track-2'; video.currentTime = 0")
        #expect(near(page.volume, 0))
        page.event("playing", at: 800, "video.paused = false")
        page.event("timeupdate", at: 1100, "video.currentTime = 0.225")
        #expect(near(page.volume, 0.6 * 0.5.squareRoot()))
        page.event("timeupdate", at: 1400, "video.currentTime = 0.5")
        #expect(page.volume == 0.6)
    }

    @Test("A command dropped for a newer intent recovers at once")
    func supersededReleaseRecoversNow() throws {
        let page = try TransitionPage()
        page.event("timeupdate", at: 0, "video.currentTime = 40")
        page.send(.fadeOut(token: 5, milliseconds: 300, fadeInMilliseconds: 450))
        page.event("timeupdate", at: 300)
        page.send(.release(token: 5, superseded: true))
        page.event("timeupdate", at: 425)
        #expect(near(page.volume, 0.6 * 0.5.squareRoot()))
        page.event("timeupdate", at: 560)
        #expect(page.volume == 0.6)
    }

    @Test("New media never inherits a held pause fade")
    func newMediaDropsHeldFadeOut() throws {
        let page = try TransitionPage(crossfadeSeconds: 0)
        page.event("timeupdate", at: 0, "video.currentTime = 199.6")
        page.send(.fadeOut(token: 8, milliseconds: 300, fadeInMilliseconds: 0))
        page.event("timeupdate", at: 300)
        #expect(near(page.volume, 0))
        // YouTube Music swaps media without a pause event.
        page.event("loadstart", at: 350, "video.currentSrc = 'blob:track-2'; video.currentTime = 0")
        page.event("playing", at: 700)
        #expect(page.volume == 0.6)
    }

    @Test("Scrubbing back after a skip that went nowhere does not fade in")
    func scrubAfterFailedSkip() throws {
        let page = try TransitionPage(crossfadeSeconds: 0)
        page.event("timeupdate", at: 0, "video.currentTime = 60")
        page.send(.fadeOut(token: 9, milliseconds: 300, fadeInMilliseconds: 450))
        page.event("timeupdate", at: 300)
        page.send(.release(token: 9, superseded: false))
        page.event("timeupdate", at: 1400, "video.currentTime = 61.4")
        #expect(page.volume == 0.6)
        page.event("seeked", at: 1500, "video.currentTime = 30")
        page.event("timeupdate", at: 1600, "video.currentTime = 30.1")
        #expect(page.volume == 0.6)
    }

    @Test("Previous restarting the song fades it back in")
    func previousRestartFadesIn() throws {
        let page = try TransitionPage(crossfadeSeconds: 0)
        page.event("timeupdate", at: 0, "video.currentTime = 60")
        page.send(.fadeOut(token: 10, milliseconds: 300, fadeInMilliseconds: 450))
        page.event("seeked", at: 320, "video.currentTime = 0")
        #expect(near(page.volume, 0))
        page.event("timeupdate", at: 545, "video.currentTime = 0.225")
        #expect(near(page.volume, 0.6 * 0.5.squareRoot()))
        page.event("timeupdate", at: 800, "video.currentTime = 0.5")
        #expect(page.volume == 0.6)
    }

    @Test("A gain the engine stopped updating is not trusted by enforcement")
    func staleGainFallsBack() throws {
        let page = try TransitionPage(crossfadeSeconds: 5)
        page.event("timeupdate", at: 0, "video.currentTime = 198")
        page.event("pause", at: 10, "video.paused = true")
        #expect(page.number("window.__kasetTransitionGain()") < 1)
        page.run("clock = 6000;")
        #expect(page.number("window.__kasetTransitionGain()") == 1)
    }

    @Test("With both settings off the engine does no work on media events")
    func offDoesNoWork() throws {
        let page = try TransitionPage(crossfadeSeconds: 0, fadesTransportControls: false)
        page.run("getElementByIdCalls = 0;")
        page.event("timeupdate", at: 0, "video.currentTime = 199.5")
        page.event("seeked", at: 100)
        page.event("playing", at: 200)
        #expect(page.number("getElementByIdCalls") == 0)
        #expect(page.volume == 0.6)
    }

    @Test("Fade-in on play is ignored while transport fades are off")
    func fadeInOnPlayRespectsSetting() throws {
        let page = try TransitionPage(crossfadeSeconds: 5, fadesTransportControls: false)
        page.run("video.paused = true;")
        page.send(.fadeInOnPlay(milliseconds: 350))
        page.event("play", at: 100, "video.paused = false")
        #expect(page.volume == 0.6)
    }

    @Test("Resume fades in from silence once playback starts")
    func resumeFadesIn() throws {
        let page = try TransitionPage()
        page.run("video.paused = true; video.currentTime = 30;")
        page.send(.fadeInOnPlay(milliseconds: 350))
        #expect(near(page.volume, 0))
        page.event("play", at: 1000, "video.paused = false")
        #expect(near(page.volume, 0))
        page.event("timeupdate", at: 1175)
        #expect(near(page.volume, 0.6 * 0.5.squareRoot()))
        page.event("timeupdate", at: 1400)
        #expect(page.volume == 0.6)
    }

    @Test("A resume fade-in that never plays expires at the user's volume")
    func resumeFadeExpires() throws {
        let page = try TransitionPage()
        page.run("video.paused = true;")
        page.send(.fadeInOnPlay(milliseconds: 350))
        page.event("play", at: 6000, "video.paused = false")
        #expect(page.volume == 0.6)
    }
}

// MARK: - Commands

@Suite("Song transition commands", .tags(.service))
struct SongTransitionCommandTests {
    @Test("Commands are fixed calls with clamped integer arguments")
    func commandsAreClamped() {
        #expect(SongTransitionCommand.fadeOut(token: -4, milliseconds: 99999, fadeInMilliseconds: -1).script
            == "if (window.__kasetSongTransitions) { window.__kasetSongTransitions.fadeOut(0, 5000, 0); }")
        #expect(SongTransitionCommand.release(token: 9, superseded: true).script
            == "if (window.__kasetSongTransitions) { window.__kasetSongTransitions.release(9, true); }")
        #expect(SongTransitionCommand.fadeInOnPlay(milliseconds: 350).script
            == "if (window.__kasetSongTransitions) { window.__kasetSongTransitions.fadeInOnPlay(350); }")
        #expect(SongTransitionCommand.configure(SongTransitionSettings(crossfadeSeconds: 40, fadesTransportControls: true)).script
            == "if (window.__kasetSongTransitions) { window.__kasetSongTransitions.configure({ crossfadeSeconds: 12, fadesTransportControls: true }); }")
    }

    @Test("Settings clamp crossfade to 0…12 seconds")
    func settingsClamp() {
        #expect(SongTransitionSettings(crossfadeSeconds: -2, fadesTransportControls: false).crossfadeSeconds == 0)
        #expect(SongTransitionSettings(crossfadeSeconds: 13, fadesTransportControls: false).crossfadeSeconds == 12)
        #expect(SongTransitionSettings(crossfadeSeconds: 5, fadesTransportControls: false).isCrossfadeEnabled)
        #expect(!SongTransitionSettings.off.isCrossfadeEnabled)
    }
}

// MARK: - Loudness trim

@Suite("Song transitions keep YouTube's loudness trim", .tags(.service))
@MainActor
struct SongTransitionLoudnessTests {
    /// A `#movie_player` whose response is for `id` with `db` loudness.
    private static func player(id: String, db: Double, playing: String? = nil) -> String {
        """
        moviePlayer = { getPlayerResponse: function() { return { videoDetails: { videoId: '\(id)' },
            playerConfig: { audioConfig: { loudnessDb: \(db) } } }; },
          getVideoData: function() { return { video_id: '\(playing ?? id)' }; } };
        """
    }

    private static let trim = 0.770_016 // loudnessDb 2.27

    @Test("After a crossfade a loud track settles at YouTube's trimmed level, not the raw volume")
    func fadeInSettlesAtTrimmedLevel() throws {
        let page = try TransitionPage(crossfadeSeconds: 8)
        page.run(Self.player(id: "aaaaaaaaaaa", db: -1))
        page.event("timeupdate", at: 0, "video.currentTime = 199.9")
        page.event("pause", at: 100, "video.currentTime = 200; video.paused = true; video.ended = true")
        page.event("ended")
        page.run(Self.player(id: "bbbbbbbbbbb", db: 2.27))
        page.event("loadstart", at: 400, "video.currentSrc = 'blob:track-2'; video.ended = false; video.currentTime = 0; video.duration = NaN")
        page.event("playing", at: 900, "video.paused = false")
        page.event("timeupdate", at: 1650, "video.currentTime = 0.75; video.duration = 180")
        #expect(near(page.volume, 0.6 * Self.trim * 0.5.squareRoot()))
        page.event("timeupdate", at: 2450, "video.currentTime = 1.55")
        #expect(near(page.volume, 0.6 * Self.trim))
        // YouTube writes the same trimmed level; the settle step must not push it back up.
        page.event("volumechange", at: 2600, "video.volume = \(0.6 * Self.trim)")
        page.event("timeupdate", at: 2700, "video.currentTime = 1.8")
        #expect(near(page.volume, 0.6 * Self.trim))
    }

    @Test("A loud track's end fade starts from its trimmed level, never jumping up")
    func tailStartsFromTrimmedLevel() throws {
        let page = try TransitionPage(crossfadeSeconds: 5)
        page.run(Self.player(id: "aaaaaaaaaaa", db: 2.27))
        page.run("video.volume = \(0.6 * Self.trim);")
        page.event("timeupdate", at: 0, "video.currentTime = 100")
        #expect(near(page.volume, 0.6 * Self.trim))
        page.event("timeupdate", at: 1000, "video.currentTime = 195.05")
        #expect(page.volume <= 0.6 * Self.trim + 0.001)
        page.event("timeupdate", at: 2000, "video.currentTime = 197.5")
        #expect(near(page.volume, 0.6 * Self.trim * 0.5.squareRoot()))
        #expect(near(page.number("window.__kasetLoudnessTrim()"), Self.trim))
    }

    @Test("A player response for another video is not trusted")
    func staleResponseKeepsUserVolume() throws {
        let page = try TransitionPage(crossfadeSeconds: 8)
        page.event("timeupdate", at: 0, "video.currentTime = 199.9")
        page.event("pause", at: 100, "video.currentTime = 200; video.paused = true; video.ended = true")
        page.event("ended")
        page.run(Self.player(id: "aaaaaaaaaaa", db: 2.27, playing: "bbbbbbbbbbb"))
        page.event("loadstart", at: 400, "video.currentSrc = 'blob:track-2'; video.ended = false; video.currentTime = 0; video.duration = NaN")
        page.event("playing", at: 900, "video.paused = false")
        page.event("timeupdate", at: 2450, "video.currentTime = 1.55; video.duration = 180")
        #expect(page.volume == 0.6)
    }
}
