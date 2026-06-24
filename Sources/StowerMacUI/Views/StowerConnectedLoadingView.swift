import SwiftUI

/// The honest cold-start loading state after a successful board load.
///
/// This slice renders **no board** — `loadDebtBoard` succeeds but the slice
/// discards its result (empty on a cold cache, possibly real rows on a warm one)
/// and the `refreshJudgments` lifecycle is the next slice. So this is a loading
/// state with a first-run time expectation, never a board and never "all caught
/// up".
internal struct StowerConnectedLoadingView: View {
    internal var body: some View {
        StowerOnboardingPane(
            title: "Connected — preparing your board",
            message: "Stower is reading your Messages on this Mac. This can take a few "
                + "minutes the first time."
        ) {
            ProgressView()
                .controlSize(.large)
                .accessibilityHidden(true)
        }
        .accessibilityElement(children: .combine)
    }
}
