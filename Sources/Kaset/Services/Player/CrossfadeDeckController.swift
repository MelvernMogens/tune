import AppKit
import Foundation
import WebKit

// MARK: - CrossfadeDeckController

/// Runs the true crossfade: polls the main page and the crossfade deck while a song
/// nears its end, asks ``CrossfadeDeckPlanner`` what to do, and owns the deck's lifetime.
///
/// With crossfade off the controller does not run at all and no deck exists. With it on,
/// it checks Kaset's native state once a second and only touches the pages (250 ms polls)
/// from `CrossfadeTiming.deckLeadSeconds` before the crossfade until the handoff ends.
/// The page engines own the audio timing (see `WebPlaybackSongTransitions`); this side
/// only decides which song the deck holds and when it exists.
@MainActor
final class CrossfadeDeckController {
    static let shared = CrossfadeDeckController()

    /// Per-launch channel name suffix shared by both pages.
    let channelToken = Int.random(in: 1 ... Int(Int32.max))

    private var loopTask: Task<Void, Never>?
    private var planner = CrossfadeDeckPlanner()
    private var deck: CrossfadeDeckWebView?
    private var lastPrimaryPhase: CrossfadePrimaryPhase = .none
    private var inProgressSince: ContinuousClock.Instant?
    private var pausedSince: ContinuousClock.Instant?
    private var lastDeckVolume: Double?
    private var lastDeckHold: Bool?
    /// A deck page that could not even be created; reported to the planner as failed.
    private var failedCreationVideoId: String?
    /// Next is starting a quick overlap; a second press meanwhile takes the plain path.
    private var isBeginningQuickOverlap = false
    /// Set by `nudge()`: the loop runs its next step now instead of after its sleep.
    private var wakeRequested = false
    private(set) var handoff: CrossfadeHandoff?
    private let logger = DiagnosticsLogger.player

    private static let nearInterval: Duration = .milliseconds(250)
    private static let farInterval: Duration = .seconds(1)
    /// The loop's sleep is sliced so a nudge (seek, Next) is answered within this.
    private static let sleepSlice: Duration = .milliseconds(250)
    /// A deck kept through a pause longer than this is released.
    private static let pausedDeckLifetime: Duration = .seconds(60)
    private static let handoffLifetimeMilliseconds: Double = 15000

    private init() {}

    var hasDeck: Bool {
        self.deck != nil
    }

    /// Handoff for a main-page document starting now, if one is still valid.
    var handoffForNewDocument: CrossfadeHandoff? {
        guard let handoff = self.handoff,
              Date().timeIntervalSince1970 * 1000 < handoff.expiresAtMilliseconds
        else { return nil }
        return handoff
    }

    /// Starts the loop when crossfade is on; with it off, cleans up and stops.
    func settingsDidChange(_ settings: SongTransitionSettings) {
        if settings.isCrossfadeEnabled {
            self.startIfNeeded()
        } else if self.loopTask != nil || self.deck != nil {
            // The page engine cancels its own overlap on configure; release the deck.
            self.tearDownDeck()
            self.handoff = nil
            self.lastPrimaryPhase = .none
            self.inProgressSince = nil
            self.loopTask?.cancel()
            self.loopTask = nil
        }
    }

    func startIfNeeded() {
        guard self.loopTask == nil,
              SettingsManager.shared.crossfadeSeconds > 0,
              !UITestConfig.isRunningUnitTests
        else { return }
        self.loopTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                guard let interval = await self.tick() else {
                    self.loopTask = nil
                    return
                }
                await self.sleep(interval)
            }
        }
    }

    /// Re-evaluates now (a seek or skip may have moved the song into, or out of, the
    /// crossfade window), so the deck is created without waiting for the next poll.
    func nudge() {
        guard SettingsManager.shared.crossfadeSeconds > 0 else { return }
        if self.loopTask == nil {
            self.startIfNeeded()
        } else {
            self.wakeRequested = true
        }
    }

    private func sleep(_ interval: Duration) async {
        var left = interval
        while left > .zero, !self.wakeRequested, !Task.isCancelled {
            let slice = min(left, Self.sleepSlice)
            try? await Task.sleep(for: slice)
            left -= slice
        }
        self.wakeRequested = false
    }

    // MARK: Seeks near the end

    /// Where a user seek should land so the crossfade still has room (see
    /// `CrossfadeTiming.seekTarget`). Unchanged when no crossfade would run.
    func seekTarget(for time: Double, player: PlayerService) -> Double {
        let seconds = SettingsManager.shared.crossfadeSeconds
        guard seconds > 0,
              player.state == .playing,
              self.isEligible(player, crossfadeSeconds: seconds),
              let nextIndex = player.expectedQueueIndexAfterCurrentTrack(),
              let next = player.queue[safe: nextIndex]?.videoId,
              next != player.currentTrack?.videoId
        else { return time }
        let isDeckReady = self.deck?.videoId == next && {
            switch self.lastPrimaryPhase {
            case .armed, .overlapping: true
            default: false
            }
        }()
        return CrossfadeTiming.seekTarget(time, duration: player.duration, isDeckReady: isDeckReady)
    }

    // MARK: Next with the deck ready

    /// Starts a short overlap into the queue's next song when the deck already holds it.
    /// Returns the overlap length, or nil when Next should use the plain transition.
    func beginQuickOverlap(player: PlayerService) async -> Int? {
        let seconds = SettingsManager.shared.crossfadeSeconds
        guard seconds > 0,
              !self.isBeginningQuickOverlap,
              let deck = self.deck,
              let token = self.lastPrimaryPhase.token,
              case .armed = self.lastPrimaryPhase,
              player.state == .playing,
              let nextIndex = player.expectedQueueIndexAfterCurrentTrack(),
              player.repeatMode != .one,
              player.queue[safe: nextIndex]?.videoId == deck.videoId,
              let primary = SingletonPlayerWebView.shared.webView
        else { return nil }
        let milliseconds = CrossfadeTiming.quickOverlapMilliseconds(crossfadeSeconds: seconds)
        self.isBeginningQuickOverlap = true
        defer { self.isBeginningQuickOverlap = false }
        let script = "return window.__kasetSongTransitions ? window.__kasetSongTransitions.quickOverlap(\(token), \(milliseconds)) === true : false;"
        let started = (try? await primary.callAsyncJavaScript(script, arguments: [:], in: nil, contentWorld: .page)) as? Bool
        guard started == true else { return nil }
        self.lastPrimaryPhase = .overlapping(token: token)
        self.inProgressSince = ContinuousClock.now
        self.setHandoff(token: token, videoId: deck.videoId)
        self.startIfNeeded()
        return milliseconds
    }

    /// The skip behind a quick overlap was dropped: stop the overlap.
    func cancelQuickOverlap() {
        SingletonPlayerWebView.shared.sendSongTransitionCommand(.cancelOverlap(token: nil))
    }

    // MARK: Loop

    /// One step; returns the delay before the next, or nil to stop the loop.
    private func tick() async -> Duration? {
        let crossfadeSeconds = SettingsManager.shared.crossfadeSeconds
        guard crossfadeSeconds > 0 || self.deck != nil else {
            self.handoff = nil
            return nil
        }
        guard let player = SingletonPlayerWebView.shared.coordinator?.playerService,
              let primary = SingletonPlayerWebView.shared.webView
        else {
            self.tearDownDeck()
            return Self.farInterval
        }

        let remaining: Double? = player.duration > 0 && player.duration.isFinite
            ? max(0, player.duration - player.progress)
            : nil
        let near = remaining.map { $0 <= Double(crossfadeSeconds) + CrossfadeTiming.deckLeadSeconds + 1 } ?? false
        // Far from any song end with nothing in flight: native state only, no page work.
        if !near, self.deck == nil, self.lastPrimaryPhase == .none, self.handoff == nil {
            return Self.farInterval
        }

        // A document that is still loading has no engine to ask; an in-flight
        // crossfade carries on in the new document (see `handoffForNewDocument`).
        if let phase = await Self.primaryPhase(primary) {
            self.lastPrimaryPhase = phase
        } else if !(self.lastPrimaryPhase.isInProgress && self.handoffForNewDocument != nil) {
            self.lastPrimaryPhase = .none
        }
        if self.lastPrimaryPhase.isInProgress {
            if self.inProgressSince == nil { self.inProgressSince = ContinuousClock.now }
        } else {
            self.inProgressSince = nil
        }
        let deckStatus: CrossfadeDeckStatus = if let deck = self.deck {
            await deck.status()
        } else if let failedCreationVideoId = self.failedCreationVideoId {
            .failed(videoId: failedCreationVideoId)
        } else {
            .none
        }

        let input = CrossfadeDeckPlanner.Input(
            crossfadeSeconds: crossfadeSeconds,
            isEligible: self.isEligible(player, crossfadeSeconds: crossfadeSeconds),
            currentVideoId: player.currentTrack?.videoId,
            nextVideoId: player.expectedQueueIndexAfterCurrentTrack().flatMap { player.queue[safe: $0]?.videoId },
            remaining: remaining,
            deck: deckStatus,
            primary: self.lastPrimaryPhase,
            inProgressSeconds: self.inProgressSince.map { Self.seconds(ContinuousClock.now - $0) }
        )
        for action in self.planner.decide(input) {
            self.perform(action, player: player, container: primary.superview)
        }
        if let deck = self.deck, self.lastDeckVolume != player.volume {
            deck.setVolume(player.volume)
            self.lastDeckVolume = player.volume
        }
        // While the deck is the audible song (handoff), the main element is silent and
        // may not even be playing, so the user's pause reaches the deck from here.
        if let deck = self.deck, self.lastPrimaryPhase.isInProgress {
            let hold = player.isExplicitPauseIntentActive
            if self.lastDeckHold != hold {
                if hold || self.lastDeckHold == true { deck.setHold(hold) }
                self.lastDeckHold = hold
            }
        } else {
            self.lastDeckHold = nil
        }
        let busy = self.deck != nil || self.lastPrimaryPhase != .none
        return busy || near ? Self.nearInterval : Self.farInterval
    }

    private func perform(_ action: CrossfadeDeckPlanner.Action, player: PlayerService, container: NSView?) {
        switch action {
        case let .loadDeck(videoId, _):
            self.tearDownDeck()
            self.failedCreationVideoId = videoId
            guard let container,
                  let webKitManager = SingletonPlayerWebView.shared.webKitManager,
                  let deck = CrossfadeDeckWebView(
                      videoId: videoId,
                      channelToken: self.channelToken,
                      volume: player.volume,
                      webKitManager: webKitManager,
                      container: container
                  )
            else { return }
            deck.onRemoteCommand = { [weak player] command in
                player?.enqueueRemoteMusicTransportCommand(
                    command,
                    issuedAtMilliseconds: Date().timeIntervalSince1970 * 1000
                )
            }
            self.failedCreationVideoId = nil
            self.deck = deck
            self.lastDeckVolume = player.volume
        case let .preparePrimary(token, videoId):
            SingletonPlayerWebView.shared.sendSongTransitionCommand(
                .prepareOverlap(token: token, videoId: videoId, channelToken: self.channelToken)
            )
        case let .armPrimary(token):
            SingletonPlayerWebView.shared.sendSongTransitionCommand(.armOverlap(token: token))
        case let .cancelPrimary(token):
            SingletonPlayerWebView.shared.sendSongTransitionCommand(.cancelOverlap(token: token))
        case .rewindDeck:
            self.deck?.rewind()
        case .tearDownDeck:
            self.failedCreationVideoId = nil
            self.tearDownDeck()
        case let .keepHandoff(token, videoId):
            self.setHandoff(token: token, videoId: videoId)
        case .clearHandoff:
            self.handoff = nil
        }
    }

    private func setHandoff(token: Int, videoId: String) {
        if let handoff, handoff.token == token, handoff.videoId == videoId {
            return
        }
        self.handoff = CrossfadeHandoff(
            token: token,
            videoId: videoId,
            channelToken: self.channelToken,
            expiresAtMilliseconds: Date().timeIntervalSince1970 * 1000 + Self.handoffLifetimeMilliseconds
        )
    }

    private func tearDownDeck() {
        guard let deck else { return }
        self.deck = nil
        self.lastDeckVolume = nil
        self.lastDeckHold = nil
        deck.tearDown()
    }

    /// Whether a true crossfade fits what is playing right now.
    private func isEligible(_ player: PlayerService, crossfadeSeconds: Int) -> Bool {
        let isPausedTooLong: Bool
        if player.state == .paused {
            let since = self.pausedSince ?? ContinuousClock.now
            self.pausedSince = since
            isPausedTooLong = ContinuousClock.now - since > Self.pausedDeckLifetime
        } else {
            self.pausedSince = nil
            isPausedTooLong = false
        }
        let isActive = player.state == .playing || player.state == .buffering
            || (player.state == .paused && self.deck != nil && !isPausedTooLong)
        return isActive
            && !player.isShowingAd
            && !player.isAirPlayConnected
            && !player.showVideo
            && !player.isNowPlayingVideoVisible
            && SingletonPlayerWebView.shared.displayMode == .hidden
            && player.repeatMode != .one
            && player.currentEpisode == nil
            && player.currentTrack?.musicVideoType != .podcastEpisode
            && !player.isRestoringPlaybackSession
            && !player.isPendingRestoredLoadDeferred
            && !SingletonPlayerWebView.shared.isUsingCookieFreeDataStore
            && player.duration > Double(crossfadeSeconds * SongTransitionTiming.minimumTrackLengthMultiple)
    }

    /// The page engine's overlap phase, or nil when the document has no engine yet.
    private static func primaryPhase(_ webView: WKWebView) async -> CrossfadePrimaryPhase? {
        let script = "return window.__kasetSongTransitions && window.__kasetSongTransitions.overlapState ? JSON.stringify(window.__kasetSongTransitions.overlapState()) : null;"
        guard let json = (try? await webView.callAsyncJavaScript(script, arguments: [:], in: nil, contentWorld: .page)) as? String,
              let data = json.data(using: .utf8),
              let state = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        return CrossfadePrimaryPhase.fromPage(
            phase: state["phase"] as? String,
            token: (state["token"] as? NSNumber)?.intValue
        )
    }

    private static func seconds(_ duration: Duration) -> Double {
        let components = duration.components
        return Double(components.seconds) + Double(components.attoseconds) / 1e18
    }
}
