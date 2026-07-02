import Foundation

/// VFO state for an additional receive slice (a receiver beyond the main RX1).
/// `id` is the slice's receiver index (1-based for extra slices). The main
/// receiver keeps the full DSP controls; extra slices carry a compact VFO.
struct SliceInfo: Identifiable, Sendable {
    let id: Int              // slice / receiver index (1…maxSlices-1)
    var frequencyHz: UInt32
    var mode: RadioMode
    var volume: Float
    var pan: Float           // −1 = hard left … +1 = hard right
}
