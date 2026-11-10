import AppKit
import Foundation
import WebKit

// MARK: - CrossfadeDeckWebView

/// The short-lived second YouTube Music page that plays the opening of the next song
/// during a true crossfade. One instance per song; it is created about
/// `CrossfadeTiming.deckLeadSeconds` before the crossfade and torn down right after
/// the handoff, so its WebContent process exits between songs.
@MainActor
final class CrossfadeDeckWebView: NSObject {
    /// Forwards the deck page's media-session actions without retaining the deck.
    private final class MessageProxy: NSObject, WKScriptMessageHandler {
        weak var deck: CrossfadeDeckWebView?

        func userContentController(_: WKUserContentController, didReceive message: WKScriptMessage) {
            MainActor.assumeIsolated {
                guard let deck = self.deck,
                      message.webView === deck.webView,
                      message.frameInfo.isMainFrame,
                      message.frameInfo.securityOrigin.host == "music.youtube.com",
                      let body = message.body as? [String: Any],
                      let type = body["type"] as? String,
                      let command = SingletonPlayerWebView.remoteTransportCommand(forMessageType: type)
                else { return }
                deck.onRemoteCommand?(command)
            }
        }
    }

    static let messageHandlerName = "kasetCrossfadeDeck"
    /// A deck that is not playable after this long is treated as failed.
    static let loadTimeout: Duration = .seconds(10)

    let videoId: String
    let createdAt = ContinuousClock.now
    private(set) var webView: WKWebView?
    private(set) var didFail = false
    private let proxy = MessageProxy()
    var onRemoteCommand: (@MainActor (MusicRemoteTransportCommand) -> Void)?
    private let logger = DiagnosticsLogger.player

    /// Creates and starts loading the deck, or returns nil when the page can't be built.
    init?(
        videoId: String,
        channelToken: Int,
        volume: Double,
        webKitManager: WebKitManager,
        container: NSView
    ) {
        guard let source = CrossfadeDeckScript.script(channelToken: channelToken, videoId: videoId, volume: volume),
              let url = CrossfadeDeckScript.watchURL(videoId: videoId)
        else { return nil }
        self.videoId = videoId
        super.init()

        // Same data store (cookies, localStorage) as the main player, so the deck is
        // signed in; its own content controller carries only the deck script.
        let configuration = webKitManager.createWebViewConfiguration()
        // The deck lives for seconds and must fade smoothly while Tune is in the
        // background: hidden-page timer throttling (1 Hz) would make its fades step.
        configuration.preferences.inactiveSchedulingPolicy = .none
        configuration.userContentController.addUserScript(WKUserScript(
            source: source,
            injectionTime: .atDocumentStart,
            forMainFrameOnly: true
        ))
        self.proxy.deck = self
        configuration.userContentController.add(self.proxy, name: Self.messageHandlerName)

        let webView = WKWebView(frame: container.bounds, configuration: configuration)
        webView.customUserAgent = WebKitManager.userAgent
        webView.navigationDelegate = self
        webView.autoresizingMask = [.width, .height]
        webView.setAccessibilityElement(false)
        container.addSubview(webView, positioned: .below, relativeTo: container.subviews.first)
        self.webView = webView
        self.logger.info("Crossfade deck: loading \(videoId)")
        webView.load(URLRequest(url: url))
    }

    /// Polls the page. A dead, failed or overdue page reports `.failed`.
    func status() async -> CrossfadeDeckStatus {
        guard let webView, !self.didFail else { return .failed(videoId: self.videoId) }
        let raw = try? await webView.callAsyncJavaScript(
            CrossfadeDeckScript.stateScript,
            arguments: [:],
            in: nil,
            contentWorld: .page
        )
        if let json = raw as? String,
           let data = json.data(using: .utf8),
           let state = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        {
            let pageVideoId = state["videoId"] as? String
            let phase = state["phase"] as? String
            // The page lost the song (YouTube navigated elsewhere): done with it.
            if let pageVideoId, pageVideoId != self.videoId, phase != "loading" {
                return .stopped(videoId: self.videoId)
            }
            let status = CrossfadeDeckStatus.fromPage(phase: phase, videoId: self.videoId)
            if case .loading = status, ContinuousClock.now - self.createdAt > Self.loadTimeout {
                return .failed(videoId: self.videoId)
            }
            return status
        }
        if ContinuousClock.now - self.createdAt > Self.loadTimeout {
            return .failed(videoId: self.videoId)
        }
        return .loading(videoId: self.videoId)
    }

    func setVolume(_ volume: Double) {
        self.webView?.evaluateJavaScript(CrossfadeDeckScript.setVolumeScript(volume), completionHandler: nil)
    }

    func rewind() {
        self.webView?.evaluateJavaScript(CrossfadeDeckScript.rewindScript, completionHandler: nil)
    }

    func setHold(_ paused: Bool) {
        self.webView?.evaluateJavaScript(CrossfadeDeckScript.holdScript(paused: paused), completionHandler: nil)
    }

    /// How long an audible deck fades before it is released.
    static let teardownFade: Duration = .milliseconds(220)

    /// Silences and releases the page so its WebContent process exits. An audible deck
    /// fades out first (never a hard cut); the page is then closed without navigating
    /// anywhere, so nothing of it can linger in a back/forward or process cache.
    func tearDown() {
        guard let webView else { return }
        self.logger.info("Crossfade deck: tearing down \(self.videoId)")
        self.webView = nil
        self.proxy.deck = nil
        self.onRemoteCommand = nil
        webView.navigationDelegate = nil
        webView.evaluateJavaScript(CrossfadeDeckScript.fadeAwayScript, completionHandler: nil)
        Task { @MainActor in
            try? await Task.sleep(for: Self.teardownFade)
            Self.close(webView)
        }
    }

    private static func close(_ webView: WKWebView) {
        webView.evaluateJavaScript(CrossfadeDeckScript.stopScript, completionHandler: nil)
        webView.pauseAllMediaPlayback(completionHandler: nil)
        webView.configuration.userContentController.removeScriptMessageHandler(forName: Self.messageHandlerName)
        webView.configuration.userContentController.removeAllUserScripts()
        webView.stopLoading()
        webView.removeFromSuperview()
    }
}

// MARK: - WKNavigationDelegate

extension CrossfadeDeckWebView: WKNavigationDelegate {
    func webView(_: WKWebView, didFail _: WKNavigation!, withError error: Error) {
        self.logger.warning("Crossfade deck navigation failed: \(error.localizedDescription)")
        self.didFail = true
    }

    func webView(_: WKWebView, didFailProvisionalNavigation _: WKNavigation!, withError error: Error) {
        self.logger.warning("Crossfade deck load failed: \(error.localizedDescription)")
        self.didFail = true
    }

    func webViewWebContentProcessDidTerminate(_: WKWebView) {
        self.logger.warning("Crossfade deck content process terminated")
        self.didFail = true
    }

    func webView(
        _: WKWebView,
        decidePolicyFor navigationAction: WKNavigationAction,
        decisionHandler: @escaping @MainActor (WKNavigationActionPolicy) -> Void
    ) {
        // The deck stays on YouTube Music; anything else (sign-in walls, popups) fails it.
        let host = navigationAction.request.url?.host
        let isMainFrame = navigationAction.targetFrame?.isMainFrame ?? true
        if isMainFrame, host != "music.youtube.com", navigationAction.request.url?.scheme != "about" {
            self.didFail = true
            decisionHandler(.cancel)
            return
        }
        decisionHandler(.allow)
    }
}
