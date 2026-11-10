import JavaScriptCore
import Testing
import WebKit
@testable import Kaset

// MARK: - SingletonPlayerIdlePromptGuardScriptTests

@Suite(.serialized, .tags(.service))
@MainActor
struct SingletonPlayerIdlePromptGuardScriptTests {
    @Test("Idle prompt guard is installed into the playback document at document end")
    func guardIsInstalledIntoPlaybackWebView() {
        let singleton = SingletonPlayerWebView.makeTestInstance()
        let webView = singleton.getWebView(
            webKitManager: WebKitManager.makeTestInstance(),
            playerService: PlayerService()
        )
        defer { singleton.tearDown() }

        let scripts = webView.configuration.userContentController.userScripts
        let guardScripts = scripts.filter { $0.source == SingletonPlayerWebView.idlePromptGuardScript }
        #expect(guardScripts.count == 1)
        #expect(guardScripts.first?.injectionTime == .atDocumentEnd)
        #expect(guardScripts.first?.isForMainFrameOnly == true)

        // Reinstalling for a new document must not duplicate the guard.
        singleton.refreshInstalledUserScripts()
        let reinstalled = webView.configuration.userContentController.userScripts
            .filter { $0.source == SingletonPlayerWebView.idlePromptGuardScript }
        #expect(reinstalled.count == 1)
    }

    @Test("Guard script targets YouTube Music's idle prompt and Kaset's intent flags")
    func guardScriptContainsKeyMarkers() {
        let script = SingletonPlayerWebView.idlePromptGuardScript
        #expect(script.contains("ytmusic-you-there-renderer"))
        #expect(script.contains("window._lact"))
        #expect(script.contains("__kasetPlaybackSuppressed"))
        #expect(script.contains("__kasetBlockAutoplay"))
        #expect(script.contains("__kasetIdlePromptGuardInstalled"))
    }

    @Test("Activity clock is refreshed only while Kaset intends playback")
    func refreshesActivityClockOnlyWhenPlaybackWanted() throws {
        let context = try #require(self.makeContext())
        try self.evaluate("window._lact = 1;", in: context)
        try self.evaluate(SingletonPlayerWebView.idlePromptGuardScript, in: context)
        #expect((context.evaluateScript("window._lact")?.toDouble() ?? 0) > 1_000_000)
        #expect(context.evaluateScript("intervals[0].ms")?.toInt32() == 60000)

        try self.evaluate("window._lact = 1; window.__kasetPlaybackSuppressed = true; intervals[0].fn();", in: context)
        #expect(context.evaluateScript("window._lact")?.toDouble() == 1)

        try self.evaluate(
            "window.__kasetPlaybackSuppressed = false; window.__kasetBlockAutoplay = true; intervals[0].fn();",
            in: context
        )
        #expect(context.evaluateScript("window._lact")?.toDouble() == 1)

        try self.evaluate("window.__kasetBlockAutoplay = false; window.__kasetRefreshPageActivity();", in: context)
        #expect((context.evaluateScript("window._lact")?.toDouble() ?? 0) > 1_000_000)
    }

    @Test("Guard does not create an activity clock YouTube Music has not initialized")
    func doesNotCreateActivityClock() throws {
        let context = try #require(self.makeContext())
        try self.evaluate(SingletonPlayerWebView.idlePromptGuardScript, in: context)
        #expect(context.evaluateScript("typeof window._lact")?.toString() == "undefined")
    }

    @Test("Visible idle prompt is answered and Kaset-wanted playback resumes once")
    func answersVisiblePromptAndResumes() throws {
        let context = try #require(self.makeContext())
        try self.evaluate("window._lact = 1;", in: context)
        try self.evaluate(SingletonPlayerWebView.idlePromptGuardScript, in: context)
        try self.evaluate("showPrompt(); video.paused = true; mutationCallback(); drainTimeouts();", in: context)

        #expect(context.evaluateScript("confirmClicks")?.toInt32() == 1)
        #expect(context.evaluateScript("playCalls")?.toInt32() == 1)
        #expect(context.evaluateScript("querySelectors[0]")?.toString() == "yt-button-renderer[dialog-confirm] button")

        // Further DOM churn while the same prompt is still up does not re-click.
        try self.evaluate("mutationCallback(); drainTimeouts();", in: context)
        #expect(context.evaluateScript("confirmClicks")?.toInt32() == 1)
    }

    @Test("Idle prompt never resumes media Kaset paused")
    func promptDoesNotResumeSuppressedPlayback() throws {
        let context = try #require(self.makeContext())
        try self.evaluate(SingletonPlayerWebView.idlePromptGuardScript, in: context)
        try self.evaluate(
            "window.__kasetPlaybackSuppressed = true; showPrompt(); video.paused = true; mutationCallback(); drainTimeouts();",
            in: context
        )
        #expect(context.evaluateScript("confirmClicks")?.toInt32() == 0)
        #expect(context.evaluateScript("playCalls")?.toInt32() == 0)
    }

    @Test("Closed prompt left in the DOM is ignored")
    func hiddenPromptIsIgnored() throws {
        let context = try #require(self.makeContext())
        try self.evaluate(SingletonPlayerWebView.idlePromptGuardScript, in: context)
        try self.evaluate(
            "showPrompt(); dialog.opened = false; video.paused = true; mutationCallback(); drainTimeouts();",
            in: context
        )
        #expect(context.evaluateScript("confirmClicks")?.toInt32() == 0)
        #expect(context.evaluateScript("playCalls")?.toInt32() == 0)
    }

    private func makeContext() -> JSContext? {
        guard let context = JSContext() else { return nil }
        context.exceptionHandler = { _, exception in
            Issue.record("JavaScript exception: \(exception?.toString() ?? "unknown")")
        }
        context.evaluateScript(
            """
            var window = this;
            var intervals = [];
            var timeouts = [];
            var listeners = {};
            var confirmClicks = 0;
            var playCalls = 0;
            var mutationCallback = function() {};
            var promptRenderer = null;
            function setInterval(fn, ms) { intervals.push({ fn: fn, ms: ms }); return intervals.length; }
            function setTimeout(fn, ms) { timeouts.push(fn); return timeouts.length; }
            function drainTimeouts() { var pending = timeouts; timeouts = []; pending.forEach(function(fn) { fn(); }); }
            function MutationObserver(callback) { mutationCallback = callback; }
            MutationObserver.prototype.observe = function() {};
            function getComputedStyle() { return { display: 'block', visibility: 'visible' }; }
            var video = {
                tagName: 'VIDEO',
                paused: false,
                ended: false,
                play: function() { playCalls += 1; this.paused = false; return { catch: function() {} }; }
            };
            var confirmButton = { click: function() { confirmClicks += 1; } };
            var querySelectors = [];
            var dialog = { opened: true, hidden: false, close: function() { this.opened = false; } };
            function showPrompt() {
                promptRenderer = {
                    isConnected: true,
                    closest: function() { return dialog; },
                    querySelector: function(selector) {
                        querySelectors.push(selector);
                        return selector.indexOf('[dialog-confirm]') >= 0 ? confirmButton : null;
                    }
                };
            }
            var document = {
                readyState: 'complete',
                body: {},
                documentElement: {},
                addEventListener: function(name, fn) { listeners[name] = fn; },
                querySelector: function(selector) {
                    if (selector === 'video') return video;
                    if (selector === 'ytmusic-you-there-renderer') return promptRenderer;
                    return null;
                }
            };
            """
        )
        return context
    }

    private func evaluate(_ script: String, in context: JSContext) throws {
        context.exception = nil
        _ = context.evaluateScript(script)
        if let exception = context.exception?.toString() {
            Issue.record("JavaScript exception: \(exception)")
            throw IdlePromptGuardScriptError.javaScriptException(exception)
        }
    }
}

// MARK: - IdlePromptGuardScriptError

private enum IdlePromptGuardScriptError: Error {
    case javaScriptException(String)
}
