import Foundation

/// Maidenhead grid locator math: validation, coordinates, distance, bearing.
public enum Maidenhead {

    /// True for a syntactically valid 4- or 6-character locator ("EN52", "EN52xa").
    public static func isValid(_ grid: String) -> Bool {
        let g = grid.uppercased()
        guard g.count == 4 || g.count == 6 else { return false }
        let chars = Array(g)
        guard ("A"..."R").contains(String(chars[0])), ("A"..."R").contains(String(chars[1])),
              chars[2].isNumber, chars[3].isNumber else { return false }
        if chars.count == 6 {
            guard ("A"..."X").contains(String(chars[4])), ("A"..."X").contains(String(chars[5])) else { return false }
        }
        return true
    }

    /// Center latitude/longitude of a grid square, in degrees.
    public static func coordinates(of grid: String) -> (latitude: Double, longitude: Double)? {
        let g = grid.uppercased()
        guard isValid(g) else { return nil }
        let chars = Array(g.unicodeScalars)
        let A = Character("A").unicodeScalars.first!.value
        let zero = Character("0").unicodeScalars.first!.value

        var lon = Double(chars[0].value - A) * 20.0 - 180.0
        var lat = Double(chars[1].value - A) * 10.0 - 90.0
        lon += Double(chars[2].value - zero) * 2.0
        lat += Double(chars[3].value - zero) * 1.0

        if chars.count == 6 {
            lon += Double(chars[4].value - A) * (2.0 / 24.0)
            lat += Double(chars[5].value - A) * (1.0 / 24.0)
            lon += 2.0 / 48.0
            lat += 1.0 / 48.0
        } else {
            lon += 1.0
            lat += 0.5
        }
        return (lat, lon)
    }

    /// Great-circle distance between two grid locators, in kilometers.
    public static func distanceKm(from: String, to: String) -> Double? {
        guard let a = coordinates(of: from), let b = coordinates(of: to) else { return nil }
        let r = 6371.0
        let lat1 = a.latitude * .pi / 180, lat2 = b.latitude * .pi / 180
        let dLat = lat2 - lat1
        let dLon = (b.longitude - a.longitude) * .pi / 180
        let h = sin(dLat / 2) * sin(dLat / 2) + cos(lat1) * cos(lat2) * sin(dLon / 2) * sin(dLon / 2)
        return 2 * r * asin(min(1, sqrt(h)))
    }

    /// Initial great-circle bearing from one locator to another, degrees true.
    public static func bearingDegrees(from: String, to: String) -> Double? {
        guard let a = coordinates(of: from), let b = coordinates(of: to) else { return nil }
        let lat1 = a.latitude * .pi / 180, lat2 = b.latitude * .pi / 180
        let dLon = (b.longitude - a.longitude) * .pi / 180
        let y = sin(dLon) * cos(lat2)
        let x = cos(lat1) * sin(lat2) - sin(lat1) * cos(lat2) * cos(dLon)
        let deg = atan2(y, x) * 180 / .pi
        return deg < 0 ? deg + 360 : deg
    }
}
