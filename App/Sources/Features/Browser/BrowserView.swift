import SwiftUI
import UIKit
import WebKit

/// IQOS 公式の Web アプリを開くアプリ内ブラウザ（Bluetooth つき）。
struct BrowserView: View {
    let startURL: URL
    var onClose: () -> Void

    @State private var bridge = WebBluetoothBridge()
    @State private var model = BrowserModel()
    @State private var acknowledged = false

    var body: some View {
        NavigationStack {
            ZStack(alignment: .top) {
                if acknowledged {
                    WebViewHost(url: startURL, bridge: bridge, model: model)
                        .ignoresSafeArea(edges: .bottom)
                    if model.progress < 1 {
                        ProgressView(value: model.progress)
                            .progressViewStyle(.linear)
                            .tint(Theme.accent)
                    }
                } else {
                    UpdateNotice { acknowledged = true }
                }
            }
            .navigationTitle(model.host ?? "IQOS 公式")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("閉じる") {
                        bridge.shutdown()
                        onClose()
                    }
                }
                if acknowledged {
                    ToolbarItemGroup(placement: .bottomBar) {
                        Button { model.webView?.goBack() } label: { Image(systemName: "chevron.backward") }
                            .disabled(!model.canGoBack)
                            .accessibilityLabel("戻る")
                        Button { model.webView?.goForward() } label: { Image(systemName: "chevron.forward") }
                            .disabled(!model.canGoForward)
                            .accessibilityLabel("進む")
                        Spacer()
                        if let a = bridge.activity {
                            Label(a, systemImage: "dot.radiowaves.left.and.right")
                                .font(.footnote)
                                .foregroundStyle(Theme.accent)
                        }
                        Spacer()
                        Button { model.webView?.reload() } label: { Image(systemName: "arrow.clockwise") }
                            .accessibilityLabel("再読み込み")
                    }
                }
            }
        }
        .sheet(item: $bridge.chooser) { _ in
            DeviceChooser(bridge: bridge)
                .presentationDetents([.medium])
                .interactiveDismissDisabled(false)
        }
        .onAppear { UIApplication.shared.isIdleTimerDisabled = true }
        .onDisappear {
            UIApplication.shared.isIdleTimerDisabled = false
            bridge.shutdown()
        }
    }
}

@MainActor
@Observable
final class BrowserModel {
    var progress: Double = 0
    var host: String?
    var canGoBack = false
    var canGoForward = false
    @ObservationIgnored weak var webView: WKWebView?
}

/// 更新の前に読んでもらう注意。
private struct UpdateNotice: View {
    var onContinue: () -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 40))
                    .foregroundStyle(.yellow)
                    .accessibilityHidden(true)
                Text("公式の Web アプリを開きます")
                    .font(.title2.bold())
                VStack(alignment: .leading, spacing: 10) {
                    bullet("ソフトウェアの更新中は、このアプリを閉じたり、画面を切り替えたりしないでください。")
                    bullet("チャージャーを十分に充電し、iPhone のすぐ近くに置いてください。")
                    bullet("このブラウザの Bluetooth の部分は非公式の仕組みです。心配な場合は、公式が案内している方法（Bluefy や PC）で更新してください。")
                    bullet("Bluetooth は IQOS 公式（iqos.com）のページからだけ使えます。")
                }
                .font(.body)
                PrimaryButton(title: "わかりました。開く", action: onContinue)
                    .padding(.top, 8)
            }
            .padding(24)
        }
    }

    private func bullet(_ s: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text("•").foregroundStyle(.secondary)
            Text(s)
        }
    }
}

/// ページが本体を求めたときに出す一覧。
private struct DeviceChooser: View {
    @Bindable var bridge: WebBluetoothBridge

    var body: some View {
        NavigationStack {
            List {
                if bridge.found.isEmpty {
                    HStack(spacing: 12) {
                        ProgressView()
                        Text("近くの本体を探しています…")
                            .foregroundStyle(.secondary)
                    }
                }
                ForEach(bridge.found) { d in
                    Button {
                        bridge.choose(d.id)
                    } label: {
                        HStack {
                            Image(systemName: "dot.radiowaves.left.and.right")
                                .foregroundStyle(Theme.accent)
                                .accessibilityHidden(true)
                            Text(d.name).foregroundStyle(.primary)
                            Spacer()
                            Text(SignalText.describe(d.rssi)).font(.footnote).foregroundStyle(.secondary)
                        }
                        .frame(minHeight: 44)
                    }
                }
            }
            .navigationTitle("接続する本体を選ぶ")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("キャンセル") { bridge.choose(nil) }
                }
            }
        }
        .onDisappear { if bridge.chooser != nil { bridge.choose(nil) } }
    }
}

/// WKWebView を SwiftUI に載せる。
private struct WebViewHost: UIViewRepresentable {
    let url: URL
    let bridge: WebBluetoothBridge
    let model: BrowserModel

    func makeCoordinator() -> Coordinator { Coordinator(model: model) }

    func makeUIView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        let content = WKUserContentController()
        if let path = Bundle.main.url(forResource: "webbluetooth", withExtension: "js"),
           let js = try? String(contentsOf: path, encoding: .utf8) {
            content.addUserScript(WKUserScript(source: js, injectionTime: .atDocumentStart, forMainFrameOnly: false))
        }
        content.addScriptMessageHandler(bridge, contentWorld: .page, name: "hlble")
        config.userContentController = content
        config.applicationNameForUserAgent = "HolderLink/1"
        config.allowsInlineMediaPlayback = true

        let web = WKWebView(frame: .zero, configuration: config)
        web.navigationDelegate = context.coordinator
        web.uiDelegate = context.coordinator
        web.allowsBackForwardNavigationGestures = true
        context.coordinator.observe(web)
        bridge.webView = web
        model.webView = web
        web.load(URLRequest(url: url))
        return web
    }

    func updateUIView(_ uiView: WKWebView, context: Context) {}

    static func dismantleUIView(_ uiView: WKWebView, coordinator: Coordinator) {
        uiView.configuration.userContentController.removeAllScriptMessageHandlers()
        coordinator.observations = []
    }

    @MainActor
    final class Coordinator: NSObject, WKNavigationDelegate, WKUIDelegate {
        let model: BrowserModel
        var observations: [NSKeyValueObservation] = []

        init(model: BrowserModel) { self.model = model }

        func observe(_ web: WKWebView) {
            observations = [
                web.observe(\.estimatedProgress) { [weak self] w, _ in
                    let v = w.estimatedProgress
                    Task { @MainActor in self?.model.progress = v }
                },
                web.observe(\.url) { [weak self] w, _ in
                    let h = w.url?.host
                    Task { @MainActor in self?.model.host = h }
                },
                web.observe(\.canGoBack) { [weak self] w, _ in
                    let v = w.canGoBack
                    Task { @MainActor in self?.model.canGoBack = v }
                },
                web.observe(\.canGoForward) { [weak self] w, _ in
                    let v = w.canGoForward
                    Task { @MainActor in self?.model.canGoForward = v }
                },
            ]
        }

        // 新しい窓で開くリンクは同じ画面で開く
        func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                     for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
            if navigationAction.targetFrame == nil { webView.load(navigationAction.request) }
            return nil
        }

        // http / https 以外（電話・メールなど）は iPhone 側に渡す
        func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                     decisionHandler: @escaping @MainActor @Sendable (WKNavigationActionPolicy) -> Void) {
            if let url = navigationAction.request.url, let scheme = url.scheme?.lowercased(),
               !["http", "https", "about", "blob", "data"].contains(scheme) {
                UIApplication.shared.open(url)
                decisionHandler(.cancel)
                return
            }
            decisionHandler(.allow)
        }

        func webView(_ webView: WKWebView, runJavaScriptAlertPanelWithMessage message: String,
                     initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping @MainActor @Sendable () -> Void) {
            present(UIAlertController(title: nil, message: message, preferredStyle: .alert), actions: [
                UIAlertAction(title: "OK", style: .default) { _ in completionHandler() },
            ], fallback: completionHandler)
        }

        func webView(_ webView: WKWebView, runJavaScriptConfirmPanelWithMessage message: String,
                     initiatedByFrame frame: WKFrameInfo,
                     completionHandler: @escaping @MainActor @Sendable (Bool) -> Void) {
            present(UIAlertController(title: nil, message: message, preferredStyle: .alert), actions: [
                UIAlertAction(title: "キャンセル", style: .cancel) { _ in completionHandler(false) },
                UIAlertAction(title: "OK", style: .default) { _ in completionHandler(true) },
            ], fallback: { completionHandler(false) })
        }

        private func present(_ alert: UIAlertController, actions: [UIAlertAction], fallback: @escaping () -> Void) {
            actions.forEach(alert.addAction)
            guard let root = UIApplication.shared.connectedScenes
                .compactMap({ ($0 as? UIWindowScene)?.keyWindow?.rootViewController }).first else {
                fallback()
                return
            }
            var top = root
            while let next = top.presentedViewController { top = next }
            top.present(alert, animated: true)
        }
    }
}

enum SignalText {
    static func describe(_ rssi: Int) -> String {
        switch rssi {
        case (-60)...: "電波 強い"
        case (-75)...: "電波 ふつう"
        default: "電波 弱い"
        }
    }
}
