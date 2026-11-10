import Foundation

// MARK: - CrossfadeDeckScript

/// Document-start script for the crossfade deck: a short-lived second YouTube Music page
/// that plays the opening of the next song while the main player fades the current one out.
///
/// The deck never acts on its own. It loads the next song paused at 0 (YouTube's own
/// autoplay is refused), and only the main page starts, refades, pauses, cancels or hands
/// it off, through a `BroadcastChannel` both pages open with the same per-launch name.
/// Everything that would make the deck count as a play is dropped: history, watch-time
/// and attestation pings never leave the page, so only the main player records the song.
/// See `docs/adr/0044-crossfade-deck.md`.
enum CrossfadeDeckScript {
    /// Channel message kinds shared with `WebPlaybackSongTransitions`.
    static let channelPrefix = "__kasetCrossfade."

    static func channelName(token: Int) -> String {
        "\(Self.channelPrefix)\(min(max(token, 0), Int(Int32.max)))"
    }

    /// YouTube video ids are 11 characters of `[A-Za-z0-9_-]`; anything else is refused
    /// so no page or network value is ever interpolated into a script.
    static func isValidVideoId(_ value: String) -> Bool {
        value.count == 11 && value.allSatisfy { character in
            character.isASCII && (character.isLetter || character.isNumber || character == "-" || character == "_")
        }
    }

    static func watchURL(videoId: String) -> URL? {
        guard Self.isValidVideoId(videoId) else { return nil }
        var components = URLComponents(string: "https://music.youtube.com/watch")
        components?.queryItems = [URLQueryItem(name: "v", value: videoId)]
        return components?.url
    }

    /// The deck's document-start script.
    static func script(channelToken: Int, videoId: String, volume: Double) -> String? {
        guard Self.isValidVideoId(videoId) else { return nil }
        let clampedVolume = volume.isFinite ? min(max(volume, 0), 1) : 1
        return """
        (() => {
            if (window.__kasetDeck) return;
            const CHANNEL = '\(Self.channelName(token: channelToken))';
            const VIDEO_ID = '\(videoId)';
            \(WebPlaybackLoudness.trimFunction)
            \(Self.engine)
            window.__kasetDeck.setVolume(\(clampedVolume));
        })();
        """
    }

    /// Calls into the deck page from Swift (validated literals only).
    static func setVolumeScript(_ volume: Double) -> String {
        let clamped = volume.isFinite ? min(max(volume, 0), 1) : 1
        return "if (window.__kasetDeck) { window.__kasetDeck.setVolume(\(clamped)); }"
    }

    static let stateScript = "return window.__kasetDeck ? JSON.stringify(window.__kasetDeck.state()) : null;"

    static let rewindScript = "if (window.__kasetDeck) { window.__kasetDeck.rewind(); }"

    /// Pauses or resumes an audible deck with the user's transport (the main page only
    /// sees its own element, which during a handoff is still silent).
    static func holdScript(paused: Bool) -> String {
        "if (window.__kasetDeck) { window.__kasetDeck.hold(\(paused ? "true" : "false")); }"
    }

    /// Fades an audible deck out (`CrossfadeDeckWebView.teardownFade`) before it closes.
    static let fadeAwayScript = "if (window.__kasetDeck) { window.__kasetDeck.fadeAway(200); }"

    static let stopScript = """
    if (window.__kasetDeck) { window.__kasetDeck.shutdown(); }
    else { const v = document.querySelector('video'); if (v) { try { v.volume = 0; v.pause(); } catch (_) {} } }
    """

    private static var engine: String {
        """
        const IDLE_TICK_MS = 250;
        const ACTIVE_TICK_MS = 40;
        const MIN_FADE_SECONDS = 0.3;
        const BLOCKED = /\\/api\\/stats\\/(playback|watchtime|delayplay|atr)|\\/ptracking/;

        let allowPlay = false;
        let volume = 1;
        let phase = 'loading';
        // Fade-in: gain goes from `from` to 1 over `seconds` of the deck's own media clock.
        let fade = null;
        // Fade-out on the shared wall clock: { Ts, D, from, then: 'stop' | 'rewind' }.
        let out = null;
        let timer = null;
        let timerMs = 0;
        let gain = 0;

        function nowMs() { return Date.now(); }
        function video() { return document.querySelector('video'); }
        function videoId() {
            try {
                const player = document.getElementById('movie_player');
                const data = player && typeof player.getVideoData === 'function' ? player.getVideoData() : null;
                return data && typeof data.video_id === 'string' ? data.video_id : null;
            } catch (_) { return null; }
        }
        function clampUnit(value) {
            return typeof value === 'number' && Number.isFinite(value) ? Math.min(1, Math.max(0, value)) : 0;
        }

        // Only the main player may count as a play.
        function isBlocked(url) {
            try { return BLOCKED.test(String(url && url.url ? url.url : url || '')); } catch (_) { return false; }
        }
        const originalFetch = window.fetch;
        if (typeof originalFetch === 'function') {
            window.fetch = function(input) {
                if (isBlocked(input)) return Promise.resolve(new Response(null, { status: 204 }));
                return originalFetch.apply(this, arguments);
            };
        }
        if (navigator.sendBeacon) {
            const originalBeacon = navigator.sendBeacon.bind(navigator);
            navigator.sendBeacon = function(url, data) { return isBlocked(url) ? true : originalBeacon(url, data); };
        }
        const originalOpen = XMLHttpRequest.prototype.open;
        XMLHttpRequest.prototype.open = function(method, url) {
            if (isBlocked(url)) arguments[1] = 'data:text/plain,';
            return originalOpen.apply(this, arguments);
        };
        const imageSource = Object.getOwnPropertyDescriptor(HTMLImageElement.prototype, 'src');
        if (imageSource && imageSource.set) {
            Object.defineProperty(HTMLImageElement.prototype, 'src', {
                configurable: true,
                get() { return imageSource.get.call(this); },
                set(value) { if (!isBlocked(value)) imageSource.set.call(this, value); }
            });
        }

        // YouTube's autoplay (and its own queue advance) is refused until the main page starts the deck.
        const originalPlay = HTMLMediaElement.prototype.play;
        HTMLMediaElement.prototype.play = function() {
            if (!allowPlay) {
                try { this.volume = 0; } catch (_) {}
                return Promise.reject(new DOMException('crossfade deck is idle', 'NotAllowedError'));
            }
            return originalPlay.apply(this, arguments);
        };

        // Media keys and the Now Playing card reach the deck only while it is audible;
        // route them to Kaset's native transport like the main page does.
        try {
            if (navigator.mediaSession && typeof navigator.mediaSession.setActionHandler === 'function') {
                const setHandler = navigator.mediaSession.setActionHandler.bind(navigator.mediaSession);
                const forward = { play: 'REMOTE_PLAY', pause: 'REMOTE_PAUSE', nexttrack: 'REMOTE_NEXT', previoustrack: 'REMOTE_PREVIOUS' };
                navigator.mediaSession.setActionHandler = function(action) {
                    if (forward[action]) return;
                    try { setHandler(action, null); } catch (_) {}
                };
                Object.keys(forward).forEach(action => {
                    try {
                        setHandler(action, () => {
                            try { window.webkit.messageHandlers.kasetCrossfadeDeck.postMessage({ type: forward[action] }); } catch (_) {}
                        });
                    } catch (_) {}
                });
            }
        } catch (_) {}

        const channel = typeof BroadcastChannel === 'function' ? new BroadcastChannel(CHANNEL) : null;

        function post(message) {
            if (!channel) return;
            try { channel.postMessage(message); } catch (_) {}
        }

        function isExpectedMedia() {
            const id = videoId();
            return id === null || id === VIDEO_ID;
        }

        function isReady(v) {
            return !!v && v.readyState >= 3 && videoId() === VIDEO_ID && Number.isFinite(v.duration);
        }

        function computeGain(v, t) {
            if (out) {
                const progress = out.D > 0 ? (t - out.Ts) / out.D : 1;
                if (progress >= 1) return null;
                if (progress <= 0) return out.from;
                return out.from * Math.cos(progress * Math.PI / 2);
            }
            // A paused deck keeps its level, so resuming continues the fade from there.
            if (phase === 'paused') return gain;
            if (phase !== 'playing' || !fade) return phase === 'playing' ? 1 : 0;
            const elapsed = v.currentTime - fade.startX;
            if (!Number.isFinite(elapsed) || fade.seconds <= 0) return 1;
            const progress = Math.min(1, Math.max(0, elapsed / fade.seconds));
            return fade.from + (1 - fade.from) * Math.sin(progress * Math.PI / 2);
        }

        // YouTube's loudness trim for this song, so the deck plays it at the level the
        // main page (and YouTube Music) will: the handoff swap stays level.
        let trim = null;
        function loudnessTrim() {
            if (trim !== null) return trim;
            if (videoId() !== VIDEO_ID) return 1;
            const value = __kasetLoudnessTrimFor(document.getElementById('movie_player'));
            if (value === null) return 1;
            trim = value;
            return value;
        }

        function apply(v) {
            const want = volume * loudnessTrim() * clampUnit(gain);
            if (Math.abs(v.volume - want) > 0.002) { try { v.volume = want; } catch (_) {} }
        }

        function finishOut(v) {
            const then = out ? out.then : 'stop';
            out = null;
            gain = 0;
            allowPlay = false;
            fade = null;
            try { v.volume = 0; v.pause(); } catch (_) {}
            if (then === 'rewind' && isExpectedMedia()) {
                try { v.currentTime = 0; } catch (_) {}
                phase = 'ready';
            } else {
                phase = 'stopped';
            }
        }

        function tick() {
            const v = video();
            const t = nowMs();
            if (!v) { schedule(IDLE_TICK_MS); return; }
            if (phase === 'loading' && isReady(v) && v.paused) phase = 'ready';
            if (phase === 'playing' && !isExpectedMedia()) {
                // YouTube moved on to its own next song: never let the deck play it.
                out = null;
                finishOut(v);
            }
            const next = computeGain(v, t);
            if (next === null) {
                finishOut(v);
            } else {
                gain = next;
            }
            apply(v);
            const playing = !v.paused && !v.ended;
            post({ k: 'deck', T: t, x: v.currentTime, paused: v.paused || v.ended, phase: phase, g: gain });
            schedule(playing || out ? ACTIVE_TICK_MS : IDLE_TICK_MS);
        }

        function schedule(ms) {
            if (timer !== null && timerMs === ms) return;
            if (timer !== null) clearInterval(timer);
            timerMs = ms;
            timer = setInterval(tick, ms);
        }

        function startPlayback(seconds) {
            const v = video();
            if (!v || !(phase === 'ready' || phase === 'paused') || !isExpectedMedia()) return;
            const resume = phase === 'paused';
            out = null;
            allowPlay = true;
            const fadeSeconds = Math.max(MIN_FADE_SECONDS, Number.isFinite(seconds) ? seconds : MIN_FADE_SECONDS);
            fade = { from: resume ? clampUnit(gain) : 0, startX: resume ? v.currentTime : 0, seconds: fadeSeconds };
            if (!resume) {
                gain = 0;
                try { if (v.currentTime > 0.05) v.currentTime = 0; } catch (_) {}
            }
            apply(v);
            phase = 'playing';
            try {
                const promise = v.play();
                if (promise && typeof promise.catch === 'function') promise.catch(() => {});
            } catch (_) {}
            tick();
        }

        function fadeOut(Ts, D, then) {
            const v = video();
            if (!v) return;
            if (phase !== 'playing' && phase !== 'paused') {
                if (then === 'rewind' && phase !== 'loading') {
                    out = { Ts: nowMs(), D: 0, from: 0, then: then };
                    finishOut(v);
                }
                return;
            }
            out = { Ts: Ts, D: Math.max(0, D), from: clampUnit(gain), then: then };
            phase = 'out';
            tick();
        }

        if (channel) {
            channel.onmessage = (event) => {
                const m = event && event.data;
                if (!m || typeof m.k !== 'string') return;
                const v = video();
                switch (m.k) {
                case 'start':
                    startPlayback(Number(m.fade));
                    break;
                case 'refade':
                    if (phase === 'playing' && v) {
                        fade = { from: clampUnit(gain), startX: v.currentTime, seconds: Math.max(MIN_FADE_SECONDS, Number(m.fade) || 0) };
                    }
                    break;
                case 'pause':
                    if (phase === 'playing' && v) {
                        allowPlay = false;
                        try { v.pause(); } catch (_) {}
                        phase = 'paused';
                    }
                    break;
                case 'resume':
                    if (phase === 'paused') startPlayback(Number(m.fade));
                    break;
                case 'swap':
                    fadeOut(Number(m.Ts) || nowMs(), Number(m.D) || 0, 'stop');
                    break;
                case 'cancel':
                    fadeOut(nowMs(), Number(m.D) || 0, 'rewind');
                    break;
                default:
                    break;
                }
            };
        }

        // `timeupdate` keeps the fades moving even if the page's timers get throttled.
        ['loadedmetadata', 'canplay', 'canplaythrough', 'pause', 'playing', 'emptied', 'loadstart', 'timeupdate'].forEach(type =>
            document.addEventListener(type, (event) => {
                if (event.target && event.target.tagName === 'VIDEO') tick();
            }, true));
        document.addEventListener('ended', (event) => {
            const v = event.target;
            if (!v || v.tagName !== 'VIDEO') return;
            allowPlay = false;
            out = null;
            finishOut(v);
        }, true);
        document.addEventListener('volumechange', (event) => {
            const v = event.target;
            if (v && v.tagName === 'VIDEO') apply(v);
        }, true);

        window.__kasetDeck = {
            setVolume(value) {
                volume = clampUnit(value);
                const v = video();
                if (v) apply(v);
            },
            state() {
                const v = video();
                return {
                    phase: phase,
                    videoId: videoId(),
                    time: v ? v.currentTime : null,
                    paused: v ? v.paused : true,
                    readyState: v ? v.readyState : 0,
                    gain: gain
                };
            },
            rewind() {
                fadeOut(nowMs(), 200, 'rewind');
            },
            fadeAway(ms) {
                fadeOut(nowMs(), Math.max(0, Number(ms) || 0), 'stop');
            },
            hold(paused) {
                const v = video();
                if (!v) return;
                if (paused && phase === 'playing') {
                    allowPlay = false;
                    try { v.pause(); } catch (_) {}
                    phase = 'paused';
                    tick();
                } else if (!paused && phase === 'paused') {
                    startPlayback(MIN_FADE_SECONDS);
                }
            },
            shutdown() {
                allowPlay = false;
                out = null;
                fade = null;
                gain = 0;
                phase = 'stopped';
                const v = video();
                if (v) { try { v.volume = 0; v.pause(); } catch (_) {} }
                if (timer !== null) { clearInterval(timer); timer = null; }
                if (channel) { try { channel.close(); } catch (_) {} }
            }
        };
        schedule(IDLE_TICK_MS);
        """
    }
}
