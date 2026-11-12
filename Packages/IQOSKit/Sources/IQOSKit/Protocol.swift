// IQOS ILUMA の BLE 通信の決まりごと。
// バイト列と意味は、公開ライブラリ iqos 1.1.0（https://github.com/V-VX/iqos, GPL-3.0）の
// 調査結果（事実）を参照し、コードは写さずに Swift で書き起こした。

import Foundation

public enum IQOSError: Error, Equatable, Sendable {
    case decode(String)
    case unsupported(String)
    case transport(String)
    case timeout
}

// MARK: - BLE の接続先

public enum IQOSUUID {
    public static let deviceInfoService = "180A"
    public static let coreService = "DAEBB240-B041-11E4-9E45-0002A5D5C51B"
    public static let battery = "F8A54120-B041-11E4-9BE7-0002A5D5C51B"
    public static let control = "E16C6E20-B041-11E4-A4C3-0002A5D5C51B"
    public static let modelNumber = "2A24"
    public static let serialNumber = "2A25"
    public static let softwareRevision = "2A28"
    public static let manufacturerName = "2A29"
}

// MARK: - 返事の見分け方

/// 送った命令に対する返事かどうかを、先頭付近のバイトで見分ける。
public struct ResponseMatcher: Sendable, Equatable {
    public let offset: Int
    public let bytes: [UInt8]

    public init(offset: Int = 0, _ bytes: [UInt8]) {
        self.offset = offset
        self.bytes = bytes
    }

    public func matches(_ frame: [UInt8]) -> Bool {
        guard frame.count >= offset + bytes.count else { return false }
        return Array(frame[offset..<(offset + bytes.count)]) == bytes
    }
}

// MARK: - 機種

public enum DeviceModel: String, Sendable, CaseIterable {
    case ilumaOne, iluma, ilumaPrime, ilumaIOne, ilumaI, ilumaIPrime, unknown

    /// Bluetooth の表示名から機種を判定する（長い名前から順に見る）。
    public init(localName: String) {
        let n = localName.trimmingCharacters(in: .whitespaces).uppercased()
        if n.contains("ILUMA I PRIME") { self = .ilumaIPrime }
        else if n.contains("ILUMA I ONE") { self = .ilumaIOne }
        else if n.contains("ILUMA I") { self = .ilumaI }
        else if n.contains("ILUMA PRIME") { self = .ilumaPrime }
        else if n.contains("ILUMA ONE") { self = .ilumaOne }
        else if n.contains("ILUMA") { self = .iluma }
        else { self = .unknown }
    }

    public var displayName: String {
        switch self {
        case .ilumaOne: "IQOS ILUMA ONE"
        case .iluma: "IQOS ILUMA"
        case .ilumaPrime: "IQOS ILUMA PRIME"
        case .ilumaIOne: "IQOS ILUMA i ONE"
        case .ilumaI: "IQOS ILUMA i"
        case .ilumaIPrime: "IQOS ILUMA i PRIME"
        case .unknown: "不明な機種"
        }
    }

    /// ホルダーとチャージャーが分かれている機種（ONE 以外）。
    public var hasHolder: Bool {
        switch self {
        case .iluma, .ilumaPrime, .ilumaI, .ilumaIPrime: true
        default: false
        }
    }

    public var isKnown: Bool { self != .unknown }
    public var supportsBasic: Bool { isKnown }              // 明るさ・振動・ロック
    public var supportsGestureAndAutoStart: Bool { hasHolder }
    public var supportsChargeStartVibration: Bool { hasHolder }
}

// MARK: - 明るさ

public enum Brightness: String, Sendable, CaseIterable {
    case high, low

    public static let loadCommand: [UInt8] = [0x00, 0xC0, 0x02, 0x23, 0xC3]
    public static let matcher = ResponseMatcher([0x00, 0xC0, 0x86, 0x23])

    public init(response r: [UInt8]) throws {
        guard r.count >= 9 else { throw IQOSError.decode("明るさ：返事が短い") }
        guard Self.matcher.matches(r) else { throw IQOSError.decode("明るさ：見出しが違う") }
        switch r[4] {
        case 0x64: self = .high
        case 0x1E: self = .low
        default: throw IQOSError.decode("明るさ：知らない値")
        }
    }

    public var writeCommands: [[UInt8]] {
        switch self {
        case .high:
            [[0x00, 0xC0, 0x46, 0x23, 0x64, 0x00, 0x00, 0x00, 0x4F],
             [0x00, 0xC0, 0x02, 0x23, 0xC3],
             [0x00, 0xC9, 0x44, 0x24, 0x64, 0x00, 0x00, 0x00, 0x34]]
        case .low:
            [[0x00, 0xC0, 0x46, 0x23, 0x1E, 0x00, 0x00, 0x00, 0xE1],
             [0x00, 0xC0, 0x02, 0x23, 0xC3],
             [0x00, 0xC9, 0x44, 0x24, 0x1E, 0x00, 0x00, 0x00, 0x9A]]
        }
    }
}

// MARK: - 振動

public struct VibrationSettings: Sendable, Equatable {
    public var heatingStart: Bool
    public var startingToUse: Bool
    public var puffEnd: Bool
    public var manuallyTerminated: Bool
    /// 充電開始時。ONE 系は持たないので nil。
    public var chargeStart: Bool?

    public init(heatingStart: Bool, startingToUse: Bool, puffEnd: Bool,
                manuallyTerminated: Bool, chargeStart: Bool? = nil) {
        self.heatingStart = heatingStart
        self.startingToUse = startingToUse
        self.puffEnd = puffEnd
        self.manuallyTerminated = manuallyTerminated
        self.chargeStart = chargeStart
    }

    public static let loadCommand: [UInt8] = [0x00, 0xC9, 0x00, 0x23, 0xE9]
    public static let matcher = ResponseMatcher([0x00, 0x08, 0x84, 0x23])
    public static let loadChargeStartCommand: [UInt8] = [0x00, 0xC9, 0x07, 0x04, 0x04, 0x00, 0x00, 0x00, 0x08]
    public static let chargeStartMatcher = ResponseMatcher([0x00, 0x08, 0x8B, 0x04])

    public static let startVibrate: [UInt8] = [0x00, 0xC0, 0x45, 0x22, 0x01, 0x1E, 0x00, 0x00, 0xC3]
    public static let stopVibrate: [UInt8] = [0x00, 0xC0, 0x45, 0x22, 0x00, 0x1E, 0x00, 0x00, 0xD5]

    static let heatingStartFlag: UInt16 = 0x0100
    static let startingToUseFlag: UInt16 = 0x1000
    static let manuallyTerminatedFlag: UInt16 = 0x0010
    static let puffEndFlag: UInt16 = 0x0001

    static let chargeStartOnResponse: [UInt8] = [
        0x00, 0x08, 0x8B, 0x04, 0x04, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x56,
    ]
    static let chargeStartOffResponse: [UInt8] = [
        0x00, 0x08, 0x8B, 0x04, 0x04, 0x00, 0x00, 0x00, 0x00, 0x09, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        0x00, 0x00, 0xEE,
    ]

    static let chargeStartOnCommands: [[UInt8]] = [
        [0x01, 0xC9, 0x4F, 0x04, 0x5B, 0x04, 0x00, 0xFF, 0xFF, 0xFF, 0x00, 0x00, 0x00, 0x00, 0x00,
         0x00, 0x00, 0x00, 0x00, 0x00],
        [0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x06],
        [0x01, 0xC9, 0x4F, 0x04, 0x72, 0x05, 0x00, 0xFF, 0xFF, 0xFF, 0x00, 0x00, 0x00, 0x00, 0x00,
         0x00, 0x00, 0x00, 0x00, 0x00],
        [0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x72],
        [0x00, 0xC9, 0x47, 0x04, 0x00, 0xFF, 0xFF, 0x00, 0xDA],
        [0x00, 0xC9, 0x07, 0x04, 0x04, 0x00, 0x00, 0x00, 0x08],
        [0x00, 0xC9, 0x07, 0x04, 0x05, 0x00, 0x00, 0x00, 0x1E],
    ]
    static let chargeStartOffCommands: [[UInt8]] = [
        [0x01, 0xC9, 0x4F, 0x04, 0x64, 0x04, 0x00, 0xFF, 0xFF, 0xFF, 0x09, 0x00, 0x00, 0x00, 0x00,
         0x00, 0x00, 0x00, 0x00, 0x00],
        [0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x0C],
        [0x01, 0xC9, 0x4F, 0x04, 0x4D, 0x05, 0x00, 0xFF, 0xFF, 0xFF, 0x09, 0x00, 0x00, 0x00, 0x00,
         0x00, 0x00, 0x00, 0x00, 0x00],
        [0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x78],
        [0x00, 0xC9, 0x47, 0x04, 0x00, 0xFF, 0xFF, 0x00, 0xDA],
        [0x00, 0xC9, 0x07, 0x04, 0x04, 0x00, 0x00, 0x00, 0x08],
        [0x00, 0xC9, 0x07, 0x04, 0x05, 0x00, 0x00, 0x00, 0x1E],
    ]

    public init(response r: [UInt8], model: DeviceModel) throws {
        guard r.count >= 9 else { throw IQOSError.decode("振動：返事が短い") }
        guard Self.matcher.matches(r) else { throw IQOSError.decode("振動：見出しが違う") }
        let okKind: Bool = model.supportsChargeStartVibration ? (r[4] == 0x10 || r[4] == 0x03) : r[4] == 0x10
        guard okKind else { throw IQOSError.decode("振動：見出しが違う") }
        self.init(heatingStart: r[6] & 0x01 != 0,
                  startingToUse: r[6] & 0x10 != 0,
                  puffEnd: r[7] & 0x01 != 0,
                  manuallyTerminated: r[7] & 0x10 != 0)
    }

    public static func chargeStart(response r: [UInt8]) throws -> Bool {
        guard r.count >= 19 else { throw IQOSError.decode("充電開始の振動：返事が短い") }
        if r == chargeStartOnResponse { return true }
        if r == chargeStartOffResponse { return false }
        return r[8] == 0x01
    }

    var register: UInt16 {
        var v: UInt16 = 0
        if heatingStart { v |= Self.heatingStartFlag }
        if startingToUse { v |= Self.startingToUseFlag }
        if puffEnd { v |= Self.puffEndFlag }
        if manuallyTerminated { v |= Self.manuallyTerminatedFlag }
        return v
    }

    static func checksum(_ reg: UInt16) -> UInt8 {
        var c: UInt8 = 0x77
        if reg & puffEndFlag != 0 { c ^= 0x07 }
        if reg & manuallyTerminatedFlag != 0 { c ^= 0x70 }
        if reg & heatingStartFlag != 0 { c ^= 0x15 }
        if reg & startingToUseFlag != 0 { c ^= 0x57 }
        return c
    }

    var mainCommand: [UInt8] {
        let reg = register
        return [0x00, 0xC9, 0x44, 0x23, 0x10, 0x00, UInt8(reg >> 8), UInt8(reg & 0xFF), Self.checksum(reg)]
    }

    var allCoreOff: Bool { !heatingStart && !startingToUse && !puffEnd && !manuallyTerminated }

    public func updateCommands(model: DeviceModel) throws -> [[UInt8]] {
        guard model.supportsBasic else { throw IQOSError.unsupported("この機種は振動の設定に未対応") }
        if !model.supportsChargeStartVibration {
            guard chargeStart == nil else { throw IQOSError.unsupported("この機種は充電開始の振動に未対応") }
            return [mainCommand]
        }
        guard let charge = chargeStart else { throw IQOSError.decode("充電開始の振動の値が必要") }
        var cmds = [mainCommand]
        if charge || !allCoreOff {
            cmds += charge ? Self.chargeStartOnCommands : Self.chargeStartOffCommands
        }
        return cmds
    }
}

// MARK: - スマートジェスチャー・オートスタート

public enum Gesture {
    public static func smartGestureCommand(_ on: Bool) -> [UInt8] {
        on ? [0x00, 0xC9, 0x47, 0x24, 0x04, 0x01, 0x00, 0x00, 0x3C]
           : [0x00, 0xC9, 0x47, 0x24, 0x04, 0x00, 0x00, 0x00, 0x57]
    }

    public static func autoStartCommand(_ on: Bool) -> [UInt8] {
        on ? [0x00, 0xC9, 0x47, 0x24, 0x01, 0x01, 0x00, 0x00, 0x3F]
           : [0x00, 0xC9, 0x47, 0x24, 0x01, 0x00, 0x00, 0x00, 0x54]
    }

    public static let loadAutoStartCommand: [UInt8] = [0x00, 0xC9, 0x07, 0x24, 0x01, 0x00, 0x00, 0x00, 0x22]
    public static let autoStartMatcher = ResponseMatcher([0x00, 0x08, 0x87, 0x24])

    public static func autoStart(response r: [UInt8]) throws -> Bool {
        guard r.count >= 9 else { throw IQOSError.decode("オートスタート：返事が短い") }
        guard autoStartMatcher.matches(r) else { throw IQOSError.decode("オートスタート：見出しが違う") }
        guard r[4] == 0x01 else { throw IQOSError.decode("オートスタート：設定番号が違う") }
        switch r[5] {
        case 0x00: return false
        case 0x01: return true
        default: throw IQOSError.decode("オートスタート：知らない値")
        }
    }
}

// MARK: - ロック

public enum Lock {
    static let confirmation: [UInt8] = [0x00, 0xC0, 0x01, 0x00, 0xF6]
    public static let lockCommands: [[UInt8]] = [
        [0x00, 0xC9, 0x44, 0x04, 0x02, 0xFF, 0x00, 0x00, 0x5A],
        [0x00, 0xC9, 0x00, 0x04, 0x1C],
        confirmation,
    ]
    public static let unlockCommands: [[UInt8]] = [
        [0x00, 0xC9, 0x44, 0x04, 0x00, 0x00, 0x00, 0x00, 0x5D],
        [0x00, 0xC9, 0x00, 0x04, 0x1C],
        confirmation,
    ]
}

// MARK: - 診断（使用回数・使用日数・電圧）

public struct Diagnostics: Sendable, Equatable {
    public var totalCount: UInt16?
    public var daysUsed: UInt16?
    public var batteryVoltage: Double?

    public init(totalCount: UInt16? = nil, daysUsed: UInt16? = nil, batteryVoltage: Double? = nil) {
        self.totalCount = totalCount
        self.daysUsed = daysUsed
        self.batteryVoltage = batteryVoltage
    }

    public static let telemetryCommand: [UInt8] = [0x00, 0xC9, 0x10, 0x02, 0x01, 0x01, 0x75, 0xD6]
    public static let timestampCommand: [UInt8] = [0x00, 0xC0, 0x10, 0x02, 0x00, 0x04, 0x38, 0xEF]
    public static let voltageCommand: [UInt8] = [0x00, 0xC0, 0x00, 0x21, 0xE7]

    public static let telemetryMatcher = ResponseMatcher(offset: 2, [0x90, 0x22])
    public static let timestampMatcher = ResponseMatcher(offset: 2, [0x80, 0x02])
    public static let voltageMatcher = ResponseMatcher(offset: 2, [0x88, 0x21])

    /// 参考元と同じ順番（使用回数 → 日数 → 使用回数 → 電圧）。
    public static let sequence: [([UInt8], ResponseMatcher)] = [
        (telemetryCommand, telemetryMatcher),
        (timestampCommand, timestampMatcher),
        (telemetryCommand, telemetryMatcher),
        (voltageCommand, voltageMatcher),
    ]

    static let tagCount: UInt8 = 0x8E
    static let tagDays: UInt8 = 0x17

    /// 返事を 1 つ読み込んで値を埋める。知らない返事は無視する。
    public mutating func absorb(_ r: [UInt8]) throws {
        guard r.count >= 4 else { throw IQOSError.decode("診断：返事が短い") }
        switch (r[2], r[3]) {
        case (0x90, 0x22):
            guard r.count >= 6 else { throw IQOSError.decode("使用回数：返事が短い") }
            guard UInt16(r[4]) | UInt16(r[5]) << 8 == 0x0101 else { throw IQOSError.decode("使用回数：印が違う") }
            let blocks = max(Int(r[3]) - 2, 0) / 8
            guard r.count >= 6 + blocks * 8 else { throw IQOSError.decode("使用回数：長さが足りない") }
            for i in 0..<blocks {
                let o = 6 + i * 8
                let value = UInt16(r[o + 4]) | UInt16(r[o + 5]) << 8
                switch r[o + 7] {
                case Self.tagCount: totalCount = value
                case Self.tagDays: daysUsed = value
                default: break
                }
            }
        case (0x80, 0x02):
            guard r.count >= 6 else { throw IQOSError.decode("使用日数：返事が短い") }
            daysUsed = UInt16(r[4]) | UInt16(r[5]) << 8
        case (0x88, 0x21):
            guard r.count >= 7 else { throw IQOSError.decode("電圧：返事が短い") }
            batteryVoltage = Double(UInt16(r[5]) | UInt16(r[6]) << 8) / 1000
        default:
            break
        }
    }
}

// MARK: - 本体ソフトのバージョン・型番

public enum Part: Sendable {
    /// チャージャー（参考元では stick）
    case charger
    /// ホルダー
    case holder

    var target: UInt8 { self == .charger ? 0xC0 : 0xC9 }
    var replyTarget: UInt8 { self == .charger ? 0xC0 : 0x08 }
}

public struct FirmwareVersion: Sendable, Equatable, CustomStringConvertible {
    public var major: UInt8, minor: UInt8, patch: UInt8, year: UInt8

    public init(major: UInt8, minor: UInt8, patch: UInt8, year: UInt8) {
        self.major = major; self.minor = minor; self.patch = patch; self.year = year
    }

    public static func loadCommand(_ part: Part) -> [UInt8] { [0x00, part.target, 0x00, 0x00, 0x00, 0x00, 0x00] }
    public static func matcher(_ part: Part) -> ResponseMatcher { ResponseMatcher([0x00, part.replyTarget, 0x88, 0x00]) }

    public init(response r: [UInt8], part: Part) throws {
        guard r.count >= 10 else { throw IQOSError.decode("バージョン：返事が短い") }
        guard Self.matcher(part).matches(r) else { throw IQOSError.decode("バージョン：見出しが違う") }
        self.init(major: r[6], minor: r[7], patch: r[8], year: r[9])
    }

    public var description: String { "v\(major).\(minor).\(patch).\(year)" }
}

public enum ProductNumber {
    public static func loadCommand(_ part: Part) -> [UInt8] { [0x00, part.target, 0x00, 0x03, 0x09] }
    public static func matcher(_ part: Part) -> ResponseMatcher { ResponseMatcher([0x00, part.replyTarget, 0x88, 0x03]) }

    public static func parse(_ r: [UInt8], part: Part) throws -> String {
        guard r.count >= 4 else { throw IQOSError.decode("型番：返事が短い") }
        guard matcher(part).matches(r) else { throw IQOSError.decode("型番：見出しが違う") }
        let payload: ArraySlice<UInt8>
        switch part {
        case .charger:
            guard r.count > 5 else { throw IQOSError.decode("型番：中身が無い") }
            payload = r[4..<(r.count - 1)]   // 最後の 1 バイトは検査用
        case .holder:
            guard r.count > 4 else { throw IQOSError.decode("型番：中身が無い") }
            payload = r[4...]
        }
        return String(payload.map { (0x20...0x7E).contains($0) ? Character(UnicodeScalar($0)) : "." })
    }
}

// MARK: - 表示用

public func hexString(_ bytes: [UInt8]) -> String {
    bytes.map { b in
        let s = String(b, radix: 16, uppercase: true)
        return s.count == 1 ? "0" + s : s
    }.joined(separator: " ")
}
