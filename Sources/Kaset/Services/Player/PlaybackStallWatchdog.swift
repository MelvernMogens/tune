import Foundation

// MARK: - PlaybackStallWatchdog

/// Pure decision logic that detects Music playback which silently stopped advancing.
///
/// Kaset's natural track-end path is event driven: the WebView observer reports
/// `ended`, Swift advances its queue, and a router or document navigation loads the
/// next song. Every link is guarded by generation/identity checks and one-shot,
/// confirmation-gated fallbacks, so a lost event, a confirmation satisfied by a
/// paused target, an exhausted page-side autoplay budget, or a throttled WebContent
/// process can leave playback stuck with no further signal. This watchdog is the
/// liveness backstop: it samples native playback state on a fixed tick and escalates
/// through bounded recovery actions only while Kaset intends audible playback.
///
/// The type performs no I/O. ``PlayerService`` builds an ``Observation`` per tick and
/// performs the returned ``Action``, which keeps every decision unit-testable.
struct PlaybackStallWatchdog: Equatable {
    struct Configuration: Equatable {
        /// A load or native handoff that has not produced playing media. Longer than the
        /// router fallback (15 s) plus its full-page reload, and the native handoff timeout
        /// (3 s), so Kaset's own bounded fallbacks always win first.
        var transitionTimeout: Duration = .seconds(30)
        /// The target media was confirmed but never started (paused at its first second).
        var unstartedTimeout: Duration = .seconds(10)
        /// The current track sits at its end while Kaset still intends playback.
        var endedWithoutAdvanceTimeout: Duration = .seconds(6)
        /// Kaset reports `.playing` but the content clock has not moved.
        var frozenProgressTimeout: Duration = .seconds(25)
        /// Minimum spacing between two recovery actions, so a slower recovery can finish.
        var recoveryCooldown: Duration = .seconds(20)
        /// An advertisement whose clock moved within this window counts as live playback.
        var advertisementProgressGrace: Duration = .seconds(5)
        /// Total recoveries allowed before any forward content progress is observed again.
        var maxRecoveriesWithoutProgress = 5
        /// Minimum forward clock movement that proves playback is alive.
        var progressEpsilon: TimeInterval = 0.25
        /// Distance from the end of a track that counts as "finished".
        var nearEndTolerance: TimeInterval = 1.5
        /// A paused target past this position already played, so its pause is left alone.
        /// This also covers a watchdog that starts observing mid-track.
        var unstartedProgressCeiling: TimeInterval = 2

        static let `default` = Configuration()
    }

    /// A single native playback sample.
    struct Observation: Equatable {
        var now: ContinuousClock.Instant
        /// Kaset intends audible playback: no explicit/user pause, stop, end, or deferred restore.
        var wantsPlayback: Bool
        /// Identifies the current playback target. A change starts a new stall window.
        var trackKey: String?
        /// A load, restore, or native queue handoff is in flight.
        var isTransitioning: Bool
        /// Native transport state is `.playing`.
        var isPlaying: Bool
        var progress: TimeInterval
        var duration: TimeInterval
        var isShowingAd: Bool
        var lastAdvertisementProgressAt: ContinuousClock.Instant?
        /// The queue can continue after the current track (next entry, repeat, or mix continuation).
        var hasSuccessor: Bool
        /// Kaset's own track-end handler is still running (for example awaiting a mix
        /// continuation). Its stall gets the longer transition budget before recovery.
        var isAdvanceInFlight = false
        /// Media is routed to an external receiver (AirPlay), whose clock reporting is
        /// not reliable enough to treat a still clock as a frozen pipeline.
        var isExternalPlaybackRoute = false
        /// The page's own media controls are visible (video window), so a paused or
        /// still clock may be the listener's choice rather than a stall.
        var isMediaUserControllable = false
        /// Without connectivity every recovery would fail; the stall window waits instead.
        var isNetworkAvailable = true
    }

    enum StallKind: String, Equatable, Sendable {
        /// Navigation/handoff started but the target never reported playing media.
        case transition
        /// The target was confirmed but stayed paused at its start.
        case unstarted
        /// The track finished but nothing advanced to its successor.
        case endedWithoutAdvance
        /// Playing state with a clock that stopped moving.
        case frozenProgress
    }

    enum Action: Equatable {
        case none
        /// Ask the current document to play its (already confirmed) media.
        case resumeMedia(StallKind)
        /// Retry the expected target through YouTube Music's SPA router.
        case retryViaRouter(StallKind)
        /// Replace the playback document with a full load of the expected target.
        case reloadFullPage(StallKind)
        /// Move to the queue successor (or replay under repeat-one).
        case advance(StallKind)
        /// Stop escalating and pause so the UI reflects reality.
        case giveUp(StallKind)

        var stallKind: StallKind? {
            switch self {
            case .none: nil
            case let .resumeMedia(kind), let .retryViaRouter(kind), let .reloadFullPage(kind),
                 let .advance(kind), let .giveUp(kind):
                kind
            }
        }
    }

    let configuration: Configuration
    private(set) var recoveriesWithoutProgress = 0
    private(set) var stallKind: StallKind?
    private(set) var stallSince: ContinuousClock.Instant?
    private(set) var cooldownUntil: ContinuousClock.Instant?
    private(set) var trackKey: String?
    private(set) var trackHasStarted = false
    private(set) var hasGivenUp = false
    private var lastProgress: TimeInterval?

    init(configuration: Configuration = .default) {
        self.configuration = configuration
    }

    /// Forgets all stall state. Called whenever Kaset stops intending playback,
    /// so a user pause or stop always disarms recovery.
    mutating func reset() {
        self.recoveriesWithoutProgress = 0
        self.stallKind = nil
        self.stallSince = nil
        self.cooldownUntil = nil
        self.trackKey = nil
        self.trackHasStarted = false
        self.hasGivenUp = false
        self.lastProgress = nil
    }

    // swiftlint:disable:next cyclomatic_complexity
    mutating func evaluate(_ observation: Observation) -> Action {
        guard observation.wantsPlayback else {
            self.reset()
            return .none
        }

        if observation.trackKey != self.trackKey {
            // A new target restarts the stall window, but the recovery level persists
            // until real progress: a recovery that itself changes the target (reload or
            // skip) must not be able to loop forever.
            self.trackKey = observation.trackKey
            self.trackHasStarted = false
            self.lastProgress = nil
            self.clearStall()
        }

        let advancedForward = self.lastProgress.map {
            observation.progress - $0 >= self.configuration.progressEpsilon
        } ?? false
        self.lastProgress = observation.progress

        if observation.isPlaying, advancedForward, !observation.isShowingAd {
            self.trackHasStarted = true
            self.recoveriesWithoutProgress = 0
            self.hasGivenUp = false
            self.cooldownUntil = nil
            self.clearStall()
            return .none
        }

        if observation.isShowingAd,
           let lastAdvertisementProgressAt = observation.lastAdvertisementProgressAt,
           observation.now - lastAdvertisementProgressAt <= self.configuration.advertisementProgressGrace
        {
            // A live advertisement is legitimate playback; it is not content start.
            self.clearStall()
            return .none
        }

        guard !self.hasGivenUp else { return .none }

        guard observation.isNetworkAvailable else {
            // Restart the window after reconnecting instead of burning the budget offline.
            self.clearStall()
            return .none
        }

        guard let kind = self.classify(observation) else {
            self.clearStall()
            return .none
        }
        if self.stallKind != kind {
            self.stallKind = kind
            self.stallSince = observation.now
        }
        guard let stallSince = self.stallSince,
              observation.now - stallSince >= self.timeout(
                  for: kind,
                  isAdvanceInFlight: observation.isAdvanceInFlight
              )
        else { return .none }
        if let cooldownUntil = self.cooldownUntil, observation.now < cooldownUntil {
            return .none
        }

        guard self.recoveriesWithoutProgress < self.configuration.maxRecoveriesWithoutProgress else {
            self.hasGivenUp = true
            self.clearStall()
            return .giveUp(kind)
        }

        let action = Self.recoveryAction(
            for: kind,
            level: self.recoveriesWithoutProgress,
            hasSuccessor: observation.hasSuccessor
        )
        self.recoveriesWithoutProgress += 1
        self.cooldownUntil = observation.now.advanced(by: self.configuration.recoveryCooldown)
        self.stallSince = observation.now
        return action
    }

    /// Classifies a non-progressing sample. Returns `nil` for states that must not be
    /// recovered automatically: a mid-track pause of media that already played may come
    /// from outside Kaset (AirPlay receiver, the visible video page, an OS route change),
    /// and resuming it would override the listener. YouTube Music's own idle pause is
    /// prevented in-page by ``SingletonPlayerWebView/idlePromptGuardScript``.
    private func classify(_ observation: Observation) -> StallKind? {
        if observation.isMediaUserControllable {
            // The video window (or the click-to-start toast) is attended, and the page's
            // own controls can legitimately pause, scrub, or hold a track at its end.
            return nil
        }
        if observation.isTransitioning {
            return .transition
        }
        let isAtEnd = observation.duration > 0
            && observation.progress >= observation.duration - self.configuration.nearEndTolerance
        if isAtEnd {
            // Resuming finished media would restart it, so a finished track either
            // advances or, at the end of a non-repeating queue, is left alone.
            return observation.hasSuccessor ? .endedWithoutAdvance : nil
        }
        if observation.isExternalPlaybackRoute {
            // An AirPlay receiver negotiates and reports its clock on its own schedule;
            // only the long transition budget and a finished track are trusted there.
            return nil
        }
        if observation.isPlaying {
            return .frozenProgress
        }
        if !self.trackHasStarted, observation.progress <= self.configuration.unstartedProgressCeiling {
            return .unstarted
        }
        return nil
    }

    private func timeout(for kind: StallKind, isAdvanceInFlight: Bool) -> Duration {
        switch kind {
        case .transition: self.configuration.transitionTimeout
        case .unstarted: self.configuration.unstartedTimeout
        case .endedWithoutAdvance:
            isAdvanceInFlight
                ? self.configuration.transitionTimeout
                : self.configuration.endedWithoutAdvanceTimeout
        case .frozenProgress: self.configuration.frozenProgressTimeout
        }
    }

    /// Escalation ladder. The level is the number of recoveries already attempted
    /// since the last real progress; the last rung repeats until the global budget
    /// in ``Configuration/maxRecoveriesWithoutProgress`` turns into ``Action/giveUp(_:)``.
    ///
    /// A no-progress streak skips at most one song for load failures: the level
    /// survives target changes, so a skipped-to track that also fails only reloads.
    /// A frozen clock never skips, because the usual cause (a network outage) would
    /// otherwise silently burn through the listener's queue.
    static func recoveryAction(for kind: StallKind, level: Int, hasSuccessor: Bool) -> Action {
        let skipOrReload: Action = hasSuccessor ? .advance(kind) : .reloadFullPage(kind)
        let ladder: [Action] = switch kind {
        case .transition:
            // `play()` here could restart the outgoing media, so start with navigation.
            [.retryViaRouter(kind), .reloadFullPage(kind), skipOrReload, .reloadFullPage(kind)]
        case .unstarted:
            [.resumeMedia(kind), .retryViaRouter(kind), .reloadFullPage(kind), skipOrReload, .reloadFullPage(kind)]
        case .endedWithoutAdvance:
            // Reloading a finished song would replay it; only the successor helps.
            [.advance(kind)]
        case .frozenProgress:
            [.resumeMedia(kind), .reloadFullPage(kind)]
        }
        return ladder[min(max(level, 0), ladder.count - 1)]
    }

    private mutating func clearStall() {
        self.stallKind = nil
        self.stallSince = nil
    }
}
