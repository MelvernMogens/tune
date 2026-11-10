import Foundation

// MARK: - WebPlaybackSongTransitions

/// Page-side gain engine for song transitions on the main playback `<video>` element.
///
/// The engine owns one number, `gain` (0…1), and keeps the element at
/// `window.__kasetTargetVolume * trim * gain`, where `trim` is YouTube's own loudness
/// normalization for the track (`WebPlaybackLoudness`). The user's volume (`__kasetTargetVolume`) is
/// never modified, so the volume slider, persistence and the observer's enforcement
/// keep working on the base value; the observer's `enforceVolumeNow` reads
/// `window.__kasetTransitionGain()` so it enforces the faded value instead of
/// fighting it. While no fade is active the engine never writes the element volume.
///
/// Gain is the product of independent parts, each of which can only lower it:
/// - **tail**: equal-power fade-out over the last N seconds of a song, computed from
///   the media clock (`timeupdate` keeps firing while hidden). A seek that lands inside
///   the window fades from there over the time that is left;
/// - **fade-in**: equal-power fade-in of the next media, armed by a tail or a manual
///   skip and started when new media actually plays, measured on the media clock;
/// - **ramp**: wall-clock ramps for manual pause / resume / skip;
/// - **overlap**: the true crossfade with the crossfade deck (a second page that plays
///   the next song, see `CrossfadeDeckScript`). The deck starts when this song's tail
///   starts; when this element moves on to the same song it is held silent, seeked and
///   rate-nudged onto the deck's clock, and the two swap with a 150 ms equal-power fade.
///
/// Every part has a recovery path (pause, seek, new media, ads, AirPlay, expiry), so
/// the element always returns to exactly the level YouTube Music itself would set.
enum WebPlaybackSongTransitions {
    /// Document-start user script with the settings current at install time.
    /// `handoff` carries an in-flight crossfade into a fresh document, so a full-page
    /// navigation to the next song still starts silent and syncs to the deck.
    static func script(settings: SongTransitionSettings, handoff: CrossfadeHandoff? = nil) -> String {
        """
        (() => {
            const initialConfig = \(SongTransitionCommand.configLiteral(settings));
            const initialHandoff = \(handoff?.literal ?? "null");
            if (window.__kasetSongTransitions) {
                window.__kasetSongTransitions.configure(initialConfig);
                return;
            }
            \(Self.mathFunctions)
            \(PlaybackAdDetectionScript.detection)
            \(WebPlaybackLoudness.trimFunction)
            \(Self.engine)
        })();
        """
    }

    /// Pure curve and scheduling functions (also exercised directly by tests).
    static var mathFunctions: String {
        """
        const MAX_FADE_IN_SECONDS = \(SongTransitionTiming.maximumFadeInSeconds);
        const MIN_TRACK_MULTIPLE = \(SongTransitionTiming.minimumTrackLengthMultiple);

        function __kasetClampUnit(value) {
            if (typeof value !== 'number' || !Number.isFinite(value)) return 1;
            return Math.min(1, Math.max(0, value));
        }

        // Equal-power curves: out² + in² = 1 at every point, so a fade keeps
        // perceived loudness smooth instead of dipping in the middle.
        function __kasetEqualPowerOut(progress) {
            return Math.cos(__kasetClampUnit(progress) * Math.PI / 2);
        }

        function __kasetEqualPowerIn(progress) {
            return Math.sin(__kasetClampUnit(progress) * Math.PI / 2);
        }

        function __kasetFadeInSeconds(crossfadeSeconds) {
            if (typeof crossfadeSeconds !== 'number' || !Number.isFinite(crossfadeSeconds)) return 0;
            return Math.min(Math.max(crossfadeSeconds, 0), MAX_FADE_IN_SECONDS);
        }

        // Length of the end-of-song fade window, or 0 when this media gets none:
        // crossfade off, unknown/infinite duration (live), or a song too short
        // for the fade to sound intentional.
        function __kasetTailWindowSeconds(duration, crossfadeSeconds) {
            if (typeof crossfadeSeconds !== 'number' || !Number.isFinite(crossfadeSeconds)
                || crossfadeSeconds <= 0) return 0;
            if (typeof duration !== 'number' || !Number.isFinite(duration)
                || duration <= crossfadeSeconds * MIN_TRACK_MULTIPLE) return 0;
            return crossfadeSeconds;
        }

        function __kasetTailGain(currentTime, duration, crossfadeSeconds) {
            const windowSeconds = __kasetTailWindowSeconds(duration, crossfadeSeconds);
            if (windowSeconds <= 0 || typeof currentTime !== 'number'
                || !Number.isFinite(currentTime)) return 1;
            const remaining = duration - currentTime;
            if (remaining >= windowSeconds) return 1;
            return __kasetEqualPowerOut(1 - Math.max(0, remaining) / windowSeconds);
        }

        // A fade that starts part-way into the window (a seek landed there, or the
        // deck arrived late): from `startGain` to silence over `startRemaining` seconds.
        function __kasetShortenedTailGain(remaining, startRemaining, startGain) {
            if (typeof remaining !== 'number' || !Number.isFinite(remaining)) return 1;
            if (!(startRemaining > 0)) return 0;
            const progress = 1 - Math.max(0, remaining) / startRemaining;
            return __kasetClampUnit(startGain) * __kasetEqualPowerOut(progress);
        }
        """
    }

    private static var engine: String {
        """
        const ARM_LIFETIME_MS = 12000;
        const OUT_HOLD_MS = 3000;
        const RELEASE_GRACE_MS = 800;
        const RECOVERY_RAMP_MS = 250;
        const FADE_IN_PLAY_WAIT_MS = 4000;
        const BACKWARD_JUMP_SECONDS = 0.75;
        const TICK_MS = 40;
        const RESTART_SECONDS = 1;
        const STALE_GAIN_MS = 5000;
        const NATURAL_ENTRY_SLACK_SECONDS = 0.6;
        const END_PAUSE_SECONDS = 0.35;
        const OVERLAP_MIN_DECK_FADE_SECONDS = \(CrossfadeTiming.minimumDeckFadeSeconds);
        const OVERLAP_GIVE_UP_REMAINING_SECONDS = \(CrossfadeTiming.pendingGiveUpRemainingSeconds);
        const OVERLAP_RESTART_MS = 300;
        const OVERLAP_CANCEL_MS = 200;
        const QUICK_HOLD_MS = 3000;
        const HANDOFF_GIVE_UP_MS = \(CrossfadeTiming.handoffGiveUpMilliseconds);
        const HANDOFF_RELEASE_MS = 800;
        const HANDOFF_FADE_IN_SECONDS = 0.4;
        const SWAP_LEAD_MS = 80;
        const SWAP_MS = \(CrossfadeTiming.swapMilliseconds);
        const SYNC_TOLERANCE_SECONDS = \(CrossfadeTiming.syncToleranceSeconds);
        const SYNC_SAMPLES = 5;
        // Seek-only alignment (no rate nudging): re-seek whenever the error exceeds the
        // sync tolerance, learning the seek latency each time.
        const RESEEK_ERROR_SECONDS = SYNC_TOLERANCE_SECONDS;
        const RESEEK_GAP_MS = 300;
        const DECK_STALE_MS = 1500;
        const SETTLE_MS = 2000;
        const SETTLE_TOLERANCE = 0.01;
        const AD_CONFIRM_MS = 300;
        const LATE_START_FADE_SECONDS = \(CrossfadeTiming.lateStartFadeSeconds);
        const LATE_GIVE_UP_MS = \(CrossfadeTiming.lateGiveUpMilliseconds);

        let config = { crossfadeSeconds: 0, fadesTransportControls: false };
        let gain = 1;
        let appliedGain = 1;
        let ramp = null;
        let armed = null;
        let fadeIn = null;
        let tailRecord = null;
        let lastTailGain = 1;
        let podcastKey = null;
        let podcastValue = false;
        let lastTailActive = false;
        let lastTickKey = null;
        let lastTickAt = 0;
        let timer = null;
        // True crossfade with the deck page; see `CrossfadeDeckScript`.
        let overlap = null;
        let lastOverlapGain = 1;
        let lastOverlapResult = null;
        let handoffLatency = 0.15;
        let engineWrite = false;
        let adSeenAt = null;
        let settleUntil = 0;
        let trimKey = null;
        let trimValue = 1;

        function nowMs() {
            return (typeof performance !== 'undefined' && typeof performance.now === 'function')
                ? performance.now()
                : Date.now();
        }

        // Shared with the deck page (another process), so always the wall clock.
        function wallMs() {
            return Date.now();
        }

        function currentVideo() {
            return document.querySelector('video');
        }

        function mediaKey(video) {
            return String(video.currentSrc || video.src || '') + '|' + String(video.__kasetMediaGeneration || 0);
        }

        function playerVideoId() {
            try {
                const player = document.getElementById('movie_player');
                const data = player && typeof player.getVideoData === 'function' ? player.getVideoData() : null;
                return data && typeof data.video_id === 'string' && data.video_id ? data.video_id : null;
            } catch (_) {
                return null;
            }
        }

        function sanitizeConfig(value) {
            const seconds = value && typeof value.crossfadeSeconds === 'number'
                && Number.isFinite(value.crossfadeSeconds)
                ? Math.min(12, Math.max(0, Math.round(value.crossfadeSeconds)))
                : 0;
            return {
                crossfadeSeconds: seconds,
                fadesTransportControls: !!(value && value.fadesTransportControls === true)
            };
        }

        function isAdPlaying() {
            try {
                return hasAdPlayerSignal() || !!window.__kasetAdVideoId;
            } catch (_) {
                return false;
            }
        }

        // Podcast episodes play through the song queue too; they end on speech,
        // so they never get the end-of-song fade. Only read while in the tail
        // window, when the player response certainly describes this media.
        function isPodcast(key) {
            if (podcastKey === key) return podcastValue;
            let value = false;
            try {
                const player = document.getElementById('movie_player');
                const response = player && typeof player.getPlayerResponse === 'function'
                    ? player.getPlayerResponse()
                    : null;
                const type = response && response.videoDetails && response.videoDetails.musicVideoType;
                value = typeof type === 'string' && type.indexOf('PODCAST') !== -1;
            } catch (_) {}
            podcastKey = key;
            podcastValue = value;
            return value;
        }

        // YouTube's own per-track loudness trim for the media this element plays
        // (see `WebPlaybackLoudness`), cached per media and player video id.
        function loudnessTrim() {
            const video = currentVideo();
            const key = (video ? mediaKey(video) : '') + '|' + String(playerVideoId());
            if (key === trimKey) return trimValue;
            const value = __kasetLoudnessTrimFor(document.getElementById('movie_player'));
            if (value === null) return 1;
            trimKey = key;
            trimValue = value;
            return value;
        }

        // The level this element plays at with no fade: the user's volume scaled by
        // YouTube's loudness trim, i.e. exactly what YouTube Music itself would set.
        // Fades and the post-fade settle use it, so a loud track never comes back
        // hotter than YouTube plays it.
        function targetVolume() {
            const target = window.__kasetTargetVolume;
            if (typeof target !== 'number' || !Number.isFinite(target)) return null;
            return Math.min(1, Math.max(0, target)) * loudnessTrim();
        }

        function writeVolume(video, value) {
            engineWrite = true;
            try { video.volume = value; } catch (_) {}
            engineWrite = false;
        }

        function apply(video) {
            const target = targetVolume();
            if (target === null) return;
            const t = nowMs();
            if (gain < 1) settleUntil = t + SETTLE_MS;
            // Idle: never touch the element, so behaviour with transitions off
            // (or between fades) is exactly the volume enforcement's. Right after a
            // fade, the exact user volume is re-asserted so no residue sticks.
            if (gain >= 1 && appliedGain >= 1) {
                // Same tolerance as the observer's enforcement, so YouTube's own small
                // per-track loudness trim (e.g. 0.99) is left alone.
                if (t < settleUntil && Math.abs(video.volume - target) > SETTLE_TOLERANCE) writeVolume(video, target);
                return;
            }
            const effective = target * gain;
            appliedGain = gain;
            if (Math.abs(video.volume - effective) <= 0.002) return;
            writeVolume(video, effective);
        }

        // While this element is held under the deck (handoff, swap), YouTube resets
        // its volume on seeks and new media; such writes never make it louder than
        // the engine's level, so the held song can't flash in over the deck.
        (function guardVolumeWrites() {
            if (typeof HTMLMediaElement === 'undefined' || !HTMLMediaElement.prototype) return;
            const descriptor = Object.getOwnPropertyDescriptor(HTMLMediaElement.prototype, 'volume');
            if (!descriptor || !descriptor.get || !descriptor.set || !descriptor.configurable) return;
            Object.defineProperty(HTMLMediaElement.prototype, 'volume', {
                configurable: true,
                enumerable: descriptor.enumerable,
                get() { return descriptor.get.call(this); },
                set(value) {
                    let next = value;
                    if (!engineWrite && overlap && this === currentVideo()
                        && (overlap.phase === 'handoff' || overlap.phase === 'swap' || overlap.phase === 'late')) {
                        const target = targetVolume();
                        const requested = Number(value);
                        if (target !== null && Number.isFinite(requested)) {
                            next = Math.min(requested, target * __kasetClampUnit(gain));
                        }
                    }
                    descriptor.set.call(this, next);
                }
            });
        })();

        function resetAll() {
            ramp = null;
            armed = null;
            fadeIn = null;
        }

        function recoverFrom(level, t) {
            if (level >= 1) return;
            const from = ramp ? Math.min(level, rampGain(t, true)) : level;
            ramp = { kind: 'in', from: Math.max(0, from), startAt: t, ms: RECOVERY_RAMP_MS, expiresAt: t + RECOVERY_RAMP_MS };
        }

        function rampGain(t, playing) {
            if (!ramp) return 1;
            if (ramp.kind === 'out') {
                const progress = ramp.ms > 0 ? (t - ramp.startAt) / ramp.ms : 1;
                if (progress < 1) return ramp.from * __kasetEqualPowerOut(progress);
                if (t < ramp.holdUntil) return 0;
                // Nothing paused or replaced the media in time: recover.
                ramp = {
                    kind: 'in',
                    from: 0,
                    startAt: ramp.holdUntil,
                    ms: RECOVERY_RAMP_MS,
                    expiresAt: ramp.holdUntil + RECOVERY_RAMP_MS
                };
            }
            if (ramp.startAt === null) {
                // A resume that never started playing in time keeps no fade.
                if (t > ramp.expiresAt) { ramp = null; return 1; }
                if (!playing) return ramp.from;
                ramp.startAt = t;
            }
            const progress = ramp.ms > 0 ? (t - ramp.startAt) / ramp.ms : 1;
            if (progress >= 1) { ramp = null; return 1; }
            return ramp.from + (1 - ramp.from) * __kasetEqualPowerIn(progress);
        }

        function isInTailWindow(video, currentTime) {
            const windowSeconds = __kasetTailWindowSeconds(video.duration, config.crossfadeSeconds);
            return windowSeconds > 0 && typeof currentTime === 'number'
                && Number.isFinite(currentTime) && video.duration - currentTime < windowSeconds;
        }

        // MARK: overlap (crossfade deck)

        function overlapPost(message) {
            if (!overlap || !overlap.channel) return;
            try { overlap.channel.postMessage(message); } catch (_) {}
        }

        function openOverlap(spec, phase, sourceKey) {
            let channel = null;
            try {
                channel = typeof BroadcastChannel === 'function' ? new BroadcastChannel(spec.channel) : null;
            } catch (_) {
                channel = null;
            }
            if (!channel) return false;
            overlap = {
                token: spec.token,
                videoId: spec.videoId,
                channel: channel,
                phase: phase,
                sourceKey: sourceKey,
                deck: null,
                startPostedAt: null,
                deckPaused: false,
                quick: null,
                handoff: null,
                swap: null,
                // The source song ended before the deck could start (it was still
                // loading): the deck starts as soon as it can, see `lateStep`.
                sourceEnded: false,
                scrubbedOut: false,
                lateSince: null,
                lateTail: false
            };
            channel.onmessage = (event) => {
                const m = event && event.data;
                if (!overlap || !m || m.k !== 'deck') return;
                overlap.deck = {
                    T: Number(m.T),
                    x: Number(m.x),
                    paused: !!m.paused,
                    phase: String(m.phase || ''),
                    at: wallMs()
                };
            };
            return true;
        }

        function closeOverlap(result) {
            if (!overlap) return;
            lastOverlapResult = { token: overlap.token, result: result, at: wallMs() };
            try { overlap.channel.close(); } catch (_) {}
            overlap = null;
        }

        function deckNow() {
            if (!overlap || !overlap.deck || !Number.isFinite(overlap.deck.x)) return null;
            const deck = overlap.deck;
            return deck.paused ? deck.x : deck.x + Math.max(0, wallMs() - deck.T) / 1000;
        }

        function deckIsFresh() {
            return !!(overlap && overlap.deck && wallMs() - overlap.deck.at <= DECK_STALE_MS);
        }

        // Stops the overlap wherever it is; the deck fades out (and rewinds, so a
        // re-armed overlap can reuse it) and this element ramps back up.
        function cancelOverlap(result) {
            if (!overlap) return;
            const t = nowMs();
            const w = wallMs();
            switch (overlap.phase) {
            case 'overlapping':
            case 'late':
                overlapPost({ k: 'cancel', D: OVERLAP_CANCEL_MS });
                break;
            case 'handoff':
            case 'swap':
                overlapPost({ k: 'swap', Ts: w, D: OVERLAP_CANCEL_MS });
                break;
            default:
                break;
            }
            const video = currentVideo();
            if (video && overlap.handoff) {
                try { video.playbackRate = 1; } catch (_) {}
            }
            recoverFrom(lastOverlapGain, t);
            lastOverlapGain = 1;
            closeOverlap(result || 'cancelled');
        }

        function deckFadeSeconds(remaining) {
            return Math.max(OVERLAP_MIN_DECK_FADE_SECONDS, remaining);
        }

        // The deck starts now; this song's fade covers whatever is left of it.
        function startOverlap(video, key, remaining, windowSeconds) {
            if (remaining < windowSeconds - NATURAL_ENTRY_SLACK_SECONDS) {
                tailRecord = { key: key, startRemaining: Math.max(0.05, remaining), startGain: lastTailGain };
            }
            overlap.phase = 'overlapping';
            overlap.deckPaused = false;
            overlap.startPostedAt = wallMs();
            overlapPost({ k: 'start', fade: deckFadeSeconds(remaining) });
        }

        function beginHandoff() {
            overlap.phase = 'handoff';
            overlap.quick = null;
            overlap.handoff = { startedAt: wallMs(), seekAt: null, okCount: 0 };
            armed = null;
            fadeIn = null;
            tailRecord = null;
            if (ramp && ramp.kind === 'out') ramp = null;
        }

        function handoffGain(video, playing, hasClock, currentTime, t) {
            const w = wallMs();
            const handoff = overlap.handoff;
            const id = playerVideoId();
            if (id && id !== overlap.videoId) {
                // Something other than the deck's song is playing: let it in gently.
                overlapPost({ k: 'swap', Ts: w, D: OVERLAP_CANCEL_MS });
                try { video.playbackRate = 1; } catch (_) {}
                closeOverlap('mismatch');
                lastOverlapGain = 1;
                if (playing && hasClock) {
                    fadeIn = { start: currentTime, seconds: HANDOFF_FADE_IN_SECONDS, wallDeadline: t + 5000 };
                }
                return null;
            }
            const deckGone = (overlap.deck && overlap.deck.phase === 'stopped')
                || (!deckIsFresh() && w - handoff.startedAt > DECK_STALE_MS);
            if (deckGone) {
                try { video.playbackRate = 1; } catch (_) {}
                closeOverlap('deck-gone');
                recoverFrom(0, t);
                lastOverlapGain = 1;
                return null;
            }
            if (w - handoff.startedAt > HANDOFF_GIVE_UP_MS) {
                // Could not line up in time: fade the deck out and this element in
                // from where it is. Never silence, and the overlap ends here.
                try { video.playbackRate = 1; } catch (_) {}
                overlap.phase = 'swap';
                overlap.swap = { Ts: w, D: HANDOFF_RELEASE_MS };
                overlapPost({ k: 'swap', Ts: w, D: HANDOFF_RELEASE_MS });
                return 0;
            }
            if (deckIsFresh() && overlap.deck.phase === 'ready') {
                // The deck never started (a late or re-armed overlap). If this element
                // is already playing the song, it takes over; otherwise the deck
                // starts and covers the load.
                if (playing && hasClock) {
                    giveUpIntoFadeIn('deck-idle', video, playing, hasClock, currentTime, t);
                    return null;
                }
                if (overlap.startPostedAt === null || w - overlap.startPostedAt > OVERLAP_RESTART_MS) {
                    overlap.startPostedAt = w;
                    overlapPost({ k: 'start', fade: LATE_START_FADE_SECONDS });
                }
                return 0;
            }
            if (!playing || !hasClock || video.readyState < 2 || id !== overlap.videoId
                || !deckIsFresh() || overlap.deck.paused) {
                return 0;
            }
            const deckTime = deckNow();
            if (deckTime === null) return 0;
            const error = currentTime - deckTime;
            if (handoff.seekAt === null
                || (Math.abs(error) > RESEEK_ERROR_SECONDS && !video.seeking && w - handoff.seekAt > RESEEK_GAP_MS)) {
                if (handoff.seekAt !== null) {
                    handoffLatency = Math.max(0.05, Math.min(2, handoffLatency - error));
                }
                handoff.seekAt = w;
                handoff.okCount = 0;
                try { video.currentTime = deckTime + handoffLatency; } catch (_) {}
                return 0;
            }
            if (video.seeking) return 0;
            // Line up by seeking only, never by nudging playbackRate: once WebKit has
            // played an element at a rate other than 1 it keeps its time-pitch stretcher
            // engaged for the rest of the media, which crackles audibly on the songs that
            // follow ("it happens on the second song"). The element is silent here, so an
            // extra re-seek costs nothing.
            if (video.playbackRate !== 1) {
                try { video.playbackRate = 1; } catch (_) {}
            }
            handoff.okCount = Math.abs(error) < SYNC_TOLERANCE_SECONDS ? handoff.okCount + 1 : 0;
            if (handoff.okCount >= SYNC_SAMPLES) {
                const Ts = w + SWAP_LEAD_MS;
                overlap.phase = 'swap';
                overlap.swap = { Ts: Ts, D: SWAP_MS, error: error };
                overlapPost({ k: 'swap', Ts: Ts, D: SWAP_MS });
            }
            return 0;
        }

        // Ends an overlap that never became audible; the media now playing (or the
        // next to play) fades in briefly instead of starting at full volume.
        function giveUpIntoFadeIn(result, video, playing, hasClock, currentTime, t) {
            const sourceKey = overlap ? overlap.sourceKey : null;
            const songChanged = sourceKey === null || mediaKey(video) !== sourceKey;
            overlapPost({ k: 'cancel', D: OVERLAP_CANCEL_MS });
            try { video.playbackRate = 1; } catch (_) {}
            closeOverlap(result);
            lastOverlapGain = 1;
            if (playing && hasClock && songChanged) {
                fadeIn = { start: currentTime, seconds: HANDOFF_FADE_IN_SECONDS, wallDeadline: t + 5000 };
            } else {
                armed = {
                    key: sourceKey === null ? mediaKey(video) : sourceKey,
                    time: hasClock ? currentTime : 0,
                    seconds: HANDOFF_FADE_IN_SECONDS,
                    at: t,
                    fromTail: false,
                    sawNewMedia: songChanged
                };
            }
        }

        // The source song is over and the deck had not started: start it the moment
        // it is ready (it fills the silence while this element loads the same song),
        // then hand off as usual. If this element plays first, it simply fades in.
        function lateStep(video, key, playing, hasClock, currentTime, t) {
            const w = wallMs();
            const songChanged = key !== overlap.sourceKey;
            const id = playerVideoId();
            if (songChanged && id && id !== overlap.videoId) {
                giveUpIntoFadeIn('late-mismatch', video, playing, hasClock, currentTime, t);
                return { gain: 1, holdTail: false };
            }
            if (deckIsFresh() && overlap.deck.phase === 'ready') {
                overlap.phase = 'overlapping';
                overlap.startPostedAt = w;
                overlap.deckPaused = false;
                overlapPost({ k: 'start', fade: LATE_START_FADE_SECONDS });
                if (songChanged) {
                    beginHandoff();
                    return { gain: 0, holdTail: false };
                }
                return { gain: 1, holdTail: false };
            }
            if ((songChanged && playing) || w - overlap.lateSince > LATE_GIVE_UP_MS) {
                giveUpIntoFadeIn('late-lost', video, playing, hasClock, currentTime, t);
                return { gain: 1, holdTail: false };
            }
            return { gain: songChanged ? 0 : 1, holdTail: false };
        }

        // Gain part for the overlap; may also adjust `tailHeld` via the return shape.
        function overlapStep(video, key, playing, hasClock, currentTime, t, tail) {
            if (!overlap) return { gain: 1, holdTail: false };
            const w = wallMs();
            switch (overlap.phase) {
            case 'pending':
            case 'armed': {
                if (overlap.sourceEnded) {
                    // The song ended before the overlap could start: the deck still
                    // covers the gap while this element loads the next song.
                    overlap.phase = 'late';
                    overlap.lateSince = w;
                    return lateStep(video, key, playing, hasClock, currentTime, t);
                }
                if (overlap.sourceKey !== null && key !== overlap.sourceKey) {
                    cancelOverlap('song-changed');
                    return { gain: 1, holdTail: false };
                }
                if (!tail.inWindow) {
                    overlap.lateTail = false;
                    return { gain: 1, holdTail: false };
                }
                if (overlap.phase === 'armed') {
                    if (playing) startOverlap(video, key, tail.remaining, tail.windowSeconds);
                    return { gain: 1, holdTail: false };
                }
                // Deck still loading: hold this song at full volume while there is
                // time for the overlap, then fade it over what is left. The deck
                // starts whenever it is ready, even after this song has ended.
                if (tail.remaining > OVERLAP_GIVE_UP_REMAINING_SECONDS && !overlap.lateTail) {
                    return { gain: 1, holdTail: true };
                }
                if (!overlap.lateTail) {
                    overlap.lateTail = true;
                    tailRecord = { key: key, startRemaining: Math.max(0.05, tail.remaining), startGain: lastTailGain };
                }
                return { gain: 1, holdTail: false };
            }
            case 'late':
                return lateStep(video, key, playing, hasClock, currentTime, t);
            case 'overlapping': {
                if (overlap.sourceKey === null || key !== overlap.sourceKey) {
                    beginHandoff();
                    return { gain: 0, holdTail: false };
                }
                if (overlap.quick) {
                    const quick = overlap.quick;
                    if (w > quick.startAt + quick.ms + QUICK_HOLD_MS) {
                        cancelOverlap('quick-expired');
                        return { gain: 1, holdTail: false };
                    }
                    const progress = quick.ms > 0 ? (w - quick.startAt) / quick.ms : 1;
                    return { gain: progress >= 1 ? 0 : __kasetEqualPowerOut(progress), holdTail: false };
                }
                if (!tail.inWindow) {
                    // Only a seek back out of the window cancels. The element emptying
                    // or ending at the song boundary (duration unknown for a moment)
                    // is not a scrub, and the deck must keep playing through it.
                    if (!overlap.scrubbedOut) return { gain: 1, holdTail: false };
                    overlap.scrubbedOut = false;
                    // Scrubbed back out of the window: the deck stops and rewinds,
                    // ready for the next time this song reaches its end.
                    overlapPost({ k: 'cancel', D: OVERLAP_CANCEL_MS });
                    overlap.phase = 'armed';
                    overlap.startPostedAt = null;
                    overlap.deckPaused = false;
                    return { gain: 1, holdTail: false };
                }
                // A start that raced the deck's own rewind is sent again.
                if (playing && !overlap.deckPaused && overlap.deck && overlap.deck.phase === 'ready'
                    && overlap.startPostedAt !== null && w - overlap.startPostedAt > OVERLAP_RESTART_MS) {
                    overlap.startPostedAt = w;
                    overlapPost({ k: 'start', fade: deckFadeSeconds(tail.remaining) });
                }
                return { gain: 1, holdTail: false };
            }
            case 'handoff': {
                const value = handoffGain(video, playing, hasClock, currentTime, t);
                return { gain: value === null ? 1 : value, holdTail: false };
            }
            case 'swap': {
                const swap = overlap.swap;
                const progress = swap.D > 0 ? (w - swap.Ts) / swap.D : 1;
                if (progress >= 1) {
                    closeOverlap(swap.D === SWAP_MS ? 'done' : 'released');
                    return { gain: 1, holdTail: false };
                }
                return { gain: progress <= 0 ? 0 : __kasetEqualPowerIn(progress), holdTail: false };
            }
            default:
                return { gain: 1, holdTail: false };
            }
        }

        function tailState(video, key, hasClock, currentTime) {
            const windowSeconds = __kasetTailWindowSeconds(video.duration, config.crossfadeSeconds);
            if (windowSeconds <= 0 || !hasClock) {
                return { inWindow: false, remaining: Infinity, windowSeconds: windowSeconds };
            }
            const remaining = video.duration - currentTime;
            const inWindow = remaining < windowSeconds && !isPodcast(key);
            return { inWindow: inWindow, remaining: remaining, windowSeconds: windowSeconds };
        }

        function tick() {
            const video = currentVideo();
            if (!video) {
                stopTimer();
                return;
            }
            const t = nowMs();
            lastTickAt = t;
            // Nothing configured or in flight: no work at all (no ad probing).
            if (config.crossfadeSeconds <= 0 && !ramp && !armed && !fadeIn && !overlap
                && gain >= 1 && appliedGain >= 1) {
                stopTimer();
                return;
            }
            const playing = !video.paused && !video.ended;
            const currentTime = video.currentTime;
            const hasClock = typeof currentTime === 'number' && Number.isFinite(currentTime);

            // Ads and AirPlay always play at the user's exact volume. YouTube's player
            // reports an ad for a moment while it loads the next song, so an ad
            // signal counts only once it has lasted AD_CONFIRM_MS (otherwise that
            // blip cancelled the next song's fade-in and could cancel an overlap).
            const adNow = isAdPlaying();
            if (!adNow) adSeenAt = null;
            else if (adSeenAt === null) adSeenAt = t;
            const adConfirmed = adNow && t - adSeenAt >= AD_CONFIRM_MS;
            if (adConfirmed || video.webkitCurrentPlaybackTargetIsWireless) {
                if (overlap) cancelOverlap('ad-or-airplay');
                resetAll();
                tailRecord = null;
                lastTailActive = false;
                lastOverlapGain = 1;
                gain = 1;
                apply(video);
                stopTimer();
                return;
            }

            const key = mediaKey(video);
            let inGain = 1;
            const tail = tailState(video, key, hasClock, currentTime);
            const step = overlapStep(video, key, playing, hasClock, currentTime, t, tail);
            const overlapActive = !!overlap;

            if (armed && t - armed.at > ARM_LIFETIME_MS) armed = null;
            if (armed) {
                // New media, or the same media restarted (repeat, Previous →
                // seek 0), fades in. Other scrubbing never fades in from silence.
                const jumpedBack = hasClock && currentTime + BACKWARD_JUMP_SECONDS < armed.time;
                const isNewMedia = armed.sawNewMedia || key !== armed.key
                    || (jumpedBack && currentTime < RESTART_SECONDS);
                if (!isNewMedia && jumpedBack && armed.fromTail && !isInTailWindow(video, currentTime)) {
                    // Scrubbed back out of a song-end fade: no fade-in from
                    // silence, just a short ramp from where the fade had got to.
                    armed = null;
                    if (!ramp && gain < 1) {
                        ramp = { kind: 'in', from: gain, startAt: t, ms: RECOVERY_RAMP_MS, expiresAt: t + RECOVERY_RAMP_MS };
                    }
                } else if (isNewMedia) {
                    if (playing && hasClock) {
                        fadeIn = { start: currentTime, seconds: armed.seconds, wallDeadline: t + armed.seconds * 1000 + 5000 };
                        armed = null;
                        if (ramp && ramp.kind === 'out') ramp = null;
                    } else {
                        inGain = 0;
                    }
                }
            }

            if (fadeIn) {
                const elapsed = hasClock ? currentTime - fadeIn.start : Number.NaN;
                if (!Number.isFinite(elapsed) || elapsed < -0.25 || fadeIn.seconds <= 0
                    || elapsed >= fadeIn.seconds || t > fadeIn.wallDeadline) {
                    fadeIn = null;
                } else {
                    inGain = __kasetEqualPowerIn(Math.max(0, elapsed) / fadeIn.seconds);
                }
            }

            let tailGain = 1;
            let tailActive = false;
            if (tailRecord && tailRecord.key !== key) tailRecord = null;
            if (tail.inWindow && !step.holdTail) {
                tailActive = true;
                tailGain = tailRecord
                    ? __kasetShortenedTailGain(tail.remaining, tailRecord.startRemaining, tailRecord.startGain)
                    : __kasetTailGain(currentTime, video.duration, config.crossfadeSeconds);
                // Only the plain (single-element) transition fades the next song in;
                // with the deck, the next song is already playing.
                if (playing && !overlapActive) {
                    armed = {
                        key: key,
                        time: currentTime,
                        seconds: __kasetFadeInSeconds(config.crossfadeSeconds),
                        at: t,
                        fromTail: true,
                        sawNewMedia: false
                    };
                }
            } else if (!tail.inWindow && tailRecord) {
                tailRecord = null;
            }
            // With an overlap the plain path's `armed` recovery is off, so a scrub
            // back out of the window ramps up from where the fade had got to here.
            if (overlapActive && lastTailActive && !tailActive && key === lastTickKey && lastTailGain < 1) {
                recoverFrom(lastTailGain, t);
            }
            lastTailActive = tailActive;
            lastTailGain = tailGain;
            lastTickKey = key;

            if (overlapActive && armed && armed.fromTail) armed = null;

            const rGain = rampGain(t, playing);
            lastOverlapGain = overlap ? __kasetClampUnit(step.gain) : 1;
            gain = __kasetClampUnit(rGain * tailGain * inGain * step.gain);
            apply(video);

            // Smooth 40 ms steps only while something is fading on a playing
            // element; paused or idle media relies on media events alone. A
            // handoff keeps ticking while the next song loads.
            const handingOff = !!overlap && (overlap.phase === 'handoff' || overlap.phase === 'swap'
                || overlap.phase === 'late' || (overlap.phase === 'overlapping' && !!overlap.quick));
            const active = handingOff
                || (playing && (gain < 1 || !!ramp || !!fadeIn || tailActive || t < settleUntil
                    || (!!overlap && overlap.phase === 'overlapping')));
            if (active || adNow) startTimer(); else stopTimer();
        }

        function startTimer() {
            if (timer !== null) return;
            timer = setInterval(tick, TICK_MS);
        }

        function stopTimer() {
            if (timer === null) return;
            clearInterval(timer);
            timer = null;
        }

        function isNaturalEnd(video) {
            return video.ended || (Number.isFinite(video.duration) && Number.isFinite(video.currentTime)
                && video.duration - video.currentTime < END_PAUSE_SECONDS);
        }

        function onMediaEvent(event) {
            const video = event && event.target;
            if (!video || video.tagName !== 'VIDEO' || video !== currentVideo()) return;
            switch (event.type) {
            case 'loadstart':
            case 'emptied':
                // New media never inherits a held fade-out: if a fade-in is
                // armed it keeps the start silent until playback; otherwise the
                // next song plays at the user's volume.
                if (armed) armed.sawNewMedia = true;
                if (ramp && ramp.kind === 'out') ramp = null;
                fadeIn = null;
                tailRecord = null;
                break;
            case 'ended':
                if (overlap && overlap.sourceKey === mediaKey(video)) overlap.sourceEnded = true;
                break;
            case 'pause':
                // A paused element is silent; drop held fade-outs so it resumes
                // at the user's volume unless a resume fade-in is requested.
                if (ramp && ramp.kind === 'out') ramp = null;
                if (overlap && overlap.sourceKey === mediaKey(video) && isNaturalEnd(video)) {
                    overlap.sourceEnded = true;
                }
                if (overlap && overlap.phase === 'overlapping' && !overlap.quick
                    && overlap.sourceKey === mediaKey(video) && !isNaturalEnd(video)) {
                    overlap.deckPaused = true;
                    overlapPost({ k: 'pause' });
                }
                break;
            case 'play':
            case 'playing':
                if (overlap && overlap.phase === 'overlapping' && overlap.deckPaused
                    && overlap.sourceKey === mediaKey(video)) {
                    overlap.deckPaused = false;
                    const remaining = video.duration - video.currentTime;
                    if (Number.isFinite(remaining) && remaining > 0) {
                        overlapPost({ k: 'resume', fade: Math.max(0.3, remaining) });
                    }
                }
                break;
            case 'seeking':
                // Wait for `seeked`: the landing position decides the fade.
                return;
            case 'seeked': {
                const key = mediaKey(video);
                if (overlap && overlap.phase !== 'pending' && overlap.phase !== 'armed'
                    && overlap.phase !== 'overlapping') {
                    // The handoff's own seeks on the next song.
                    break;
                }
                const windowSeconds = __kasetTailWindowSeconds(video.duration, config.crossfadeSeconds);
                const remaining = video.duration - video.currentTime;
                const landedInTail = windowSeconds > 0 && Number.isFinite(remaining) && remaining < windowSeconds;
                if (landedInTail) {
                    // Seeking into the last seconds still crossfades, over the time
                    // that is left, starting from wherever the fade already was.
                    const startGain = lastTailActive ? lastTailGain : 1;
                    tailRecord = { key: key, startRemaining: Math.max(0.05, remaining), startGain: startGain };
                    if (overlap && overlap.phase === 'overlapping' && !overlap.quick) {
                        overlapPost({ k: 'refade', fade: Math.max(0.3, remaining) });
                    }
                } else {
                    tailRecord = null;
                    if (overlap && overlap.phase === 'overlapping' && !overlap.quick
                        && overlap.sourceKey === key && Number.isFinite(remaining)) {
                        overlap.scrubbedOut = true;
                    }
                }
                break;
            }
            case 'volumechange': {
                // Another writer (setVolume, YouTube) restored the base volume
                // mid-fade; re-apply the faded value. No-op while idle. Uses the
                // same (staleness-guarded) gain as the observer's enforcement so
                // the two can never pull in different directions.
                const effectiveGain = window.__kasetTransitionGain();
                if (effectiveGain < 1) {
                    const target = targetVolume();
                    if (target !== null && Math.abs(video.volume - target * effectiveGain) > 0.005) {
                        appliedGain = Math.min(appliedGain, effectiveGain);
                        writeVolume(video, target * effectiveGain);
                    }
                }
                return;
            }
            default:
                break;
            }
            tick();
        }

        [
            'timeupdate', 'play', 'playing', 'pause', 'ended', 'seeking', 'seeked',
            'loadstart', 'emptied', 'durationchange', 'volumechange',
            'webkitcurrentplaybacktargetiswirelesschanged'
        ].forEach(type => document.addEventListener(type, onMediaEvent, true));

        function isValidOverlapSpec(spec) {
            return !!spec && typeof spec.token === 'number' && Number.isFinite(spec.token)
                && typeof spec.videoId === 'string' && /^[A-Za-z0-9_-]{11}$/.test(spec.videoId)
                && typeof spec.channel === 'string' && spec.channel.indexOf('\(CrossfadeDeckScript.channelPrefix)') === 0;
        }

        const api = {
            configure(value) {
                config = sanitizeConfig(value);
                if (config.crossfadeSeconds <= 0) {
                    armed = null;
                    fadeIn = null;
                    tailRecord = null;
                    if (overlap) cancelOverlap('disabled');
                }
                if (!config.fadesTransportControls) ramp = null;
                tick();
            },
            fadeOut(token, milliseconds, fadeInMilliseconds) {
                const video = currentVideo();
                if (!video || video.paused || video.ended) return;
                const t = nowMs();
                const playing = true;
                const from = ramp ? rampGain(t, playing) : 1;
                ramp = {
                    kind: 'out',
                    token: token,
                    from: from,
                    startAt: t,
                    ms: Math.max(0, milliseconds),
                    holdUntil: t + Math.max(0, milliseconds) + OUT_HOLD_MS
                };
                if (fadeInMilliseconds > 0) {
                    armed = {
                        key: mediaKey(video),
                        time: Number.isFinite(video.currentTime) ? video.currentTime : 0,
                        seconds: fadeInMilliseconds / 1000,
                        at: t,
                        fromTail: false,
                        token: token,
                        sawNewMedia: false
                    };
                }
                tick();
            },
            // `superseded`: the command behind the fade never ran, so recover
            // now instead of waiting for a pause or track change.
            release(token, superseded) {
                const clearedArming = !!(superseded && armed && !armed.fromTail && armed.token === token);
                if (clearedArming) armed = null;
                if (!ramp || ramp.kind !== 'out' || ramp.token !== token) {
                    if (clearedArming) tick();
                    return;
                }
                const t = nowMs();
                const holdUntil = superseded ? t : t + RELEASE_GRACE_MS;
                ramp.holdUntil = Math.min(ramp.holdUntil, holdUntil);
                tick();
            },
            fadeInOnPlay(milliseconds) {
                if (!config.fadesTransportControls) return;
                const video = currentVideo();
                const t = nowMs();
                const from = ramp ? Math.min(rampGain(t, false), 1) : 0;
                const playing = !!video && !video.paused && !video.ended;
                ramp = {
                    kind: 'in',
                    from: playing ? from : 0,
                    startAt: playing ? t : null,
                    ms: Math.max(0, milliseconds),
                    expiresAt: t + FADE_IN_PLAY_WAIT_MS
                };
                tick();
            },
            // The deck is loading `videoId` for the overlap at this song's end.
            prepareOverlap(spec) {
                if (config.crossfadeSeconds <= 0 || !isValidOverlapSpec(spec)) return false;
                if (overlap) {
                    if (overlap.token === spec.token) return true;
                    if (overlap.phase !== 'pending' && overlap.phase !== 'armed') return false;
                    cancelOverlap('replaced');
                }
                const video = currentVideo();
                if (!video) return false;
                const remaining = video.duration - video.currentTime;
                if (Number.isFinite(remaining) && remaining <= OVERLAP_GIVE_UP_REMAINING_SECONDS) return false;
                if (!openOverlap(spec, 'pending', mediaKey(video))) return false;
                tick();
                return true;
            },
            // The deck has the next song buffered at 0.
            armOverlap(token) {
                if (!overlap || overlap.token !== token || overlap.phase !== 'pending') return false;
                overlap.phase = 'armed';
                tick();
                return true;
            },
            // Next pressed while the deck is ready: overlap for `milliseconds`,
            // after which Swift performs the skip and the handoff takes over.
            quickOverlap(token, milliseconds) {
                const video = currentVideo();
                if (!overlap || overlap.token !== token || overlap.phase !== 'armed'
                    || !video || video.paused || video.ended) return false;
                const ms = Math.max(100, milliseconds);
                overlap.phase = 'overlapping';
                overlap.quick = { startAt: wallMs(), ms: ms };
                overlap.startPostedAt = wallMs();
                tailRecord = null;
                overlapPost({ k: 'start', fade: ms / 1000 });
                tick();
                return true;
            },
            cancelOverlap(token) {
                if (!overlap || (token !== null && token !== undefined && overlap.token !== token)) return;
                cancelOverlap('cancelled');
                tick();
            },
            overlapState() {
                return {
                    phase: overlap ? overlap.phase : 'none',
                    token: overlap ? overlap.token : null,
                    videoId: overlap ? overlap.videoId : null,
                    last: lastOverlapResult
                };
            },
            gain() {
                return gain;
            },
            // Read by the silent audio output keep-alive (`WebPlaybackAudioOutput`).
            crossfadeSeconds() {
                return config.crossfadeSeconds;
            },
            // Read-only snapshot for diagnostics.
            debugState() {
                return {
                    gain: gain,
                    armed: armed ? { key: armed.key, fromTail: armed.fromTail, sawNewMedia: armed.sawNewMedia } : null,
                    fadeIn: fadeIn ? { start: fadeIn.start, seconds: fadeIn.seconds } : null,
                    ramp: ramp ? ramp.kind : null,
                    overlap: overlap ? overlap.phase : null,
                    ad: isAdPlaying()
                };
            }
        };

        // Read by the observer's volume enforcement. A gain the engine has not
        // re-evaluated for a while is never trusted, so enforcement can always
        // fall back to the user's volume.
        window.__kasetTransitionGain = function() {
            if (gain < 1 && nowMs() - lastTickAt > STALE_GAIN_MS) return 1;
            return __kasetClampUnit(gain);
        };
        // Read by the observer's enforcement while a fade is active, so both scale
        // the user's volume by the same loudness trim.
        window.__kasetLoudnessTrim = function() {
            return loudnessTrim();
        };
        window.__kasetSongTransitions = api;
        api.configure(initialConfig);
        // A full-page navigation to the next song mid-crossfade: start silent and
        // sync to the deck (any media in this new document is the next song).
        if (initialHandoff && isValidOverlapSpec(initialHandoff) && config.crossfadeSeconds > 0
            && typeof initialHandoff.expiresAt === 'number' && wallMs() < initialHandoff.expiresAt) {
            if (openOverlap(initialHandoff, 'overlapping', null)) {
                lastOverlapGain = 0;
            }
        }
        """
    }
}
