import Foundation

/// Semantic interpretation of a decoded FT8/FT4 message text.
public struct FT8ParsedMessage: Sendable, Equatable {
    public enum Kind: Sendable, Equatable {
        /// "CQ W9FYI EN52", "CQ DX W9FYI EN52", "CQ POTA W9FYI"
        case cq(modifier: String?, call: String, grid: String?)
        /// "K1ABC W9FYI EN52" — grid reply (Tx1)
        case gridReply(grid: String)
        /// "K1ABC W9FYI -07" — signal report (Tx2)
        case report(snr: Int)
        /// "K1ABC W9FYI R-07" — roger + report (Tx3)
        case rogerReport(snr: Int)
        /// "K1ABC W9FYI RRR"
        case rrr
        /// "K1ABC W9FYI RR73"
        case rr73
        /// "K1ABC W9FYI 73"
        case seventyThree
        /// Anything else (free text, telemetry, contest exchanges)
        case other
    }

    /// Addressee callsign (nil for CQ and free text).
    public let to: String?
    /// Sender callsign (nil if unparseable).
    public let from: String?
    public let kind: Kind
    /// Original message text.
    public let text: String

    /// Grid contained in the message, if any.
    public var grid: String? {
        switch kind {
        case .cq(_, _, let g): return g
        case .gridReply(let g): return g
        default: return nil
        }
    }

    /// True if this message is a CQ call.
    public var isCQ: Bool {
        if case .cq = kind { return true }
        return false
    }

    /// True if this message is addressed to `call` (angle brackets ignored).
    public func isAddressed(to call: String) -> Bool {
        guard let to else { return false }
        return to == call.uppercased()
    }

    /// Parse a decoded message text into its semantic form.
    public static func parse(_ text: String) -> FT8ParsedMessage {
        let cleaned = text.trimmingCharacters(in: .whitespaces).uppercased()
        var tokens = cleaned.split(separator: " ").map { stripBrackets(String($0)) }
        guard !tokens.isEmpty else {
            return FT8ParsedMessage(to: nil, from: nil, kind: .other, text: text)
        }

        if tokens[0] == "CQ" {
            tokens.removeFirst()
            var modifier: String? = nil
            // "CQ DX", "CQ POTA", "CQ NA", "CQ 123": modifier precedes the call
            if tokens.count >= 2, !looksLikeCallsign(tokens[0]) || (tokens.count >= 2 && looksLikeCallsign(tokens[1]) && tokens[0].count <= 4 && !looksLikeGrid(tokens[1])) {
                if !looksLikeCallsign(tokens[0]) {
                    modifier = tokens.removeFirst()
                }
            }
            guard let call = tokens.first, looksLikeCallsign(call) else {
                return FT8ParsedMessage(to: nil, from: nil, kind: .other, text: text)
            }
            tokens.removeFirst()
            let grid = tokens.first.flatMap { looksLikeGrid($0) ? $0 : nil }
            return FT8ParsedMessage(to: nil, from: call,
                                    kind: .cq(modifier: modifier, call: call, grid: grid),
                                    text: text)
        }

        // Directed message: "{to} {from} {payload}"
        guard tokens.count >= 2, looksLikeCallsign(tokens[0]), looksLikeCallsign(tokens[1]) else {
            return FT8ParsedMessage(to: nil, from: nil, kind: .other, text: text)
        }
        let to = tokens[0], from = tokens[1]
        let payload = tokens.count >= 3 ? tokens[2] : ""

        let kind: Kind
        switch payload {
        case "": kind = .other
        case "RRR": kind = .rrr
        case "RR73": kind = .rr73
        case "73": kind = .seventyThree
        default:
            if looksLikeGrid(payload) {
                kind = .gridReply(grid: payload)
            } else if payload.hasPrefix("R"), let snr = parseReport(String(payload.dropFirst())) {
                kind = .rogerReport(snr: snr)
            } else if let snr = parseReport(payload) {
                kind = .report(snr: snr)
            } else {
                kind = .other
            }
        }
        return FT8ParsedMessage(to: to, from: from, kind: kind, text: text)
    }

    /// Format a signal report the way FT8 messages carry it: "+05", "-13".
    public static func formatReport(_ snr: Int) -> String {
        let clamped = max(-30, min(30, snr))
        return String(format: "%+03d", clamped)
    }

    // MARK: - Helpers

    static func stripBrackets(_ s: String) -> String {
        s.trimmingCharacters(in: CharacterSet(charactersIn: "<>"))
    }

    /// Heuristic callsign check: 3-11 chars, contains at least one digit and
    /// one letter, alphanumeric plus '/'.
    static func looksLikeCallsign(_ s: String) -> Bool {
        guard s.count >= 3, s.count <= 11 else { return false }
        guard s.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "/" }) else { return false }
        guard s.contains(where: \.isNumber), s.contains(where: \.isLetter) else { return false }
        // Grids also contain letters+digits; exclude exact grid shape
        return !looksLikeGrid(s)
    }

    static func looksLikeGrid(_ s: String) -> Bool {
        guard s.count == 4 else { return false }
        let c = Array(s)
        return c[0].isLetter && c[1].isLetter && c[2].isNumber && c[3].isNumber
            && ("A"..."R").contains(String(c[0])) && ("A"..."R").contains(String(c[1]))
            && s != "RR73" // RR73 has grid shape but is a token
    }

    static func parseReport(_ s: String) -> Int? {
        guard s.count >= 2, s.first == "+" || s.first == "-" else { return nil }
        guard let value = Int(s) else { return nil }
        return (-50...50).contains(value) ? value : nil
    }
}
