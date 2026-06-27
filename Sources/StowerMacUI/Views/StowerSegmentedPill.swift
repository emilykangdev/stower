import SwiftUI

/// A warm custom segmented control that replaces `.pickerStyle(.segmented)` — the most
/// obviously "stock SwiftUI" element on the board.
///
/// The active segment gets a soft peach (`tabActiveFill`) capsule and switching
/// cross-fades on the `tabSwitch` motion token. A segmented `Picker` gives VoiceOver and
/// keyboard selection for free; this control re-adds both by hand so the swap is not an
/// accessibility regression (JC1): every segment is a focusable `Button` carrying the
/// `.isSelected` trait, with a warm (non-blue) focus ring drawn when it holds focus.
///
/// Generic over any option set with a title, so the board's tab control drives it off
/// `StowerBoardTab` without hardcoded strings.
internal struct StowerSegmentedPill<Option: Hashable & Identifiable>: View {
    /// The bound selection.
    @Binding internal var selection: Option

    /// The segments, in display order.
    internal let options: [Option]

    /// The label for a segment.
    internal let title: (Option) -> String

    /// Reduce Motion (read in the parent view), gating the selection cross-fade.
    internal let reduceMotion: Bool

    /// Which segment currently holds keyboard focus (drives the warm focus ring).
    @FocusState private var focusedOption: Option?

    internal var body: some View {
        HStack(spacing: Self.segmentSpacing) {
            ForEach(options) { option in
                segment(option)
            }
        }
        .padding(Self.trackPadding)
        .background(StowerPalette.surface, in: Capsule())
        .animation(StowerMotion.tabSwitch(reduceMotion), value: selection)
    }

    private func segment(_ option: Option) -> some View {
        let isSelected = option == selection
        return Button {
            selection = option
        } label: {
            Text(title(option))
                .font(.callout.weight(isSelected ? .semibold : .regular))
                .foregroundStyle(
                    isSelected ? StowerPalette.textPrimary : StowerPalette.textSecondary
                )
                .padding(.horizontal, Self.segmentHorizontalPadding)
                .padding(.vertical, Self.segmentVerticalPadding)
                .frame(maxWidth: .infinity)
                .background {
                    if isSelected {
                        Capsule().fill(StowerPalette.tabActiveFill)
                    }
                }
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .focused($focusedOption, equals: option)
        .overlay {
            if focusedOption == option {
                Capsule().strokeBorder(StowerPalette.coral, lineWidth: Self.focusRingWidth)
            }
        }
        .accessibilityAddTraits(isSelected ? [.isSelected] : [])
    }

    // Computed (not `static let`): a generic type can't hold stored static properties.
    private static var segmentSpacing: CGFloat { 2 }
    private static var trackPadding: CGFloat { 3 }
    private static var segmentHorizontalPadding: CGFloat { 14 }
    private static var segmentVerticalPadding: CGFloat { 6 }
    private static var focusRingWidth: CGFloat { 2 }
}
