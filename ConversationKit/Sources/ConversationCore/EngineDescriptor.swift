import Foundation

/// Identifies which engine (and which version of it) produced a piece of data,
/// so transcripts, embeddings, and attributions remain interpretable after an
/// engine is swapped or upgraded.
public struct EngineDescriptor: Hashable, Codable, Sendable {
    /// Stable reverse-DNS style identifier, e.g. `apple.speech.transcriber`.
    public var identifier: String
    /// Engine or model version when known.
    public var version: String?

    public init(identifier: String, version: String? = nil) {
        self.identifier = identifier
        self.version = version
    }
}
