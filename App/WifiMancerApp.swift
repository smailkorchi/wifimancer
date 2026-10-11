import SwiftUI

@main
struct WifiMancerApp: App {

    @StateObject private var store = AppStore()
    @StateObject private var coord: AppCoordinator
    @StateObject private var helper = HelperClient.shared
    @StateObject private var known  = KnownNetworks.shared
    @StateObject private var loc    = LocationGate.shared

    private var availableWindowSize: CGSize {
        let visible = NSScreen.main?.visibleFrame.size ?? CGSize(width: 1440, height: 900)
        return CGSize(width: max(1, visible.width - 48),
                      height: max(1, visible.height - 48))
    }

    init() {
        let s = AppStore()
        _store = StateObject(wrappedValue: s)
        _coord = StateObject(wrappedValue: AppCoordinator(store: s))
        FontRegistrar.register()
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(store)
                .environmentObject(coord)
                .environmentObject(helper)
                .environmentObject(known)
                .environmentObject(loc)
                .frame(minWidth: min(1100, availableWindowSize.width),
                       minHeight: min(720, availableWindowSize.height))
                .preferredColorScheme(.dark)
                .task { await coord.boot() }
        }
        .defaultSize(width: min(1200, availableWindowSize.width),
                     height: min(840, availableWindowSize.height))
        .windowStyle(.hiddenTitleBar)
        .windowResizability(.contentMinSize)
        .commands {
            CommandGroup(replacing: .appInfo) { }
            CommandMenu("Network") {
                Button("Rescan now") { coord.startContinuousScan() }.keyboardShortcut("r")
                Button("Toggle Blocking") { Task { await coord.toggleBlocking() } }
                    .keyboardShortcut("b", modifiers: [.command, .shift])
            }
        }

        MenuBarExtra("Wifi Mancer", systemImage: "antenna.radiowaves.left.and.right") {
            MenuBarPanel()
                .environmentObject(store)
                .environmentObject(coord)
                .environmentObject(helper)
                .environmentObject(known)
                .environmentObject(loc)
        }
        .menuBarExtraStyle(.window)
    }
}
