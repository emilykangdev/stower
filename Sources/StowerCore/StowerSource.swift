/// A source adapter that can contribute items to the Stower index.
public enum StowerSource: String, Codable, CaseIterable, Sendable {
    /// Apple Messages.
    case messages

    /// Apple Photos.
    case photos
}
