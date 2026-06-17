import Foundation

/// A conversation's facts paired with its last act's message GUID.
///
/// The GUID is the verdict cache's key, but it must not reach the public
/// `StowerConversationState.init` — adding a required init argument would break
/// every caller, including the app's fixtures. So it rides alongside the state
/// in this internal record instead, and only the provider and cache see it.
internal struct StowerConversationStateRecord: Sendable, Equatable {
    /// The neutral per-conversation facts.
    internal let state: StowerConversationState

    /// The GUID of the conversation's true last act.
    internal let lastMessageGUID: String
}
