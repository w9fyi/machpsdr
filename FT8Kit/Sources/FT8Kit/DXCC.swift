import Foundation

/// Continents used for CQ answering filters.
public enum Continent: String, CaseIterable, Codable, Sendable, Identifiable {
    case northAmerica = "NA"
    case southAmerica = "SA"
    case europe = "EU"
    case africa = "AF"
    case asia = "AS"
    case oceania = "OC"
    case antarctica = "AN"

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .northAmerica: return "North America"
        case .southAmerica: return "South America"
        case .europe: return "Europe"
        case .africa: return "Africa"
        case .asia: return "Asia"
        case .oceania: return "Oceania"
        case .antarctica: return "Antarctica"
        }
    }
}

/// A DXCC entity resolved from a callsign prefix.
public struct DXCCEntity: Sendable, Equatable {
    public let name: String
    public let continent: Continent
}

/// Callsign-prefix → DXCC entity lookup using a built-in table of common
/// prefixes (longest-match wins). Not exhaustive; unknown prefixes return nil.
public enum DXCCLookup {

    /// Resolve the DXCC entity for a callsign. Portable suffixes (/P, /QRP,
    /// /M, single digit) are ignored; a leading portable prefix (e.g. PJ4/K1ABC)
    /// takes precedence, matching standard DX convention.
    public static func entity(for callsign: String) -> DXCCEntity? {
        var call = callsign.uppercased().trimmingCharacters(in: CharacterSet(charactersIn: "<>"))
        // Handle A/B forms: the part that looks like a prefix (shorter, or the
        // leading part by convention) determines the entity.
        if call.contains("/") {
            let parts = call.split(separator: "/").map(String.init)
            if parts.count == 2 {
                let suffixes: Set<String> = ["P", "M", "MM", "AM", "QRP", "A", "R"]
                if suffixes.contains(parts[1]) || parts[1].count == 1 {
                    call = parts[0]           // K1ABC/P → K1ABC
                } else {
                    call = parts[0]           // PJ4/K1ABC → PJ4 (prefix wins)
                }
            } else {
                call = parts.first ?? call
            }
        }
        for length in stride(from: min(4, call.count), through: 1, by: -1) {
            let prefix = String(call.prefix(length))
            if let hit = table[prefix] { return hit }
        }
        return nil
    }

    /// Continent for a callsign, if the prefix is known.
    public static func continent(for callsign: String) -> Continent? {
        entity(for: callsign)?.continent
    }

    // Longest-prefix-match table of common DXCC prefixes.
    static let table: [String: DXCCEntity] = {
        var t: [String: DXCCEntity] = [:]
        func add(_ prefixes: [String], _ name: String, _ c: Continent) {
            for p in prefixes { t[p] = DXCCEntity(name: name, continent: c) }
        }
        // North America
        add(["K", "W", "N", "AA", "AB", "AC", "AD", "AE", "AF", "AG", "AI", "AJ", "AK", "AL"], "United States", .northAmerica)
        add(["KH6", "KH7"], "Hawaii", .oceania)
        add(["KL", "AL7", "NL7", "WL7"], "Alaska", .northAmerica)
        add(["KP4", "NP4", "WP4", "KP3"], "Puerto Rico", .northAmerica)
        add(["VE", "VA", "VO", "VY"], "Canada", .northAmerica)
        add(["XE", "XF", "4A", "6D"], "Mexico", .northAmerica)
        add(["TI", "TE"], "Costa Rica", .northAmerica)
        add(["HP", "HO"], "Panama", .northAmerica)
        add(["TG"], "Guatemala", .northAmerica)
        add(["YS"], "El Salvador", .northAmerica)
        add(["HR"], "Honduras", .northAmerica)
        add(["YN"], "Nicaragua", .northAmerica)
        add(["CO", "CM"], "Cuba", .northAmerica)
        add(["HI"], "Dominican Republic", .northAmerica)
        add(["HH"], "Haiti", .northAmerica)
        add(["6Y"], "Jamaica", .northAmerica)
        add(["ZF"], "Cayman Islands", .northAmerica)
        add(["V3"], "Belize", .northAmerica)
        add(["C6"], "Bahamas", .northAmerica)
        add(["VP5"], "Turks & Caicos", .northAmerica)
        add(["FM"], "Martinique", .northAmerica)
        add(["FG"], "Guadeloupe", .northAmerica)
        add(["P4"], "Aruba", .southAmerica)
        add(["PJ2"], "Curacao", .southAmerica)
        add(["PJ4"], "Bonaire", .southAmerica)
        add(["8P"], "Barbados", .northAmerica)
        add(["9Y", "9Z"], "Trinidad & Tobago", .southAmerica)
        // South America
        add(["LU", "LW", "AY", "AZ", "L2", "L3", "L4", "L5", "L6", "L7", "L8", "L9"], "Argentina", .southAmerica)
        add(["PY", "PP", "PQ", "PR", "PS", "PT", "PU", "PV", "PW", "PX", "ZZ", "ZY", "ZX", "ZW", "ZV"], "Brazil", .southAmerica)
        add(["CE", "CA", "CB", "CC", "CD", "XQ", "XR", "3G"], "Chile", .southAmerica)
        add(["HK", "HJ", "5J", "5K"], "Colombia", .southAmerica)
        add(["OA", "OB", "OC"], "Peru", .southAmerica)
        add(["YV", "YW", "YX", "YY", "4M"], "Venezuela", .southAmerica)
        add(["HC", "HD"], "Ecuador", .southAmerica)
        add(["CP"], "Bolivia", .southAmerica)
        add(["ZP"], "Paraguay", .southAmerica)
        add(["CX", "CV", "CW"], "Uruguay", .southAmerica)
        add(["PZ"], "Suriname", .southAmerica)
        add(["8R"], "Guyana", .southAmerica)
        // Europe
        add(["G", "M", "2E"], "England", .europe)
        add(["GM", "MM", "2M"], "Scotland", .europe)
        add(["GW", "MW", "2W"], "Wales", .europe)
        add(["GI", "MI", "2I"], "Northern Ireland", .europe)
        add(["GD"], "Isle of Man", .europe)
        add(["GJ"], "Jersey", .europe)
        add(["GU"], "Guernsey", .europe)
        add(["EI", "EJ"], "Ireland", .europe)
        add(["F", "TM", "TK"], "France", .europe)
        add(["DA", "DB", "DC", "DD", "DE", "DF", "DG", "DH", "DJ", "DK", "DL", "DM", "DN", "DO", "DP", "DQ", "DR"], "Germany", .europe)
        add(["I", "IK", "IZ", "IW", "IU"], "Italy", .europe)
        add(["EA", "EB", "EC", "ED", "EE", "EF", "EG", "EH", "AM", "AN", "AO"], "Spain", .europe)
        add(["CT", "CQ", "CR", "CS"], "Portugal", .europe)
        add(["PA", "PB", "PC", "PD", "PE", "PF", "PG", "PH", "PI"], "Netherlands", .europe)
        add(["ON", "OO", "OP", "OQ", "OR", "OS", "OT"], "Belgium", .europe)
        add(["HB", "HE"], "Switzerland", .europe)
        add(["OE"], "Austria", .europe)
        add(["OZ", "OU", "OV", "5P", "5Q"], "Denmark", .europe)
        add(["SM", "SA", "SB", "SC", "SD", "SE", "SF", "SG", "SH", "SI", "SJ", "SK", "SL", "7S", "8S"], "Sweden", .europe)
        add(["LA", "LB", "LC", "LD", "LE", "LF", "LG", "LH", "LI", "LJ", "LK", "LL", "LM", "LN"], "Norway", .europe)
        add(["OH", "OF", "OG", "OI"], "Finland", .europe)
        add(["SP", "SN", "SO", "SQ", "SR", "3Z", "HF"], "Poland", .europe)
        add(["OK", "OL"], "Czech Republic", .europe)
        add(["OM"], "Slovakia", .europe)
        add(["HA", "HG"], "Hungary", .europe)
        add(["YO", "YP", "YQ", "YR"], "Romania", .europe)
        add(["LZ"], "Bulgaria", .europe)
        add(["SV", "SW", "SX", "SY", "SZ", "J4"], "Greece", .europe)
        add(["9A"], "Croatia", .europe)
        add(["S5"], "Slovenia", .europe)
        add(["E7"], "Bosnia-Herzegovina", .europe)
        add(["YU", "YT"], "Serbia", .europe)
        add(["Z3"], "North Macedonia", .europe)
        add(["ZA"], "Albania", .europe)
        add(["UA", "UB", "UC", "UD", "UE", "UF", "UG", "UH", "UI", "RA", "RB", "RC", "RD", "RE", "RF", "RG", "RJ", "RK", "RL", "RM", "RN", "RO", "RQ", "RT", "RU", "RV", "RW", "RX", "RY", "RZ", "R1", "R2", "R3", "R4", "R5", "R6", "R7", "R8", "R9", "R0"], "European Russia", .europe)
        add(["UA9", "UA0", "RA9", "RA0", "R8", "R9", "R0"], "Asiatic Russia", .asia)
        add(["UR", "US", "UT", "UU", "UV", "UW", "UX", "UY", "UZ", "EM", "EN", "EO"], "Ukraine", .europe)
        add(["EU", "EV", "EW"], "Belarus", .europe)
        add(["YL"], "Latvia", .europe)
        add(["LY"], "Lithuania", .europe)
        add(["ES"], "Estonia", .europe)
        add(["OY"], "Faroe Islands", .europe)
        add(["TF"], "Iceland", .europe)
        add(["EA8", "EB8", "EC8", "ED8"], "Canary Islands", .africa)
        add(["CT3", "CQ3"], "Madeira", .africa)
        add(["CU"], "Azores", .europe)
        add(["4O"], "Montenegro", .europe)
        add(["ER"], "Moldova", .europe)
        add(["9H"], "Malta", .europe)
        add(["5B", "C4", "P3"], "Cyprus", .asia)
        add(["T7"], "San Marino", .europe)
        add(["HV"], "Vatican", .europe)
        add(["3A"], "Monaco", .europe)
        add(["C3"], "Andorra", .europe)
        add(["LX"], "Luxembourg", .europe)
        add(["HB0"], "Liechtenstein", .europe)
        // Africa
        add(["ZS", "ZR", "ZT", "ZU"], "South Africa", .africa)
        add(["CN"], "Morocco", .africa)
        add(["7X"], "Algeria", .africa)
        add(["3V"], "Tunisia", .africa)
        add(["SU"], "Egypt", .africa)
        add(["5N"], "Nigeria", .africa)
        add(["9J"], "Zambia", .africa)
        add(["Z2"], "Zimbabwe", .africa)
        add(["5Z"], "Kenya", .africa)
        add(["ET"], "Ethiopia", .africa)
        add(["6W"], "Senegal", .africa)
        add(["9G"], "Ghana", .africa)
        add(["TR"], "Gabon", .africa)
        add(["D2"], "Angola", .africa)
        add(["C9"], "Mozambique", .africa)
        add(["5R"], "Madagascar", .africa)
        add(["3B8"], "Mauritius", .africa)
        add(["FR"], "Reunion", .africa)
        add(["EA9"], "Ceuta & Melilla", .africa)
        add(["IH9"], "African Italy", .africa)
        add(["V5"], "Namibia", .africa)
        add(["A2"], "Botswana", .africa)
        add(["7Q"], "Malawi", .africa)
        add(["5H"], "Tanzania", .africa)
        add(["5X"], "Uganda", .africa)
        add(["9X"], "Rwanda", .africa)
        add(["TU"], "Cote d'Ivoire", .africa)
        add(["TZ"], "Mali", .africa)
        // Asia
        add(["JA", "JE", "JF", "JG", "JH", "JI", "JJ", "JK", "JL", "JM", "JN", "JO", "JP", "JQ", "JR", "JS", "7J", "7K", "7L", "7M", "7N", "8J", "8N"], "Japan", .asia)
        add(["HL", "HM", "6K", "6L", "6M", "6N", "DS", "DT"], "South Korea", .asia)
        add(["BY", "BA", "BD", "BG", "BH", "BI", "BJ", "BL", "BT", "BZ", "B1", "B2", "B3", "B4", "B5", "B6", "B7", "B8", "B9", "B0"], "China", .asia)
        add(["BV", "BX", "BU", "BW"], "Taiwan", .asia)
        add(["VR2", "VR"], "Hong Kong", .asia)
        add(["XX9"], "Macao", .asia)
        add(["VU"], "India", .asia)
        add(["AP"], "Pakistan", .asia)
        add(["S2"], "Bangladesh", .asia)
        add(["4S"], "Sri Lanka", .asia)
        add(["9N"], "Nepal", .asia)
        add(["HS", "E2"], "Thailand", .asia)
        add(["9V"], "Singapore", .asia)
        add(["9M2", "9M4", "9W2", "9W4"], "West Malaysia", .asia)
        add(["9M6", "9M8", "9W6", "9W8"], "East Malaysia", .oceania)
        add(["YB", "YC", "YD", "YE", "YF", "YG", "YH", "7A", "7B", "7C", "7D", "7E", "7F", "7G", "7H", "7I", "8A", "8B", "8C", "8D", "8E", "8F", "8G", "8H", "8I"], "Indonesia", .oceania)
        add(["DU", "DV", "DW", "DX", "DY", "DZ", "4D", "4E", "4F", "4G", "4H", "4I"], "Philippines", .oceania)
        add(["XV", "3W"], "Vietnam", .asia)
        add(["XU"], "Cambodia", .asia)
        add(["XW"], "Laos", .asia)
        add(["XZ"], "Myanmar", .asia)
        add(["TA", "TB", "TC", "YM"], "Turkey", .asia)
        add(["4X", "4Z"], "Israel", .asia)
        add(["JY"], "Jordan", .asia)
        add(["OD"], "Lebanon", .asia)
        add(["YK"], "Syria", .asia)
        add(["YI"], "Iraq", .asia)
        add(["EP", "EQ"], "Iran", .asia)
        add(["HZ", "7Z", "8Z"], "Saudi Arabia", .asia)
        add(["A4"], "Oman", .asia)
        add(["A6"], "United Arab Emirates", .asia)
        add(["A7"], "Qatar", .asia)
        add(["A9"], "Bahrain", .asia)
        add(["9K"], "Kuwait", .asia)
        add(["7O"], "Yemen", .asia)
        add(["EK"], "Armenia", .asia)
        add(["4J", "4K"], "Azerbaijan", .asia)
        add(["4L"], "Georgia", .asia)
        add(["UN", "UO", "UP", "UQ"], "Kazakhstan", .asia)
        add(["EX"], "Kyrgyzstan", .asia)
        add(["EY"], "Tajikistan", .asia)
        add(["EZ"], "Turkmenistan", .asia)
        add(["UK", "UJ", "UL", "UM"], "Uzbekistan", .asia)
        add(["JT", "JU", "JV"], "Mongolia", .asia)
        add(["A5"], "Bhutan", .asia)
        add(["8Q"], "Maldives", .asia)
        // Oceania
        add(["VK", "AX"], "Australia", .oceania)
        add(["ZL", "ZM"], "New Zealand", .oceania)
        add(["P2"], "Papua New Guinea", .oceania)
        add(["3D2"], "Fiji", .oceania)
        add(["5W"], "Samoa", .oceania)
        add(["A3"], "Tonga", .oceania)
        add(["FK"], "New Caledonia", .oceania)
        add(["FO"], "French Polynesia", .oceania)
        add(["KH2"], "Guam", .oceania)
        add(["KH0"], "Mariana Islands", .oceania)
        add(["V7"], "Marshall Islands", .oceania)
        add(["V6"], "Micronesia", .oceania)
        add(["T3"], "Kiribati", .oceania)
        add(["H4"], "Solomon Islands", .oceania)
        add(["YJ"], "Vanuatu", .oceania)
        add(["E5"], "Cook Islands", .oceania)
        // Antarctica
        add(["KC4", "8J1", "DP0", "DP1", "RI1"], "Antarctica", .antarctica)
        return t
    }()
}
