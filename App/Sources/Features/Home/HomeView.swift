import SwiftUI

struct HomeView: View {
    @Environment(DeviceStore.self) private var store

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    StatusPill(text: "接続中 ・ \(store.ble.deviceName)", connected: true)

                    BatteryRing(percent: store.battery, voltage: store.diagnostics.batteryVoltage)

                    HStack(spacing: 12) {
                        StatCard(value: store.diagnostics.totalCount.map { $0.formatted() } ?? "—",
                                 unit: "回", label: "累計の使用回数")
                        StatCard(value: store.diagnostics.daysUsed.map { $0.formatted() } ?? "—",
                                 unit: "日", label: "使用日数")
                    }

                    PrimaryButton(title: store.findingMe ? "振動を止める" : "本体を探す（振動）",
                                  systemImage: "waveform") {
                        store.toggleFindMe()
                    }

                    HStack(spacing: 14) {
                        Image(systemName: store.locked ? "lock.fill" : "lock.open")
                            .font(.title3)
                            .foregroundStyle(.secondary)
                            .frame(width: 24)
                            .accessibilityHidden(true)
                        SettingToggleRow(title: "本体をロック",
                                         subtitle: "オンの間は加熱できません",
                                         isOn: store.locked,
                                         isBusy: store.busy.contains("locked")) { on in
                            Task { await store.setLocked(on) }
                        }
                    }
                    .padding(.horizontal, 16)
                    .frame(minHeight: 68)
                    .background(Color(.secondarySystemGroupedBackground),
                                in: RoundedRectangle(cornerRadius: 12, style: .continuous))

                    Group {
                        if let t = store.lastUpdated {
                            Text("最終更新 \(t.formatted(date: .omitted, time: .shortened)) ・ 引き下げて更新")
                        } else {
                            Text("読み込み中…")
                        }
                    }
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .padding(.leading, 16)
                }
                .padding(16)
            }
            .background(Color(.systemGroupedBackground))
            .navigationTitle("ホーム")
            .refreshable { await store.refreshAll() }
        }
    }
}
