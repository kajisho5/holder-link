import Testing
@testable import IQOSKit

// 期待値は参考元 iqos 1.1.0 のテストに書かれている値。

@Suite struct ModelTests {
    @Test func 名前から機種を判定() {
        #expect(DeviceModel(localName: "IQOS ILUMA") == .iluma)
        #expect(DeviceModel(localName: "IQOS ILUMA i PRIME") == .ilumaIPrime)
        #expect(DeviceModel(localName: "IQOS ILUMA i ONE") == .ilumaIOne)
        #expect(DeviceModel(localName: "IQOS ILUMA ONE") == .ilumaOne)
        #expect(DeviceModel(localName: "mystery device") == .unknown)
    }

    @Test func 無印ILUMAの対応範囲() {
        let m = DeviceModel.iluma
        #expect(m.supportsBasic)
        #expect(m.supportsGestureAndAutoStart)
        #expect(m.supportsChargeStartVibration)
        #expect(!DeviceModel.ilumaOne.supportsGestureAndAutoStart)
        #expect(!DeviceModel.unknown.supportsBasic)
    }
}

@Suite struct BrightnessTests {
    @Test func 読み取り() throws {
        #expect(try Brightness(response: [0x00, 0xC0, 0x86, 0x23, 0x64, 0, 0, 0, 0]) == .high)
        #expect(try Brightness(response: [0x00, 0xC0, 0x86, 0x23, 0x1E, 0, 0, 0, 0]) == .low)
        #expect(throws: IQOSError.self) { try Brightness(response: [0x00, 0x00, 0x86, 0x23, 0x64, 0, 0, 0, 0]) }
        #expect(throws: IQOSError.self) { try Brightness(response: [0x00, 0xC0, 0x86, 0x23, 0xFF, 0, 0, 0, 0]) }
        #expect(throws: IQOSError.self) { try Brightness(response: [0x00, 0xC0, 0x86, 0x23]) }
    }

    @Test func 読み取り命令() {
        #expect(Brightness.loadCommand == [0x00, 0xC0, 0x02, 0x23, 0xC3])
    }
}

@Suite struct VibrationTests {
    @Test func 基本の書き込み() throws {
        let s = VibrationSettings(heatingStart: true, startingToUse: false, puffEnd: true, manuallyTerminated: false)
        let cmds = try s.updateCommands(model: .ilumaOne)
        // 0x77 ^ 0x07 ^ 0x15 = 0x65
        #expect(cmds == [[0x00, 0xC9, 0x44, 0x23, 0x10, 0x00, 0x01, 0x01, 0x65]])
    }

    @Test func 全部オフ() throws {
        let s = VibrationSettings(heatingStart: false, startingToUse: false, puffEnd: false, manuallyTerminated: false)
        #expect(try s.updateCommands(model: .ilumaOne) == [[0x00, 0xC9, 0x44, 0x23, 0x10, 0x00, 0x00, 0x00, 0x77]])
    }

    @Test func 全部オン() throws {
        let s = VibrationSettings(heatingStart: true, startingToUse: true, puffEnd: true, manuallyTerminated: true)
        let c = try s.updateCommands(model: .ilumaOne)[0]
        #expect(c == [0x00, 0xC9, 0x44, 0x23, 0x10, 0x00, 0x11, 0x11, 0x77 ^ 0x07 ^ 0x70 ^ 0x15 ^ 0x57])
    }

    @Test func ホルダー機種は充電開始の命令を足す() throws {
        let on = VibrationSettings(heatingStart: true, startingToUse: false, puffEnd: false,
                                   manuallyTerminated: false, chargeStart: true)
        let cmds = try on.updateCommands(model: .iluma)
        #expect(cmds.count == 8)
        #expect(cmds[1].first == 0x01)
        // 全部オフかつ充電開始もオフなら本命令だけ
        let off = VibrationSettings(heatingStart: false, startingToUse: false, puffEnd: false,
                                    manuallyTerminated: false, chargeStart: false)
        #expect(try off.updateCommands(model: .iluma).count == 1)
        // ホルダー機種で充電開始の値が無いのは誤り
        let missing = VibrationSettings(heatingStart: true, startingToUse: false, puffEnd: false, manuallyTerminated: false)
        #expect(throws: IQOSError.self) { try missing.updateCommands(model: .iluma) }
        // ONE で充電開始を指定するのも誤り
        #expect(throws: IQOSError.self) { try on.updateCommands(model: .ilumaOne) }
    }

    @Test func 読み取り() throws {
        let r: [UInt8] = [0x00, 0x08, 0x84, 0x23, 0x10, 0x00, 0x11, 0x01, 0x00]
        let s = try VibrationSettings(response: r, model: .ilumaOne)
        #expect(s.heatingStart && s.startingToUse && s.puffEnd && !s.manuallyTerminated)
        let r2: [UInt8] = [0x00, 0x08, 0x84, 0x23, 0x03, 0x00, 0x00, 0x10, 0x00]
        #expect(throws: IQOSError.self) { try VibrationSettings(response: r2, model: .ilumaOne) }
        let s2 = try VibrationSettings(response: r2, model: .iluma)
        #expect(s2.manuallyTerminated && !s2.heatingStart)
    }

    @Test func 充電開始の読み取り() throws {
        #expect(try VibrationSettings.chargeStart(response: VibrationSettings.chargeStartOnResponse))
        #expect(try !VibrationSettings.chargeStart(response: VibrationSettings.chargeStartOffResponse))
    }
}

@Suite struct GestureTests {
    @Test func オートスタート() throws {
        #expect(try Gesture.autoStart(response: [0x00, 0x08, 0x87, 0x24, 0x01, 0x01, 0, 0, 0]))
        #expect(try !Gesture.autoStart(response: [0x00, 0x08, 0x87, 0x24, 0x01, 0x00, 0, 0, 0]))
        #expect(throws: IQOSError.self) { try Gesture.autoStart(response: [0x00, 0x08, 0x87, 0x24, 0x04, 0x01, 0, 0, 0]) }
    }

    @Test func 命令() {
        #expect(Gesture.smartGestureCommand(true) == [0x00, 0xC9, 0x47, 0x24, 0x04, 0x01, 0x00, 0x00, 0x3C])
        #expect(Gesture.autoStartCommand(false) == [0x00, 0xC9, 0x47, 0x24, 0x01, 0x00, 0x00, 0x00, 0x54])
    }
}

@Suite struct LockTests {
    @Test func 命令の並び() {
        #expect(Lock.lockCommands[0] == [0x00, 0xC9, 0x44, 0x04, 0x02, 0xFF, 0x00, 0x00, 0x5A])
        #expect(Lock.unlockCommands[0] == [0x00, 0xC9, 0x44, 0x04, 0x00, 0x00, 0x00, 0x00, 0x5D])
        #expect(Lock.lockCommands[1] == Lock.unlockCommands[1])
        #expect(Lock.lockCommands[2] == [0x00, 0xC0, 0x01, 0x00, 0xF6])
    }
}

@Suite struct DiagnosticsTests {
    @Test func 使用回数と日数() throws {
        var d = Diagnostics()
        // 長さ 0x22 = 34 → (34-2)/8 = 4 ブロック
        var r: [UInt8] = [0x00, 0x08, 0x90, 0x22, 0x01, 0x01]
        r += [0, 0, 0, 0, 0x04, 0x05, 0, 0x8E]   // 使用回数 0x0504
        r += [0, 0, 0, 0, 0x2A, 0x00, 0, 0x17]   // 日数 42
        r += [UInt8](repeating: 0, count: 16)
        try d.absorb(r)
        #expect(d.totalCount == 0x0504)
        #expect(d.daysUsed == 42)
    }

    @Test func 電圧() throws {
        var d = Diagnostics()
        try d.absorb([0x00, 0xC0, 0x88, 0x21, 0x00, 0x50, 0x0F])   // 0x0F50 = 3920
        #expect(d.batteryVoltage == 3.92)
    }

    @Test func 知らない返事は無視() throws {
        var d = Diagnostics()
        try d.absorb([0x00, 0x00, 0x11, 0x22])
        #expect(d == Diagnostics())
    }
}

@Suite struct FirmwareTests {
    @Test func バージョンと型番() throws {
        let f = try FirmwareVersion(response: [0x00, 0xC0, 0x88, 0x00, 0, 0, 1, 2, 3, 24], part: .charger)
        #expect(f.description == "v1.2.3.24")
        #expect(throws: IQOSError.self) {
            try FirmwareVersion(response: [0x00, 0xC0, 0x88, 0x00, 0, 0, 1, 2, 3, 24], part: .holder)
        }
        let stick = [0x00, 0xC0, 0x88, 0x03] + Array("ABCD123456".utf8) + [0xAA]
        #expect(try ProductNumber.parse(stick, part: .charger) == "ABCD123456")
        let holder = [0x00, 0x08, 0x88, 0x03] + Array("HOLDER123456".utf8)
        #expect(try ProductNumber.parse(holder, part: .holder) == "HOLDER123456")
        #expect(try ProductNumber.parse([0x00, 0x08, 0x88, 0x03, 0x41, 0x00, 0xFF], part: .holder) == "A..")
        #expect(ProductNumber.loadCommand(.charger) == [0x00, 0xC0, 0x00, 0x03, 0x09])
        #expect(ProductNumber.loadCommand(.holder) == [0x00, 0xC9, 0x00, 0x03, 0x09])
    }
}

// MARK: - 偽物の通信でクライアントの順番を確かめる

actor MockTransport: IQOSTransport {
    var sent: [[UInt8]] = []
    var replies: [[UInt8]: [UInt8]] = [:]

    init(replies: [[UInt8]: [UInt8]] = [:]) { self.replies = replies }

    func send(_ frame: [UInt8]) async throws { sent.append(frame) }

    func request(_ frame: [UInt8], expecting matcher: ResponseMatcher) async throws -> [UInt8] {
        sent.append(frame)
        guard let r = replies[frame], matcher.matches(r) else { throw IQOSError.timeout }
        return r
    }

    func readBattery() async throws -> UInt8 { 82 }
}

@Suite struct ClientTests {
    @Test func 振動の書き込みで充電開始を読んでから送る() async throws {
        let mock = MockTransport(replies: [VibrationSettings.loadChargeStartCommand: VibrationSettings.chargeStartOnResponse])
        let client = IQOSClient(transport: mock, model: .iluma)
        try await client.setVibration(VibrationSettings(heatingStart: true, startingToUse: false,
                                                        puffEnd: false, manuallyTerminated: false))
        let sent = await mock.sent
        #expect(sent.first == VibrationSettings.loadChargeStartCommand)
        #expect(sent.count == 1 + 8)
    }

    @Test func 診断は4回問い合わせる() async throws {
        var tele: [UInt8] = [0x00, 0x08, 0x90, 0x22, 0x01, 0x01]
        tele += [0, 0, 0, 0, 0x10, 0x00, 0, 0x8E]
        tele += [UInt8](repeating: 0, count: 24)
        let mock = MockTransport(replies: [
            Diagnostics.telemetryCommand: tele,
            Diagnostics.timestampCommand: [0x00, 0xC0, 0x80, 0x02, 0x07, 0x00],
            Diagnostics.voltageCommand: [0x00, 0xC0, 0x88, 0x21, 0x00, 0x50, 0x0F],
        ])
        let d = try await IQOSClient(transport: mock, model: .iluma).diagnostics()
        #expect(d.totalCount == 16)
        #expect(d.daysUsed == 7)
        #expect(d.batteryVoltage == 3.92)
        #expect(await mock.sent.count == 4)
    }

    @Test func ONEはオートスタート非対応() async {
        let client = IQOSClient(transport: MockTransport(), model: .ilumaOne)
        await #expect(throws: IQOSError.self) { try await client.setAutoStart(true) }
    }

    @Test func ロックは3本送る() async throws {
        let mock = MockTransport()
        try await IQOSClient(transport: mock, model: .iluma).setLocked(true)
        #expect(await mock.sent == Lock.lockCommands)
    }
}
