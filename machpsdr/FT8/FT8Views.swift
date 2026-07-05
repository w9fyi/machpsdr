import SwiftUI
import FT8Kit

/// FT8/FT4 digital-mode panel: band/mode selection, activity table,
/// CQ + autosequence controls, auto-answer policy, and callsign alerts.
struct FT8SectionView: View {
    @Bindable var session: RadioSession
    @Environment(FT8Controller.self) private var ft8

    @State private var selectedDecodeID: UUID?
    @State private var customMHzText = ""
    @State private var newAlertCall = ""
    @State private var newAlertBand = "any"

    var body: some View {
        @Bindable var ft8 = ft8

        if !ft8.station.info.isReadyForFT8 {
            Text("Set your callsign and grid square in Settings ▸ Station before operating FT8.")
                .font(.caption)
                .foregroundStyle(.orange)
        }

        // MARK: Channel selection
        HStack {
            Picker("Mode", selection: Binding(
                get: { ft8.mode },
                set: { ft8.setMode($0) }
            )) {
                ForEach(FTxProtocolMode.allCases) { m in
                    Text(m.rawValue).tag(m)
                }
            }
            .pickerStyle(.segmented)
            .frame(width: 160)

            Picker("Band", selection: Binding(
                get: { ft8.selectedBandID },
                set: { ft8.setBand($0) }
            )) {
                ForEach(ft8.availableBandIDs, id: \.self) { band in
                    if let ch = FTxBandPlan.primaryChannel(bandID: band, mode: ft8.mode) {
                        Text(ch.displayName).tag(band)
                    }
                }
            }
            .disabled(ft8.useCustomFrequency)
        }

        Toggle("Custom dial frequency", isOn: $ft8.useCustomFrequency)
        if ft8.useCustomFrequency {
            HStack {
                TextField("MHz", text: $customMHzText)
                    .frame(width: 110)
                    .onSubmit { applyCustomFrequency() }
                Button("Set") { applyCustomFrequency() }
                Text(String(format: "Dial: %.6f MHz", Double(ft8.dialFrequencyHz) / 1_000_000))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .onAppear {
                customMHzText = String(format: "%.6f", Double(ft8.customFrequencyHz) / 1_000_000)
            }
        }

        // MARK: Start / stop
        HStack {
            Button(ft8.isRunning ? "Stop" : "Start") {
                ft8.isRunning ? ft8.stop() : ft8.start()
            }
            .disabled(!ft8.isRunning && !ft8.canStart)

            if let reason = ft8.startBlockedReason {
                Text(reason)
                    .font(.caption)
                    .foregroundStyle(.orange)
            }

            Text(ft8.statusText)
                .foregroundStyle(.secondary)
            Spacer()
            if ft8.isTransmitting {
                Label(ft8.currentTxText ?? "TX", systemImage: "dot.radiowaves.left.and.right")
                    .foregroundStyle(.red)
                    .font(.caption.bold())
            }
        }

        if ft8.isRunning {
            operatingControls(ft8: ft8)
            incomingCallBanner(ft8: ft8)
            decodeTable(ft8: ft8)
        }

        DisclosureGroup("Auto-answer policy") {
            autoAnswerControls(ft8: ft8)
        }
        DisclosureGroup("Callsign alerts (\(ft8.alerts.alerts.count))") {
            alertControls(ft8: ft8)
        }
        if !ft8.qsoLog.isEmpty {
            Text("QSOs this session: \(ft8.qsoLog.count) — last: \(ft8.qsoLog.last!.record.dxCall)")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - Operating controls

    @ViewBuilder
    private func operatingControls(ft8: FT8Controller) -> some View {
        @Bindable var ft8 = ft8
        HStack {
            Button("Call CQ") { ft8.startCQ() }
                .disabled(!ft8.txEnabled)
            TextField("CQ modifier (DX, POTA…)", text: $ft8.cqModifier)
                .frame(width: 150)
            Toggle("Enable TX", isOn: $ft8.txEnabled)
                .toggleStyle(.button)
                .tint(ft8.txEnabled ? .green : .red)
            Button("Halt TX") { ft8.txEnabled = false }
                .tint(.red)
        }
        HStack {
            Toggle("Autosequence", isOn: $ft8.autoSequence)
            Toggle("Auto-answer my CQ", isOn: $ft8.autoAnswerReplies)
            Toggle("Auto-call CQs", isOn: $ft8.autoAnswerCQs)
            Toggle("Hound", isOn: $ft8.houndMode)
                .help("DXpedition Fox/Hound mode: call above 1000 Hz and follow the fox's RR73 flow")
        }
        HStack {
            Picker("TX slot", selection: $ft8.txSlotPreference) {
                ForEach(FT8Controller.TxSlotPreference.allCases) { p in
                    Text(p.rawValue).tag(p)
                }
            }
            .frame(width: 190)
            Slider(value: $ft8.txOffsetHz, in: 200...3_000, step: 10) {
                Text("TX \(Int(ft8.txOffsetHz)) Hz")
            }
            Toggle("RR73", isOn: $ft8.preferRR73)
                .help("End QSOs with RR73 instead of RRR + 73")
        }
    }

    @ViewBuilder
    private func incomingCallBanner(ft8: FT8Controller) -> some View {
        if let caller = ft8.incomingCallers.first, ft8.engine.phase == .idle {
            HStack {
                Label("\(caller.parsed.from ?? "?") is calling you: \(caller.decode.text)",
                      systemImage: "bell.badge.fill")
                    .foregroundStyle(.orange)
                Spacer()
                Button("Answer") { ft8.respond(to: caller) }
                    .buttonStyle(.borderedProminent)
            }
        }
    }

    // MARK: - Decode table

    @ViewBuilder
    private func decodeTable(ft8: FT8Controller) -> some View {
        @Bindable var ft8 = ft8
        Picker("Show", selection: $ft8.displayFilter) {
            ForEach(FT8Controller.DisplayFilter.allCases) { f in
                Text(f.rawValue).tag(f)
            }
        }
        .pickerStyle(.segmented)

        Table(ft8.filteredDecodes, selection: $selectedDecodeID) {
            TableColumn("UTC") { entry in
                Text(entry.utcTime).monospacedDigit()
            }
            .width(60)
            TableColumn("dB") { entry in
                Text("\(entry.decode.snr)").monospacedDigit()
            }
            .width(35)
            TableColumn("DT") { entry in
                Text(String(format: "%+.1f", entry.decode.timeOffset - 0.5)).monospacedDigit()
            }
            .width(40)
            TableColumn("Freq") { entry in
                Text("\(Int(entry.decode.audioFrequency))").monospacedDigit()
            }
            .width(45)
            TableColumn("Message") { entry in
                Text(entry.decode.text)
                    .foregroundStyle(rowColor(entry))
                    .fontWeight(entry.addressedToMe || entry.isAlert ? .bold : .regular)
            }
            TableColumn("DXCC") { entry in
                Text(entry.parsed.from.flatMap { DXCCLookup.entity(for: $0)?.name } ?? "")
                    .foregroundStyle(.secondary)
            }
            .width(120)
        }
        .frame(minHeight: 220)
        .contextMenu(forSelectionType: UUID.self) { ids in
            if let entry = ft8.filteredDecodes.first(where: { ids.contains($0.id) }) {
                Button("Work \(entry.parsed.from ?? "station")") { ft8.respond(to: entry) }
                if let call = entry.parsed.from {
                    Button("Add alert for \(call)") {
                        ft8.alerts.add(callsign: call, bandID: nil)
                    }
                }
            }
        } primaryAction: { ids in
            if let entry = ft8.filteredDecodes.first(where: { ids.contains($0.id) }) {
                ft8.respond(to: entry)
            }
        }
        .onKeyPress(.return) {
            if let id = selectedDecodeID,
               let entry = ft8.filteredDecodes.first(where: { $0.id == id }) {
                ft8.respond(to: entry)
                return .handled
            }
            return .ignored
        }
        Text("Double-click a line (or select and press Return) to work that station.")
            .font(.caption)
            .foregroundStyle(.secondary)
    }

    private func rowColor(_ entry: FT8DecodeEntry) -> Color {
        if entry.addressedToMe { return .red }
        if entry.isAlert { return .orange }
        if entry.parsed.isCQ { return .green }
        return .primary
    }

    // MARK: - Auto-answer policy

    @ViewBuilder
    private func autoAnswerControls(ft8: FT8Controller) -> some View {
        @Bindable var ft8 = ft8
        Picker("Answer order", selection: Binding(
            get: { ft8.answerPolicy.order },
            set: { ft8.answerPolicy.order = $0 }
        )) {
            ForEach(FT8AutoAnswerPolicy.Order.allCases) { o in
                Text(o.displayName).tag(o)
            }
        }
        Toggle("Skip stations already worked this session", isOn: Binding(
            get: { ft8.answerPolicy.skipWorked },
            set: { ft8.answerPolicy.skipWorked = $0 }
        ))
        Text("Limit to continents (none selected = anywhere):")
            .font(.caption)
        HStack {
            ForEach(Continent.allCases) { c in
                Toggle(c.rawValue, isOn: Binding(
                    get: { ft8.answerPolicy.continents.contains(c) },
                    set: { on in
                        if on { ft8.answerPolicy.continents.insert(c) }
                        else { ft8.answerPolicy.continents.remove(c) }
                    }
                ))
                .toggleStyle(.button)
            }
        }
    }

    // MARK: - Alerts

    @ViewBuilder
    private func alertControls(ft8: FT8Controller) -> some View {
        HStack {
            TextField("Callsign", text: $newAlertCall)
                .frame(width: 110)
            Picker("Band", selection: $newAlertBand) {
                Text("Any band").tag("any")
                ForEach(Band.all) { band in
                    Text(band.name).tag(band.id)
                }
            }
            .frame(width: 140)
            Button("Add alert") {
                ft8.alerts.add(callsign: newAlertCall,
                               bandID: newAlertBand == "any" ? nil : newAlertBand)
                newAlertCall = ""
            }
            .disabled(newAlertCall.trimmingCharacters(in: .whitespaces).isEmpty)
        }
        ForEach(ft8.alerts.alerts) { alert in
            HStack {
                Toggle(isOn: Binding(
                    get: { alert.enabled },
                    set: { ft8.alerts.setEnabled($0, id: alert.id) }
                )) {
                    Text("\(alert.callsign) — \(alert.bandID ?? "any band")")
                }
                Spacer()
                Button(role: .destructive) {
                    ft8.alerts.remove(id: alert.id)
                } label: {
                    Image(systemName: "trash")
                }
                .buttonStyle(.borderless)
            }
        }
    }

    private func applyCustomFrequency() {
        guard let mhz = Double(customMHzText.replacingOccurrences(of: ",", with: ".")),
              mhz > 0.1, mhz < 500 else { return }
        ft8.customFrequencyHz = UInt32(mhz * 1_000_000)
    }
}

/// Settings ▸ Station: operator identity used on the air and for logging.
struct StationSettingsView: View {
    @Environment(FT8Controller.self) private var ft8

    var body: some View {
        @Bindable var station = ft8.station
        Form {
            Section("Operator") {
                TextField("Callsign", text: $station.info.callsign)
                    .textCase(.uppercase)
                TextField("Grid square (e.g. EN52 or EN52xa)", text: $station.info.grid)
                if !station.info.grid.isEmpty && !Maidenhead.isValid(station.info.grid) {
                    Text("Grid must be 4 or 6 characters, e.g. EN52 or EN52xa.")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
            }
            Section("Location") {
                TextField("City", text: $station.info.city)
                TextField("State / Province", text: $station.info.state)
                TextField("Country", text: $station.info.country)
            }
            Section("Zones") {
                Picker("ITU region", selection: Binding(
                    get: { station.info.ituRegion ?? 0 },
                    set: { station.info.ituRegion = $0 == 0 ? nil : $0 }
                )) {
                    Text("Unset").tag(0)
                    Text("Region 1 (EU/AF)").tag(1)
                    Text("Region 2 (Americas)").tag(2)
                    Text("Region 3 (Asia/Pacific)").tag(3)
                }
                TextField("CQ zone", value: Binding(
                    get: { station.info.cqZone ?? 0 },
                    set: { station.info.cqZone = $0 == 0 ? nil : $0 }
                ), format: .number)
                TextField("ITU zone", value: Binding(
                    get: { station.info.ituZone ?? 0 },
                    set: { station.info.ituZone = $0 == 0 ? nil : $0 }
                ), format: .number)
            }
            if station.info.isReadyForFT8 {
                Section {
                    Text("Ready for FT8 as \(station.info.callsign.uppercased()) @ \(station.info.grid4)")
                        .foregroundStyle(.green)
                }
            }
        }
        .formStyle(.grouped)
    }
}
