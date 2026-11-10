# Tune

A native macOS app for YouTube Music. Dark, minimal, artwork-first — with synced lyrics, a fullscreen
Now Playing view, real Spotify-style crossfade, and your own YouTube Music home feed.

Tune is an unofficial client built on top of [Kaset](https://github.com/sozercan/kaset) by Sertac Ozercan (MIT).

## Download

1. Go to **[Releases](../../releases/latest)** and download **`Tune.zip`**.
2. Unzip it and drag **Tune.app** into your **Applications** folder.
3. **First launch only:** the app isn't notarized by Apple, so macOS blocks a normal double-click.
   Open **Terminal** and run:

   ```bash
   xattr -dr com.apple.quarantine /Applications/Tune.app
   ```

   Then open Tune normally. (Alternative: right-click Tune.app → **Open** → **Open**.)
4. Click **Sign in** at the bottom of the sidebar and log in with your Google account.
   Your login stays on your Mac — Tune talks only to YouTube Music / Google, and a public lyrics database.

Requires macOS 15.4 or later (Apple Silicon or Intel). YouTube Music Premium recommended (no ads, background play).

## Features

- **Your Home feed** — the same shelves as YouTube Music (Listen again, Quick picks, mixes, videos), artwork-first.
- **Fullscreen Now Playing** (⇧⌘F) — big artwork tinted backdrop, synced lyrics that follow the song, Up Next
  queue you can drag to reorder (⌥⌘U), search (/ or ⌘K), Song ↔ Video toggle that shows the real music video.
- **Crossfade** — Settings → Music → Crossfade: the next song starts playing during the last seconds of the
  current one, like Spotify.
- **Reliable playback** — handles YouTube Music's "Are you still listening?" pause and recovers from stalls.
- **Equalizer**, Last.fm scrobbling, mini player, AirPlay, media keys, AppleScript & Shortcuts.

## Keyboard shortcuts

| | |
|---|---|
| Space | Play / pause |
| ⌘← / ⌘→ | Previous / next |
| ⌘K (or ⌘F) | Search |
| ⇧⌘F | Fullscreen Now Playing |
| ⌥⌘U | Up Next queue (in fullscreen) |
| ⇧⌘K | AI command bar |

## Good to know

- Tune uses YouTube Music's unofficial web API, like every third-party YouTube Music app. It works for
  personal listening, but Google could change something and break it at any time.
- Built from source with `swift build`; package with `Scripts/build-app.sh debug`. See `AGENTS.md` for
  development notes.

## Credits & license

MIT. Based on [Kaset](https://github.com/sozercan/kaset) © 2025 Sertac Ozercan — see `LICENSE`.
