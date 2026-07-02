import SwiftUI

/// Radio detail: stacked panadapters, connection controls, and the per-domain
/// control sections. Each section is its own view (its own invalidation
/// boundary) — this is the seam new features plug into.
struct RadioDetailView: View {
    let radio: DiscoveredRadio
    @Bindable var session: RadioSession

    var body: some View {
        VStack(spacing: 0) {
            if session.isConnected {
                SpectrumStackView(session: session)
            }

            Form {
                Section("Radio") {
                    LabeledContent("Board", value: radio.board.displayName)
                    LabeledContent("IP Address", value: radio.ipAddress)
                    LabeledContent("MAC Address", value: radio.macAddress)
                    LabeledContent("Firmware", value: radio.firmwareVersion)
                }

                Section("Connection") {
                    connectionControls
                }

                Section("MIDI Tuning") {
                    MIDISectionView(session: session)
                }

                if session.isConnected {
                    Section("Tuning") {
                        TuningSectionView(session: session)
                    }
                    Section("Receivers (Slices)") {
                        SlicesSectionView(session: session)
                    }
                    Section("AGC & RF Gain") {
                        AGCSectionView(session: session)
                    }
                    Section("Noise Reduction") {
                        NoiseReductionSectionView(session: session)
                    }
                    Section("Squelch") {
                        SquelchSectionView(session: session)
                    }
                    Section("RX Equalizer") {
                        RXEqualizerSectionView(session: session)
                    }
                    Section("Transmit") {
                        TransmitSectionView(session: session)
                    }
                    Section("TX Audio") {
                        TXAudioSectionView(session: session)
                    }
                    Section("Live Stream") {
                        LiveStatusSectionView(session: session)
                    }
                }
            }
            .formStyle(.grouped)
        }
        .navigationTitle(radio.board.displayName)
        .onChange(of: radio.id) { _, _ in
            session.disconnect()
        }
        .onDisappear { session.disconnect() }
    }

    @ViewBuilder
    private var connectionControls: some View {
        switch session.state {
        case .disconnected:
            Button("Connect") { session.connect(to: radio) }
        case .connecting:
            HStack { ProgressView().controlSize(.small); Text("Connecting…") }
        case .streaming:
            Button("Disconnect", role: .destructive) { session.disconnect() }
        case .failed(let message):
            VStack(alignment: .leading) {
                Label(message, systemImage: "exclamationmark.triangle").foregroundStyle(.red)
                Button("Retry") { session.connect(to: radio) }
            }
        }
    }
}
