import SwiftUI

/// Observable model that scans the local network for HPSDR radios.
@MainActor
@Observable
final class RadioBrowser {
    var radios: [DiscoveredRadio] = []
    var isScanning = false
    var errorMessage: String?

    private let discovery = RadioDiscovery()

    func scan() async {
        isScanning = true
        errorMessage = nil
        defer { isScanning = false }
        do {
            radios = try await discovery.discover()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
