import Foundation

/// How to choose which station to answer when several are available.
public struct FT8AutoAnswerPolicy: Codable, Sendable, Equatable {
    public enum Order: String, Codable, CaseIterable, Sendable, Identifiable {
        case loudestFirst
        case closestFirst
        case furthestFirst

        public var id: String { rawValue }

        public var displayName: String {
            switch self {
            case .loudestFirst: return "Loudest first"
            case .closestFirst: return "Closest first"
            case .furthestFirst: return "Furthest first"
            }
        }
    }

    public var order: Order
    /// Restrict to these continents (empty = no restriction).
    public var continents: Set<Continent>
    /// Skip stations already worked this session.
    public var skipWorked: Bool

    public init(order: Order = .loudestFirst, continents: Set<Continent> = [],
                skipWorked: Bool = true) {
        self.order = order
        self.continents = continents
        self.skipWorked = skipWorked
    }
}

/// A station eligible for answering (a CQ caller, or a reply to our CQ).
public struct FT8AnswerCandidate: Sendable, Equatable {
    public let call: String
    public let grid: String?
    public let snr: Int
    public let message: FT8RxMessage

    public init(call: String, grid: String?, snr: Int, message: FT8RxMessage) {
        self.call = call
        self.grid = grid
        self.snr = snr
        self.message = message
    }
}

/// Pure selection logic for auto-answering.
public enum FT8AutoAnswer {

    /// Choose the station to work next according to the policy.
    /// - Parameters:
    ///   - myGrid: our grid, used for distance ordering.
    ///   - workedCalls: callsigns already worked (skipped when policy says so).
    public static func select(from candidates: [FT8AnswerCandidate],
                              policy: FT8AutoAnswerPolicy,
                              myGrid: String,
                              workedCalls: Set<String>) -> FT8AnswerCandidate? {
        var pool = candidates
        if policy.skipWorked {
            pool = pool.filter { !workedCalls.contains($0.call.uppercased()) }
        }
        if !policy.continents.isEmpty {
            pool = pool.filter {
                guard let c = DXCCLookup.continent(for: $0.call) else { return false }
                return policy.continents.contains(c)
            }
        }
        switch policy.order {
        case .loudestFirst:
            return pool.max { $0.snr < $1.snr }
        case .closestFirst:
            return pool.min { distance($0, myGrid) < distance($1, myGrid) }
        case .furthestFirst:
            return pool.max { distance($0, myGrid) < distance($1, myGrid) }
        }
    }

    /// Extract answer candidates from a slot's CQ decodes.
    public static func cqCandidates(in messages: [FT8RxMessage]) -> [FT8AnswerCandidate] {
        messages.compactMap { msg in
            guard case .cq(_, let call, let grid) = msg.parsed.kind else { return nil }
            return FT8AnswerCandidate(call: call, grid: grid, snr: msg.snr, message: msg)
        }
    }

    /// Extract candidates from replies to our CQ.
    public static func replyCandidates(in messages: [FT8RxMessage]) -> [FT8AnswerCandidate] {
        messages.compactMap { msg in
            guard let from = msg.parsed.from else { return nil }
            return FT8AnswerCandidate(call: from, grid: msg.parsed.grid, snr: msg.snr, message: msg)
        }
    }

    /// Stations without a grid sort to the end for closest-first and are
    /// ignored for furthest-first only when a gridded candidate exists.
    private static func distance(_ candidate: FT8AnswerCandidate, _ myGrid: String) -> Double {
        guard let g = candidate.grid,
              let km = Maidenhead.distanceKm(from: myGrid, to: g) else {
            return Double.greatestFiniteMagnitude / 2
        }
        return km
    }
}
