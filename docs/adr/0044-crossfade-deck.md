# ADR-0044: Crossfade deck (true overlapping crossfade)

## Status

Accepted. Partly supersedes ADR-0043: the single-element fades remain the fallback.

## Context

ADR-0043 faded the end of a song out and the next one in on the one playback `<video>`. the user
heard the result as "the song finishes, it stops for a few seconds, then continues". Two causes:

1. Every song change was a full page load. YouTube Music removed `ytmusic-app.resolveCommand`,
   so the router navigation always failed and fell back to `location.replace` (≈1–3 s of silence,
   plus a fresh document each song).
2. One element can never overlap two songs, so even a fast load leaves a dip.

A spike (Oct 2026, signed-in Premium account, real app) loaded the next song in a second hidden
WKWebView on the same data store and played both pages at once for 25+ s: neither paused, no
"playing on another device" prompt. A cold second page was playable 1.3–1.5 s after creation; its
WebContent process costs ≈440–530 MB RSS and exits ≈0.5 s after the page is closed.

## Decision

- **Router fix.** Navigation tries `resolveCommand`, then the app instance's
  `handleNavigationEndpoint`, then a bubbling `yt-navigate` event. Song changes are SPA again
  (≈0.5 s, same document).
- **Crossfade deck.** With Crossfade on, `CrossfadeDeckController` (1 s native-state poll, 250 ms
  page polls only near a song end) asks the pure `CrossfadeDeckPlanner` what to do. About
  `N + 6` s before the end it creates a `CrossfadeDeckWebView` (same data store, its own content
  controller, `inactiveSchedulingPolicy = .none`) holding the next queue song paused at 0. The deck
  page refuses YouTube's autoplay and drops history / watch-time / attestation pings, so only the
  main player records the play; its media-session actions are forwarded to Kaset's transport.
- **Overlap.** The main page engine (`WebPlaybackSongTransitions`) talks to the deck over a
  per-launch `BroadcastChannel`. When the song enters its last N s it starts the deck (fade-in over
  the time left, at least 1.5 s) and fades itself out on the usual tail curve. When the main
  element moves on to the same song (natural end → SPA load), it is held silent, seeked and
  rate-nudged onto the deck's clock, and once five samples agree within 15 ms the two swap with a
  150 ms equal-power fade. YouTube's own volume writes cannot unmute the held element (a guarded
  `volume` setter caps them at the engine's level). The deck is then closed without navigating
  (navigating it to `about:blank` first kept the WKWebView, and its 520 MB process, alive).
- **Seeks.** A seek into the window crossfades over what is left. A seek into the last moments
  lands at most 1.5 s before the end (3 s when the deck still has to load) so there is always room
  for an overlap; a seek back out cancels and rewinds the deck. Seeks nudge the controller, so the
  deck is created at once.
- **Next** with the deck ready runs a quick overlap of `min(N, 2)` s, then the skip.
- **Late deck.** If the deck is not ready when the song ends, it starts the moment it is (0.3 s
  fade) and covers the main element's load; if the main element plays first, it just fades in.
- **Pause/volume.** The main page pauses/resumes the deck during the overlap; during the handoff
  (main element silent) Kaset's explicit pause intent reaches the deck from the controller. The
  user's volume is pushed to the deck each poll.
- **Off = nothing.** Crossfade 0 never runs the controller loop or creates a deck.
- **Ineligible** (deck never used, single-element fades instead): video mode or the video window,
  AirPlay, ads, repeat-one, podcasts/episodes, signed-out (cookie-free store), restoring a session,
  songs no longer than 3N, no known next song.

## Consequences

- No audible gap at natural ends, scrubs into the window, or Next inside the window (measured: no
  silence > 100 ms; the swap is inaudible because both pages play the same audio in sync).
- RAM: +0 with Crossfade off; with it on, one extra WebContent process (≈520–535 MB) for ≈14–20 s
  around each song end, then it exits. Kaset's own process stays within a few MB.
- During the overlap the deck's audio bypasses the EQ process tap (the tap covers the processes it
  found when it started).
- The deck page may briefly own the system Now Playing card for the next song; it is gone after
  the handoff and the main page publishes the same song.
- More moving parts in the page; every phase has a bounded give-up (late deck 6 s, handoff 8 s,
  session 25 s) that returns the main element to the exact user volume.
