import CoreBluetooth
import Foundation
import IQOSKit
import Observation

struct LogEntry: Identifiable, Equatable {
    enum Direction: String { case sent = "送信", received = "受信", note = "メモ" }
    let id = UUID()
    let time: Date
    let direction: Direction
    let text: String
}

struct DiscoveredDevice: Identifiable, Equatable {
    let id: UUID
    let name: String
    var rssi: Int
    var isIQOS = true
    var alreadyConnected = false
}

/// IQOS 本体との BLE 接続。画面からはこれと DeviceStore だけを見る。
@MainActor
@Observable
final class BLEManager: NSObject {
    enum State: Equatable {
        case unavailable(String)
        case idle
        case scanning
        case connecting
        case ready
    }

    private(set) var state: State = .idle
    private(set) var discovered: [DiscoveredDevice] = []
    private(set) var log: [LogEntry] = []
    private(set) var model: DeviceModel = .unknown
    private(set) var deviceName: String = ""
    private(set) var deviceInfo: [String: String] = [:]   // 2A24 など → 値
    var lastError: String?
    /// 調査用：IQOS 以外も含めて、名前のある機器をすべて一覧に出す
    var showAll = false { didSet { if oldValue != showAll { discovered = discovered.filter { showAll || $0.isIQOS } } } }

    @ObservationIgnored private var central: CBCentralManager!
    @ObservationIgnored private var peripherals: [UUID: CBPeripheral] = [:]
    @ObservationIgnored private var localNames: [UUID: String] = [:]
    @ObservationIgnored private var peripheral: CBPeripheral?
    @ObservationIgnored private var batteryChar: CBCharacteristic?
    @ObservationIgnored private var controlChar: CBCharacteristic?
    @ObservationIgnored private var userWantsConnection = false
    @ObservationIgnored private var pendingReconnect: CBPeripheral?
    @ObservationIgnored private var seen: Set<UUID> = []
    @ObservationIgnored private var stage = ""

    // 待ち合わせ
    @ObservationIgnored var connectCont: Pending<Void>?
    @ObservationIgnored var servicesCont: Pending<Void>?
    @ObservationIgnored var charsCont: Pending<Void>?
    @ObservationIgnored var charsRemaining = 0
    @ObservationIgnored var notifyCont: Pending<Void>?
    @ObservationIgnored var readConts: [String: Pending<[UInt8]>] = [:]
    @ObservationIgnored var writeConts: [Pending<Void>] = []
    @ObservationIgnored var waiter: (matcher: ResponseMatcher, pending: Pending<[UInt8]>)?
    @ObservationIgnored private var chain: Task<Void, Never>?

    static let savedKey = "lastPeripheralID"
    static let responseTimeout: Duration = .seconds(3)

    override init() {
        super.init()
        central = CBCentralManager(delegate: self, queue: .main)
    }

    var savedID: UUID? {
        UserDefaults.standard.string(forKey: Self.savedKey).flatMap(UUID.init(uuidString:))
    }

    // MARK: 探す・つなぐ

    func startScan() {
        guard central.state == .poweredOn else { return }
        discovered = []
        seen = []
        state = .scanning
        note("探し始め（iOS \(ProcessInfo.processInfo.operatingSystemVersionString)）")
        // すでに iPhone とつながっている IQOS は広告を出さないことがあるので、先に拾う
        let known = central.retrieveConnectedPeripherals(withServices: [CBUUID(string: IQOSUUID.coreService),
                                                                          CBUUID(string: IQOSUUID.deviceInfoService)])
        for p in known {
            let name = p.name ?? "名前なし"
            let iqos = Self.looksLikeIQOS(name: name, services: [])
            note("iPhone に接続済みの機器：\(name) \(p.identifier.uuidString.prefix(8))")
            peripherals[p.identifier] = p
            localNames[p.identifier] = name
            if iqos || showAll {
                discovered.append(DiscoveredDevice(id: p.identifier, name: name, rssi: 0, isIQOS: iqos, alreadyConnected: true))
            }
        }
        central.scanForPeripherals(withServices: nil, options: [CBCentralManagerScanOptionAllowDuplicatesKey: false])
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(30))
            guard let self, self.state == .scanning else { return }
            self.central.stopScan()
            self.state = .idle
            self.note("探し終わり：見つけた機器 \(self.seen.count) 台、うち IQOS らしいもの \(self.discovered.filter(\.isIQOS).count) 台")
        }
    }

    static func looksLikeIQOS(name: String, services: [CBUUID]) -> Bool {
        let upper = name.uppercased()
        return upper.contains("IQOS") || upper.contains("ILUMA")
            || services.contains(CBUUID(string: IQOSUUID.coreService))
    }

    func stopScan() {
        central.stopScan()
        if state == .scanning { state = .idle }
    }

    func connect(_ id: UUID) async {
        stopScan()
        let p = peripherals[id] ?? central.retrievePeripherals(withIdentifiers: [id]).first
        guard let p else { lastError = "本体が見つかりません"; return }
        peripherals[id] = p
        userWantsConnection = true
        do {
            try await open(p)
        } catch {
            note("接続に失敗：\(describe(error))（段階：\(stage)）")
            lastError = "接続できませんでした（\(stage)で止まりました）。本体の電源を入れ直して、もう一度お試しください。続くときは「通信ログ」をコピーして送ってください"
            central.cancelPeripheralConnection(p)
            state = .idle
        }
    }

    /// 前回の本体に自動でつなぐ。
    func reconnectSaved() async {
        guard let id = savedID, state == .idle, central.state == .poweredOn else { return }
        await connect(id)
    }

    func disconnect(forget: Bool) {
        userWantsConnection = false
        if let p = peripheral { central.cancelPeripheralConnection(p) }
        if let p = pendingReconnect { central.cancelPeripheralConnection(p); pendingReconnect = nil }
        if forget { UserDefaults.standard.removeObject(forKey: Self.savedKey) }
        reset()
        state = .idle
    }

    private func open(_ p: CBPeripheral) async throws {
        state = .connecting
        stage = "接続"
        peripheral = p
        p.delegate = self
        deviceName = localNames[p.identifier] ?? p.name ?? "IQOS"
        model = DeviceModel(localName: deviceName)
        note("接続開始：\(deviceName)")

        try await withTimeout(.seconds(15)) { (cont: Pending<Void>) in self.connectCont = cont; self.central.connect(p) }
        try await setup(p)
    }

    /// つながった後の下調べ（接続口を探して、知らせを受け取る設定をする）。
    private func setup(_ p: CBPeripheral) async throws {
        stage = "サービスを探す"
        try await withTimeout(.seconds(10)) { (cont: Pending<Void>) in self.servicesCont = cont; p.discoverServices(nil) }
        let services = p.services ?? []
        if !services.isEmpty {
            try await withTimeout(.seconds(10)) { (cont: Pending<Void>) in
                self.charsCont = cont
                self.charsRemaining = services.count
                services.forEach { p.discoverCharacteristics(nil, for: $0) }
            }
        }
        note("サービス：" + services.map(\.uuid.uuidString).joined(separator: ", "))
        stage = "送受信口を探す"
        let all = services.flatMap { $0.characteristics ?? [] }
        note("キャラクタリスティック：" + all.map(\.uuid.uuidString).joined(separator: ", "))
        batteryChar = all.first { $0.uuid == CBUUID(string: IQOSUUID.battery) }
        controlChar = all.first { $0.uuid == CBUUID(string: IQOSUUID.control) }
        guard let control = controlChar else { throw IQOSError.transport("命令の送受信口が見つからない") }
        stage = "知らせの受け取り設定（ここでペアリングを求められることがある）"
        try await withTimeout(.seconds(10)) { (cont: Pending<Void>) in self.notifyCont = cont; p.setNotifyValue(true, for: control) }

        // 本体情報（読めなくても続ける）
        if let dis = services.first(where: { $0.uuid == CBUUID(string: IQOSUUID.deviceInfoService) }) {
            for c in dis.characteristics ?? [] {
                if let bytes = try? await read(c) {
                    deviceInfo[c.uuid.uuidString] = String(decoding: bytes, as: UTF8.self)
                        .trimmingCharacters(in: .controlCharacters)
                }
            }
        }
        if model == .unknown, let m = deviceInfo[IQOSUUID.modelNumber] { model = DeviceModel(localName: m) }
        if model == .unknown { model = .iluma }   // 名前で判定できないときは ILUMA 扱い（記録に残す）
        UserDefaults.standard.set(p.identifier.uuidString, forKey: Self.savedKey)
        note("準備完了：機種 \(model.displayName)")
        state = .ready
    }

    private func reset() {
        let err = IQOSError.transport("接続が切れました")
        connectCont?.resume(throwing: err); connectCont = nil
        servicesCont?.resume(throwing: err); servicesCont = nil
        charsCont?.resume(throwing: err); charsCont = nil
        notifyCont?.resume(throwing: err); notifyCont = nil
        readConts.values.forEach { $0.resume(throwing: err) }; readConts = [:]
        writeConts.forEach { $0.resume(throwing: err) }; writeConts = []
        waiter?.pending.resume(throwing: err); waiter = nil
        peripheral = nil
        batteryChar = nil
        controlChar = nil
        deviceInfo = [:]
    }

    // MARK: 送受信（1 本ずつ順番に）

    /// 前の操作が終わってから次を始める。
    func serial<T: Sendable>(_ op: @escaping @MainActor () async throws -> T) async throws -> T {
        let previous = chain
        let task = Task { @MainActor () async throws -> T in
            await previous?.value
            return try await op()
        }
        chain = Task { _ = try? await task.value }
        return try await task.value
    }

    func sendOnMain(_ frame: [UInt8]) async throws {
        guard let p = peripheral, let c = controlChar, state == .ready else { throw IQOSError.transport("未接続") }
        logBytes(.sent, frame)
        try await withTimeout(.seconds(5)) { (cont: Pending<Void>) in
            self.writeConts.append(cont)
            p.writeValue(Data(frame), for: c, type: .withResponse)
        }
    }

    func requestOnMain(_ frame: [UInt8], _ matcher: ResponseMatcher) async throws -> [UInt8] {
        guard state == .ready else { throw IQOSError.transport("未接続") }
        let pending = Pending<[UInt8]>()
        waiter = (matcher, pending)
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: Self.responseTimeout)
            guard let self, pending.isWaiting else { return }
            if self.waiter?.pending === pending { self.waiter = nil }
            self.note("返事が来ない：\(hexString(frame))")
            pending.resume(throwing: IQOSError.timeout)
        }
        do {
            try await sendOnMain(frame)
        } catch {
            if waiter?.pending === pending { waiter = nil }
            pending.resume(throwing: error)
        }
        return try await pending.value()
    }

    func readBatteryOnMain() async throws -> UInt8 {
        guard let c = batteryChar else { throw IQOSError.transport("電池の読み取り口が無い") }
        let r = try await read(c)
        guard r.count >= 3 else { throw IQOSError.decode("電池：返事が短い") }
        return r[2]
    }

    private func read(_ c: CBCharacteristic) async throws -> [UInt8] {
        guard let p = peripheral else { throw IQOSError.transport("未接続") }
        let key = c.uuid.uuidString
        let r = try await withTimeout(.seconds(5)) { (cont: Pending<[UInt8]>) in
            self.readConts[key] = cont
            p.readValue(for: c)
        }
        logBytes(.received, r, label: key.count <= 4 ? key : "電池")
        return r
    }

    /// 待ち合わせの仕組み。時間切れなら .timeout。
    private func withTimeout<T>(_ limit: Duration, _ start: (Pending<T>) -> Void) async throws -> T {
        let pending = Pending<T>()
        start(pending)
        Task { @MainActor in
            try? await Task.sleep(for: limit)
            pending.resume(throwing: IQOSError.timeout)
        }
        return try await pending.value()
    }

    // MARK: ログ

    func note(_ text: String) {
        append(LogEntry(time: .now, direction: .note, text: text))
    }

    func logBytes(_ dir: LogEntry.Direction, _ bytes: [UInt8], label: String? = nil) {
        append(LogEntry(time: .now, direction: dir, text: (label.map { "[\($0)] " } ?? "") + hexString(bytes)))
    }

    private func append(_ e: LogEntry) {
        log.append(e)
        if log.count > 500 { log.removeFirst(log.count - 500) }
    }

    func clearLog() { log = [] }

    func describe(_ error: Error) -> String {
        if let e = error as? IQOSError {
            switch e {
            case .decode(let s), .unsupported(let s), .transport(let s): return s
            case .timeout: return "時間切れ"
            }
        }
        return error.localizedDescription
    }
}

/// 1 回だけ結果を受け取れる入れ物。返事と時間切れが両方来ても、先に来た方だけが使われる。
@MainActor
final class Pending<T> {
    private var result: Result<T, Error>?
    private var cont: CheckedContinuation<T, Error>?

    var isWaiting: Bool { result == nil }

    func resume(returning v: T) { finish(.success(v)) }
    func resume(throwing e: Error) { finish(.failure(e)) }

    private func finish(_ r: Result<T, Error>) {
        guard result == nil else { return }
        result = r
        cont?.resume(with: r)
        cont = nil
    }

    func value() async throws -> T {
        if let result { return try result.get() }
        return try await withCheckedThrowingContinuation { c in
            if let result { c.resume(with: result) } else { cont = c }
        }
    }
}

// MARK: - CoreBluetooth からの知らせ（main キューで届く）

extension BLEManager: CBCentralManagerDelegate, CBPeripheralDelegate {
    nonisolated func centralManagerDidUpdateState(_ central: CBCentralManager) {
        let st = central.state
        MainActor.assumeIsolated {
            switch st {
            case .poweredOn:
                if case .unavailable = self.state { self.state = .idle }
                Task { await self.reconnectSaved() }
            case .poweredOff: self.state = .unavailable("Bluetooth がオフです")
            case .unauthorized: self.state = .unavailable("Bluetooth の使用が許可されていません")
            case .unsupported: self.state = .unavailable("この iPhone は Bluetooth に対応していません")
            default: break
            }
        }
    }

    nonisolated func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral,
                                    advertisementData: [String: Any], rssi RSSI: NSNumber) {
        let advName = advertisementData[CBAdvertisementDataLocalNameKey] as? String
        let name = advName ?? peripheral.name ?? ""
        let services = (advertisementData[CBAdvertisementDataServiceUUIDsKey] as? [CBUUID] ?? [])
            + (advertisementData[CBAdvertisementDataOverflowServiceUUIDsKey] as? [CBUUID] ?? [])
        let maker = (advertisementData[CBAdvertisementDataManufacturerDataKey] as? Data).map { [UInt8]($0) }
        let connectable = (advertisementData[CBAdvertisementDataIsConnectable] as? NSNumber)?.boolValue
        let rssi = RSSI.intValue
        MainActor.assumeIsolated {
            let id = peripheral.identifier
            let iqos = Self.looksLikeIQOS(name: name, services: services)
            if !self.seen.contains(id) {
                self.seen.insert(id)
                // 調査用に、見つけた機器を 1 回だけ記録する（名前のない機器は IQOS らしいときだけ）
                if iqos || !name.isEmpty {
                    var line = "発見：\(name.isEmpty ? "名前なし" : name) 電波\(rssi)"
                    if !services.isEmpty { line += " サービス[\(services.map(\.uuidString).joined(separator: ","))]" }
                    if let maker { line += " メーカー[\(hexString(Array(maker.prefix(12))))]" }
                    if connectable == false { line += " 接続不可" }
                    self.note(line)
                }
            }
            guard iqos || (self.showAll && !name.isEmpty) else { return }
            self.peripherals[id] = peripheral
            self.localNames[id] = name
            if let i = self.discovered.firstIndex(where: { $0.id == id }) {
                self.discovered[i].rssi = rssi
            } else {
                self.discovered.append(DiscoveredDevice(id: id, name: name.isEmpty ? "名前なし（IQOS のサービスあり）" : name,
                                                        rssi: rssi, isIQOS: iqos))
            }
        }
    }

    nonisolated func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        MainActor.assumeIsolated {
            if let c = self.connectCont { c.resume(returning: ()); self.connectCont = nil; return }
            // 予約しておいた再接続が成立した
            guard peripheral.identifier == self.pendingReconnect?.identifier, self.userWantsConnection else { return }
            self.pendingReconnect = nil
            self.peripheral = peripheral
            self.state = .connecting
            Task { @MainActor in
                do { try await self.setup(peripheral) }
                catch {
                    self.note("再接続に失敗：\(self.describe(error))")
                    central.cancelPeripheralConnection(peripheral)
                    self.state = .idle
                }
            }
        }
    }

    nonisolated func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral,
                                    error: Error?) {
        MainActor.assumeIsolated {
            self.connectCont?.resume(throwing: error ?? IQOSError.transport("接続に失敗"))
            self.connectCont = nil
        }
    }

    nonisolated func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral,
                                    error: Error?) {
        MainActor.assumeIsolated {
            guard peripheral.identifier == self.peripheral?.identifier else { return }
            self.note("切断" + (error.map { "：\($0.localizedDescription)" } ?? ""))
            let wasReady = self.state == .ready
            self.reset()
            self.state = .idle
            if wasReady && self.userWantsConnection {
                // 離れて切れたときは、近づけば自動でつながるように予約しておく（iOS が待ち続けてくれる）
                self.note("再接続を待っています")
                self.pendingReconnect = peripheral
                peripheral.delegate = self
                self.central.connect(peripheral)
            }
        }
    }

    nonisolated func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        MainActor.assumeIsolated {
            if let error { self.servicesCont?.resume(throwing: error) } else { self.servicesCont?.resume(returning: ()) }
            self.servicesCont = nil
        }
    }

    nonisolated func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService,
                                error: Error?) {
        MainActor.assumeIsolated {
            self.charsRemaining -= 1
            if self.charsRemaining <= 0 { self.charsCont?.resume(returning: ()); self.charsCont = nil }
        }
    }

    nonisolated func peripheral(_ peripheral: CBPeripheral, didUpdateNotificationStateFor characteristic: CBCharacteristic,
                                error: Error?) {
        MainActor.assumeIsolated {
            if let error { self.notifyCont?.resume(throwing: error) } else { self.notifyCont?.resume(returning: ()) }
            self.notifyCont = nil
        }
    }

    nonisolated func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic,
                                error: Error?) {
        let bytes = [UInt8](characteristic.value ?? Data())
        let key = characteristic.uuid.uuidString
        let isControl = characteristic.uuid == CBUUID(string: IQOSUUID.control)
        MainActor.assumeIsolated {
            if let pending = self.readConts.removeValue(forKey: key) {
                if let error { pending.resume(throwing: error) } else { pending.resume(returning: bytes) }
                return
            }
            guard isControl else { return }
            self.logBytes(.received, bytes)
            if let w = self.waiter, w.matcher.matches(bytes) {
                self.waiter = nil
                w.pending.resume(returning: bytes)
            }
        }
    }

    nonisolated func peripheral(_ peripheral: CBPeripheral, didWriteValueFor characteristic: CBCharacteristic,
                                error: Error?) {
        MainActor.assumeIsolated {
            while let first = self.writeConts.first, !first.isWaiting { self.writeConts.removeFirst() }
            guard !self.writeConts.isEmpty else { return }
            let pending = self.writeConts.removeFirst()
            if let error { pending.resume(throwing: error) } else { pending.resume(returning: ()) }
        }
    }
}

// MARK: - IQOSKit の通信の決まりに合わせる

/// IQOSClient に渡す本物の通信。命令は 1 本ずつ順番に流す。
struct BLETransport: IQOSTransport {
    let manager: BLEManager

    func send(_ frame: [UInt8]) async throws {
        try await manager.serial { try await manager.sendOnMain(frame) }
    }

    func request(_ frame: [UInt8], expecting matcher: ResponseMatcher) async throws -> [UInt8] {
        try await manager.serial { try await manager.requestOnMain(frame, matcher) }
    }

    func readBattery() async throws -> UInt8 {
        try await manager.serial { try await manager.readBatteryOnMain() }
    }
}
