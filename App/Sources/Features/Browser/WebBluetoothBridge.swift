import CoreBluetooth
import Foundation
import Observation
import WebKit

/// アプリ内ブラウザの navigator.bluetooth を CoreBluetooth につなぐ橋。
/// 安全のため、IQOS 公式（iqos.com とその下）のページからの依頼にだけ答える。
@MainActor
@Observable
final class WebBluetoothBridge: NSObject {
    struct Filter {
        var name: String?
        var namePrefix: String?
        var services: [CBUUID]
    }

    /// 本体を選ぶシート
    struct Chooser: Identifiable {
        let id = UUID()
        var filters: [Filter]
        var acceptAll: Bool
    }

    var chooser: Chooser?
    var found: [DiscoveredDevice] = []
    var poweredOn = false
    var activity: String?      // 「通信中」の表示用
    var transferCount = 0

    @ObservationIgnored weak var webView: WKWebView?
    @ObservationIgnored private var central: CBCentralManager!
    @ObservationIgnored private var peripherals: [UUID: CBPeripheral] = [:]
    @ObservationIgnored private var advServices: [UUID: [CBUUID]] = [:]
    @ObservationIgnored private var names: [UUID: String] = [:]
    @ObservationIgnored private var chooserPending: Pending<UUID?>?

    @ObservationIgnored private var services: [Int: CBService] = [:]
    @ObservationIgnored private var characteristics: [Int: CBCharacteristic] = [:]
    @ObservationIgnored private var handleOf: [ObjectIdentifier: Int] = [:]
    @ObservationIgnored private var nextHandle = 1

    @ObservationIgnored private var connectWait: [UUID: Pending<Void>] = [:]
    @ObservationIgnored private var servicesWait: [UUID: Pending<Void>] = [:]
    @ObservationIgnored private var charsWait: [ObjectIdentifier: Pending<Void>] = [:]
    @ObservationIgnored private var readWait: [ObjectIdentifier: [Pending<[UInt8]>]] = [:]
    @ObservationIgnored private var writeWait: [ObjectIdentifier: [Pending<Void>]] = [:]
    @ObservationIgnored private var notifyWait: [ObjectIdentifier: Pending<Void>] = [:]
    @ObservationIgnored private var sendReady: [Pending<Void>] = []
    @ObservationIgnored private var powerWait: [Pending<Void>] = []

    static let allowedHostSuffix = "iqos.com"
    static let base = "-0000-1000-8000-00805f9b34fb"

    override init() {
        super.init()
        central = CBCentralManager(delegate: self, queue: .main)
    }

    /// ブラウザを閉じるときに全部切る。
    func shutdown() {
        central.stopScan()
        for p in peripherals.values where p.state != .disconnected { central.cancelPeripheralConnection(p) }
        chooserPending?.resume(returning: nil)
    }

    static func isAllowed(_ host: String?) -> Bool {
        guard let h = host?.lowercased() else { return false }
        return h == allowedHostSuffix || h.hasSuffix("." + allowedHostSuffix)
    }

    // MARK: UUID の形をそろえる

    static func canonical(_ u: CBUUID) -> String {
        let s = u.uuidString.lowercased()
        switch s.count {
        case 4: return "0000" + s + base
        case 8: return s + base
        default: return s
        }
    }

    private func handle(for object: AnyObject) -> Int {
        let key = ObjectIdentifier(object)
        if let h = handleOf[key] { return h }
        let h = nextHandle
        nextHandle += 1
        handleOf[key] = h
        return h
    }

    // MARK: 依頼の処理

    private func perform(op: String, args: [String: Any]) async throws -> Any {
        switch op {
        case "availability":
            return central.state != .unsupported && central.state != .unauthorized
        case "knownDevices":
            return peripherals.values.filter { $0.state == .connected }.map { ["id": $0.identifier.uuidString, "name": names[$0.identifier] ?? $0.name ?? ""] }
        case "requestDevice":
            return try await requestDevice(args)
        case "connect":
            let p = try peripheral(args)
            try await waitPoweredOn()
            if p.state != .connected {
                let w = Pending<Void>()
                connectWait[p.identifier] = w
                central.connect(p)
                try await timeout(w, .seconds(20))
            }
            return true
        case "disconnect":
            if let p = try? peripheral(args) { central.cancelPeripheralConnection(p) }
            return true
        case "services":
            let p = try peripheral(args)
            if p.services == nil {
                let w = Pending<Void>()
                servicesWait[p.identifier] = w
                p.discoverServices(nil)
                try await timeout(w, .seconds(15))
            }
            let filter = (args["uuid"] as? String).map { $0.lowercased() }
            return (p.services ?? [])
                .filter { filter == nil || Self.canonical($0.uuid) == filter }
                .map { s -> [String: Any] in
                    let h = handle(for: s)
                    services[h] = s
                    return ["handle": h, "uuid": Self.canonical(s.uuid)]
                }
        case "characteristics":
            guard let h = args["service"] as? Int, let s = services[h], let p = s.peripheral else {
                throw BridgeError("InvalidStateError: サービスが無効です")
            }
            if s.characteristics == nil {
                let w = Pending<Void>()
                charsWait[ObjectIdentifier(s)] = w
                p.discoverCharacteristics(nil, for: s)
                try await timeout(w, .seconds(15))
            }
            let filter = (args["uuid"] as? String).map { $0.lowercased() }
            return (s.characteristics ?? [])
                .filter { filter == nil || Self.canonical($0.uuid) == filter }
                .map { c -> [String: Any] in
                    let ch = handle(for: c)
                    characteristics[ch] = c
                    let pr = c.properties
                    return ["handle": ch, "uuid": Self.canonical(c.uuid), "props": [
                        "broadcast": pr.contains(.broadcast), "read": pr.contains(.read),
                        "writeWithoutResponse": pr.contains(.writeWithoutResponse), "write": pr.contains(.write),
                        "notify": pr.contains(.notify), "indicate": pr.contains(.indicate),
                        "authenticatedSignedWrites": pr.contains(.authenticatedSignedWrites),
                        "reliableWrite": false, "writableAuxiliaries": false,
                    ]]
                }
        case "read":
            let (p, c) = try characteristic(args)
            let w = Pending<[UInt8]>()
            readWait[ObjectIdentifier(c), default: []].append(w)
            p.readValue(for: c)
            return try await timeout(w, .seconds(10))
        case "write":
            let (p, c) = try characteristic(args)
            let bytes = (args["bytes"] as? [Any] ?? []).compactMap { ($0 as? NSNumber)?.uint8Value }
            let withResponse = args["response"] as? Bool ?? true
            let type: CBCharacteristicWriteType = withResponse ? .withResponse : .withoutResponse
            let maxLen = p.maximumWriteValueLength(for: type)
            guard bytes.count <= maxLen else {
                throw BridgeError("NotSupportedError: 1 回に送れる長さ（\(maxLen) バイト）を超えています")
            }
            transferCount += 1
            activity = "本体と通信中"
            if withResponse {
                let w = Pending<Void>()
                writeWait[ObjectIdentifier(c), default: []].append(w)
                p.writeValue(Data(bytes), for: c, type: .withResponse)
                try await timeout(w, .seconds(10))
            } else {
                // 送り過ぎて取りこぼさないよう、iPhone 側の送信待ちが空くまで待つ
                while !p.canSendWriteWithoutResponse {
                    let w = Pending<Void>()
                    sendReady.append(w)
                    try await timeout(w, .seconds(10))
                }
                p.writeValue(Data(bytes), for: c, type: .withoutResponse)
            }
            return true
        case "notify":
            let (p, c) = try characteristic(args)
            let on = args["on"] as? Bool ?? true
            let w = Pending<Void>()
            notifyWait[ObjectIdentifier(c)] = w
            p.setNotifyValue(on, for: c)
            try await timeout(w, .seconds(10))
            return true
        default:
            throw BridgeError("NotSupportedError: \(op) には未対応です")
        }
    }

    private func peripheral(_ args: [String: Any]) throws -> CBPeripheral {
        guard let s = args["id"] as? String, let id = UUID(uuidString: s), let p = peripherals[id] else {
            throw BridgeError("NotFoundError: 本体が見つかりません")
        }
        return p
    }

    private func characteristic(_ args: [String: Any]) throws -> (CBPeripheral, CBCharacteristic) {
        guard let h = args["handle"] as? Int, let c = characteristics[h], let p = c.service?.peripheral else {
            throw BridgeError("InvalidStateError: キャラクタリスティックが無効です")
        }
        guard p.state == .connected else { throw BridgeError("NetworkError: 接続されていません") }
        return (p, c)
    }

    private func requestDevice(_ args: [String: Any]) async throws -> Any {
        try await waitPoweredOn()
        let filters = (args["filters"] as? [[String: Any]] ?? []).map { f in
            Filter(name: f["name"] as? String, namePrefix: f["namePrefix"] as? String,
                   services: (f["services"] as? [String] ?? []).map { CBUUID(string: $0) })
        }
        found = []
        let pending = Pending<UUID?>()
        chooserPending?.resume(returning: nil)
        chooserPending = pending
        chooser = Chooser(filters: filters, acceptAll: args["acceptAll"] as? Bool ?? false)
        central.scanForPeripherals(withServices: nil, options: [CBCentralManagerScanOptionAllowDuplicatesKey: false])
        let picked = try await pending.value()
        central.stopScan()
        chooser = nil
        guard let id = picked, peripherals[id] != nil else {
            throw BridgeError("NotFoundError: 本体の選択がキャンセルされました")
        }
        return ["id": id.uuidString, "name": names[id] ?? ""]
    }

    /// シートで選ばれた（または閉じられた）。
    func choose(_ id: UUID?) {
        chooserPending?.resume(returning: id)
        chooserPending = nil
        chooser = nil
        central.stopScan()
    }

    private func matches(_ id: UUID) -> Bool {
        guard let c = chooser else { return false }
        if c.acceptAll { return true }
        let name = names[id] ?? ""
        let adv = Set(advServices[id] ?? [])
        return c.filters.contains { f in
            if let n = f.name, n != name { return false }
            if let pre = f.namePrefix, !name.hasPrefix(pre) { return false }
            if !f.services.isEmpty && !Set(f.services).isSubset(of: adv) {
                // サービスを広告しない機器もあるので、名前の条件があればそれで良しとする
                return f.name != nil || f.namePrefix != nil
            }
            return f.name != nil || f.namePrefix != nil || !f.services.isEmpty
        }
    }

    private func waitPoweredOn() async throws {
        if central.state == .poweredOn { return }
        if central.state == .unauthorized || central.state == .unsupported || central.state == .poweredOff {
            throw BridgeError("NotFoundError: Bluetooth が使えません")
        }
        let w = Pending<Void>()
        powerWait.append(w)
        try await timeout(w, .seconds(5))
    }

    private func timeout<T>(_ p: Pending<T>, _ limit: Duration) async throws -> T {
        Task { @MainActor in
            try? await Task.sleep(for: limit)
            p.resume(throwing: BridgeError("NetworkError: 時間切れです"))
        }
        return try await p.value()
    }

    private func emit(_ js: String) {
        webView?.evaluateJavaScript(js, completionHandler: nil)
    }
}

struct BridgeError: Error, CustomStringConvertible {
    let description: String
    init(_ d: String) { description = d }
}

// MARK: - ページからの依頼

extension WebBluetoothBridge: WKScriptMessageHandlerWithReply {
    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage,
                               replyHandler: @escaping @MainActor @Sendable (Any?, String?) -> Void) {
        let host = message.frameInfo.securityOrigin.host
        guard Self.isAllowed(host) else {
            replyHandler(nil, "SecurityError: このページからは Bluetooth を使えません（IQOS 公式のページのみ）")
            return
        }
        guard let body = message.body as? [String: Any], let op = body["op"] as? String else {
            replyHandler(nil, "NotSupportedError: 依頼の形が不正です")
            return
        }
        let args = body["args"] as? [String: Any] ?? [:]
        Task { @MainActor in
            do { replyHandler(try await self.perform(op: op, args: args), nil) }
            catch let e as BridgeError { replyHandler(nil, e.description) }
            catch { replyHandler(nil, "NetworkError: \(error.localizedDescription)") }
            if op == "write" { self.activity = nil }
        }
    }
}

// MARK: - CoreBluetooth からの知らせ

extension WebBluetoothBridge: CBCentralManagerDelegate, CBPeripheralDelegate {
    nonisolated func centralManagerDidUpdateState(_ central: CBCentralManager) {
        let on = central.state == .poweredOn
        MainActor.assumeIsolated {
            self.poweredOn = on
            if on { self.powerWait.forEach { $0.resume(returning: ()) }; self.powerWait = [] }
        }
    }

    nonisolated func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral,
                                    advertisementData: [String: Any], rssi RSSI: NSNumber) {
        let name = (advertisementData[CBAdvertisementDataLocalNameKey] as? String) ?? peripheral.name ?? ""
        let adv = advertisementData[CBAdvertisementDataServiceUUIDsKey] as? [CBUUID] ?? []
        let rssi = RSSI.intValue
        MainActor.assumeIsolated {
            let id = peripheral.identifier
            self.peripherals[id] = peripheral
            self.names[id] = name
            self.advServices[id] = adv
            peripheral.delegate = self
            guard !name.isEmpty, self.matches(id) else { return }
            if let i = self.found.firstIndex(where: { $0.id == id }) { self.found[i].rssi = rssi }
            else { self.found.append(DiscoveredDevice(id: id, name: name, rssi: rssi)) }
        }
    }

    nonisolated func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        MainActor.assumeIsolated { self.connectWait.removeValue(forKey: peripheral.identifier)?.resume(returning: ()) }
    }

    nonisolated func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        MainActor.assumeIsolated {
            self.connectWait.removeValue(forKey: peripheral.identifier)?
                .resume(throwing: BridgeError("NetworkError: 接続できませんでした"))
        }
    }

    nonisolated func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral,
                                    error: Error?) {
        MainActor.assumeIsolated {
            let err = BridgeError("NetworkError: 接続が切れました")
            for s in peripheral.services ?? [] {
                for c in s.characteristics ?? [] {
                    let k = ObjectIdentifier(c)
                    self.readWait.removeValue(forKey: k)?.forEach { $0.resume(throwing: err) }
                    self.writeWait.removeValue(forKey: k)?.forEach { $0.resume(throwing: err) }
                    self.notifyWait.removeValue(forKey: k)?.resume(throwing: err)
                }
            }
            self.sendReady.forEach { $0.resume(throwing: err) }
            self.sendReady = []
            self.activity = nil
            self.emit("window.__hlble && window.__hlble.disconnected('\(peripheral.identifier.uuidString)')")
        }
    }

    nonisolated func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        MainActor.assumeIsolated {
            let w = self.servicesWait.removeValue(forKey: peripheral.identifier)
            if let error { w?.resume(throwing: BridgeError("NetworkError: \(error.localizedDescription)")) }
            else { w?.resume(returning: ()) }
        }
    }

    nonisolated func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        MainActor.assumeIsolated {
            let w = self.charsWait.removeValue(forKey: ObjectIdentifier(service))
            if let error { w?.resume(throwing: BridgeError("NetworkError: \(error.localizedDescription)")) }
            else { w?.resume(returning: ()) }
        }
    }

    nonisolated func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic,
                                error: Error?) {
        let bytes = [UInt8](characteristic.value ?? Data())
        MainActor.assumeIsolated {
            let k = ObjectIdentifier(characteristic)
            if var list = self.readWait[k], !list.isEmpty {
                let w = list.removeFirst()
                self.readWait[k] = list
                if let error { w.resume(throwing: BridgeError("NetworkError: \(error.localizedDescription)")) }
                else { w.resume(returning: bytes) }
                return   // 読み取りの結果は readValue 側で value を更新して通知する
            }
            guard let h = self.handleOf[k] else { return }
            let list = bytes.map(String.init).joined(separator: ",")
            self.emit("window.__hlble && window.__hlble.value(\(h), [\(list)])")
        }
    }

    nonisolated func peripheral(_ peripheral: CBPeripheral, didWriteValueFor characteristic: CBCharacteristic, error: Error?) {
        MainActor.assumeIsolated {
            let k = ObjectIdentifier(characteristic)
            guard var list = self.writeWait[k], !list.isEmpty else { return }
            let w = list.removeFirst()
            self.writeWait[k] = list
            if let error { w.resume(throwing: BridgeError("NetworkError: \(error.localizedDescription)")) }
            else { w.resume(returning: ()) }
        }
    }

    nonisolated func peripheral(_ peripheral: CBPeripheral, didUpdateNotificationStateFor characteristic: CBCharacteristic,
                                error: Error?) {
        MainActor.assumeIsolated {
            let w = self.notifyWait.removeValue(forKey: ObjectIdentifier(characteristic))
            if let error { w?.resume(throwing: BridgeError("NetworkError: \(error.localizedDescription)")) }
            else { w?.resume(returning: ()) }
        }
    }

    nonisolated func peripheralIsReady(toSendWriteWithoutResponse peripheral: CBPeripheral) {
        MainActor.assumeIsolated {
            let waiting = self.sendReady
            self.sendReady = []
            waiting.forEach { $0.resume(returning: ()) }
        }
    }
}
