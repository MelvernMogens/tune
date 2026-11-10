# ADR-0045: Crackle — transitions keep YouTube's loudness trim; no silent AudioContext with crossfade on

## Status

Accepted (Nov 2026). Amends ADR-0036 (when the silent output exists) and the crossfade
ADRs (the level fades return to).

## Context

the user heard crackling only in Tune (YouTube Music in Chrome clean on the same Mac and
MacBook Pro speakers), starting on the second song and staying, EQ off, crossfade 5 s.
Two guessed fixes had not helped. This time the output was measured: a Core Audio process
tap on Tune's WebKit GPU process recorded the samples Tune hands to Core Audio, with a page
census (element volume, `loudnessDb`, live `AudioContext`s) and GPU-process / coreaudiod
context-switch rates. YouTube's decode is deterministic, so two captures of the same song
can be aligned and diffed (residual ≈ -110 dB when both are clean).

Findings:

1. **Loudness trim dropped after every transition (proven).** YouTube Music lowers loud
   tracks itself: element volume = player volume × `10^(-loudnessDb/20)` when `loudnessDb`
   > 0 (2.27 dB → 0.7700). The transition engine, the observer's fade enforcement and the
   crossfade deck faded to and settled at the raw user volume. Song 1 is never touched by
   them, so it played at YouTube's level; from song 2 on a loud track played hot until
   YouTube re-applied its trim about a minute later. Bangarang (2.27 dB) after a natural
   crossfade: element volume 1.0 instead of 0.770, peak 1.364, 26,893 frames at or above
   full scale in one minute (clipping). After the fix: 0.770, peak 1.022, 5 such frames.
2. **The silent `AudioContext` kept the hardware buffer at 128 frames all session.** Any
   live `AudioContext` makes WebKit set the GPU process's IO buffer to Web Audio's render
   quantum (`MediaSessionManagerCocoa::updateSessionState`). ADR-0036's graph opened on the
   first play and lived until a pause: GPU process 490 vs 112 context switches/s,
   coreaudiod 820–1125 vs 250/s. With crossfade on, the captured output was bit-identical
   with and without it, including across deck crossfades. With crossfade 0 it is still
   needed: without it the first 60–220 ms of each next song were cut (3 of 3).
3. **Changing it while music plays is worse.** A variant that held the graph only around
   song changes (open 1.5 s before the end, close 300 ms or 2 s after the next song
   started) disturbed the stream at each close for up to ~1 s (opening region or ~2 s in).
   So the graph either lives through playback or does not exist.

No dropout inside Tune's own stream was found in any condition, even under a 12-process
CPU stress; a device-level effect of the 128-frame buffer can't be captured digitally and
is not claimed.

## Decision

- **One loudness trim for every writer.** `WebPlaybackLoudness.trimFunction` reads it from
  the player response (only when it describes the playing video). The engine's target, the
  observer's enforcement during fades and the deck's volume all scale by it. With no fade
  the element is still left to YouTube.
- **No silent output with crossfade on.** `WebPlaybackAudioOutput` asks the transition
  engine (`crossfadeSeconds()`) before opening; with crossfade on it never opens (the deck
  keeps the output running at song changes). The document-start `prepare` waits one tick so
  the engine exists. With crossfade off its play/pause lifetime is unchanged.

## Consequences

- Loud tracks keep YouTube's level through crossfades, skips and the post-fade settle.
- With crossfade on, playback runs on WebKit's normal media buffer for the whole session.
- With crossfade on, a manual start or a skip without a ready deck may lose the first
  ~0.1–0.2 s of the song while the output comes up (as gapless transitions did without the
  graph). Podcasts with crossfade on change without a fade, so the same applies to them.
- Measurement recipe: HANDOFF.md and the `tune-music-app` skill.
