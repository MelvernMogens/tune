// MARK: - WebPlaybackLoudness

/// YouTube Music's own loudness normalization, as page JavaScript.
///
/// YouTube lowers loud tracks itself: the element plays at the player volume times
/// `10^(-loudnessDb / 20)` when the track's `loudnessDb` is positive (measured Nov 2026:
/// `loudnessDb` 2.27 → element volume 0.7700 at player volume 100; tracks at or below 0 dB
/// play at the player volume). Anything that writes the element volume itself (the song
/// transition engine, the crossfade deck) must scale by the same trim, otherwise loud
/// tracks play several dB hotter than in YouTube Music and their peaks clip.
enum WebPlaybackLoudness {
    /// Defines `__kasetLoudnessTrimFor(player)`: the trim for the media `player`
    /// (`#movie_player`) is playing, `1` when the track is not attenuated or the
    /// response has no loudness, and `null` while the player response still
    /// describes another video (unknown; callers use 1 and ask again later).
    static let trimFunction = """
    function __kasetLoudnessTrimFor(player) {
        try {
            const response = player && typeof player.getPlayerResponse === 'function'
                ? player.getPlayerResponse()
                : null;
            const audio = response && response.playerConfig && response.playerConfig.audioConfig;
            const db = audio ? Number(audio.loudnessDb) : NaN;
            const responseId = response && response.videoDetails ? response.videoDetails.videoId : null;
            const data = player && typeof player.getVideoData === 'function' ? player.getVideoData() : null;
            const playingId = data && typeof data.video_id === 'string' ? data.video_id : null;
            if (responseId && playingId && responseId !== playingId) return null;
            if (!Number.isFinite(db) || db <= 0) return 1;
            return Math.min(1, Math.max(0, Math.pow(10, -db / 20)));
        } catch (_) {
            return 1;
        }
    }
    """
}
