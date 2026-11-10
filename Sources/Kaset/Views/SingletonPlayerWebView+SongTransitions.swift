import Foundation
import WebKit

// MARK: - SingletonPlayerWebView Song Transitions

extension SingletonPlayerWebView {
    /// Document-start engine for crossfade and transport fades, carrying the
    /// settings current at install time (`installUserScripts` runs per document).
    static func makeSongTransitionUserScript() -> WKUserScript {
        WKUserScript(
            source: WebPlaybackSongTransitions.script(
                settings: SettingsManager.shared.songTransitionSettings,
                handoff: CrossfadeDeckController.shared.handoffForNewDocument
            ),
            injectionTime: .atDocumentStart,
            forMainFrameOnly: true
        )
    }

    /// Pushes changed settings into the loaded page and into the installed
    /// document-start script, like the media-control and audio-quality settings.
    func applySongTransitionSettings(_ settings: SongTransitionSettings) {
        self.refreshInstalledUserScripts()
        self.sendSongTransitionCommand(.configure(settings))
        CrossfadeDeckController.shared.settingsDidChange(settings)
    }

    func sendSongTransitionCommand(_ command: SongTransitionCommand) {
        self.webView?.evaluateJavaScript(command.script, completionHandler: nil)
    }
}
