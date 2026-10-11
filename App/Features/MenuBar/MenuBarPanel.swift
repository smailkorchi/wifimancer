import SwiftUI
import Network

/// Menu-bar dashboard. Tile grid inspired by CleanMyMac's menubar app —
/// each tile is a glanceable, single-purpose widget with its own icon +
/// primary metric + secondary detail. Click → drives the action; hover →
/// telegraphs interactivity.
///
/// Numbers shown here are the truth, not placeholders. The previous panel
/// rendered "Down 0.0 / Up 6.6" because the per-MAC pcap counter credits
/// BOTH src and dst MACs for every frame — `if mac == selfMAC` is not a
/// direction split, it's a coincidence of which slot got credited first.
/// We now report total interface throughput (`sum / 2`, undoing the
/// double-count) and probe the gateway every 30 s for real latency.
struct MenuBarPanel: View {
    @EnvironmentObject var store: AppStore
    @EnvironmentObject var coord: AppCoordinator
    @EnvironmentObject var helper: HelperClient

    @State private var gatewayMs: Double? = nil
    @State private var probeTask: Task<Void, Never>? = nil

    var body: some View {
        VStack(spacing: 12) {
            networkHeader
            statGrid
            throughputCard
            footerRow
            actionRow
        }
        .padding(14)
        .frame(width: 360)
        .background(
            LinearGradient(colors: [Brand.surface, Brand.surfaceLo],
                           startPoint: .top, endPoint: .bottom)
        )
        .onAppear { startGatewayProbe() }
        .onDisappear {
            probeTask?.cancel()
            probeTask = nil
        }
    }

    // MARK: header

    private var networkHeader: some View {
        let ssid = store.context?.ssid
        let connected = (ssid?.isEmpty == false) && ssid != "<redacted>"
        return HStack(spacing: 12) {
            // Inside-the-menu brand mark — same artwork as the app icon
            // in /Applications. The menubar trigger itself (the small
            // status item) keeps its SF Symbol so it tints correctly
            // with the system menubar foreground; this is the bigger
            // tile the user sees once the menu opens.
            Image("AppLogo")
                .resizable()
                .interpolation(.high)
                .frame(width: 36, height: 36)
            VStack(alignment: .leading, spacing: 1) {
                Text(ssid ?? (connected ? "Connected" : "No network"))
                    .font(BrandFont.heading(15, weight: .semibold))
                    .foregroundStyle(Brand.light)
                    .lineLimit(1)
                    .truncationMode(.middle)
                HStack(spacing: 6) {
                    Circle()
                        .fill(helper.connected ? Brand.trust : Brand.warning)
                        .frame(width: 6, height: 6)
                    Text(headerSubtitle)
                        .font(BrandFont.mono(11))
                        .foregroundStyle(Brand.muted)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 0)
            BreathingDot(color: store.blocking ? Brand.cut : (connected ? Brand.trust : Brand.muted))
        }
    }

    private var headerSubtitle: String {
        guard helper.connected else { return "Helper offline" }
        if let ip = store.context?.selfIPv4, !ip.isEmpty { return ip }
        return "Resolving…"
    }

    // MARK: 2x2 tile grid

    private var statGrid: some View {
        LazyVGrid(columns: [GridItem(.flexible(), spacing: 8),
                            GridItem(.flexible(), spacing: 8)],
                  spacing: 8) {
            // Cut state — primary action read
            StatTile(
                icon: !store.helperSessionReady || store.startingBlocking ? "hourglass" : store.blocking ? "bolt.slash.fill" : "shield.lefthalf.filled",
                iconTint: !store.helperSessionReady || store.startingBlocking || store.stoppingBlocking ? Brand.warning : store.blocking ? Brand.cut : Brand.muted,
                title: !store.helperSessionReady ? "Preparing" : store.startingBlocking ? "Starting" : store.stoppingBlocking ? "Stopping" : store.blocking ? "Armed" : "Idle",
                value: store.blocking ? "\(store.armedTargetIPv4s.count)" : "—",
                detail: !store.helperSessionReady ? "ending previous session" : store.startingBlocking ? "preparing IPv4 targets" : store.stoppingBlocking ? "waiting for helper" : store.blocking ? "IPv4 targets" : "no active session"
            )

            // Devices on the LAN
            StatTile(
                icon: "rectangle.stack.fill",
                iconTint: Brand.info,
                title: "Devices",
                value: "\(store.devices.count)",
                detail: "\(store.allowlistedDevices.count) trusted · \(store.blockedDevices.count) untrusted"
            )

            // Latency (gateway probe)
            StatTile(
                icon: "wave.3.right",
                iconTint: latencyTint,
                title: "Gateway",
                value: gatewayMs.map { String(format: "%.0f", $0) } ?? "—",
                detail: gatewayMs == nil ? "probing…" : "ms · \(store.context?.gatewayIPv4 ?? "-")"
            )

            // Throughput peak in the recent window — gives a "is the link
            // doing anything right now" read at a glance.
            StatTile(
                icon: "speedometer",
                iconTint: Brand.warning,
                title: "Throughput",
                value: throughputDisplay.value,
                detail: throughputDisplay.unit + " · " + throughputDisplay.trend
            )
        }
    }

    // MARK: throughput sparkline

    private var throughputCard: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Last 60s")
                    .font(BrandFont.heading(10, weight: .semibold))
                    .foregroundStyle(Brand.muted)
                Spacer()
                Text(rangeLabel)
                    .font(BrandFont.mono(10))
                    .foregroundStyle(Brand.mutedDim)
            }
            Sparkline(values: sparklineSamples, tint: Brand.cut)
                .frame(height: 28)
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Brand.surfaceLo.opacity(0.6))
                .overlay(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .stroke(Brand.hairline, lineWidth: 1))
        )
    }

    private var sparklineSamples: [Double] {
        // Last ~60 ticks; each tick is 1s. Reflect interface throughput,
        // not the broken Down/Up split.
        store.throughputHistory.suffix(60).map { ($0.downBps + $0.upBps) / 2 }
    }

    private var rangeLabel: String {
        let s = sparklineSamples
        guard !s.isEmpty else { return "—" }
        let peak = (s.max() ?? 0) * 8
        return "peak " + formatBitsPerSecond(peak)
    }

    // MARK: footer row (gateway info)

    private var footerRow: some View {
        HStack(spacing: 8) {
            Label {
                Text(store.context?.subnetCIDR ?? "—")
                    .font(BrandFont.mono(10))
                    .foregroundStyle(Brand.muted)
            } icon: {
                Image(systemName: "network")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(Brand.mutedDim)
            }
            Spacer()
            Label {
                Text(store.context?.interface ?? "—")
                    .font(BrandFont.mono(10))
                    .foregroundStyle(Brand.muted)
            } icon: {
                Image(systemName: "cable.connector")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(Brand.mutedDim)
            }
        }
    }

    // MARK: action row

    private var actionRow: some View {
        VStack(spacing: 8) {
            // Primary engage toggle — full width so it's the obvious target.
            BrandSwitch(
                isOn: Binding(
                    get: { store.blockingRequested },
                    set: { _ in
                        Task { await coord.toggleBlocking() }
                    }),
                onColor: Brand.cut,
                offColor: Brand.mutedDim,
                label: (on: store.startingBlocking ? "Cancel start" : "Armed",
                        off: !store.helperSessionReady ? "Preparing…" : store.stoppingBlocking ? "Stopping…" : "Engage cut"),
                compact: true
            )
            .disabled(!store.helperSessionReady || store.stoppingBlocking)

            // Secondary actions — speed test, rescan, open app, quit.
            HStack(spacing: 6) {
                MenuActionButton(icon: "gauge.with.dots.needle.67percent",
                                 label: "Speed") {
                    Task { await coord.runSpeedTest() }
                }
                MenuActionButton(icon: "arrow.clockwise", label: "Rescan") {
                    coord.refreshContext()
                    coord.startContinuousScan()
                    Task { gatewayMs = await probeGatewayLatency() }
                }
                MenuActionButton(icon: "macwindow", label: "Open") {
                    NSApp.activate(ignoringOtherApps: true)
                    if let win = NSApp.windows.first(where: { $0.canBecomeMain }) {
                        win.makeKeyAndOrderFront(nil)
                    }
                }
                MenuActionButton(icon: "power", label: "Quit",
                                 tint: Brand.danger) {
                    NSApp.terminate(nil)
                }
            }
        }
    }

    // MARK: throughput formatting

    private struct ThroughputDisplay {
        let value: String
        let unit: String
        let trend: String
    }

    private var throughputDisplay: ThroughputDisplay {
        let recent = store.throughputHistory.suffix(5)
        guard !recent.isEmpty else {
            return ThroughputDisplay(value: "0", unit: "Kb/s", trend: "idle")
        }
        // Halve the per-MAC sum because pcap credits both src and dst for
        // every frame, doubling the apparent throughput.
        let avgBps = recent.map { ($0.downBps + $0.upBps) / 2 }
                           .reduce(0, +) / Double(recent.count)
        let bits = avgBps * 8
        let (val, unit) = scale(bits)
        let prevAvg: Double = {
            let prev = store.throughputHistory.dropLast(5).suffix(5)
            guard !prev.isEmpty else { return avgBps }
            return prev.map { ($0.downBps + $0.upBps) / 2 }
                       .reduce(0, +) / Double(prev.count)
        }()
        let trend: String
        if avgBps > prevAvg * 1.2      { trend = "↑ rising" }
        else if avgBps < prevAvg * 0.8 { trend = "↓ falling" }
        else                            { trend = "steady" }
        return ThroughputDisplay(value: val, unit: unit, trend: trend)
    }

    private func formatBitsPerSecond(_ bits: Double) -> String {
        let (v, u) = scale(bits)
        return "\(v) \(u)"
    }

    private func scale(_ bits: Double) -> (String, String) {
        switch bits {
        case 1_000_000_000...:
            return (String(format: "%.1f", bits / 1_000_000_000), "Gb/s")
        case 1_000_000...:
            return (String(format: "%.1f", bits / 1_000_000), "Mb/s")
        case 1_000...:
            return (String(format: "%.0f", bits / 1_000), "Kb/s")
        default:
            return (String(format: "%.0f", bits), "b/s")
        }
    }

    private var latencyTint: Color {
        guard let ms = gatewayMs else { return Brand.muted }
        if ms < 30  { return Brand.trust }
        if ms < 100 { return Brand.warning }
        return Brand.cut
    }

    // MARK: gateway latency probe (every 30s)

    private func startGatewayProbe() {
        probeTask?.cancel()
        probeTask = Task {
            // Initial probe immediately so the tile resolves fast on open.
            gatewayMs = await probeGatewayLatency()
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 30_000_000_000)
                guard !Task.isCancelled else { return }
                let ms = await probeGatewayLatency()
                await MainActor.run { self.gatewayMs = ms }
            }
        }
    }

    /// TCP handshake to the gateway IP — cheap, doesn't depend on the helper,
    /// and gives a real round-trip number. Falls back to nil when there's no
    /// gateway resolved yet or the connection times out (>2 s).
    private func probeGatewayLatency() async -> Double? {
        guard let gwStr = store.context?.gatewayIPv4, !gwStr.isEmpty,
              let port = NWEndpoint.Port(rawValue: 80) else { return nil }
        let host = NWEndpoint.Host(gwStr)
        let start = Date.now
        return await withCheckedContinuation { (cont: CheckedContinuation<Double?, Never>) in
            let lock = NSLock()
            var resumed = false
            func finish(_ v: Double?) {
                lock.lock(); defer { lock.unlock() }
                guard !resumed else { return }
                resumed = true
                cont.resume(returning: v)
            }
            let conn = NWConnection(host: host, port: port, using: .tcp)
            conn.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    let ms = Date.now.timeIntervalSince(start) * 1000
                    finish(ms)
                    conn.cancel()
                case .failed, .cancelled:
                    finish(nil)
                default: break
                }
            }
            conn.start(queue: .global())
            DispatchQueue.global().asyncAfter(deadline: .now() + 2.0) {
                finish(nil)
                conn.cancel()
            }
        }
    }
}

// MARK: tile

private struct StatTile: View {
    let icon: String
    let iconTint: Color
    let title: String
    let value: String
    let detail: String

    @State private var hover = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: icon)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(iconTint)
                Text(title)
                    .font(BrandFont.heading(10, weight: .semibold))
                    .foregroundStyle(Brand.muted)
                    .textCase(.uppercase)
                Spacer(minLength: 0)
            }
            Text(value)
                .font(BrandFont.heading(22, weight: .bold))
                .foregroundStyle(Brand.light)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
            Text(detail)
                .font(BrandFont.mono(10))
                .foregroundStyle(Brand.mutedDim)
                .lineLimit(1)
                .truncationMode(.tail)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, minHeight: 76, alignment: .topLeading)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(LinearGradient(
                    colors: [iconTint.opacity(hover ? 0.10 : 0.06), Brand.surfaceLo.opacity(0.55)],
                    startPoint: .topLeading, endPoint: .bottomTrailing))
                .overlay(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .stroke(iconTint.opacity(hover ? 0.45 : 0.18), lineWidth: 1))
        )
        .onHover { hover = $0 }
        .animation(Motion.snap, value: hover)
    }
}

// MARK: action button

private struct MenuActionButton: View {
    let icon: String
    let label: String
    var tint: Color = Brand.muted
    let action: () -> Void

    @State private var hover = false

    var body: some View {
        Button(action: action) {
            VStack(spacing: 4) {
                Image(systemName: icon)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(hover ? tint : Brand.muted)
                Text(label)
                    .font(BrandFont.heading(10, weight: .semibold))
                    .foregroundStyle(hover ? tint : Brand.muted)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 8)
            .background(
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .fill(hover ? Brand.surfaceHi : Brand.surfaceLo.opacity(0.5))
                    .overlay(
                        RoundedRectangle(cornerRadius: 9, style: .continuous)
                            .stroke(Brand.hairline, lineWidth: 1))
            )
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
        .animation(Motion.snap, value: hover)
    }
}

// MARK: sparkline

/// Lightweight area-fill sparkline. Drawn with `Canvas` so it's a single
/// composited layer instead of a Path stack; the fill uses a gradient to
/// the bottom edge so it reads as "energy" instead of just a line.
private struct Sparkline: View {
    let values: [Double]
    let tint: Color

    var body: some View {
        GeometryReader { geo in
            Canvas { ctx, size in
                guard values.count >= 2 else {
                    // Empty state: a flat hairline so the card never looks
                    // broken even on a fresh launch.
                    var p = Path()
                    p.move(to: CGPoint(x: 0, y: size.height - 1))
                    p.addLine(to: CGPoint(x: size.width, y: size.height - 1))
                    ctx.stroke(p, with: .color(Brand.hairline), lineWidth: 1)
                    return
                }

                let maxV = max(values.max() ?? 0, 1)
                let stepX = size.width / CGFloat(values.count - 1)
                var line = Path()
                var fill = Path()
                fill.move(to: CGPoint(x: 0, y: size.height))
                for (i, v) in values.enumerated() {
                    let x = CGFloat(i) * stepX
                    let y = size.height - (CGFloat(v / maxV) * (size.height - 2)) - 1
                    if i == 0 { line.move(to: CGPoint(x: x, y: y)) }
                    else      { line.addLine(to: CGPoint(x: x, y: y)) }
                    fill.addLine(to: CGPoint(x: x, y: y))
                }
                fill.addLine(to: CGPoint(x: size.width, y: size.height))
                fill.closeSubpath()

                ctx.fill(fill, with: .linearGradient(
                    Gradient(colors: [tint.opacity(0.45), tint.opacity(0.0)]),
                    startPoint: .zero,
                    endPoint: CGPoint(x: 0, y: size.height)
                ))
                ctx.stroke(line, with: .color(tint), lineWidth: 1.4)
            }
        }
    }
}
