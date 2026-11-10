import Foundation

// MARK: - TrackDisplayText

/// Display-only cleanup of YouTube titles and bylines.
///
/// YouTube video uploads arrive as "Artist - Title [Official Lyric Video]" with an empty
/// artist slot, and WebView bylines can carry separators around empty fields
/// ("• Emerald •"). These helpers produce the text a view shows; they never touch the
/// stored `Song` (titles, artists, and IDs stay as YouTube sent them, so lookups,
/// scrobbles, and queue identity are unaffected).
enum TrackDisplayText {
    /// What a row shows for one track.
    struct Display: Equatable {
        let title: String
        /// Empty when no artist is known; views decide whether to show a placeholder.
        let artist: String
    }

    // MARK: Display

    /// Title and artist for display. Splits "Artist - Title" when the artist slot is
    /// empty, drops the artist prefix when it repeats the known artist, and removes
    /// upload noise such as "(Official Audio)" or "[Official Lyric Video]".
    static func display(title rawTitle: String, artist rawArtist: String?) -> Display {
        // Rows re-render often (queue, shelves, status line); memoize the regex work.
        let key = "\(rawTitle)\u{1F}\(rawArtist ?? "")" as NSString
        if let cached = Self.displayCache.object(forKey: key) {
            return cached.display
        }
        let display = Self.computeDisplay(title: rawTitle, artist: rawArtist)
        Self.displayCache.setObject(DisplayBox(display), forKey: key)
        return display
    }

    private static func computeDisplay(title rawTitle: String, artist rawArtist: String?) -> Display {
        var artist = Self.cleanByline(rawArtist ?? "")
        if Self.isPlaceholderArtist(artist) {
            artist = ""
        }
        var title = Self.cleanTitle(rawTitle)

        if let split = Self.splitArtistTitle(title) {
            if artist.isEmpty {
                artist = split.artist
                title = split.title
            } else if split.artist.caseInsensitiveCompare(artist) == .orderedSame
                || artist.lowercased().hasPrefix(split.artist.lowercased() + ",")
            {
                title = split.title
            }
        }

        if title.isEmpty {
            title = rawTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return Display(title: title, artist: artist)
    }

    // MARK: Bylines

    /// Splits a byline on `•`, `·`, and `|`, drops empty fields and placeholder text,
    /// and rejoins the rest with " · ". "• Emerald •" → "Emerald".
    static func cleanByline(_ raw: String) -> String {
        let separators = CharacterSet(charactersIn: "•·|")
        return raw
            .components(separatedBy: separators)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: " · ")
    }

    // MARK: Titles

    /// Removes upload noise and stray edge separators from a title. Meaningful
    /// qualifiers — "(feat. …)", "(Live)", "(Acoustic)", "(Remastered 2011)" — stay.
    /// Falls back to the trimmed original when cleaning would leave nothing.
    static func cleanTitle(_ raw: String) -> String {
        var title = raw
        for regex in Self.noiseExpressions {
            let range = NSRange(title.startIndex..., in: title)
            title = regex.stringByReplacingMatches(in: title, range: range, withTemplate: " ")
        }
        // "life with u - acoustic (acoustic)" → "life with u - acoustic".
        if let repeated = Self.repeatedQualifierExpression {
            let range = NSRange(title.startIndex..., in: title)
            title = repeated.stringByReplacingMatches(in: title, range: range, withTemplate: "$1")
        }
        title = Self.collapseWhitespace(title)
            .replacingOccurrences(of: "( ", with: "(")
            .replacingOccurrences(of: " )", with: ")")
            .replacingOccurrences(of: "[ ", with: "[")
            .replacingOccurrences(of: " ]", with: "]")
        title = title.trimmingCharacters(in: Self.edgeSeparators)
        if title.isEmpty {
            return raw.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return title
    }

    // MARK: Private

    /// Bracketed or dash-suffixed upload tags. Each kind word must be present, so a
    /// bare "(Official)" or "(Live Video Session)" is left alone.
    private static let noiseExpressions: [NSRegularExpression] = Self.noisePatterns.compactMap {
        try? NSRegularExpression(pattern: $0, options: [.caseInsensitive])
    }

    /// A word or two immediately repeated as a parenthetical.
    private static let repeatedQualifierExpression = try? NSRegularExpression(
        pattern: #"\b(\w+(?:\s\w+)?)\s+\(\1\)"#,
        options: [.caseInsensitive]
    )

    private static let noisePatterns: [String] = [
        // (Official Music Video) [Official Lyric Video] (Official Audio) (Lyrics) (MV)
        // (Official Video Lirik) (Visualizer) (Audio) 【MV】 (M/V) (Video Clip)
        #"\s*[\(\[【]\s*(?:official\s+)?(?:music\s+|lyrics?\s+|video\s+)?(?:video|audio|visuali[sz]er|mv|m/v|lyrics?|lirik|clip)(?:\s+(?:video|lirik|clip|hd|4k))?\s*[\)\]】]"#,
        // (HD) [4K] (HQ)
        #"\s*[\(\[]\s*(?:hd|hq|4k)\s*[\)\]]"#,
        // "Title - Official Video" / "Title | Official Music Video" at the end.
        #"\s+[-|｜–—]\s+official\s+(?:music\s+|lyrics?\s+)?(?:video|audio|visuali[sz]er|mv)\s*$"#,
    ]

    /// Words that start a version/part suffix ("Song - Original Mix", "Intro - Part 2"),
    /// which never name an artist.
    private static let versionSuffixExpression = try? NSRegularExpression(
        pattern: #"^(?:\d{4}\s+)?(?:remaster(?:ed)?|live|acoustic|unplugged|radio|edit|remix|mix|original|extended|club|version|demo|instrumental|karaoke|mono|stereo|single|part|pt\.?|vol\.?|volume|chapter|ep\.?|episode|interlude|intro|outro|reprise|slowed|sped|reverb|cover|piano|orchestral|session|from)\b"#,
        options: [.caseInsensitive]
    )

    /// NSCache is internally synchronized, so sharing it across isolation domains is safe.
    private nonisolated(unsafe) static let displayCache: NSCache<NSString, DisplayBox> = {
        let cache = NSCache<NSString, DisplayBox>()
        cache.countLimit = 2000
        return cache
    }()

    private final class DisplayBox: NSObject {
        let display: Display
        init(_ display: Display) {
            self.display = display
        }
    }

    private static let edgeSeparators = CharacterSet(charactersIn: "•·|-–—")
        .union(.whitespacesAndNewlines)

    private static func collapseWhitespace(_ text: String) -> String {
        text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    private static func isPlaceholderArtist(_ artist: String) -> Bool {
        artist.caseInsensitiveCompare("Unknown Artist") == .orderedSame
    }

    /// "Artist - Title" with exactly one spaced dash separator and both sides non-empty.
    /// Titles with several dashes ("A - B - C") are ambiguous and stay whole.
    private static func splitArtistTitle(_ title: String) -> (artist: String, title: String)? {
        for separator in [" - ", " – ", " — "] {
            let parts = title.components(separatedBy: separator)
            guard parts.count == 2 else { continue }
            let artist = parts[0].trimmingCharacters(in: .whitespacesAndNewlines)
            let rest = parts[1].trimmingCharacters(in: .whitespacesAndNewlines)
            guard !artist.isEmpty, !rest.isEmpty else { return nil }
            // "Song - Remastered 2011" / "Song - Live at …" name a version, not an artist.
            if let regex = Self.versionSuffixExpression,
               regex.firstMatch(in: rest, range: NSRange(rest.startIndex..., in: rest)) != nil
            {
                return nil
            }
            return (artist, rest)
        }
        return nil
    }
}

// MARK: - Song + Display

extension Song {
    /// Cleaned title and artist for display (see `TrackDisplayText`).
    var displayText: TrackDisplayText.Display {
        TrackDisplayText.display(title: self.title, artist: self.artistsDisplay)
    }
}

// MARK: - HomeSectionItem + Display

extension HomeSectionItem {
    /// Card title for display: songs and videos get the cleaned title, everything
    /// else shows its name as-is.
    var displayTitle: String {
        if case let .song(song) = self {
            return song.displayText.title
        }
        return self.title
    }
}
