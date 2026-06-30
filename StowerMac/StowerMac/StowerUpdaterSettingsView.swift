import SwiftUI

/// Settings view for Stower's automatic-update preferences.
///
/// Presents two controls in a dependency hierarchy: automatic checks gate the
/// download-and-install toggle. When checks are off the lower toggle is visible
/// but disabled, so users understand the relationship without a tooltip.
/// A trust line at the bottom reinforces the EdDSA verification story.
public struct StowerUpdaterSettingsView: View {

    private enum Layout {
        static let connectorWidth: CGFloat = 1
        static let connectorHeight: CGFloat = 24
        static let connectorInset: CGFloat = 18
        static let dependentIndent: CGFloat = 28
        static let sectionSpacing: CGFloat = 20
        static let trustLineTopPadding: CGFloat = 12
    }

    private enum Copy {
        static let checksLabel = "Check for updates automatically"
        static let downloadLabel = "Automatically download & install"
        static let trustLine =
            "Updates are downloaded from Stower and verified with EdDSA before installing."
        static let disabledHint = "Enable automatic checks to allow automatic downloads."
    }

    @ObservedObject public var controller: StowerUpdaterController

    public init(controller: StowerUpdaterController) {
        self.controller = controller
    }

    public var body: some View {
        Form {
            Section {
                checksToggle
                dependentRow
            }
            Section {
                trustFooter
            }
        }
        .formStyle(.grouped)
        .padding(.vertical, Layout.sectionSpacing)
        .frame(minWidth: 360, idealWidth: 400, maxWidth: 520)
    }

    private var checksToggle: some View {
        Toggle(Copy.checksLabel, isOn: $controller.automaticallyChecksForUpdates)
            .toggleStyle(.switch)
    }

    private var dependentRow: some View {
        HStack(alignment: .top, spacing: 0) {
            VStack(spacing: 0) {
                Spacer().frame(height: 4)
                connector
            }
            .frame(width: Layout.dependentIndent)

            Toggle(Copy.downloadLabel, isOn: $controller.automaticallyDownloadsUpdates)
                .toggleStyle(.switch)
                .disabled(!controller.automaticallyChecksForUpdates)
                .help(controller.automaticallyChecksForUpdates ? "" : Copy.disabledHint)
        }
    }

    private var connector: some View {
        HStack(spacing: 0) {
            Spacer()
            VStack(spacing: 0) {
                Rectangle()
                    .fill(connectorColor)
                    .frame(width: Layout.connectorWidth, height: Layout.connectorHeight / 2)
                HStack(spacing: 0) {
                    Rectangle()
                        .fill(connectorColor)
                        .frame(width: Layout.connectorWidth, height: Layout.connectorHeight / 2)
                    Rectangle()
                        .fill(connectorColor)
                        .frame(height: Layout.connectorWidth)
                        .frame(maxWidth: .infinity)
                }
            }
            .frame(width: Layout.connectorInset, height: Layout.connectorHeight)
        }
    }

    private var connectorColor: Color {
        controller.automaticallyChecksForUpdates
            ? Color.accentColor.opacity(0.4)
            : Color.secondary.opacity(0.25)
    }

    private var trustFooter: some View {
        Label {
            Text(Copy.trustLine)
                .font(.footnote)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        } icon: {
            Image(systemName: "lock.fill")
                .font(.footnote)
                .foregroundStyle(.tertiary)
        }
        .padding(.top, Layout.trustLineTopPadding)
    }
}
