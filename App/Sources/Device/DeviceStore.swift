import Foundation
import IQOSKit
import Observation

/// 画面に出す本体の値と、画面からの操作。値は「未取得」を nil で表す。
@MainActor
@Observable
final class DeviceStore {
    let ble = BLEManager()

    var battery: UInt8?
    var brightness: Brightness?
    var vibration: VibrationSettings?
    var autoStart: Bool?
    var diagnostics = Diagnostics()
    var chargerFirmware: FirmwareVersion?
    var holderFirmware: FirmwareVersion?
    var chargerProduct: String?
    var holderProduct: String?
    var lastUpdated: Date?

    /// 本体から読み戻せない値は、最後に送った値をこの iPhone に覚えておく。
    var smartGesture: Bool { didSet { UserDefaults.standard.set(smartGesture, forKey: "smartGesture") } }
    var locked: Bool { didSet { UserDefaults.standard.set(locked, forKey: "locked") } }

    var busy: Set<String> = []       // 送信中の項目
    var errorMessage: String?
    var findingMe = false
    var refreshing = false

    @ObservationIgnored private var findMeTask: Task<Void, Never>?

    init() {
        smartGesture = UserDefaults.standard.object(forKey: "smartGesture") as? Bool ?? true
        locked = UserDefaults.standard.bool(forKey: "locked")
    }

    private var client: IQOSClient<BLETransport> {
        IQOSClient(transport: BLETransport(manager: ble), model: ble.model)
    }

    var isReady: Bool { ble.state == .ready }
    var model: DeviceModel { ble.model }

    // MARK: 読み込み

    func refreshAll() async {
        guard isReady, !refreshing else { return }
        refreshing = true
        defer { refreshing = false }
        let c = client
        battery = await attempt("電池") { try await c.batteryPercent() } ?? battery
        brightness = await attempt("明るさ") { try await c.brightness() } ?? brightness
        vibration = await attempt("振動") { try await c.vibration() } ?? vibration
        if model.supportsGestureAndAutoStart {
            autoStart = await attempt("オートスタート") { try await c.autoStart() } ?? autoStart
        }
        if let d = await attempt("診断", { try await c.diagnostics() }) { diagnostics = d }
        chargerFirmware = await attempt("チャージャーのバージョン") { try await c.firmware(.charger) } ?? chargerFirmware
        chargerProduct = await attempt("チャージャーの型番") { try await c.productNumber(.charger) } ?? chargerProduct
        if model.hasHolder {
            holderFirmware = await attempt("ホルダーのバージョン") { try await c.firmware(.holder) } ?? holderFirmware
            holderProduct = await attempt("ホルダーの型番") { try await c.productNumber(.holder) } ?? holderProduct
        }
        lastUpdated = .now
    }

    func refreshBattery() async {
        guard isReady else { return }
        let c = client
        battery = await attempt("電池") { try await c.batteryPercent() } ?? battery
    }

    func clear() {
        battery = nil; brightness = nil; vibration = nil; autoStart = nil
        diagnostics = Diagnostics(); chargerFirmware = nil; holderFirmware = nil
        chargerProduct = nil; holderProduct = nil; lastUpdated = nil
    }

    /// 失敗しても全体は止めず、ログに残して nil を返す。
    private func attempt<T: Sendable>(_ label: String, _ op: () async throws -> T) async -> T? {
        do { return try await op() }
        catch {
            ble.note("\(label)：読めませんでした（\(ble.describe(error))）")
            return nil
        }
    }

    // MARK: 変更（送る → 読み直す → 反映。失敗したら元に戻して理由を出す）

    func setBrightness(_ value: Brightness) async {
        let old = brightness
        brightness = value
        await change("brightness", restore: { self.brightness = old }) {
            try await self.client.setBrightness(value)
            self.brightness = try await self.client.brightness()
        }
    }

    func setVibration(_ value: VibrationSettings) async {
        let old = vibration
        vibration = value
        await change("vibration", restore: { self.vibration = old }) {
            try await self.client.setVibration(value)
            self.vibration = try await self.client.vibration()
        }
    }

    func setAutoStart(_ on: Bool) async {
        let old = autoStart
        autoStart = on
        await change("autoStart", restore: { self.autoStart = old }) {
            try await self.client.setAutoStart(on)
            self.autoStart = try await self.client.autoStart()
        }
    }

    func setSmartGesture(_ on: Bool) async {
        let old = smartGesture
        smartGesture = on
        await change("smartGesture", restore: { self.smartGesture = old }) {
            try await self.client.setSmartGesture(on)
        }
    }

    func setLocked(_ on: Bool) async {
        let old = locked
        locked = on
        await change("locked", restore: { self.locked = old }) {
            try await self.client.setLocked(on)
        }
    }

    private func change(_ key: String, restore: @escaping () -> Void, _ op: @escaping () async throws -> Void) async {
        busy.insert(key)
        defer { busy.remove(key) }
        do { try await op() }
        catch {
            restore()
            errorMessage = "変更できませんでした（\(ble.describe(error))）"
            ble.note("変更に失敗：\(key)：\(ble.describe(error))")
        }
    }

    // MARK: 公式の Web アプリ

    static let officialUpdateURL = URL(string: "https://jp.iqos.com/apps")!
    var showOfficialBrowser = false

    /// 公式ページを開く。同時に 2 か所からつながないよう、先にこのアプリの接続を切る。
    func openOfficialBrowser() {
        stopFindMe()
        ble.disconnect(forget: false)
        showOfficialBrowser = true
    }

    func closeOfficialBrowser() {
        showOfficialBrowser = false
        Task {
            try? await Task.sleep(for: .seconds(1))
            await ble.reconnectSaved()
        }
    }

    // MARK: 本体を探す

    func toggleFindMe() {
        if findingMe { stopFindMe(); return }
        findingMe = true
        findMeTask = Task {
            do {
                try await client.startFindMe()
                try await Task.sleep(for: .seconds(8))
            } catch is CancellationError {
            } catch {
                errorMessage = "振動させられませんでした（\(ble.describe(error))）"
            }
            try? await client.stopFindMe()
            findingMe = false
        }
    }

    func stopFindMe() {
        findMeTask?.cancel()
        findMeTask = nil
    }
}
