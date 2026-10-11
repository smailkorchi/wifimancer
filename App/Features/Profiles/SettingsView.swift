import SwiftUI
import UserNotifications

struct SettingsView: View {
    @EnvironmentObject var helper: HelperClient
    @EnvironmentObject var store: AppStore
    @EnvironmentObject var coord: AppCoordinator
    @State private var pingResult: String?
    @State private var helperVersion: String?
    @State private var notifStatus: UNAuthorizationStatus = .notDetermined

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                SectionHeader("Settings", subtitle: "Helper · notifications · diagnostics")

                helperCard
                notificationsCard
                hotkeysCard
                aboutCard
            }
        }
        .task { await refreshNotifStatus() }
    }

    // MARK: helper

    private var helperCard: some View {
        BrandCard(padding: 18) {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    BreathingDot(color: helper.connected ? Brand.trust : Brand.cut)
                    Text("Privileged helper").bodyStyle(13, weight: .semibold)
                    Spacer()
                    Text(helper.statusText).bodyStyle(11, muted: true)
                }

                if let v = helperVersion {
                    Text("version \(v)").mono(11, muted: true)
                }
                if let p = pingResult {
                    Text("ping → \(p)").mono(11, muted: true)
                }

                HStack(spacing: 10) {
                    Button("Reinstall") {
                        Task {
                            try? await helper.install()
                            helper.connect()
                        }
                    }
                    .buttonStyle(GhostButton())

                    Button("Ping") {
                        Task { await ping() }
                    }
                    .buttonStyle(GhostButton())
                    .disabled(!helper.connected)

                    Button("Quit helper") {
                        helper.proxy()?.quit { _ in }
                    }
                    .buttonStyle(GhostButton(tint: Brand.cut))
                }
            }
        }
    }

    private func ping() async {
        await withCheckedContinuation { cont in
            helper.proxy()?.ping { reply in
                Task { @MainActor in
                    pingResult = reply
                    helper.proxy()?.version { v in
                        Task { @MainActor in helperVersion = v }
                    }
                    cont.resume()
                }
            }
        }
    }

    // MARK: notifications

    private var notificationsCard: some View {
        BrandCard(padding: 18) {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Image(systemName: "bell.badge")
                        .foregroundStyle(notifStatus == .authorized ? Brand.trust : Brand.warning)
                    Text("Notifications").bodyStyle(13, weight: .semibold)
                    Spacer()
                    Pill(text: notifLabel,
                         color: notifStatus == .authorized ? Brand.trust : Brand.warning)
                }
                Text("Wifi Mancer pings you when a brand-new device shows up on the network. Toggle per-network alerts in Profiles.")
                    .bodyStyle(11, muted: true)
                if notifStatus != .authorized {
                    Button("Enable in System Settings") {
                        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.notifications") {
                            NSWorkspace.shared.open(url)
                        }
                    }
                    .buttonStyle(GhostButton(tint: Brand.info))
                }
            }
        }
    }

    private var notifLabel: String {
        switch notifStatus {
        case .authorized: "Allowed"
        case .denied: "Denied"
        case .notDetermined: "Pending"
        case .provisional: "Provisional"
        case .ephemeral: "Ephemeral"
        @unknown default: "Unknown"
        }
    }

    private func refreshNotifStatus() async {
        let s = await UNUserNotificationCenter.current().notificationSettings()
        notifStatus = s.authorizationStatus
    }

    // MARK: hotkeys + about

    private var hotkeysCard: some View {
        BrandCard(padding: 18) {
            VStack(alignment: .leading, spacing: 8) {
                Text("Hotkeys").bodyStyle(12, weight: .semibold, muted: true)
                HotkeyRow(combo: "⌘ R",   label: "Rescan network now")
                HotkeyRow(combo: "⌘ ⇧ B", label: "Toggle blocking")
            }
        }
    }

    private var aboutCard: some View {
        BrandCard(padding: 18) {
            HStack(alignment: .top, spacing: 14) {
                // Brand mark in About — same icon as Sidebar / Menu / Dock so
                // the user has a stable "this is the app" anchor everywhere.
                Image("AppLogo")
                    .resizable()
                    .interpolation(.high)
                    .frame(width: 56, height: 56)
                    .shadow(color: Brand.cut.opacity(0.25), radius: 14, x: 0, y: 6)

                VStack(alignment: .leading, spacing: 6) {
                    Text("Wifi Mancer").bodyStyle(15, weight: .semibold)
                    Text("Version 1.0.0").mono(11, muted: true)
                    Text("Native macOS · libpcap · CoreWLAN · NDP-aware")
                        .bodyStyle(11, muted: true)
                    Button("Replay onboarding") {
                        UserDefaults.standard.set(false, forKey: "hasOnboarded")
                        store.hasOnboarded = false
                    }
                    .buttonStyle(GhostButton())
                    .padding(.top, 4)
                }
                Spacer(minLength: 0)
            }
        }
    }
}

private struct HotkeyRow: View {
    let combo: String
    let label: String
    var body: some View {
        HStack {
            Text(label).bodyStyle(13)
            Spacer()
            Text(combo)
                .mono(12)
                .padding(.horizontal, 8).padding(.vertical, 4)
                .background(RoundedRectangle(cornerRadius: 6).fill(Brand.surfaceHi))
        }
    }
}
