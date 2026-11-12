import SwiftUI
import UIKit

enum Theme {
    /// SVG デザインの差し色（#40C8E0）。ライト表示では少し濃くして読みやすくする。
    static let accent = Color(light: Color(red: 0.0, green: 0.55, blue: 0.68),
                              dark: Color(red: 0.25, green: 0.78, blue: 0.88))
}

extension Color {
    init(light: Color, dark: Color) {
        self.init(UIColor { $0.userInterfaceStyle == .dark ? UIColor(dark) : UIColor(light) })
    }
}

/// 主ボタン（高さ 50pt）
struct PrimaryButton: View {
    let title: String
    var systemImage: String?
    var isBusy = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                if isBusy { ProgressView().tint(.black) }
                else if let systemImage { Image(systemName: systemImage).accessibilityHidden(true) }
                Text(title).font(.headline)
            }
            .frame(maxWidth: .infinity, minHeight: 50)
            .foregroundStyle(.black)
            .background(Theme.accent, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
        .buttonStyle(.plain)
    }
}

/// 接続中／未接続の小さな表示
struct StatusPill: View {
    let text: String
    let connected: Bool

    var body: some View {
        HStack(spacing: 6) {
            Circle().fill(connected ? Color.green : Color.secondary).frame(width: 8, height: 8)
            Text(text).font(.footnote.weight(.semibold))
        }
        .foregroundStyle(connected ? Color.green : Color.secondary)
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background((connected ? Color.green : Color.secondary).opacity(0.15), in: Capsule())
        .accessibilityElement(children: .combine)
    }
}

/// 残量の輪
struct BatteryRing: View {
    let percent: UInt8?
    let voltage: Double?

    var body: some View {
        VStack(spacing: 12) {
            ZStack {
                Circle().stroke(Color(.tertiarySystemFill), lineWidth: 14)
                Circle()
                    .trim(from: 0, to: CGFloat(percent ?? 0) / 100)
                    .stroke(Theme.accent, style: StrokeStyle(lineWidth: 14, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                    .animation(.easeOut(duration: 0.4), value: percent)
                VStack(spacing: 2) {
                    HStack(alignment: .firstTextBaseline, spacing: 2) {
                        Text(percent.map { "\($0)" } ?? "—").font(.system(size: 52, weight: .bold, design: .rounded))
                        Text("%").font(.title3).foregroundStyle(.secondary)
                    }
                    Text("バッテリー").font(.footnote).foregroundStyle(.secondary)
                }
            }
            .frame(width: 170, height: 170)
            Text("電圧 " + (voltage.map { String(format: "%.2f V", $0) } ?? "—"))
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 24)
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("バッテリー残量 " + (percent.map { "\($0) パーセント" } ?? "不明"))
    }
}

/// 数字＋ラベルの小カード
struct StatCard: View {
    let value: String
    let unit: String
    let label: String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text(value).font(.system(size: 30, weight: .bold, design: .rounded))
                Text(unit).font(.subheadline).foregroundStyle(.secondary)
            }
            Text(label).font(.footnote).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .accessibilityElement(children: .combine)
    }
}

/// ラベル＋説明＋スイッチ（送信中は操作不可）
struct SettingToggleRow: View {
    let title: String
    var subtitle: String?
    let isOn: Bool?
    var isBusy = false
    let onChange: (Bool) -> Void

    var body: some View {
        Toggle(isOn: Binding(get: { isOn ?? false }, set: onChange)) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                if let subtitle { Text(subtitle).font(.footnote).foregroundStyle(.secondary) }
            }
        }
        .tint(.green)
        .disabled(isOn == nil || isBusy)
        .overlay(alignment: .trailing) {
            if isBusy { ProgressView().padding(.trailing, 64) }
        }
    }
}

/// ラベル＋値（長押しでコピー）
struct InfoRow: View {
    let label: String
    let value: String?
    var monospaced = false

    var body: some View {
        LabeledContent(label) {
            Text(value ?? "—")
                .font(monospaced ? .callout.monospaced() : .body)
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
        }
        .contextMenu {
            if let value { Button("コピー", systemImage: "doc.on.doc") { UIPasteboard.general.string = value } }
        }
    }
}
