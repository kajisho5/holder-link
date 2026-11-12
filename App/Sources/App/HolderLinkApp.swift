import SwiftUI

@main
struct HolderLinkApp: App {
    @State private var store = DeviceStore()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(store)
                .tint(Theme.accent)
        }
    }
}

struct RootView: View {
    @Environment(DeviceStore.self) private var store
    @Environment(\.scenePhase) private var scenePhase
    @State private var tab = 0

    private var browserBinding: Binding<Bool> {
        Binding(get: { store.showOfficialBrowser }, set: { if !$0 { store.closeOfficialBrowser() } })
    }

    var body: some View {
        Group {
            if store.isReady {
                TabView(selection: $tab) {
                    Tab("ホーム", systemImage: "house.fill", value: 0) { HomeView() }
                    Tab("設定", systemImage: "slider.horizontal.3", value: 1) { SettingsView() }
                    Tab("情報", systemImage: "info.circle", value: 2) { InfoView() }
                }
            } else {
                ConnectView()
            }
        }
        .onChange(of: store.isReady) { _, ready in
            if ready { Task { await store.refreshAll() } } else { store.clear() }
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { Task { await store.refreshBattery() } }
        }
        .fullScreenCover(isPresented: browserBinding) {
            BrowserView(startURL: DeviceStore.officialUpdateURL) { store.closeOfficialBrowser() }
        }
        .alert("うまくいきませんでした",
               isPresented: Binding(get: { store.errorMessage != nil }, set: { if !$0 { store.errorMessage = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(store.errorMessage ?? "")
        }
    }
}
