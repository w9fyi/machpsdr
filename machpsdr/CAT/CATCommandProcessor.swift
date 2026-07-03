import Foundation

/// The surface of RadioSession that CAT commands read and control. Split out as a
/// protocol so the processor can be unit-tested against a mock radio.
@MainActor
protocol CATRadioControl: AnyObject {
    var frequencyHz: UInt32 { get }
    var mode: RadioMode { get }
    var isTransmitting: Bool { get }
    var driveLevel: Double { get }
    var volume: Float { get }
    /// RX signal RMS in [0, 1]; 0 when unknown/disconnected.
    var signalRMS: Float { get }
    func setFrequency(_ hz: UInt32)
    func setMode(_ newMode: RadioMode)
    func setPTT(_ on: Bool)
    func setDrive(_ percent: Double)
    func setVolume(_ newVolume: Float)
}

/// Parses and answers Kenwood TS-2000 CAT commands — the dialect WSJT-X, fldigi,
/// and most loggers speak (rig "Kenwood TS-2000", ID 019).
///
/// Commands arrive without the trailing ';'. Per Kenwood convention, set commands
/// return no reply, read commands return a full "XX…;" answer, and anything
/// unrecognized or malformed returns "?;".
@MainActor
final class CATCommandProcessor {
    private weak var radio: CATRadioControl?

    /// Shadow VFO B: reported and settable over CAT so split-capable clients don't
    /// error out, but not yet wired to a second hardware VFO.
    private var vfoBHz: UInt32?

    init(radio: CATRadioControl) {
        self.radio = radio
    }

    /// Handles one semicolon-terminated command (terminator already stripped).
    func handle(_ rawCommand: String) -> String {
        let command = rawCommand.trimmingCharacters(in: .whitespacesAndNewlines)
        guard command.count >= 2, let radio else { return "?;" }
        let prefix = command.prefix(2).uppercased()
        let args = String(command.dropFirst(2))

        switch prefix {
        case "ID":
            return "ID019;"                       // TS-2000
        case "PS":                                // power status; sets accepted, ignored
            return args.isEmpty ? "PS1;" : ""
        case "AI":                                // auto-information; we only do polled mode
            return args.isEmpty ? "AI0;" : ""
        case "FA":
            if args.isEmpty { return "FA\(Self.freq11(radio.frequencyHz));" }
            guard let hz = Self.parseFrequency(args) else { return "?;" }
            radio.setFrequency(hz)
            return ""
        case "FB":
            if args.isEmpty { return "FB\(Self.freq11(vfoBHz ?? radio.frequencyHz));" }
            guard let hz = Self.parseFrequency(args) else { return "?;" }
            vfoBHz = hz
            return ""
        case "MD":
            if args.isEmpty { return "MD\(Self.kenwoodDigit(for: radio.mode));" }
            guard let newMode = Self.mode(forKenwoodDigit: args) else { return "?;" }
            radio.setMode(newMode)
            return ""
        case "IF":
            return args.isEmpty ? Self.ifStatus(radio) : "?;"
        case "TX":                                // TX; / TX0; / TX1; all key the rig
            radio.setPTT(true)
            return ""
        case "RX":
            radio.setPTT(false)
            return ""
        case "FR":                                // receive VFO — only VFO A exists
            return args.isEmpty ? "FR0;" : ""
        case "FT":                                // transmit VFO — no split yet
            return args.isEmpty ? "FT0;" : ""
        case "PC":                                // TX drive, 0–100 %
            if args.isEmpty { return String(format: "PC%03d;", Int(radio.driveLevel.rounded())) }
            guard let pc = Int(args), (0...100).contains(pc) else { return "?;" }
            radio.setDrive(Double(pc))
            return ""
        case "AG":                                // AF gain: AG0; / AG0xxx; with xxx 0–255
            if args.isEmpty || args == "0" {
                return String(format: "AG0%03d;", Int((radio.volume * 255).rounded()))
            }
            guard args.count == 4, args.hasPrefix("0"),
                  let level = Int(args.dropFirst()), (0...255).contains(level) else { return "?;" }
            radio.setVolume(Float(level) / 255)
            return ""
        case "SM":                                // S-meter, 0000–0030
            return String(format: "SM0%04d;", Self.sMeter30(fromRMS: radio.signalRMS))
        default:
            return "?;"
        }
    }

    // MARK: - Field formatting

    /// 11-digit zero-padded frequency field.
    static func freq11(_ hz: UInt32) -> String {
        let s = String(hz)
        return String(repeating: "0", count: max(0, 11 - s.count)) + s
    }

    /// Parses a Kenwood frequency argument (up to 11 digits) into Hz.
    static func parseFrequency(_ args: String) -> UInt32? {
        guard !args.isEmpty, args.count <= 11, args.allSatisfy(\.isNumber),
              let value = UInt64(args), value <= UInt64(UInt32.max) else { return nil }
        return UInt32(value)
    }

    /// Kenwood MD digit for a mode. 1 LSB, 2 USB, 3 CW, 4 FM, 5 AM, 6 FSK, 7 CW-R,
    /// 9 FSK-R. SAM has no Kenwood equivalent and reports as AM.
    static func kenwoodDigit(for mode: RadioMode) -> String {
        switch mode {
        case .lsb: return "1"
        case .usb: return "2"
        case .cwu: return "3"
        case .fm:  return "4"
        case .am, .sam: return "5"
        case .digl: return "6"
        case .cwl: return "7"
        case .digu: return "9"
        }
    }

    static func mode(forKenwoodDigit digit: String) -> RadioMode? {
        switch digit {
        case "1": return .lsb
        case "2": return .usb
        case "3": return .cwu
        case "4": return .fm
        case "5": return .am
        case "6": return .digl
        case "7": return .cwl
        case "9": return .digu
        default:  return nil
        }
    }

    /// The TS-2000 IF status answer: 35 data characters after "IF" (38 total with
    /// the terminator), which is what hamlib and loggers key their parsing on.
    /// Fields we don't model (RIT/XIT, memory, scan, split, tone) read as zero.
    static func ifStatus(_ radio: CATRadioControl) -> String {
        var s = "IF"
        s += freq11(radio.frequencyHz)             // P1  frequency
        s += "0000"                                // P2  step size
        s += "+00000"                              // P3  RIT/XIT offset
        s += "0"                                   // P4  RIT off
        s += "0"                                   // P5  XIT off
        s += "0"                                   // P6  channel bank
        s += "00"                                  // P7  memory channel
        s += radio.isTransmitting ? "1" : "0"      // P8  RX/TX
        s += kenwoodDigit(for: radio.mode)         // P9  mode
        s += "0"                                   // P10 VFO A
        s += "0"                                   // P11 scan off
        s += "0"                                   // P12 simplex
        s += "0"                                   // P13 tone off
        s += "00"                                  // P14 tone number
        s += "0"                                   // P15 shift off
        return s + ";"
    }

    /// Maps RX signal RMS [0, 1] onto the TS-2000's 0–30 meter scale. Uncalibrated:
    /// -120 dBFS → 0 and 0 dBFS → 30, which tracks relative strength well enough
    /// for logger bar graphs.
    static func sMeter30(fromRMS rms: Float) -> Int {
        guard rms > 0 else { return 0 }
        let dbfs = 20 * log10(Double(rms))
        return min(30, max(0, Int((dbfs + 120) / 4)))
    }
}
