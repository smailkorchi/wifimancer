import SwiftUI

/// Four-step first-launch flow: welcome → helper → location → ready.
/// Each step has a single hero element, a tight headline, body copy, and
/// any relevant live status. The plasma backdrop is the same throughout
/// for visual continuity; only the foreground composition changes.
struct OnboardingView: View {
    @EnvironmentObject var store: AppStore
    @EnvironmentObject var coord: AppCoordinator
    @EnvironmentObject var helper: HelperClient
    @EnvironmentObject var loc:    LocationGate

    @State private var step: Int = 0
    @State private var bannerProgress: CGFloat = 0
    @State private var heroPulse: Bool = false

    private let totalSteps = 4

    var body: some View {
        ZStack {
            BannerShader(progress: bannerProgress)
                .ignoresSafeArea()
                .opacity(0.55)

            // Subtle dark vignette over the plasma so the content reads
            // cleanly regardless of which colors the shader lands on.
            RadialGradient(
                colors: [Color.clear, Brand.dark.opacity(0.65)],
                center: .center, startRadius: 200, endRadius: 700)
                .ignoresSafeArea()
                .allowsHitTesting(false)

            VStack(spacing: 0) {
                Spacer(minLength: 24)

                // Animated step content. Each step is its own subview so
                // SwiftUI can transition them as discrete identities.
                Group {
                    switch step {
                    case 0: WelcomeStep(pulse: $heroPulse)
                    case 1: HelperStep()
                    case 2: LocationStep()
                    default: ReadyStep(deviceCount: store.devices.count)
                    }
                }
                .transition(
                    .asymmetric(
                        insertion: .opacity.combined(with: .move(edge: .trailing)),
                        removal:   .opacity.combined(with: .move(edge: .leading))
                    )
                )
                .id(step)

                Spacer(minLength: 18)

                StepDots(current: step, total: totalSteps)
                    .padding(.bottom, 18)

                actionRow
                    .padding(.bottom, 36)
            }
            .padding(.horizontal, 48)
            .frame(maxWidth: 760)
        }
        .onAppear {
            withAnimation(.linear(duration: 1.4)) { bannerProgress = 1 }
            withAnimation(.easeInOut(duration: 2.4).repeatForever(autoreverses: true)) {
                heroPulse = true
            }
        }
    }

    // MARK: action row

    private var actionRow: some View {
        HStack(spacing: 14) {
            if step > 0 {
                Button("Back") {
                    withAnimation(Motion.smooth) { step -= 1 }
                }
                .buttonStyle(GhostButton())
                .keyboardShortcut(.escape, modifiers: [])
            }
            Spacer()
            Button(primaryLabel) { primaryAction() }
                .buttonStyle(PrimaryButton(tint: Brand.cut))
                .keyboardShortcut(.return, modifiers: [])
                .frame(minWidth: 200)
        }
    }

    private var primaryLabel: String {
        switch step {
        case 0: return "Get started"
        case 1: return helper.connected ? "Helper ready · Continue" : "Install helper"
        case 2: return loc.ssidUnlocked ? "Permission granted · Continue" : "Allow Location"
        default: return "Enter the lobby"
        }
    }

    private func primaryAction() {
        switch step {
        case 0:
            withAnimation(Motion.smooth) { step = 1 }
        case 1:
            // The helper is already installed at app boot via
            // AppCoordinator.boot(); this step is informational + a place
            // for the user to see the live "Connected" pill before moving on.
            // If the helper isn't connected we trigger an explicit reinstall
            // so the user has a recoverable path from this screen.
            if !helper.connected {
                Task {
                    try? await helper.install()
                    helper.connect()
                }
                return
            }
            withAnimation(Motion.smooth) { step = 2 }
        case 2:
            if !loc.ssidUnlocked {
                loc.request()
                // macOS surfaces the system prompt asynchronously. We don't
                // advance — we wait for `ssidUnlocked` to flip and the
                // user to tap Continue again, so the label updates clearly.
                return
            }
            withAnimation(Motion.smooth) { step = 3 }
        default:
            UserDefaults.standard.set(true, forKey: "hasOnboarded")
            withAnimation(Motion.drift) { store.hasOnboarded = true }
        }
    }
}

// MARK: - Step 0: Welcome

private struct WelcomeStep: View {
    @Binding var pulse: Bool

    var body: some View {
        VStack(spacing: 20) {
            // Logo with breathing halo. Subtle pulse anchors the user's
            // attention while they read the headline.
            ZStack {
                Circle()
                    .fill(Brand.cut.opacity(pulse ? 0.45 : 0.18))
                    .frame(width: pulse ? 220 : 170, height: pulse ? 220 : 170)
                    .blur(radius: 36)
                Image("AppLogo")
                    .resizable()
                    .interpolation(.high)
                    .frame(width: 144, height: 144)
                    .shadow(color: Brand.cut.opacity(0.45), radius: 28, x: 0, y: 12)
            }
            .frame(height: 200)

            VStack(spacing: 8) {
                Text("Wifi Mancer")
                    .display(54, weight: .bold)
                    .foregroundStyle(Brand.light)
                Text("Layer-2 necromancer for the LAN you currently haunt.")
                    .bodyStyle(15, muted: true)
                    .multilineTextAlignment(.center)
            }

            // Three feature pills — what the app actually does. Each pill
            // is a "what + why" in one glance.
            HStack(spacing: 12) {
                FeatureChip(icon: "scope", title: "See",
                            subtitle: "Every device on your subnet")
                FeatureChip(icon: "bolt.slash.fill", title: "Cut",
                            subtitle: "Reclaim your bandwidth")
                FeatureChip(icon: "checkmark.shield.fill", title: "Trust",
                            subtitle: "Allowlist what matters")
            }
            .padding(.top, 10)
        }
    }
}

private struct FeatureChip: View {
    let icon: String
    let title: String
    let subtitle: String
    var body: some View {
        VStack(spacing: 6) {
            Image(systemName: icon)
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(Brand.cut)
                .frame(width: 36, height: 36)
                .background(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(Brand.cut.opacity(0.14))
                        .overlay(
                            RoundedRectangle(cornerRadius: 10, style: .continuous)
                                .stroke(Brand.cut.opacity(0.35), lineWidth: 1)))
            Text(title).bodyStyle(13, weight: .semibold)
            Text(subtitle).bodyStyle(11, muted: true)
                .multilineTextAlignment(.center)
                .frame(width: 130)
                .lineLimit(2)
        }
        .frame(width: 150)
    }
}

// MARK: - Step 1: Helper

private struct HelperStep: View {
    @EnvironmentObject var helper: HelperClient
    var body: some View {
        VStack(spacing: 18) {
            HeroIcon(symbol: "lock.shield.fill",
                     tint: Brand.info,
                     glow: helper.connected ? Brand.trust : Brand.warning)

            VStack(spacing: 8) {
                Text("Privileged Helper").display(34, weight: .semibold)
                Text("Wifi Mancer ships a tiny background helper that runs as root only when you ask it to act. It never sends data anywhere. Installed once at first launch.")
                    .bodyStyle(14, muted: true)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 520)
            }

            HStack(spacing: 10) {
                StatusPill(
                    on: helper.connected,
                    onLabel: "Connected", offLabel: "Pending",
                    onColor: Brand.trust, offColor: Brand.warning,
                    icon: helper.connected ? "checkmark.circle.fill" : "hourglass"
                )
                StatusPill(
                    on: true,
                    onLabel: "Local-only", offLabel: "Local-only",
                    onColor: Brand.info, offColor: Brand.info,
                    icon: "lock.shield.fill"
                )
            }
            .padding(.top, 4)

            Text(helper.statusText)
                .mono(11, muted: true)
                .padding(.top, 4)
        }
    }
}

// MARK: - Step 2: Location

private struct LocationStep: View {
    @EnvironmentObject var loc: LocationGate
    var body: some View {
        VStack(spacing: 18) {
            HeroIcon(symbol: "location.fill.viewfinder",
                     tint: Brand.warning,
                     glow: loc.ssidUnlocked ? Brand.trust : Brand.warning)

            VStack(spacing: 8) {
                Text("Wi-Fi Name Access").display(34, weight: .semibold)
                Text("On macOS 14+, apps can't read the SSID you're connected to without Location permission. Wifi Mancer never reads your location — only the network name. Required so we can save profiles per network.")
                    .bodyStyle(14, muted: true)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 520)
            }

            HStack(spacing: 10) {
                StatusPill(
                    on: loc.ssidUnlocked,
                    onLabel: "Granted", offLabel: "Pending",
                    onColor: Brand.trust, offColor: Brand.warning,
                    icon: loc.ssidUnlocked ? "checkmark.circle.fill" : "hourglass"
                )
                StatusPill(
                    on: true,
                    onLabel: "SSID only", offLabel: "SSID only",
                    onColor: Brand.info, offColor: Brand.info,
                    icon: "wifi"
                )
            }
            .padding(.top, 4)
        }
    }
}

// MARK: - Step 3: Ready

private struct ReadyStep: View {
    let deviceCount: Int
    var body: some View {
        VStack(spacing: 20) {
            ZStack {
                Circle()
                    .fill(Brand.trust.opacity(0.30))
                    .frame(width: 200, height: 200)
                    .blur(radius: 36)
                Image("AppLogo")
                    .resizable()
                    .interpolation(.high)
                    .frame(width: 132, height: 132)
                    .shadow(color: Brand.trust.opacity(0.4), radius: 24, x: 0, y: 10)
            }
            .frame(height: 200)

            VStack(spacing: 8) {
                Text("Ready").display(48, weight: .bold)
                Text(deviceCount > 0
                     ? "We've already seen \(deviceCount) device\(deviceCount == 1 ? "" : "s") on your subnet. More will fade in as they're discovered."
                     : "Your network is being scanned. Devices will fade in as they're discovered.")
                    .bodyStyle(14, muted: true)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 520)
            }
        }
    }
}

// MARK: - shared building blocks

/// Big circular icon hero used by Helper and Location steps. Inner symbol
/// is the step's tint; the outer glow color mirrors current status so the
/// user can see green/yellow at a glance and know whether they need to act.
private struct HeroIcon: View {
    let symbol: String
    let tint: Color
    let glow: Color
    var body: some View {
        ZStack {
            Circle()
                .fill(glow.opacity(0.30))
                .frame(width: 180, height: 180)
                .blur(radius: 32)
            ZStack {
                Circle()
                    .fill(LinearGradient(
                        colors: [Brand.surfaceHi, Brand.surface],
                        startPoint: .top, endPoint: .bottom))
                Circle()
                    .stroke(tint.opacity(0.4), lineWidth: 1.2)
                Image(systemName: symbol)
                    .font(.system(size: 48, weight: .semibold))
                    .foregroundStyle(tint)
            }
            .frame(width: 132, height: 132)
            .shadow(color: Color.black.opacity(0.5), radius: 18, x: 0, y: 10)
        }
        .frame(height: 180)
    }
}

private struct StatusPill: View {
    let on: Bool
    let onLabel: String
    let offLabel: String
    let onColor: Color
    let offColor: Color
    let icon: String
    var body: some View {
        let color = on ? onColor : offColor
        let label = on ? onLabel : offLabel
        HStack(spacing: 6) {
            Image(systemName: icon)
                .font(.system(size: 11, weight: .semibold))
            Text(label)
                .font(BrandFont.heading(12, weight: .semibold))
        }
        .foregroundStyle(color)
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .background(
            Capsule()
                .fill(color.opacity(0.14))
                .overlay(Capsule().stroke(color.opacity(0.4), lineWidth: 1))
        )
    }
}

/// Minimal "1 of N" indicator. Active dot is the cut color and slightly
/// wider, so the current step is unambiguous from across the room.
private struct StepDots: View {
    let current: Int
    let total: Int
    var body: some View {
        HStack(spacing: 8) {
            ForEach(0..<total, id: \.self) { i in
                Capsule()
                    .fill(i == current ? Brand.cut : Brand.mutedDim.opacity(0.5))
                    .frame(width: i == current ? 22 : 8, height: 8)
                    .animation(Motion.smooth, value: current)
            }
        }
    }
}

// MARK: - Backdrop (kept from previous version)

/// Plasma backdrop. Cheap canvas-grid procedural — gives the welcome
/// flow a moody-but-not-busy texture without needing Metal.
struct BannerShader: View {
    var progress: CGFloat
    @State private var t: CGFloat = 0

    var body: some View {
        TimelineView(.animation) { tl in
            let phase = CGFloat(tl.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 100))
            Canvas { ctx, size in
                let cols = 60
                let rows = 30
                let cw = size.width / CGFloat(cols)
                let rh = size.height / CGFloat(rows)
                for r in 0..<rows {
                    for c in 0..<cols {
                        let x = CGFloat(c) * cw
                        let y = CGFloat(r) * rh
                        let n = sin(CGFloat(c) * 0.18 + phase * 0.7)
                              + cos(CGFloat(r) * 0.22 + phase * 0.5)
                              + sin((CGFloat(c) + CGFloat(r)) * 0.07 + phase)
                        let a = 0.5 + 0.5 * n / 3
                        let color: Color = {
                            if a > 0.7 { return Brand.cut.opacity(a * progress * 0.55) }
                            if a > 0.4 { return Brand.info.opacity(a * progress * 0.32) }
                            return Brand.trust.opacity(a * progress * 0.20)
                        }()
                        ctx.fill(
                            Path(CGRect(x: x, y: y, width: cw - 1, height: rh - 1)),
                            with: .color(color)
                        )
                    }
                }
            }
        }
    }
}
