import SwiftUI
import UIKit

struct ConnectView: View {
    @Environment(DeviceStore.self) private var store

    private var ble: BLEManager { store.ble }

    var body: some View {
        VStack(spacing: 0) {
            VStack(spacing: 6) {
                Text("HOLDER LINK")
                    .font(.system(size: 28, weight: .bold))
                    .tracking(1.5)
                Text("IQOS ILUMA とつなぐ")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            .padding(.top, 40)

            DeviceIllustration(scanning: ble.state == .scanning || ble.state == .connecting)
                .frame(height: 220)
                .padding(.vertical, 16)

            content
                .padding(.horizontal, 16)

            Spacer(minLength: 16)

            VStack(spacing: 10) {
                actionButton
                Button("IQOS 公式の Web アプリを開く") { store.openOfficialBrowser() }
                    .font(.footnote)
                Text("Bluetooth を使って通信します")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 16)
        }
        .background(Color(.systemGroupedBackground))
        .alert("接続できませんでした",
               isPresented: Binding(get: { ble.lastError != nil }, set: { if !$0 { ble.lastError = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(ble.lastError ?? "")
        }
    }

    @ViewBuilder private var content: some View {
        switch ble.state {
        case .unavailable(let reason):
            VStack(spacing: 12) {
                Label(reason, systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.secondary)
                Button("設定アプリを開く") {
                    if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
                }
            }
        case .connecting:
            HStack(spacing: 10) {
                ProgressView()
                Text("接続しています…").foregroundStyle(.secondary)
            }
        default:
            VStack(alignment: .leading, spacing: 8) {
                if !ble.discovered.isEmpty {
                    Text("見つかったデバイス")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .padding(.leading, 16)
                    VStack(spacing: 0) {
                        ForEach(ble.discovered) { d in
                            Button {
                                Task { await ble.connect(d.id) }
                            } label: {
                                DeviceRow(device: d)
                            }
                            .buttonStyle(.plain)
                            if d.id != ble.discovered.last?.id { Divider().padding(.leading, 66) }
                        }
                    }
                    .background(Color(.secondarySystemGroupedBackground),
                                in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                } else if ble.state == .scanning {
                    HStack(spacing: 10) {
                        ProgressView()
                        Text("近くの本体を探しています…").foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity)
                }
                Text("本体の電源を一度切ってから入れ直すと、Bluetooth がオンになります。iPhone の近くに置いてください。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: .infinity)
                    .padding(.top, 8)
            }
        }
    }

    @ViewBuilder private var actionButton: some View {
        if ble.state == .scanning {
            PrimaryButton(title: "探すのをやめる", isBusy: true) { ble.stopScan() }
        } else {
            PrimaryButton(title: "デバイスを探す") { ble.startScan() }
                .disabled(ble.state == .connecting)
                .opacity({ if case .unavailable = ble.state { return 0.4 }; return 1 }())
        }
    }
}

private struct DeviceRow: View {
    let device: DiscoveredDevice

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: "dot.radiowaves.left.and.right")
                .foregroundStyle(Theme.accent)
                .frame(width: 36, height: 36)
                .background(Theme.accent.opacity(0.16), in: Circle())
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(device.name).font(.headline)
                Text("\(SignalText.describe(device.rssi)) ・ タップして接続")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Image(systemName: "chevron.right")
                .foregroundStyle(.tertiary)
                .accessibilityHidden(true)
        }
        .padding(.horizontal, 16)
        .frame(minHeight: 68)
        .contentShape(Rectangle())
    }
}

/// チャージャーとホルダーの簡単な絵（探している間は輪が広がる）
private struct DeviceIllustration: View {
    let scanning: Bool
    @State private var pulse = false

    var body: some View {
        ZStack {
            Circle().stroke(Theme.accent.opacity(0.18), lineWidth: 1.5).frame(width: 192)
                .scaleEffect(pulse ? 1.08 : 1)
            Circle().stroke(Theme.accent.opacity(0.32), lineWidth: 1.5).frame(width: 140)
            HStack(spacing: 12) {
                RoundedRectangle(cornerRadius: 22, style: .continuous)
                    .fill(Color(.tertiarySystemFill))
                    .overlay(RoundedRectangle(cornerRadius: 22, style: .continuous).stroke(Color(.separator), lineWidth: 1.5))
                    .frame(width: 62, height: 128)
                    .overlay(alignment: .center) {
                        VStack(spacing: 7) {
                            ForEach(0..<4) { i in
                                Circle().fill(Theme.accent.opacity(i < 3 ? 1 : 0.3)).frame(width: 4, height: 4)
                            }
                        }
                        .offset(x: 10)
                    }
                Capsule()
                    .fill(Color(.systemGray3))
                    .frame(width: 16, height: 150)
                    .overlay(alignment: .top) { Capsule().fill(Color(.systemGray6)).frame(width: 10, height: 26) }
            }
        }
        .accessibilityHidden(true)
        .onAppear { withAnimation(.easeInOut(duration: 1.2).repeatForever()) { pulse = true } }
        .animation(.default, value: scanning)
    }
}
