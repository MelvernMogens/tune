import Foundation
import JavaScriptCore
import Testing
@testable import Kaset

// MARK: - Planner

@Suite("Crossfade deck planner", .tags(.service))
struct CrossfadeDeckPlannerTests {
    private func input(
        crossfade: Int = 5,
        eligible: Bool = true,
        current: String? = "aaaaaaaaaaa",
        next: String? = "bbbbbbbbbbb",
        remaining: Double? = 9,
        deck: CrossfadeDeckStatus = .none,
        primary: CrossfadePrimaryPhase = .none,
        inProgress: Double? = nil
    ) -> CrossfadeDeckPlanner.Input {
        CrossfadeDeckPlanner.Input(
            crossfadeSeconds: crossfade,
            isEligible: eligible,
            currentVideoId: current,
            nextVideoId: next,
            remaining: remaining,
            deck: deck,
            primary: primary,
            inProgressSeconds: inProgress
        )
    }

    @Test("No deck far from the end, with crossfade off, or when ineligible")
    func noDeckOutsideTheLeadWindow() {
        var planner = CrossfadeDeckPlanner()
        #expect(planner.decide(self.input(remaining: 60)) == [.clearHandoff])
        #expect(planner.decide(self.input(crossfade: 0)) == [.clearHandoff])
        #expect(planner.decide(self.input(eligible: false)) == [.clearHandoff])
        #expect(planner.decide(self.input(next: nil)) == [.clearHandoff])
        #expect(planner.decide(self.input(next: "aaaaaaaaaaa")) == [.clearHandoff])
    }

    @Test("Inside the lead window the deck loads the next song and the page is told")
    func loadsDeckInsideLeadWindow() {
        var planner = CrossfadeDeckPlanner()
        let remaining = 5 + CrossfadeTiming.deckLeadSeconds
        #expect(planner.decide(self.input(remaining: remaining)) == [
            .clearHandoff,
            .loadDeck(videoId: "bbbbbbbbbbb", token: 1),
            .preparePrimary(token: 1, videoId: "bbbbbbbbbbb"),
        ])
        // Still loading: nothing new while the page already waits for this token.
        #expect(planner.decide(self.input(deck: .loading(videoId: "bbbbbbbbbbb"), primary: .pending(token: 1)))
            == [.clearHandoff])
        // Ready: the page is armed once.
        #expect(planner.decide(self.input(deck: .ready(videoId: "bbbbbbbbbbb"), primary: .pending(token: 1)))
            == [.clearHandoff, .armPrimary(token: 1)])
        #expect(planner.decide(self.input(deck: .ready(videoId: "bbbbbbbbbbb"), primary: .armed(token: 1)))
            == [.clearHandoff])
    }

    @Test("A deck for the wrong song is replaced and the waiting page re-prepared")
    func replacesDeckWhenNextSongChanges() {
        var planner = CrossfadeDeckPlanner()
        _ = planner.decide(self.input())
        let actions = planner.decide(self.input(
            next: "ccccccccccc",
            deck: .ready(videoId: "bbbbbbbbbbb"),
            primary: .armed(token: 1)
        ))
        #expect(actions == [
            .clearHandoff,
            .cancelPrimary(token: 1),
            .loadDeck(videoId: "ccccccccccc", token: 2),
            .preparePrimary(token: 2, videoId: "ccccccccccc"),
        ])
    }

    @Test("Leaving the window (scrub out, skip) tears the deck down")
    func tearsDownOutsideWindow() {
        var planner = CrossfadeDeckPlanner()
        _ = planner.decide(self.input())
        #expect(planner.decide(self.input(remaining: 80, deck: .ready(videoId: "bbbbbbbbbbb"), primary: .armed(token: 1)))
            == [.clearHandoff, .cancelPrimary(token: 1), .tearDownDeck])
    }

    @Test("While the overlap is in progress the deck is kept and the handoff carried")
    func keepsDeckDuringOverlap() {
        var planner = CrossfadeDeckPlanner()
        _ = planner.decide(self.input())
        let deck = CrossfadeDeckStatus.playing(videoId: "bbbbbbbbbbb")
        for phase in [CrossfadePrimaryPhase.overlapping(token: 1), .late(token: 1), .handoff(token: 1), .swap(token: 1)] {
            // Even ineligible (loading the next song) and far from any end.
            #expect(planner.decide(self.input(eligible: false, remaining: 200, deck: deck, primary: phase, inProgress: 3))
                == [.keepHandoff(token: 1, videoId: "bbbbbbbbbbb")])
        }
    }

    @Test("A lost deck or a stuck overlap is cancelled so the page recovers")
    func cancelsBrokenOverlap() {
        var planner = CrossfadeDeckPlanner()
        #expect(planner.decide(self.input(deck: .none, primary: .handoff(token: 1), inProgress: 2))
            == [.cancelPrimary(token: nil), .clearHandoff])
        #expect(planner.decide(self.input(deck: .failed(videoId: "bbbbbbbbbbb"), primary: .overlapping(token: 1), inProgress: 2))
            == [.cancelPrimary(token: nil), .clearHandoff])
        let limit = CrossfadeTiming.sessionHardLimitSeconds + 1
        #expect(planner.decide(self.input(deck: .playing(videoId: "bbbbbbbbbbb"), primary: .handoff(token: 1), inProgress: limit))
            == [.cancelPrimary(token: nil), .tearDownDeck, .clearHandoff])
        #expect(planner.decide(self.input(crossfade: 0, deck: .playing(videoId: "bbbbbbbbbbb"), primary: .overlapping(token: 1)))
            == [.cancelPrimary(token: nil), .clearHandoff])
    }

    @Test("After a handoff the finished song never gets a second deck")
    func noSecondDeckForCrossfadedSong() {
        var planner = CrossfadeDeckPlanner()
        _ = planner.decide(self.input())
        _ = planner.decide(self.input(deck: .playing(videoId: "bbbbbbbbbbb"), primary: .handoff(token: 1), inProgress: 1))
        // The handoff closed but Kaset still reports the old song (its queue advance lags).
        #expect(planner.decide(self.input(remaining: 0.2, deck: .stopped(videoId: "bbbbbbbbbbb")))
            == [.clearHandoff, .tearDownDeck])
        // Once the next song is current, its own end gets a deck again.
        _ = planner.decide(self.input(current: "bbbbbbbbbbb", next: "ccccccccccc", remaining: 120))
        #expect(planner.decide(self.input(current: "bbbbbbbbbbb", next: "ccccccccccc", remaining: 8)).contains(
            .loadDeck(videoId: "ccccccccccc", token: 2)
        ))
    }

    @Test("A failed deck is not retried for the same song, but is for the next one")
    func failedDeckIsNotRetried() {
        var planner = CrossfadeDeckPlanner()
        _ = planner.decide(self.input())
        #expect(planner.decide(self.input(deck: .failed(videoId: "bbbbbbbbbbb"), primary: .pending(token: 1)))
            == [.clearHandoff, .cancelPrimary(token: 1), .tearDownDeck])
        #expect(planner.decide(self.input()) == [.clearHandoff])
        #expect(planner.decide(self.input(next: "ccccccccccc")).contains(.loadDeck(videoId: "ccccccccccc", token: 2)))
    }

    @Test("A deck audible without an overlap is rewound; a finished one is replaced")
    func strayDeckStates() {
        var planner = CrossfadeDeckPlanner()
        _ = planner.decide(self.input())
        #expect(planner.decide(self.input(deck: .playing(videoId: "bbbbbbbbbbb"), primary: .armed(token: 1)))
            == [.clearHandoff, .rewindDeck])
        #expect(planner.decide(self.input(deck: .stopped(videoId: "bbbbbbbbbbb"), primary: .armed(token: 1))) == [
            .clearHandoff,
            .cancelPrimary(token: 1),
            .loadDeck(videoId: "bbbbbbbbbbb", token: 2),
            .preparePrimary(token: 2, videoId: "bbbbbbbbbbb"),
        ])
    }

    @Test("Page phases map from the engine's strings")
    func phaseMapping() {
        #expect(CrossfadePrimaryPhase.fromPage(phase: "late", token: 3) == .late(token: 3))
        #expect(CrossfadePrimaryPhase.late(token: 3).isInProgress)
        #expect(CrossfadePrimaryPhase.late(token: 3).isHandingOff)
        #expect(!CrossfadePrimaryPhase.armed(token: 3).isInProgress)
        #expect(CrossfadePrimaryPhase.fromPage(phase: "armed", token: nil) == .none)
        #expect(CrossfadeDeckStatus.fromPage(phase: "paused", videoId: "x") == .playing(videoId: "x"))
        #expect(CrossfadeDeckStatus.fromPage(phase: "out", videoId: "x") == .fading(videoId: "x"))
    }
}

// MARK: - Timing

@Suite("Crossfade timing", .tags(.service))
struct CrossfadeTimingTests {
    @Test("Seeks into the last moments land early enough for an overlap")
    func seekTarget() {
        let ready = CrossfadeTiming.minimumOverlapSeconds
        let cold = ready + CrossfadeTiming.deckLoadAllowanceSeconds
        #expect(CrossfadeTiming.seekTarget(100, duration: 200, isDeckReady: false) == 100)
        #expect(CrossfadeTiming.seekTarget(197, duration: 200, isDeckReady: false) == 200 - cold)
        #expect(CrossfadeTiming.seekTarget(199.8, duration: 200, isDeckReady: false) == 200 - cold)
        #expect(CrossfadeTiming.seekTarget(199.8, duration: 200, isDeckReady: true) == 200 - ready)
        #expect(CrossfadeTiming.seekTarget(198, duration: 200, isDeckReady: true) == 198)
        #expect(CrossfadeTiming.seekTarget(5.9, duration: 6, isDeckReady: false) == 5.9)
        #expect(CrossfadeTiming.seekTarget(10, duration: .nan, isDeckReady: false) == 10)
    }

    @Test("Next overlaps for at most two seconds")
    func quickOverlap() {
        #expect(CrossfadeTiming.quickOverlapMilliseconds(crossfadeSeconds: 1) == 1000)
        #expect(CrossfadeTiming.quickOverlapMilliseconds(crossfadeSeconds: 12) == 2000)
        #expect(CrossfadeTiming.quickOverlapMilliseconds(crossfadeSeconds: -3) == 0)
    }

    @Test("Deck scripts refuse anything that is not a video id")
    func deckScriptValidation() {
        #expect(CrossfadeDeckScript.script(channelToken: 1, videoId: "abc';alert(1)//", volume: 1) == nil)
        #expect(CrossfadeDeckScript.watchURL(videoId: "short") == nil)
        #expect(CrossfadeDeckScript.script(channelToken: 1, videoId: "AbC-_1234xY", volume: 0.5) != nil)
        #expect(CrossfadeHandoff.specLiteral(token: 1, videoId: "bad id", channelToken: 2) == nil)
    }
}

// MARK: - Page engine overlap

/// Runs the shipped main-page engine in JavaScriptCore with a fake `<video>` (with a real
/// `volume` accessor on its prototype), a fake clock and a fake `BroadcastChannel`.
@MainActor
private struct OverlapPage {
    let context: JSContext

    init(crossfadeSeconds: Int = 5, targetVolume: Double = 0.8) throws {
        self.context = try #require(JSContext())
        self.context.exceptionHandler = { _, exception in
            Issue.record("JavaScript exception: \(exception?.toString() ?? "unknown")")
        }
        self.context.evaluateScript(Self.harness)
        self.context.evaluateScript("window.__kasetTargetVolume = \(targetVolume);")
        self.context.evaluateScript(WebPlaybackSongTransitions.script(settings: SongTransitionSettings(
            crossfadeSeconds: crossfadeSeconds,
            fadesTransportControls: false
        )))
    }

    @discardableResult
    func run(_ script: String) -> JSValue? {
        self.context.evaluateScript(script)
    }

    func number(_ expression: String) -> Double {
        self.run(expression)?.toDouble() ?? .nan
    }

    func string(_ expression: String) -> String {
        self.run(expression)?.toString() ?? ""
    }

    var volume: Double {
        self.number("video.volume")
    }

    var phase: String {
        self.string("window.__kasetSongTransitions.overlapState().phase")
    }

    /// Kinds of the messages this page posted to the deck, in order.
    var posted: [String] {
        (self.run("posted.map(function(m) { return m.k; })")?.toArray() as? [String]) ?? []
    }

    func event(_ type: String, at milliseconds: Double, _ media: String = "") {
        self.run("clock = \(milliseconds); \(media); dispatch('\(type)');")
    }

    /// The deck page reports its clock (`x` seconds of the next song) at `milliseconds`.
    func deck(_ phase: String, x: Double, at milliseconds: Double, paused: Bool = false) {
        self.run("clock = \(milliseconds); deckSays({ k: 'deck', T: clock, x: \(x), paused: \(paused), phase: '\(phase)', g: 1 });")
    }

    func send(_ command: SongTransitionCommand) {
        self.run(command.script)
    }

    /// Prepares and arms an overlap for the song `bbbbbbbbbbb` at 150 s of a 200 s song.
    func armed() {
        self.event("timeupdate", at: 0, "video.currentTime = 150")
        self.send(.prepareOverlap(token: 7, videoId: "bbbbbbbbbbb", channelToken: 1))
        self.send(.armOverlap(token: 7))
    }

    static let harness = """
    var window = globalThis;
    var clock = 0;
    var performance = { now: function() { return clock; } };
    Date.now = function() { return clock; };
    var listeners = {};
    var moviePlayer = { getVideoData: function() { return { video_id: playingId }; } };
    var playingId = 'aaaaaaaaaaa';
    function setInterval() { return 1; }
    function clearInterval() {}
    function setTimeout() { return 0; }
    var posted = [];
    var channels = [];
    function BroadcastChannel(name) { this.name = name; this.onmessage = null; channels.push(this); }
    BroadcastChannel.prototype.postMessage = function(message) { posted.push(message); };
    BroadcastChannel.prototype.close = function() { this.closed = true; };
    function deckSays(message) {
        channels.forEach(function(channel) { if (!channel.closed && channel.onmessage) channel.onmessage({ data: message }); });
    }
    function HTMLMediaElement() {}
    Object.defineProperty(HTMLMediaElement.prototype, 'volume', {
        configurable: true,
        get: function() { return this._volume; },
        set: function(value) { this._volume = value; }
    });
    var video = new HTMLMediaElement();
    video.tagName = 'VIDEO';
    video.paused = false;
    video.ended = false;
    video.seeking = false;
    video.readyState = 4;
    video.currentTime = 0;
    video.duration = 200;
    video.currentSrc = 'blob:track-1';
    video.__maxRate = 1;
    video.__minRate = 1;
    video._rate = 1;
    Object.defineProperty(video, 'playbackRate', {
        get: function() { return this._rate; },
        set: function(value) {
            this._rate = value;
            this.__maxRate = Math.max(this.__maxRate, value);
            this.__minRate = Math.min(this.__minRate, value);
        }
    });
    video._volume = 0.8;
    video.webkitCurrentPlaybackTargetIsWireless = false;
    var document = {
        addEventListener: function(type, listener) {
            (listeners[type] = listeners[type] || []).push(listener);
        },
        querySelector: function(selector) { return selector === 'video' ? video : null; },
        getElementById: function(id) { return id === 'movie_player' ? moviePlayer : null; }
    };
    function dispatch(type) {
        (listeners[type] || []).forEach(function(listener) { listener({ type: type, target: video }); });
    }
    """
}

private func near(_ lhs: Double, _ rhs: Double, tolerance: Double = 0.003) -> Bool {
    abs(lhs - rhs) <= tolerance
}

@Suite("Crossfade deck page engine", .tags(.service))
@MainActor
struct CrossfadeOverlapEngineTests {
    @Test("The deck starts with the tail and fades in over the time that is left")
    func overlapStartsWithTail() throws {
        let page = try OverlapPage()
        page.armed()
        #expect(page.phase == "armed")
        page.event("timeupdate", at: 1000, "video.currentTime = 194")
        #expect(page.posted.isEmpty)
        page.event("timeupdate", at: 2000, "video.currentTime = 195.2")
        #expect(page.phase == "overlapping")
        #expect(page.posted == ["start"])
        #expect(near(page.number("posted[0].fade"), 4.8))
        // The outgoing song fades on its normal tail curve.
        page.event("timeupdate", at: 4400, "video.currentTime = 197.5")
        #expect(near(page.volume, 0.8 * 0.5.squareRoot()))
    }

    @Test("Natural end: the next song is held silent, synced to the deck, then swapped in")
    func handoffSyncsAndSwaps() throws {
        let page = try OverlapPage()
        page.armed()
        page.event("timeupdate", at: 1000, "video.currentTime = 195.5")
        page.deck("playing", x: 0.2, at: 1200)
        page.event("ended", at: 5500, "video.currentTime = 200; video.ended = true; video.paused = true")
        #expect(page.phase == "overlapping")
        // The SPA navigation swaps the media to the deck's song.
        page.run("playingId = 'bbbbbbbbbbb';")
        page.event("loadstart", at: 6000, "video.currentSrc = 'blob:track-2'; video.ended = false; video.currentTime = 0")
        page.event("playing", at: 6300, "video.paused = false")
        #expect(page.phase == "handoff")
        page.deck("playing", x: 5.2, at: 6300)
        page.event("timeupdate", at: 6300)
        #expect(page.volume < 0.001)
        // First sync step seeks to the deck's clock (plus the expected latency).
        #expect(page.number("video.currentTime") > 5.2)
        // Once five samples agree within tolerance, the swap is posted.
        for step in 1 ... 6 {
            let at = 6300 + Double(step) * 40
            page.deck("playing", x: 5.2 + Double(step) * 0.04, at: at)
            page.event("timeupdate", at: at, "video.currentTime = \(5.2 + Double(step) * 0.04)")
            #expect(page.volume < 0.001 || page.phase == "swap")
        }
        #expect(page.phase == "swap")
        #expect(page.posted.last == "swap")
        // A YouTube volume reset during the swap can't make it jump to full volume.
        page.run("video.volume = 0.8;")
        #expect(page.volume < 0.8)
        page.event("timeupdate", at: 6700, "video.currentTime = 5.6")
        page.event("timeupdate", at: 7000, "video.currentTime = 5.9")
        #expect(page.phase == "none")
        #expect(page.volume == 0.8)
        #expect(page.number("video.playbackRate") == 1)
        // Alignment never changes the playback rate (WebKit's time-pitch path crackles).
        #expect(page.number("video.__maxRate") <= 1.0001)
        #expect(page.number("video.__minRate") >= 0.9999)
    }

    @Test("YouTube resetting the volume while the next song is held never unmutes it")
    func heldElementIgnoresVolumeResets() throws {
        let page = try OverlapPage()
        page.armed()
        page.event("timeupdate", at: 1000, "video.currentTime = 195.5")
        page.deck("playing", x: 0.2, at: 1200)
        page.event("ended", at: 5500, "video.currentTime = 200; video.ended = true; video.paused = true")
        page.run("playingId = 'bbbbbbbbbbb';")
        page.event("loadstart", at: 6000, "video.currentSrc = 'blob:track-2'; video.ended = false; video.currentTime = 0")
        page.event("playing", at: 6300, "video.paused = false")
        page.deck("playing", x: 5.2, at: 6300)
        page.event("timeupdate", at: 6300)
        #expect(page.phase == "handoff")
        page.run("video.volume = 0.8;")
        #expect(page.volume < 0.001)
    }

    @Test("Scrubbing back out of the window cancels the overlap; the boundary does not")
    func scrubOutCancelsButBoundaryDoesNot() throws {
        let page = try OverlapPage()
        page.armed()
        page.event("timeupdate", at: 1000, "video.currentTime = 196")
        page.deck("playing", x: 0.5, at: 1500)
        #expect(page.phase == "overlapping")
        // Duration briefly unknown (media emptying at the boundary): not a scrub.
        page.event("durationchange", at: 1600, "video.duration = NaN")
        #expect(page.phase == "overlapping")
        #expect(!page.posted.contains("cancel"))
        page.run("video.duration = 200;")
        // A real seek back to mid-song stops the deck and recovers this song.
        page.event("seeking", at: 2000, "video.currentTime = 60")
        page.event("seeked", at: 2050)
        page.event("timeupdate", at: 2100)
        #expect(page.posted.contains("cancel"))
        #expect(page.phase == "armed")
        page.event("timeupdate", at: 2600, "video.currentTime = 60.5")
        #expect(page.volume == 0.8)
    }

    @Test("A deck that was still loading at the end starts late and covers the load")
    func lateDeckCoversTheGap() throws {
        let page = try OverlapPage()
        page.event("timeupdate", at: 0, "video.currentTime = 150")
        page.send(.prepareOverlap(token: 7, videoId: "bbbbbbbbbbb", channelToken: 1))
        // Held at full volume while the deck loads, then the plain fade over what is left.
        page.event("timeupdate", at: 1000, "video.currentTime = 197")
        #expect(page.volume == 0.8)
        page.event("timeupdate", at: 3000, "video.currentTime = 199.2")
        page.event("timeupdate", at: 3400, "video.currentTime = 199.6")
        #expect(page.volume < 0.8)
        page.event("ended", at: 3800, "video.currentTime = 200; video.ended = true; video.paused = true")
        #expect(page.phase == "late")
        page.deck("ready", x: 0, at: 4200)
        page.event("timeupdate", at: 4200)
        #expect(page.posted == ["start"])
        #expect(near(page.number("posted[0].fade"), CrossfadeTiming.lateStartFadeSeconds))
        page.run("playingId = 'bbbbbbbbbbb';")
        page.event("loadstart", at: 4500, "video.currentSrc = 'blob:track-2'; video.ended = false; video.currentTime = 0")
        #expect(page.phase == "handoff")
    }

    @Test("If the next song plays before a late deck is ready, it simply fades in")
    func lateDeckLosesToPrimary() throws {
        let page = try OverlapPage()
        page.event("timeupdate", at: 0, "video.currentTime = 150")
        page.send(.prepareOverlap(token: 7, videoId: "bbbbbbbbbbb", channelToken: 1))
        page.event("ended", at: 1000, "video.currentTime = 200; video.ended = true; video.paused = true")
        page.run("playingId = 'bbbbbbbbbbb';")
        page.event("loadstart", at: 1500, "video.currentSrc = 'blob:track-2'; video.ended = false; video.currentTime = 0")
        page.event("playing", at: 1800, "video.paused = false")
        #expect(page.phase == "none")
        #expect(page.posted.contains("cancel"))
        page.event("timeupdate", at: 2000, "video.currentTime = 0.2")
        #expect(page.volume > 0 && page.volume < 0.8)
        page.event("timeupdate", at: 2400, "video.currentTime = 0.6")
        #expect(page.volume == 0.8)
    }

    @Test("Turning crossfade off mid-overlap stops the deck and restores the volume")
    func disablingCancels() throws {
        let page = try OverlapPage()
        page.armed()
        page.event("timeupdate", at: 1000, "video.currentTime = 197")
        #expect(page.phase == "overlapping")
        page.send(.configure(.off))
        #expect(page.phase == "none")
        #expect(page.posted.last == "cancel")
        page.event("timeupdate", at: 1400, "video.currentTime = 197.4")
        #expect(page.volume == 0.8)
    }

    @Test("Pausing mid-overlap pauses the deck; resuming continues it")
    func pauseFollowsDeck() throws {
        let page = try OverlapPage()
        page.armed()
        page.event("timeupdate", at: 1000, "video.currentTime = 196")
        page.event("pause", at: 1500, "video.paused = true")
        #expect(page.posted.last == "pause")
        page.event("playing", at: 3000, "video.paused = false")
        #expect(page.posted.last == "resume")
    }

    @Test("Next with the deck ready overlaps for the quick window")
    func quickOverlap() throws {
        let page = try OverlapPage()
        page.armed()
        #expect(page.run("window.__kasetSongTransitions.quickOverlap(7, 2000)")?.toBool() == true)
        #expect(page.posted == ["start"])
        page.event("timeupdate", at: 1000, "video.currentTime = 151")
        #expect(near(page.volume, 0.8 * 0.5.squareRoot()))
        page.event("timeupdate", at: 2100, "video.currentTime = 152.1")
        #expect(page.volume < 0.001)
        // A quick overlap that is never followed by the skip recovers on its own.
        page.event("timeupdate", at: 5200, "video.currentTime = 155.2")
        #expect(page.phase == "none")
        page.event("timeupdate", at: 5600, "video.currentTime = 155.6")
        #expect(page.volume == 0.8)
    }
}
