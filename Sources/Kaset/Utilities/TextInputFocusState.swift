import AppKit
import SwiftUI

// MARK: - TextInputFocusState

/// Tracks whether a text field is first responder so playback menu shortcuts defer to editing.
@MainActor
@Observable
final class TextInputFocusState {
    private(set) var isFocused = false

    private var observers: [NSObjectProtocol] = []
    private var isMonitoring = false

    /// Post when SwiftUI moves focus into or out of a text field without editing it (focusing
    /// alone sends no `textDidBeginEditing`), so Space and the other bare playback shortcuts
    /// stand down while the field has focus and come back once it loses it.
    static let focusDidChangeNotification = Notification.Name("TextInputFocusState.focusDidChange")

    func startMonitoring() {
        guard !self.isMonitoring else { return }
        self.isMonitoring = true

        let names = [
            NSControl.textDidBeginEditingNotification,
            NSControl.textDidEndEditingNotification,
            NSWindow.didBecomeKeyNotification,
            NSWindow.didResignKeyNotification,
            Self.focusDidChangeNotification,
        ]

        for name in names {
            let observer = NotificationCenter.default.addObserver(
                forName: name,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                Task { @MainActor in
                    self?.updateFromFirstResponder()
                }
            }
            self.observers.append(observer)
        }

        self.updateFromFirstResponder()
    }

    isolated deinit {
        for observer in self.observers {
            NotificationCenter.default.removeObserver(observer)
        }
    }

    private func updateFromFirstResponder() {
        guard let firstResponder = NSApplication.shared.keyWindow?.firstResponder else {
            self.isFocused = false
            return
        }

        self.isFocused = firstResponder is NSTextView || firstResponder is NSTextField
    }
}
