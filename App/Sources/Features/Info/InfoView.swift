import IQOSKit
import SwiftUI
import UIKit

struct InfoView: View {
    @Environment(DeviceStore.self) private var store

    var body: some View {
        NavigationStack {
            Form {
                Section("本体") {
                    InfoRow(label: "機種", value: store.model.displayName)
                    InfoRow(label: "型番", value: store.chargerProduct, monospaced: true)
                    InfoRow(label: "シリアル", value: store.ble.deviceInfo[IQOSUUID.serialNumber], monospaced: true)
                }

                Section {
                    InfoRow(label: "チャージャー", value: store.chargerFirmware?.description, monospaced: true)
                    if store.model.hasHolder {
                        InfoRow(label: "ホルダー", value: store.holderFirmware?.description, monospaced: true)
                    }
                    Button {
                        store.openOfficialBrowser()
                    } label: {
                        Label("公式でアップデート", systemImage: "arrow.down.circle")
                    }
                } header: {
                    Text("ソフトウェア")
                } footer: {
                    Text("IQOS 公式の Web アプリをこのアプリの中で開きます。開いている間は、このアプリと本体の接続を一度切ります。")
                }

                Section("電池") {
                    InfoRow(label: "残量", value: store.battery.map { "\($0) %" })
                    InfoRow(label: "電圧", value: store.diagnostics.batteryVoltage.map { String(format: "%.2f V", $0) })
                }

                Section("調査用") {
                    NavigationLink {
                        LogView()
                    } label: {
                        LabeledContent("通信ログ", value: "\(store.ble.log.count) 件")
                    }
                }

                Section {
                    Button("接続を解除", role: .destructive) { store.ble.disconnect(forget: true) }
                        .frame(maxWidth: .infinity)
                } footer: {
                    Text("HOLDER LINK \(Bundle.main.shortVersion) ・ 非公式アプリ")
                        .frame(maxWidth: .infinity)
                }
            }
            .navigationTitle("情報")
        }
    }
}

struct LogView: View {
    @Environment(DeviceStore.self) private var store

    var body: some View {
        List(store.ble.log.reversed()) { e in
            VStack(alignment: .leading, spacing: 2) {
                HStack {
                    Text(e.direction.rawValue).font(.caption.bold())
                        .foregroundStyle(e.direction == .sent ? Theme.accent : (e.direction == .received ? .green : .secondary))
                    Text(e.time.formatted(.dateTime.hour().minute().second())).font(.caption).foregroundStyle(.secondary)
                }
                Text(e.text).font(.caption.monospaced()).textSelection(.enabled)
            }
        }
        .navigationTitle("通信ログ")
        .toolbar {
            ToolbarItemGroup(placement: .topBarTrailing) {
                Button("コピー") { UIPasteboard.general.string = exportText }
                Button("消去", role: .destructive) { store.ble.clearLog() }
            }
        }
    }

    private var exportText: String {
        let f = ISO8601DateFormatter()
        let head = "HOLDER LINK \(Bundle.main.shortVersion) / \(store.model.displayName) / iOS \(UIDevice.current.systemVersion)\n"
        return head + store.ble.log.map { "\(f.string(from: $0.time)) \($0.direction.rawValue) \($0.text)" }.joined(separator: "\n")
    }
}

extension Bundle {
    var shortVersion: String { infoDictionary?["CFBundleShortVersionString"] as? String ?? "?" }
}
