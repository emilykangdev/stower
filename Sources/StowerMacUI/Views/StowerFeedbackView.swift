import Accessibility
import SwiftUI

/// The in-app feedback sheet: a thin renderer over `StowerFeedbackFormModel`.
///
/// Layout, keyboard shortcuts, and accessibility are specified in the plan's
/// Sheet spec. All send logic lives in the model; the view only wires buttons,
/// fields, and observation to the model's published state.
internal struct StowerFeedbackView: View {
    @FocusState private var textFocus: Bool

    @Bindable internal var model: StowerFeedbackFormModel

    /// Called when the model signals `didSend` — lets `StowerBoardView` trigger
    /// the board-level success confirmation before the sheet dismisses.
    internal let onSuccess: () -> Void

    /// Dismisses the sheet by clearing the board's `feedbackFormModel`.
    ///
    /// Invoked on Cancel and after a successful send. The board drives
    /// presentation via `.sheet(item:)`, so dismissal is "drop the model".
    internal let onDismiss: () -> Void

    internal var body: some View {
        VStack(alignment: .leading, spacing: Self.sectionSpacing) {
            header
            fields
            if let message = model.errorMessage {
                errorLine(message)
            }
            actions
        }
        .padding(Self.contentPadding)
        .frame(minWidth: Self.minWidth, minHeight: Self.minHeight)
        .interactiveDismissDisabled(model.isSending)
        .onAppear { textFocus = true }
        .onChange(of: model.didSend) { _, sent in
            if sent {
                onSuccess()
                onDismiss()
            }
        }
    }

    // MARK: - Subviews

    private var header: some View {
        VStack(alignment: .leading, spacing: Self.headerSpacing) {
            Text("Send Feedback")
                .font(.headline)
                .accessibilityAddTraits(.isHeader)
            Text("Tell Emily what's working or what's not — it goes straight to her.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
    }

    private var fields: some View {
        VStack(alignment: .leading, spacing: Self.fieldSpacing) {
            textEditorField
            emailField
            if model.licenseID != nil {
                disclosureLine
            }
        }
    }

    private var textEditorField: some View {
        VStack(alignment: .trailing, spacing: Self.counterSpacing) {
            ZStack(alignment: .topLeading) {
                if model.text.isEmpty {
                    Text("What's on your mind?")
                        .foregroundStyle(.placeholder)
                        .padding(.vertical, Self.textEditorInsetVertical)
                        .padding(.horizontal, Self.textEditorInsetHorizontal)
                        .allowsHitTesting(false)
                }
                TextEditor(text: $model.text)
                    .font(.body)
                    .scrollContentBackground(.hidden)
                    .focused($textFocus)
                    .disabled(model.isSending)
                    .frame(minHeight: Self.textEditorMinHeight)
                    .accessibilityLabel("Feedback text")
            }
            .background(
                RoundedRectangle(cornerRadius: Self.fieldCornerRadius)
                    .strokeBorder(.separator, lineWidth: 1)
            )
            if model.text.count > Self.counterThreshold {
                Text("\(model.text.count) / \(StowerFeedbackFormModel.maxTextLength)")
                    .font(.caption)
                    .foregroundStyle(
                        model.text.count > StowerFeedbackFormModel.maxTextLength
                            ? .red : .secondary
                    )
                    .monospacedDigit()
            }
        }
    }

    private var emailField: some View {
        TextField("Email (optional — for a reply)", text: $model.email)
            .textFieldStyle(.roundedBorder)
            .disabled(model.isSending)
            .accessibilityLabel("Email, optional, for a reply")
    }

    private var disclosureLine: some View {
        Text("Sent with your license ID so Emily can reply.")
            .font(.caption)
            .foregroundStyle(.secondary)
    }

    private func errorLine(_ message: String) -> some View {
        Text(message)
            .font(.caption)
            .foregroundStyle(.red)
            .accessibilityLabel(message)
            .onAppear {
                AccessibilityNotification.Announcement(message).post()
            }
    }

    private var actions: some View {
        HStack {
            Spacer()
            Button("Cancel") {
                onDismiss()
            }
            .keyboardShortcut(.cancelAction)
            .disabled(model.isSending)
            sendButton
        }
    }

    @ViewBuilder private var sendButton: some View {
        if model.isSending {
            Button {
                // no-op while sending; disabled state handled below
            } label: {
                HStack(spacing: Self.spinnerSpacing) {
                    ProgressView()
                        .scaleEffect(Self.spinnerScale)
                        .frame(width: Self.spinnerSize, height: Self.spinnerSize)
                    Text("Send")
                }
            }
            .disabled(true)
        } else {
            Button("Send") {
                Task { await model.send() }
            }
            .keyboardShortcut(.defaultAction)
            .disabled(!model.canSend)
            .buttonStyle(.borderedProminent)
        }
    }

    // MARK: - Named constants (no magic literals)

    internal static let minWidth: CGFloat = 420
    internal static let minHeight: CGFloat = 260
    private static let contentPadding: CGFloat = 20
    private static let sectionSpacing: CGFloat = 16
    private static let headerSpacing: CGFloat = 4
    private static let fieldSpacing: CGFloat = 8
    private static let counterSpacing: CGFloat = 2
    private static let counterThreshold = StowerFeedbackFormModel.maxTextLength - 200
    private static let textEditorMinHeight: CGFloat = 100
    private static let textEditorInsetVertical: CGFloat = 8
    private static let textEditorInsetHorizontal: CGFloat = 5
    private static let fieldCornerRadius: CGFloat = 6
    private static let spinnerScale: CGFloat = 0.7
    private static let spinnerSize: CGFloat = 16
    private static let spinnerSpacing: CGFloat = 4
}
