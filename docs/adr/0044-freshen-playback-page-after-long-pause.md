# ADR-0044: Freshen the playback page after a long pause

## Status

Accepted

## Context

Playback runs in one long-lived, hidden `WKWebView` on music.youtube.com (ADR-0001). Track
changes use YouTube Music's in-page router, so the page is never reloaded during a session.
Its WebContent process grows with use: Activity Monitor showed ~480 MB after launch and
860–900 MB after a long session; `footprint` on a 13-minute-old process already showed
340 MB of dirty WebKit malloc (JS heap and DOM) plus 378 MB reclaimable. Kaset's injected
scripts hold no growing state (their arrays are bounded and reset per track), so the
growth is the YouTube Music single-page app itself. Only dropping the page releases it.

A reload must never be audible or visible, and the restore path must be one users already
exercise every day.

## Decision

`PlaybackDocumentFreshenPolicy` (pure, unit-tested) and `PlayerService+DocumentFreshen`
rebuild the playback WebView inert when **all** of these hold:

- playback is `.paused` with the listener's explicit pause intent (not a Kaset, system or
  ad pause), and has stayed so for 15 minutes;
- the WebView is at least 60 minutes old;
- no video surface (video window, mini-player toast, Now Playing video), AirPlay route,
  ad, restore, native queue handoff, queue maintenance or watchdog recovery is active.

The freshen moves the session into the deferred-restore state a cold launch uses
(`deferRestoredPlaybackAfterNavigationFailure`: track selected, position saved, nothing
loaded) and calls `SingletonPlayerWebView.rebuildForMemoryFreshen()`, which tears the
WebView down and creates an inert one in the same container and data store. The old page —
and usually its process — goes away. The next explicit Play full-loads the track and seeks
back through the existing restored-session path. Any state change that ends the explicit
pause cancels the pending freshen.

## Consequences

- WebContent memory returns to a cold-start baseline after every long pause, instead of
  accumulating for the life of the app.
- The first Play after such a pause is a full page load (~1–3 s, like Play after launch)
  rather than an instant resume. The 15-minute and 60-minute thresholds keep this rare.
- Uninterrupted marathon listening is not freshened; doing so at a track boundary would
  add a gap and break crossfade. Revisit if long unpaused sessions still grow too large.
