import Foundation

/// 命令を 1 本送る・送って返事を待つ、だけの決まり。本物は CoreBluetooth、テストは偽物。
public protocol IQOSTransport: Sendable {
    func send(_ frame: [UInt8]) async throws
    func request(_ frame: [UInt8], expecting matcher: ResponseMatcher) async throws -> [UInt8]
    func readBattery() async throws -> UInt8
}

/// 本体に対する操作。命令の順番は参考元と同じ。
public struct IQOSClient<T: IQOSTransport>: Sendable {
    public let transport: T
    public let model: DeviceModel

    public init(transport: T, model: DeviceModel) {
        self.transport = transport
        self.model = model
    }

    // 電池
    public func batteryPercent() async throws -> UInt8 { try await transport.readBattery() }

    // 明るさ
    public func brightness() async throws -> Brightness {
        try Brightness(response: await transport.request(Brightness.loadCommand, expecting: Brightness.matcher))
    }

    public func setBrightness(_ value: Brightness) async throws {
        guard model.supportsBasic else { throw IQOSError.unsupported("明るさ") }
        for c in value.writeCommands { try await transport.send(c) }
    }

    // 振動
    public func vibration() async throws -> VibrationSettings {
        guard model.supportsBasic else { throw IQOSError.unsupported("振動") }
        var charge: Bool?
        if model.supportsChargeStartVibration {
            let r = try await transport.request(VibrationSettings.loadChargeStartCommand,
                                                expecting: VibrationSettings.chargeStartMatcher)
            charge = try VibrationSettings.chargeStart(response: r)
        }
        let r = try await transport.request(VibrationSettings.loadCommand, expecting: VibrationSettings.matcher)
        var s = try VibrationSettings(response: r, model: model)
        s.chargeStart = charge
        return s
    }

    public func setVibration(_ settings: VibrationSettings) async throws {
        var s = settings
        if model.supportsChargeStartVibration && s.chargeStart == nil {
            let r = try await transport.request(VibrationSettings.loadChargeStartCommand,
                                                expecting: VibrationSettings.chargeStartMatcher)
            s.chargeStart = try VibrationSettings.chargeStart(response: r)
        }
        for c in try s.updateCommands(model: model) { try await transport.send(c) }
    }

    // 本体を探す
    public func startFindMe() async throws { try await transport.send(VibrationSettings.startVibrate) }
    public func stopFindMe() async throws { try await transport.send(VibrationSettings.stopVibrate) }

    // ジェスチャー・オートスタート
    public func setSmartGesture(_ on: Bool) async throws {
        guard model.supportsGestureAndAutoStart else { throw IQOSError.unsupported("スマートジェスチャー") }
        try await transport.send(Gesture.smartGestureCommand(on))
    }

    public func autoStart() async throws -> Bool {
        guard model.supportsGestureAndAutoStart else { throw IQOSError.unsupported("オートスタート") }
        return try Gesture.autoStart(response: await transport.request(Gesture.loadAutoStartCommand,
                                                                      expecting: Gesture.autoStartMatcher))
    }

    public func setAutoStart(_ on: Bool) async throws {
        guard model.supportsGestureAndAutoStart else { throw IQOSError.unsupported("オートスタート") }
        try await transport.send(Gesture.autoStartCommand(on))
    }

    // ロック
    public func setLocked(_ locked: Bool) async throws {
        guard model.supportsBasic else { throw IQOSError.unsupported("ロック") }
        for c in locked ? Lock.lockCommands : Lock.unlockCommands { try await transport.send(c) }
    }

    // 診断
    public func diagnostics() async throws -> Diagnostics {
        var d = Diagnostics()
        for (cmd, matcher) in Diagnostics.sequence {
            try d.absorb(await transport.request(cmd, expecting: matcher))
        }
        return d
    }

    // バージョン・型番
    public func firmware(_ part: Part) async throws -> FirmwareVersion {
        try FirmwareVersion(response: await transport.request(FirmwareVersion.loadCommand(part),
                                                             expecting: FirmwareVersion.matcher(part)),
                            part: part)
    }

    public func productNumber(_ part: Part) async throws -> String {
        try ProductNumber.parse(await transport.request(ProductNumber.loadCommand(part),
                                                       expecting: ProductNumber.matcher(part)),
                                part: part)
    }
}
