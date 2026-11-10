import SwiftUI

// MARK: - ErrorView

/// Reusable error view with title, message, and optional retry action.
///
/// C2: a quiet, centered title and message on the page background with one small
/// rounded-square "Try Again" action. No warning badge, no glass, no prominent button.
@available(macOS 14.0, *)
struct ErrorView: View {
    let title: String
    let message: String
    let isRetryable: Bool
    let retryAction: (() -> Void)?

    /// Creates an ErrorView with explicit parameters.
    init(
        title: String = String(localized: "Unable to load content"),
        message: String,
        isRetryable: Bool = true,
        retryAction: (() -> Void)? = nil
    ) {
        self.title = title
        self.message = message
        self.isRetryable = isRetryable
        self.retryAction = retryAction
    }

    /// Creates an ErrorView from a LoadingError.
    init(
        error: LoadingError,
        retryAction: (() -> Void)? = nil
    ) {
        self.title = error.title
        self.message = error.message
        self.isRetryable = error.isRetryable
        self.retryAction = retryAction
    }

    var body: some View {
        TuneEmptyState(title: self.title, message: self.message) {
            if self.isRetryable, let action = self.retryAction {
                Button(action: action) {
                    PlaylistActionLabel(title: String(localized: "Try Again"), systemImage: "arrow.clockwise")
                        .fixedSize()
                        .padding(.horizontal, 4)
                }
                .buttonStyle(PlaylistActionButtonStyle())
            }
        }
    }
}

// MARK: - TuneEmptyState

/// Shared C2 layout for empty and error states: a section-size title, a muted message,
/// and an optional quiet action, centered on the page.
struct TuneEmptyState<Actions: View>: View {
    let title: String
    let message: String?
    @ViewBuilder let actions: () -> Actions

    var body: some View {
        VStack(spacing: 0) {
            Text(self.title)
                .font(TuneTheme.Typeface.section)
                .foregroundStyle(TuneTheme.Palette.ink)
                .multilineTextAlignment(.center)
                .accessibilityAddTraits(.isHeader)

            if let message, !message.isEmpty {
                Text(message)
                    .font(TuneTheme.Typeface.body)
                    .foregroundStyle(TuneTheme.Palette.inkMuted)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 380)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 8)
            }

            self.actions()
                .padding(.top, 20)
        }
        .padding(TuneTheme.Spacing.gutter)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityElement(children: .contain)
    }
}

extension TuneEmptyState where Actions == EmptyView {
    init(title: String, message: String?) {
        self.init(title: title, message: message) { EmptyView() }
    }
}

#Preview {
    ErrorView(message: "Something went wrong") {
        // No-op for preview
    }
    .frame(width: 800, height: 500)
    .background(TuneTheme.Palette.background)
}
