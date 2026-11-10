# ADR-0043: Single-element song transitions

## Status

Accepted

## Context

Spotify's Crossfade setting (0–12 s) overlaps the end of one song with the start of the next.
Kaset plays YouTube Music through one hidden `WKWebView` with one DRM `<video>` element
(ADR-0001). A true overlap needs two decoders playing at once. A second playback WebView on the
same account risks YouTube pausing one of them ("playing on another device"), doubles bandwidth,
and breaks the stall watchdog, native-queue handoff (ADR-0035) and media-bound identity, which all
assume one media element. Web Audio cannot help either: EME/DRM media cannot be routed through a
`MediaElementAudioSourceNode`.

## Decision

Implement the best transition one element allows, as a gain multiplier in the page
(`WebPlaybackSongTransitions`, a document-start script):

- **Crossfade (0–12 s, default off).** Over the last N seconds of a song the element's volume
  follows an equal-power (cosine) fade to silence; the next media fades in with the sine curve
  over `min(N, 3)` seconds, so its opening is not lost. Both are computed from the media clock and
  driven by `timeupdate` (which keeps firing in hidden pages) plus a 40 ms timer while active.
  Skipped for crossfade 0, unknown or infinite duration, songs no longer than 3N, podcast
  episodes, ads, AirPlay, and when the user seeks into the last N seconds.
- **Fade on play, pause & skip (default off).** User transport commands go through
  `SongTransitionTransportGate`: a 300 ms fade-out runs before pause/next/previous, a 350 ms
  fade-in after resume, and a skip arms a 450 ms fade-in of the next song. Internal pauses and
  navigations (track end, watchdog, arbitration, queue correction) never fade.
- **The user's volume is never changed.** `__kasetTargetVolume` and `PlayerService.volume` stay the
  base value; the element is set to `target × gain`. The observer's volume enforcement reads
  `__kasetTransitionGain()` and enforces the faded value, and YouTube's player APIs keep the base
  value. While no fade is active the engine never writes the element volume.
- **Every fade has a way back to exactly the user's volume:** pause, new media (a held fade-out
  never carries into the next song), seek, ads, AirPlay, turning the setting off, a token-matched
  `release` after every gated command (immediate when a newer intent dropped the command), bounded
  holds/expiries (3 s hold, 12 s arming, 4 s resume wait), and enforcement ignores a gain the
  engine has not re-evaluated for 5 s.
- With both settings off the engine returns before doing any work on media events.

## Consequences

- Transitions sound like a fade-out followed by a fade-in, not an overlap. The silence between
  songs is whatever YouTube Music's own track switch takes.
- Pause and skip with transport fades take effect 300 ms later; a second press cuts the fade short.
- A full-document navigation between songs starts the next song without a fade-in (the engine's
  state is per document).
