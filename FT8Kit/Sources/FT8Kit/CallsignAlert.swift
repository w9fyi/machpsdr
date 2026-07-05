import Foundation

/// A watch item: notify the user when a callsign is heard, optionally only
/// on one band.
public struct CallsignAlert: Codable, Sendable, Equatable, Identifiable {
    public var id: UUID
    public var callsign: String
    /// Band ID ("20m", ...); nil = any band.
    public var bandID: String?
    public var enabled: Bool

    public init(id: UUID = UUID(), callsign: String, bandID: String? = nil, enabled: Bool = true) {
        self.id = id
        self.callsign = callsign.uppercased()
        self.bandID = bandID
        self.enabled = enabled
    }

    /// True when a decoded message involves the watched callsign on the
    /// current band (sender or addressee).
    public func matches(parsed: FT8ParsedMessage, currentBandID: String?) -> Bool {
        guard enabled else { return false }
        if let bandID, let currentBandID, bandID != currentBandID { return false }
        let call = callsign.uppercased()
        return parsed.from == call || parsed.to == call
    }
}
