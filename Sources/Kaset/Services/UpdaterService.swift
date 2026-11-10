import Foundation
import Sparkle

// MARK: - UpdaterService

/// Manages application updates via Sparkle framework.
///
/// This service wraps Sparkle's `SPUStandardUpdaterController` to provide
/// a SwiftUI-friendly interface for checking and installing updates.
///
/// Usage:
/// ```swift
/// @State private var updaterService = UpdaterService()
///
/// Button(String(localized: "Check for Updates")) {
///     updaterService.checkForUpdates()
/// }
/// .disabled(!updaterService.canCheckForUpdates)
/// ```
@MainActor
@Observable
final class UpdaterService {
    /// The Sparkle updater controller that manages the update lifecycle.
    private let updaterController: SPUStandardUpdaterController

    /// Whether automatic update checks are enabled.
    ///
    /// When enabled, the app checks for updates on launch and periodically thereafter
    /// (default: every 24 hours, configurable via `SUScheduledCheckInterval` in Info.plist).
    var automaticChecksEnabled: Bool {
        get { self.updaterController.updater.automaticallyChecksForUpdates }
        set { self.updaterController.updater.automaticallyChecksForUpdates = newValue }
    }

    /// Whether the updater can currently check for updates.
    ///
    /// This is `false` while an update check is already in progress or during installation.
    var canCheckForUpdates: Bool {
        !self.hasStartedUpdater || self.updaterController.updater.canCheckForUpdates
    }

    /// Sparkle is started on the first manual check, never at launch: Tune has no
    /// update feed, so launch-time startup only cost memory and a scheduler.
    private var hasStartedUpdater = false

    /// The date of the last update check, or `nil` if never checked.
    var lastUpdateCheckDate: Date? {
        self.updaterController.updater.lastUpdateCheckDate
    }

    /// Initializes the updater service without starting the Sparkle updater.
    init() {
        self.updaterController = SPUStandardUpdaterController(
            startingUpdater: false,
            updaterDelegate: nil,
            userDriverDelegate: nil
        )

        DiagnosticsLogger.updater.info("UpdaterService initialized")
    }

    /// Manually triggers an update check.
    ///
    /// This shows Sparkle's standard update UI, including:
    /// - "Checking for updates..." progress indicator
    /// - "A new version is available" dialog if an update exists
    /// - "You're up to date" message if no update is available
    func checkForUpdates() {
        DiagnosticsLogger.updater.info("Manually checking for updates")
        if !self.hasStartedUpdater {
            self.hasStartedUpdater = true
            self.updaterController.startUpdater()
        }
        self.updaterController.checkForUpdates(nil)
    }
}
