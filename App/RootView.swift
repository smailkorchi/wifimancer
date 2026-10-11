import SwiftUI

struct RootView: View {
    @EnvironmentObject var store: AppStore
    @EnvironmentObject var coord: AppCoordinator
    @State private var flashTrigger: Int = 0

    var body: some View {
        ZStack {
            AmbientBackdrop()
            if !store.hasOnboarded {
                OnboardingView()
                    .transition(.opacity)
            } else {
                MainSplit()
                    .transition(.opacity.combined(with: .scale(scale: 1.02)))
            }
            // App-wide engagement flash. Fires every time `store.blocking`
            // transitions either way — a brief cut-orange wash makes the
            // moment of cut/release feel like an action, not a checkbox.
            EngagementFlash(trigger: flashTrigger,
                            color: store.blocking ? Brand.cut : Brand.trust)
                .ignoresSafeArea()
            ToastOverlay()
        }
        .animation(Motion.smooth, value: store.hasOnboarded)
        .onChange(of: store.blocking) { _, _ in flashTrigger &+= 1 }
    }
}

private struct MainSplit: View {
    @EnvironmentObject var store: AppStore

    var body: some View {
        // HSplitView has known rendering bugs on macOS 14+/26 where the inner
        // content can render blank. Static HStack avoids it entirely; we don't
        // actually need a draggable splitter.
        HStack(spacing: 0) {
            Sidebar()
                .frame(width: 240)
                .frame(maxHeight: .infinity)
                .background(Brand.surfaceLo.opacity(0.7))

            Rectangle()
                .fill(Brand.hairline)
                .frame(width: 1)
                .frame(maxHeight: .infinity)

            ZStack {
                Group {
                    switch store.tab {
                    case .recon:      ReconView()
                    case .arsenal:    ArsenalView()
                    case .lobby:      LobbyView()
                    case .devices:    DevicesView()
                    case .throughput: ThroughputView()
                    case .networks:   NetworksView()
                    case .profiles:   ProfilesView()
                    case .schedule:   ScheduleView()
                    case .settings:   SettingsView()
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .padding(24)
                .transition(.asymmetric(insertion: .move(edge: .trailing).combined(with: .opacity),
                                        removal: .opacity))
                .id(store.tab)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

private struct Sidebar: View {
    @EnvironmentObject var store: AppStore
    @EnvironmentObject var coord: AppCoordinator

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 10) {
                // Real app logo here — same image the user sees in
                // /Applications and the menubar dropdown. Replaces the
                // generic SF-Symbol-on-orange-tile that didn't match the
                // shipped app-icon design.
                Image("AppLogo")
                    .resizable()
                    .interpolation(.high)
                    .frame(width: 30, height: 30)
                Text("Wifi Mancer").display(20, weight: .semibold)
            }
            .padding(.top, 40)
            .padding(.horizontal, 18)

            ContextHeader()
                .padding(.horizontal, 10)

            ScrollView {
                VStack(spacing: 4) {
                    ForEach(AppStore.Tab.allCases) { t in
                        SidebarRow(tab: t, selected: store.tab == t) {
                            withAnimation(Motion.smooth) { store.tab = t }
                        }
                    }
                }
                .padding(.horizontal, 10)
            }
            .frame(maxHeight: .infinity)

            BlockToggle()
                .padding(.horizontal, 14)
                .padding(.bottom, 18)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

private struct ContextHeader: View {
    @EnvironmentObject var store: AppStore

    var body: some View {
        let ssid = store.context?.ssid
        // "Connected" = we have a context AND the SSID actually resolved.
        // The breathing dot uses this to switch between trust-green when
        // we know the network and muted when we're still resolving.
        let connected = (ssid?.isEmpty == false) && ssid != "<redacted>"

        VStack(alignment: .leading, spacing: 0) {
            // Top: status dot + SSID. SSID truncates middle so long names
            // ("Cafe Des voyageurs 2.4G") still show identifying head + tail
            // characters at the sidebar's narrow width.
            HStack(spacing: 10) {
                BreathingDot(color: connected ? Brand.trust : Brand.muted)
                Text(ssid ?? "Searching…")
                    .font(BrandFont.heading(15, weight: .semibold))
                    .foregroundStyle(connected ? Brand.light : Brand.muted)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 14)
            .padding(.top, 12)

            // Subnet — small mono row directly under the SSID.
            Text(store.context?.subnetCIDR ?? "—.—.—.—/—")
                .font(BrandFont.mono(11))
                .foregroundStyle(Brand.mutedDim)
                .padding(.horizontal, 14)
                .padding(.top, 3)

            // Hairline separator before the stats row so the card has a
            // top "identity" zone and a bottom "stats" zone — mirrors the
            // information hierarchy the rest of the app uses.
            Rectangle()
                .fill(Brand.hairline)
                .frame(height: 1)
                .padding(.top, 10)

            // Stats row: IP version + device count. Capsule chips are more
            // glanceable than the previous Pill component at this scale.
            HStack(spacing: 6) {
                ContextChip(text: store.context?.ipv6Active == true ? "v4 + v6" : "v4",
                            tint: Brand.info)
                ContextChip(text: "\(store.devices.count) devices",
                            tint: Brand.muted)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(LinearGradient(colors: [Brand.surface, Brand.surfaceLo],
                                     startPoint: .top, endPoint: .bottom))
                .overlay(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .stroke(Brand.hairline, lineWidth: 1)
                )
        )
        .shadow(color: .black.opacity(0.25), radius: 8, x: 0, y: 2)
    }
}

private struct ContextChip: View {
    let text: String
    let tint: Color
    var body: some View {
        Text(text)
            .font(BrandFont.heading(10, weight: .semibold))
            .foregroundStyle(tint)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(
                Capsule()
                    .fill(tint.opacity(0.12))
                    .overlay(Capsule().stroke(tint.opacity(0.3), lineWidth: 0.5))
            )
    }
}

private struct SidebarRow: View {
    let tab: AppStore.Tab
    let selected: Bool
    let action: () -> Void

    @State private var hover = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: tab.icon)
                    .font(.system(size: 13,
                                  weight: selected ? .bold : .semibold))
                    .frame(width: 18)
                Text(tab.label)
                    .font(BrandFont.heading(13,
                                            weight: selected ? .semibold : .medium))
                    .tracking(selected ? 0.2 : 0)
                Spacer()
                // Selection bar — heavier, fully rounded pill, glows in cut-orange.
                // Reads as a confident "you are here" marker rather than a thin
                // accent. Slides in/out with the selection change.
                Capsule()
                    .fill(Brand.cut)
                    .frame(width: 4, height: 22)
                    .shadow(color: Brand.cut.opacity(selected ? 0.6 : 0),
                            radius: 6, x: 0, y: 0)
                    .scaleEffect(y: selected ? 1.0 : 0.0, anchor: .center)
                    .opacity(selected ? 1 : 0)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .foregroundStyle(selected ? Brand.light : Brand.muted)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(selected ? Brand.surfaceHi : (hover ? Brand.surface : Color.clear))
                    .overlay(
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .stroke(selected ? Brand.hairline : Color.clear, lineWidth: 0.75)
                    )
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
        .animation(Motion.snap, value: hover)
        .animation(Motion.smooth, value: selected)
    }
}

private struct BlockToggle: View {
    @EnvironmentObject var store: AppStore
    @EnvironmentObject var coord: AppCoordinator

    var body: some View {
        let cutCount = store.armedTargetIPv4s.count
        let pending = !store.helperSessionReady || store.startingBlocking || store.stoppingBlocking
        let statusColor = pending ? Brand.warning : (store.blocking ? Brand.cut : Brand.mutedDim)

        BrandCard(padding: 16) {
            VStack(alignment: .leading, spacing: 14) {
                // Top row: state label + breathing dot. The label is the most
                // prominent text in the entire sidebar when cut is engaged —
                // bold, all-caps, tightly tracked, in cut-orange. Reads as
                // status, not decoration.
                HStack(alignment: .center) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(!store.helperSessionReady ? "PREPARING" : store.startingBlocking ? "STARTING" : store.stoppingBlocking ? "STOPPING" : store.blocking ? "ARMED" : "IDLE")
                            .font(BrandFont.heading(11, weight: .bold))
                            .tracking(2.0)
                            .foregroundStyle(statusColor)
                            .contentTransition(.opacity)
                        Text(!store.helperSessionReady ? "ending previous helper session" : store.startingBlocking ? "preparing IPv4 targets" : store.stoppingBlocking ? "waiting for helper to stop" : store.blocking
                                ? "untrusted IPv4 devices"
                                : "toggle to cut untrusted")
                            .bodyStyle(11, muted: true)
                            .contentTransition(.opacity)
                    }
                    Spacer()
                    BreathingDot(
                        color: statusColor,
                        intensity: store.blocking ? 3.2 : 2.0,
                        period:    store.blocking ? 0.85 : 1.6
                    )
                    .id(store.blocking ? "dot-on" : "dot-off")  // restart anim
                }

                // Count helper-accepted targets, not assumed offline devices.
                if store.blocking {
                    HStack(alignment: .lastTextBaseline, spacing: 6) {
                        Text("\(cutCount)")
                            .font(.system(size: 34, weight: .heavy, design: .rounded))
                            .monospacedDigit()
                            .foregroundStyle(Brand.cut)
                            .contentTransition(.numericText())
                        Text(cutCount == 1 ? "device targeted" : "devices targeted")
                            .bodyStyle(12, muted: true)
                            .padding(.bottom, 4)
                        Spacer(minLength: 0)
                    }
                    .transition(.opacity.combined(with: .scale(scale: 0.96, anchor: .leading)))
                }

                BrandSwitch(
                    isOn: Binding(
                        get: { store.blockingRequested },
                        set: { _ in
                            Task { await coord.toggleBlocking() }
                        }),
                    onColor: Brand.cut,
                    offColor: Brand.mutedDim,
                    label: (on: store.startingBlocking ? "Cancel" : "Armed",
                            off: !store.helperSessionReady ? "Preparing…" : store.stoppingBlocking ? "Stopping…" : "Engage")
                )
                .frame(maxWidth: .infinity, alignment: .leading)
                .disabled(!store.helperSessionReady || store.stoppingBlocking)
            }
        }
        .pulsingBorder(active: store.blocking, color: Brand.cut, radius: 14)
        .animation(Motion.smooth, value: store.blocking)
    }
}

private struct ToastOverlay: View {
    @EnvironmentObject var store: AppStore
    var body: some View {
        VStack {
            if let m = store.toastMessage {
                HStack(spacing: 10) {
                    Image(systemName: "info.circle.fill").foregroundStyle(Brand.info)
                    Text(m).bodyStyle(13)
                }
                .padding(.horizontal, 16).padding(.vertical, 10)
                .background(.ultraThinMaterial, in: Capsule())
                .overlay(Capsule().stroke(Brand.hairline, lineWidth: 1))
                .transition(.move(edge: .top).combined(with: .opacity))
                .padding(.top, 12)
            }
            Spacer()
        }
        .animation(Motion.smooth, value: store.toastMessage)
        .frame(maxWidth: .infinity)
    }
}
