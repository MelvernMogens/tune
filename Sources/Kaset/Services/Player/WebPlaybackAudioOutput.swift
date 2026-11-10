/// Keeps WebKit's audio output open across short music playback transitions.
///
/// Only with crossfade off. Any live `AudioContext` makes WebKit run the GPU process on Web
/// Audio's 128-frame hardware buffer (`MediaSessionManagerCocoa::updateSessionState`), ~4×
/// the IO wakeups of plain media playback (measured Nov 2026: GPU process 490 vs 112 context
/// switches/s, coreaudiod 820–1125 vs 250/s) for as long as it lives — here, the whole
/// session. With crossfade on, natural song changes overlap on the crossfade deck, so the
/// output never closes between songs and the graph buys nothing (captured output
/// bit-identical with and without it). With crossfade off it is what keeps gapless openings
/// whole: without it the first 60–220 ms of each next song were cut. Opening or closing it
/// while music plays is not an option either: the buffer change disturbs the stream for a
/// moment (measured), so its lifetime stays tied to play/pause as before.
enum WebPlaybackAudioOutput {
    nonisolated static let script = """
    (() => {
        if (window.__kasetAudioOutput) return;
        let output = null;
        let releaseTimer = null;

        function clearReleaseTimer() {
            if (releaseTimer !== null) clearTimeout(releaseTimer);
            releaseTimer = null;
        }

        function stop() {
            clearReleaseTimer();
            const previous = output;
            output = null;
            if (!previous) return;
            try { previous.source.stop(); } catch (_) {}
            try { previous.source.disconnect(); } catch (_) {}
            try { previous.gain.disconnect(); } catch (_) {}
            try { previous.context.close().catch(() => {}); } catch (_) {}
        }

        // Crossfade on: song changes overlap on the deck page; no silent graph.
        function crossfadeIsOn() {
            try {
                const engine = window.__kasetSongTransitions;
                return !!engine && typeof engine.crossfadeSeconds === 'function'
                    && engine.crossfadeSeconds() > 0;
            } catch (_) {
                return false;
            }
        }

        function start() {
            const video = document.querySelector('video');
            if (window.__kasetPlaybackSuppressed || window.__kasetBlockAutoplay
                || (video && video.webkitCurrentPlaybackTargetIsWireless) || crossfadeIsOn()) {
                stop();
                return;
            }
            clearReleaseTimer();
            try {
                if (!output) {
                    const context = new AudioContext();
                    output = { context, source: null, gain: null };
                    const source = context.createOscillator();
                    output.source = source;
                    const gain = context.createGain();
                    output.gain = gain;
                    // No media is routed through this graph. Zero gain keeps the
                    // output active without altering DRM playback or its volume.
                    gain.gain.value = 0;
                    source.connect(gain);
                    gain.connect(context.destination);
                    source.start();
                }
                const pending = output;
                pending.context.resume().catch(() => {
                    if (output === pending) stop();
                });
            } catch (_) {
                stop();
            }
        }

        function releaseAfterTransition() {
            if (!output || releaseTimer !== null) return;
            // A failed load or the end of the queue must not leave silent output
            // running indefinitely. Normal transitions finish well within this.
            releaseTimer = setTimeout(stop, 5000);
        }

        function prepare() {
            start();
            releaseAfterTransition();
        }

        function observe(event, handler) {
            document.addEventListener(event, event => {
                const video = event.target;
                if (video && video.tagName === 'VIDEO'
                    && video === document.querySelector('video')) handler(video);
            }, true);
        }

        observe('play', prepare);
        observe('playing', start);
        observe('loadstart', () => {
            if (window.__kasetAutoplayPending) prepare();
        });
        observe('pause', video => {
            if (!window.__kasetPlaybackSuppressed && !window.__kasetBlockAutoplay
                && (video.ended || window.__kasetAutoplayPending)) {
                releaseAfterTransition();
            } else {
                stop();
            }
        });
        observe('ended', releaseAfterTransition);
        observe('emptied', releaseAfterTransition);
        observe('error', stop);
        observe('webkitcurrentplaybacktargetiswirelesschanged', video => {
            if (video.webkitCurrentPlaybackTargetIsWireless) stop();
            else if (!video.paused) start();
        });
        let currentVideo = document.querySelector('video');
        const mediaObserver = new MutationObserver(() => {
            const video = document.querySelector('video');
            if (video === currentVideo) return;
            currentVideo = video;
            // Detached media no longer sends events through this document.
            // Bound the wait for a replacement that has not started playing.
            if (video && !video.paused && !video.ended && video.readyState >= 3) start();
            else releaseAfterTransition();
        });
        mediaObserver.observe(document, { childList: true, subtree: true });
        window.addEventListener('pagehide', () => {
            mediaObserver.disconnect();
            stop();
        });
        window.__kasetAudioOutput = { prepare, stop };
        // The transition engine is installed after this script; let it exist first so
        // a crossfade setting is seen before any graph opens.
        if (window.__kasetAutoplayPending) {
            setTimeout(() => {
                if (window.__kasetAutoplayPending) prepare();
            }, 0);
        }
    })();
    """

    nonisolated static let stopScript = "window.__kasetAudioOutput?.stop();"
    nonisolated static let prepareScript = "window.__kasetAudioOutput?.prepare();"
}
