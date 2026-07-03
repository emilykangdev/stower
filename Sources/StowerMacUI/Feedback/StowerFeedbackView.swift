import SwiftUI

/// The in-app feedback sheet: a multi-line message field, an optional reply-email
/// field, a one-line disclosure of the silent metadata, and Send/Cancel.
///
/// Mirrors `StowerLicenseEntryView`'s field idiom (`.roundedBorder`, `@FocusState`
/// auto-focus, red error text). The phase drives the body: `.idle`/`.sending` show
/// the form; `.sent` shows the "Thanks — got it." confirmation + Done (JC3);
/// `.failed` shows an inline connectivity error + Retry with the typed text
/// preserved. Fires `feedback_opened` on appear via `model.markOpened()`.
internal struct StowerFeedbackView: View {
    @Bindable internal var model: StowerFeedbackModel

    /// Dismisses the sheet (Cancel / Done).
    internal let onClose: () -> Void

    @FocusState private var messageFocused: Bool

    internal var body: some View {
        VStack(alignment: .leading, spacing: Self.sectionSpacing) {
            Text(Self.title)
                .font(.headline)
            content
        }
        .padding(Self.padding)
        .frame(width: Self.sheetWidth)
        .onAppear {
            model.markOpened()
            messageFocused = true
        }
    }

    @ViewBuilder private var content: some View {
        switch model.phase {
        case .idle, .sending, .failed:
            form
        case .sent:
            confirmation
        }
    }

    private var form: some View {
        VStack(alignment: .leading, spacing: Self.fieldSpacing) {
            messageField
            emailField
            Text(Self.disclosure)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if model.phase == .failed {
                Text(Self.failureMessage)
                    .font(.callout)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            actions
        }
    }

    private var messageField: some View {
        VStack(alignment: .leading, spacing: Self.captionSpacing) {
            TextField("What's on your mind?", text: $model.message, axis: .vertical)
                .textFieldStyle(.roundedBorder)
                .lineLimit(Self.messageLineLimit, reservesSpace: true)
                .focused($messageFocused)
                .disabled(model.phase == .sending)
                .accessibilityLabel("Feedback message")
            let messageCount = model.trimmedMessage.count
            if messageCount > Self.counterThreshold {
                Text("\(messageCount) / \(StowerFeedbackModel.messageCharLimit)")
                    .font(.caption2)
                    .foregroundStyle(
                        messageCount > StowerFeedbackModel.messageCharLimit
                            ? .red : .secondary
                    )
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }
        }
    }

    private var emailField: some View {
        TextField("Email (optional, if you'd like a reply)", text: $model.email)
            .textFieldStyle(.roundedBorder)
            .autocorrectionDisabled()
            .disabled(model.phase == .sending)
            .accessibilityLabel("Reply email, optional")
    }

    private var actions: some View {
        HStack(spacing: Self.actionSpacing) {
            Button("Cancel", role: .cancel, action: onClose)
            Spacer()
            if model.phase == .sending {
                ProgressView()
                    .controlSize(.small)
            }
            Button(model.phase == .failed ? "Retry" : "Send") {
                model.send()
            }
            .buttonStyle(.borderedProminent)
            .keyboardShortcut(.defaultAction)
            .disabled(!model.canSend)
        }
    }

    private var confirmation: some View {
        VStack(alignment: .leading, spacing: Self.fieldSpacing) {
            Text(Self.thanksMessage)
                .font(.body)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Spacer()
                Button("Done", action: onClose)
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
            }
        }
    }

    private static let title = "Send feedback"
    private static let disclosure =
        "Your app version and license ID are included so we can follow up."
    private static let failureMessage =
        "Couldn't send — check your connection and Retry."
    private static let thanksMessage = "Thanks — got it."
    private static let sheetWidth: CGFloat = 420
    private static let padding: CGFloat = 20
    private static let sectionSpacing: CGFloat = 14
    private static let fieldSpacing: CGFloat = 12
    private static let captionSpacing: CGFloat = 4
    private static let actionSpacing: CGFloat = 12
    private static let messageLineLimit = 5
    private static let counterThreshold = 4500
}

#Preview("Idle") {
    StowerFeedbackView(model: StowerFeedbackPreview.model(phase: .idle), onClose: {})
}

#Preview("Failed") {
    StowerFeedbackView(model: StowerFeedbackPreview.model(phase: .failed), onClose: {})
}

#Preview("Sent") {
    StowerFeedbackView(model: StowerFeedbackPreview.model(phase: .sent), onClose: {})
}

/// Preview-only factory that builds a `StowerFeedbackModel` wired to a stub
/// transport returning a fixed result, so each phase renders without the network.
private enum StowerFeedbackPreview {
    @MainActor static func model(phase: StowerFeedbackModel.Phase) -> StowerFeedbackModel {
        let result: StowerFeedbackSendResult = phase == .failed ? .failed : .sent
        let client = StowerFeedbackClient(
            endpointURL: "https://preview.invalid",
            transport: { _ in
                let status = result == .sent ? 200 : 500
                guard let url = URL(string: "https://preview.invalid"),
                    let response = HTTPURLResponse(
                        url: url,
                        statusCode: status,
                        httpVersion: nil,
                        headerFields: nil
                    )
                else { throw URLError(.badURL) }
                return (Data(), response)
            }
        )
        let model = StowerFeedbackModel(
            client: client,
            metadata: {
                StowerFeedbackMetadata(
                    instanceID: nil,
                    licenseStatus: .trial,
                    appVersion: "1.0 (1)",
                    osVersion: "macOS 15.4"
                )
            },
            analyticsReporter: StowerNoOpAnalyticsReporter()
        )
        model.message = phase == .idle ? "" : "Loving Stower, but…"
        return model
    }
}
