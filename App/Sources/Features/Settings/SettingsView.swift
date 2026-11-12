import IQOSKit
import SwiftUI

struct SettingsView: View {
    @Environment(DeviceStore.self) private var store

    var body: some View {
        NavigationStack {
            Form {
                Section("ライト") {
                    LabeledContent("明るさ") {
                        Picker("明るさ", selection: Binding(
                            get: { store.brightness ?? .high },
                            set: { v in Task { await store.setBrightness(v) } })) {
                            Text("高").tag(Brightness.high)
                            Text("低").tag(Brightness.low)
                        }
                        .pickerStyle(.segmented)
                        .frame(width: 132)
                        .disabled(store.brightness == nil || store.busy.contains("brightness"))
                    }
                }

                Section("振動するタイミング") {
                    vibrationRow("加熱の開始", \.heatingStart)
                    vibrationRow("使用の開始", \.startingToUse)
                    vibrationRow("終了まぎわ", \.puffEnd)
                    vibrationRow("手動で止めたとき", \.manuallyTerminated)
                    if store.model.supportsChargeStartVibration {
                        SettingToggleRow(title: "充電の開始",
                                         isOn: store.vibration?.chargeStart,
                                         isBusy: store.busy.contains("vibration")) { on in
                            guard var v = store.vibration else { return }
                            v.chargeStart = on
                            Task { await store.setVibration(v) }
                        }
                    }
                }

                if store.model.supportsGestureAndAutoStart {
                    Section {
                        SettingToggleRow(title: "スマートジェスチャー",
                                         subtitle: "持ち上げて残量を表示",
                                         isOn: store.smartGesture,
                                         isBusy: store.busy.contains("smartGesture")) { on in
                            Task { await store.setSmartGesture(on) }
                        }
                        SettingToggleRow(title: "オートスタート",
                                         subtitle: "スティックを差すと加熱開始",
                                         isOn: store.autoStart,
                                         isBusy: store.busy.contains("autoStart")) { on in
                            Task { await store.setAutoStart(on) }
                        }
                    } header: {
                        Text("操作")
                    } footer: {
                        Text("スマートジェスチャーは本体から読み出せないため、この iPhone から最後に送った値を表示しています。")
                    }
                }

                Section {
                } footer: {
                    Text("変更は本体にすぐ送られ、読み直して確認します。")
                }
            }
            .navigationTitle("設定")
            .refreshable { await store.refreshAll() }
        }
    }

    private func vibrationRow(_ title: String, _ key: WritableKeyPath<VibrationSettings, Bool>) -> some View {
        SettingToggleRow(title: title,
                         isOn: store.vibration?[keyPath: key],
                         isBusy: store.busy.contains("vibration")) { on in
            guard var v = store.vibration else { return }
            v[keyPath: key] = on
            Task { await store.setVibration(v) }
        }
    }
}
