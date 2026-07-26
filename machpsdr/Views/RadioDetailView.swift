import SwiftUI

/// Radio detail: stacked panadapters, connection controls, tuning, slices, and
/// pop-out receive/transmit/FT8 control panels.
struct RadioDetailView: View {
    let radio: DiscoveredRadio
    @Bindable var session: RadioSession

    @State private var showReceiveControls = false
    @State private var showTransmitControls = false
    @State private var showFilterSettings = false
    @State private var showFT8Controls = false

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

                if session.isConnected {
                    Section("Tuning") {
                        TuningSectionView(session: session)
                    }
                    Section("Receivers (Slices)") {
                        SlicesSectionView(session: session)
                    }
                    Section("Live Stream") {
                        LiveStatusSectionView(session: session)
                    }
                }
            }
            .formStyle(.grouped)
        }
        .navigationTitle(radio.board.displayName)
        .toolbar { radioToolbar }
        .onChange(of: radio.id) { _, _ in
            session.disconnect()
        }
        .onDisappear { session.disconnect() }
    }

    @ToolbarContentBuilder
    private var radioToolbar: some ToolbarContent {
        ToolbarItemGroup {
            Button {
                session.addSlice()
            } label: {
                Label("Add Slice", systemImage: "plus")
            }
            .disabled(session.activeSliceCount >= RadioSession.maxSlices)

            ForEach(Array(session.sliceIndices), id: \.self) { index in
                Button {
                    session.setFocusedSlice(index)
                } label: {
                    Text(RadioSession.sliceShortLabel(for: index))
                        .font(.body.monospacedDigit())
                }
                .help("Focus \(RadioSession.sliceName(for: index))")
                .foregroundStyle(session.focusedSliceIndex == index ? Color.accentColor : Color.primary)
                .disabled(session.isTransmitting || session.isTuning)
            }
        }

        ToolbarItemGroup {
            Button {
                showReceiveControls.toggle()
            } label: {
                Label("Receive", systemImage: "waveform")
            }
            .popover(isPresented: $showReceiveControls, arrowEdge: .bottom) {
                receiveControls
            }

            Button {
                showTransmitControls.toggle()
            } label: {
                Label("Transmit", systemImage: "dot.radiowaves.left.and.right")
            }
            .popover(isPresented: $showTransmitControls, arrowEdge: .bottom) {
                transmitControls
            }

            Button {
                showFT8Controls.toggle()
            } label: {
                Label("FT8", systemImage: "waveform.badge.magnifyingglass")
            }
            .popover(isPresented: $showFT8Controls, arrowEdge: .bottom) {
                ft8Controls
            }

            Button {
                showFilterSettings.toggle()
            } label: {
                Label("Filters", systemImage: "slider.horizontal.3")
            }
            .popover(isPresented: $showFilterSettings, arrowEdge: .bottom) {
                FilterSettingsPanelView(session: session)
            }
        }
    }

    private var receiveControls: some View {
        Form {
            Section("AGC & RF Gain") {
                AGCSectionView(session: session)
            }
            Section("Noise Reduction") {
                NoiseReductionSectionView(session: session)
            }
            Section("Squelch") {
                SquelchSectionView(session: session)
            }
            Section("Manual Notch") {
                MNFSectionView(session: session)
            }
            Section("RX Equalizer") {
                RXEqualizerSectionView(session: session)
            }
            Section("Filters") {
                FilterSettingsPanelView(session: session)
            }
        }
        .formStyle(.grouped)
        .frame(width: 420, height: 620)
    }

    private var transmitControls: some View {
        Form {
            Section("Transmit") {
                TransmitSectionView(session: session)
            }
            Section("TX Audio") {
                TXAudioSectionView(session: session)
            }
            Section("Filters") {
                FilterSettingsPanelView(session: session)
            }
            Section("TX Processing") {
                TXProcessingSectionView(session: session)
            }
        }
        .formStyle(.grouped)
        .frame(width: 420, height: 560)
    }

    private var ft8Controls: some View {
        Form {
            Section("FT8 / FT4") {
                FT8SectionView(session: session)
            }
        }
        .formStyle(.grouped)
        .frame(width: 760, height: 640)
    }

    @ViewBuilder
    private var connectionControls: some View {
        switch session.state {
        case .disconnected:
            Button("Connect") { session.connect(to: radio) }
        case .connecting:
            HStack { ProgressView().controlSize(.small); Text("Connecting...") }
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
