import Foundation

/// Releases caches that nothing visible needs once the main window is hidden
/// (closed to the background, ⌘H, or replaced by the mini player).
///
/// On-screen views keep the bitmaps they display (`CachedAsyncImage` holds its
/// current image, Home cells hold theirs in a layer), so this only frees decodes
/// for rows that are not shown. Re-showing the window re-decodes from the disk
/// tier as rows come back into view.
@MainActor
enum MemoryRelief {
    /// Off under unit tests: suites run in parallel against the shared caches, and a
    /// window-lifecycle test must not empty a cache another test just warmed.
    static var isEnabled = !UITestConfig.isRunningUnitTests

    static func mainWindowDidHide() {
        guard self.isEnabled else { return }
        ImageCache.shared.trimMemoryCache()
        APICache.shared.purgeExpired()
        DiagnosticsLogger.app.debug("MemoryRelief: trimmed image memory tier and expired API responses")
    }
}
