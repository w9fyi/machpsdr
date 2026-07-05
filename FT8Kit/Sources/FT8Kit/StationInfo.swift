import Foundation

/// Operator station details used for FT8 messages and (future) logging.
public struct StationInfo: Codable, Sendable, Equatable {
    public var callsign: String
    /// Maidenhead locator, 4 or 6 characters.
    public var grid: String
    public var city: String
    public var state: String
    public var country: String
    /// ITU region 1-3.
    public var ituRegion: Int?
    public var ituZone: Int?
    public var cqZone: Int?

    public init(callsign: String = "", grid: String = "", city: String = "",
                state: String = "", country: String = "", ituRegion: Int? = nil,
                ituZone: Int? = nil, cqZone: Int? = nil) {
        self.callsign = callsign
        self.grid = grid
        self.city = city
        self.state = state
        self.country = country
        self.ituRegion = ituRegion
        self.ituZone = ituZone
        self.cqZone = cqZone
    }

    /// The 4-character grid used on the air.
    public var grid4: String { String(grid.uppercased().prefix(4)) }

    /// True when callsign and grid are usable for FT8 operation.
    public var isReadyForFT8: Bool {
        !callsign.trimmingCharacters(in: .whitespaces).isEmpty && Maidenhead.isValid(grid)
    }
}
