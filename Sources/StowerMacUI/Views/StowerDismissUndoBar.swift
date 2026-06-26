import SwiftUI

/// The quiet, self-closing draining-bar undo for a dismiss (single OR batch).
///
/// A calm capsule — "Dismissed · Undo" (single) / "N dismissed · Undo" (batch) — with
/// a thin line that *depletes* over the dwell window (deliberately NOT a burning /
/// alarming countdown; this is a calm app). It pauses while hovered or keyboard-focused
/// (WCAG 2.2.1), then clears itself via `onExpire`. The bar appears ONLY after the
/// dismiss write resolved (the view-model sets the slot), so it never shows over a
/// failed write. Undo and ⌘Z are the same action; this bar's button calls `onUndo`.
///
/// Honors Reduce Motion (no draining animation — a static rule) and Reduce
/// Transparency (a solid background, no material), and announces itself to VoiceOver.
internal struct StowerDismissUndoBar: View {
    /// The slot to render; its `id` restarts the drain when replaced, `count` picks
    /// the copy + dwell.
    internal let state: StowerDismissUndoBarState

    /// Reverses the dismiss (same call as ⌘Z) — the view-model's `undoLastDismiss`.
    internal let onUndo: () -> Void

    /// Fires when the dwell elapses, carrying the slot id so a stale timer can't clear
    /// a newer bar — the view-model's `expireUndoBar(id:)`.
    internal let onExpire: (Int) -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    @State private var remainingRatio: Double = 1
    @State private var isHovering = false
    @FocusState private var undoFocused: Bool

    internal var body: some View {
        HStack(spacing: Self.contentSpacing) {
            Text(label)
                .font(.callout)
                .foregroundStyle(.primary)
            Button("Undo", action: onUndo)
                .buttonStyle(.borderless)
                .focused($undoFocused)
        }
        .padding(.horizontal, Self.horizontalPadding)
        .padding(.vertical, Self.verticalPadding)
        .background(background)
        .overlay(alignment: .bottom) { drainLine }
        .clipShape(Capsule())
        .shadow(
            color: .black.opacity(Self.shadowOpacity),
            radius: Self.shadowRadius,
            y: Self.shadowY
        )
        .onHover { isHovering = $0 }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(label)
        .accessibilityHint("Undo available")
        .accessibilityAddTraits(.updatesFrequently)
        .task(id: state.id) { await drain() }
    }

    /// "Dismissed · Undo" for a single row, "N dismissed · Undo" for a batch.
    private var label: String {
        state.count > 1 ? "\(state.count) dismissed" : "Dismissed"
    }

    @ViewBuilder private var background: some View {
        if reduceTransparency {
            Capsule().fill(Color(nsColor: .windowBackgroundColor))
        } else {
            Capsule().fill(.ultraThinMaterial)
        }
    }

    /// The depleting line: a thin rule whose width tracks the remaining ratio.
    ///
    /// Static (full width, no animation) under Reduce Motion — the bar still
    /// self-dismisses.
    @ViewBuilder private var drainLine: some View {
        GeometryReader { geometry in
            Capsule()
                .fill(Color.accentColor.opacity(Self.drainOpacity))
                .frame(width: geometry.size.width * (reduceMotion ? 1 : remainingRatio))
        }
        .frame(height: Self.drainHeight)
    }

    /// Depletes `remainingRatio` from 1 to 0 over the dwell, pausing while hovered or
    /// focused, then fires `onExpire`.
    ///
    /// A manual tick (not a single `withAnimation`) is what makes pause-on-hover exact.
    private func drain() async {
        remainingRatio = 1
        let total = Self.seconds(dwell)
        var elapsed = 0.0
        while elapsed < total {
            try? await Task.sleep(for: Self.tick)
            if Task.isCancelled { return }
            guard !isHovering, !undoFocused else { continue }
            elapsed += Self.seconds(Self.tick)
            withAnimation(reduceMotion ? nil : .linear(duration: Self.seconds(Self.tick))) {
                remainingRatio = max(0, 1 - elapsed / total)
            }
        }
        onExpire(state.id)
    }

    /// The dwell window: longer for a batch so a multi-row undo isn't missed.
    private var dwell: Duration {
        state.count > 1 ? Self.batchDwell : Self.singleDwell
    }

    /// Whole seconds (with sub-second remainder) of a `Duration`, for ratio math.
    private static func seconds(_ duration: Duration) -> Double {
        let components = duration.components
        return Double(components.seconds)
            + Double(components.attoseconds) / Self.attosecondsPerSecond
    }

    /// Attoseconds in one second (the unit of `Duration.components.attoseconds`).
    private static let attosecondsPerSecond = 1e18

    /// The single-dismiss dwell (JC3 / deferred JC (a) — tune on the running app).
    private static let singleDwell: Duration = .seconds(3)

    /// The batch-dismiss dwell (longer; a bigger undo deserves a longer window).
    private static let batchDwell: Duration = .seconds(5)

    /// The drain tick granularity (smooth without busy-spinning).
    private static let tick: Duration = .milliseconds(50)

    private static let contentSpacing: CGFloat = 12
    private static let horizontalPadding: CGFloat = 16
    private static let verticalPadding: CGFloat = 10
    private static let drainHeight: CGFloat = 2
    private static let drainOpacity: CGFloat = 0.5
    private static let shadowOpacity: CGFloat = 0.15
    private static let shadowRadius: CGFloat = 8
    private static let shadowY: CGFloat = 2
}
