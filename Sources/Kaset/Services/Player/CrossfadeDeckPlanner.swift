import Foundation

// MARK: - CrossfadeDeckStatus

/// What the crossfade deck page is doing, as last polled.
enum CrossfadeDeckStatus: Equatable {
    case none
    case loading(videoId: String)
    /// Buffered and paused at 0, ready to start.
    case ready(videoId: String)
    /// Playing (or paused mid-overlap).
    case playing(videoId: String)
    /// Fading out after a swap or cancel; settles to `ready` (cancel) or `stopped`.
    case fading(videoId: String)
    /// Finished: swapped out, ended, or YouTube moved on. Never restarted.
    case stopped(videoId: String)
    case failed(videoId: String)

    var videoId: String? {
        switch self {
        case .none: nil
        case let .loading(id), let .ready(id), let .playing(id), let .fading(id), let .stopped(id), let .failed(id): id
        }
    }

    /// Maps the deck page's `phase` string.
    static func fromPage(phase: String?, videoId: String) -> CrossfadeDeckStatus {
        switch phase {
        case "ready": .ready(videoId: videoId)
        case "playing", "paused": .playing(videoId: videoId)
        case "out": .fading(videoId: videoId)
        case "stopped": .stopped(videoId: videoId)
        default: .loading(videoId: videoId)
        }
    }
}

// MARK: - CrossfadePrimaryPhase

/// The main page engine's overlap state (`__kasetSongTransitions.overlapState()`).
enum CrossfadePrimaryPhase: Equatable {
    case none
    case pending(token: Int)
    case armed(token: Int)
    case overlapping(token: Int)
    /// The song ended before the deck had started; it starts as soon as it is ready.
    case late(token: Int)
    case handoff(token: Int)
    case swap(token: Int)

    var token: Int? {
        switch self {
        case .none: nil
        case let .pending(token), let .armed(token), let .overlapping(token), let .late(token),
             let .handoff(token), let .swap(token): token
        }
    }

    /// The deck is (or is about to be) audible: the page owns the outcome now.
    var isInProgress: Bool {
        switch self {
        case .overlapping, .late, .handoff, .swap: true
        case .none, .pending, .armed: false
        }
    }

    var isHandingOff: Bool {
        switch self {
        case .late, .handoff, .swap: true
        case .none, .pending, .armed, .overlapping: false
        }
    }

    var isWaiting: Bool {
        switch self {
        case .pending, .armed: true
        case .none, .overlapping, .late, .handoff, .swap: false
        }
    }

    static func fromPage(phase: String?, token: Int?) -> CrossfadePrimaryPhase {
        guard let token else { return .none }
        switch phase {
        case "pending": return .pending(token: token)
        case "armed": return .armed(token: token)
        case "overlapping": return .overlapping(token: token)
        case "late": return .late(token: token)
        case "handoff": return .handoff(token: token)
        case "swap": return .swap(token: token)
        default: return .none
        }
    }
}

// MARK: - CrossfadeDeckPlanner

/// Pure decisions for the crossfade deck's lifecycle (no I/O; `CrossfadeDeckController`
/// polls both pages, builds an ``Input`` and performs the returned actions).
///
/// The deck exists only from `CrossfadeTiming.deckLeadSeconds` before the crossfade
/// until the handoff finishes; between songs, with crossfade off, or whenever the
/// overlap cannot be used, there is no deck at all.
struct CrossfadeDeckPlanner: Equatable {
    struct Input: Equatable {
        var crossfadeSeconds: Int
        /// Music is playing (or briefly paused) in a state a true crossfade supports.
        var isEligible: Bool
        var currentVideoId: String?
        /// The queue's song after the current one (nil: none known, repeat-one, …).
        var nextVideoId: String?
        /// Seconds left in the current song, when known.
        var remaining: Double?
        var deck: CrossfadeDeckStatus
        var primary: CrossfadePrimaryPhase
        /// How long the primary has been in an in-progress phase.
        var inProgressSeconds: Double?
    }

    enum Action: Equatable {
        /// Creates a fresh deck page (tearing down any previous one) for `videoId`.
        case loadDeck(videoId: String, token: Int)
        case preparePrimary(token: Int, videoId: String)
        case armPrimary(token: Int)
        case cancelPrimary(token: Int?)
        /// Stops the deck's playback and rewinds it (it stays loaded).
        case rewindDeck
        case tearDownDeck
        /// Keep an in-flight crossfade available to a new main-page document.
        case keepHandoff(token: Int, videoId: String)
        case clearHandoff
    }

    private(set) var token = 0
    /// A deck that failed for this song is not retried until the target changes.
    private(set) var failedVideoId: String?
    /// The song a crossfade started from. Until Kaset reports the next song as current,
    /// that song gets no second deck (its overlap already happened).
    private(set) var crossfadedSourceVideoId: String?

    mutating func decide(_ input: Input) -> [Action] {
        if input.primary.isInProgress {
            // From the handoff on, the source song is over (an overlap that is only
            // overlapping can still be scrubbed back out of and re-armed).
            if self.crossfadedSourceVideoId == nil, input.primary.isHandingOff,
               input.currentVideoId != input.deck.videoId
            {
                self.crossfadedSourceVideoId = input.currentVideoId
            }
            return self.decideInProgress(input)
        }
        if let source = self.crossfadedSourceVideoId, source != input.currentVideoId {
            self.crossfadedSourceVideoId = nil
        }
        var actions: [Action] = [.clearHandoff]

        guard input.crossfadeSeconds > 0 else {
            self.failedVideoId = nil
            if input.primary.isWaiting { actions.append(.cancelPrimary(token: input.primary.token)) }
            if input.deck != .none { actions.append(.tearDownDeck) }
            return actions
        }

        guard let target = Self.desiredTarget(input),
              self.crossfadedSourceVideoId == nil
        else {
            if input.primary.isWaiting { actions.append(.cancelPrimary(token: input.primary.token)) }
            if input.deck != .none { actions.append(.tearDownDeck) }
            return actions
        }
        if self.failedVideoId != nil, self.failedVideoId != target {
            self.failedVideoId = nil
        }
        if self.failedVideoId == target {
            if input.primary.isWaiting { actions.append(.cancelPrimary(token: input.primary.token)) }
            if input.deck != .none { actions.append(.tearDownDeck) }
            return actions
        }

        guard input.deck.videoId == target else {
            if input.primary.isWaiting { actions.append(.cancelPrimary(token: input.primary.token)) }
            self.token = self.token >= Int(Int32.max) ? 1 : self.token + 1
            actions.append(.loadDeck(videoId: target, token: self.token))
            actions.append(.preparePrimary(token: self.token, videoId: target))
            return actions
        }

        switch input.deck {
        case .loading:
            if input.primary != .pending(token: self.token), input.primary != .armed(token: self.token) {
                actions.append(.preparePrimary(token: self.token, videoId: target))
            }
        case .ready:
            switch input.primary {
            case .armed(token: self.token):
                break
            case .pending(token: self.token):
                actions.append(.armPrimary(token: self.token))
            default:
                if input.primary.isWaiting { actions.append(.cancelPrimary(token: input.primary.token)) }
                actions.append(.preparePrimary(token: self.token, videoId: target))
                actions.append(.armPrimary(token: self.token))
            }
        case .playing:
            // Audible without an overlap in progress (its cancel was missed): stop
            // and rewind it; it comes back as `ready` and is re-armed.
            actions.append(.rewindDeck)
        case .fading:
            break
        case .stopped:
            // A finished deck never restarts: load a fresh one.
            if input.primary.isWaiting { actions.append(.cancelPrimary(token: input.primary.token)) }
            self.token = self.token >= Int(Int32.max) ? 1 : self.token + 1
            actions.append(.loadDeck(videoId: target, token: self.token))
            actions.append(.preparePrimary(token: self.token, videoId: target))
        case .failed:
            self.failedVideoId = target
            if input.primary.isWaiting { actions.append(.cancelPrimary(token: input.primary.token)) }
            actions.append(.tearDownDeck)
        case .none:
            break
        }
        return actions
    }

    private func decideInProgress(_ input: Input) -> [Action] {
        let primaryToken = input.primary.token
        if input.crossfadeSeconds <= 0 {
            return [.cancelPrimary(token: nil), .clearHandoff]
        }
        if let elapsed = input.inProgressSeconds, elapsed > CrossfadeTiming.sessionHardLimitSeconds {
            return [.cancelPrimary(token: nil), .tearDownDeck, .clearHandoff]
        }
        switch input.deck {
        case .none, .failed:
            // The deck is gone: the page recovers on its own (stale deck clock);
            // make it immediate.
            return [.cancelPrimary(token: nil), .clearHandoff]
        default:
            break
        }
        guard let primaryToken, let videoId = input.deck.videoId else { return [.clearHandoff] }
        return [.keepHandoff(token: primaryToken, videoId: videoId)]
    }

    /// The song the deck should hold now, or nil when there should be no deck.
    static func desiredTarget(_ input: Input) -> String? {
        guard input.isEligible,
              let next = input.nextVideoId,
              let current = input.currentVideoId,
              next != current,
              let remaining = input.remaining,
              remaining.isFinite,
              remaining > 0,
              remaining <= Double(input.crossfadeSeconds) + CrossfadeTiming.deckLeadSeconds
        else { return nil }
        return next
    }
}
