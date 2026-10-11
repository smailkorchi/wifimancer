import SwiftUI

struct LobbyView: View {
    @EnvironmentObject var store: AppStore
    @EnvironmentObject var helper: HelperClient
    @EnvironmentObject var loc: LocationGate
    @State private var hovered: DropZone? = nil
    @State private var dragging: Bool = false

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            SectionHeader(
                store.context?.ssid ?? (loc.ssidUnlocked ? "Network" : "Permission needed"),
                subtitle: "Drag a device left to Trust · drag right to Cut",
                trailing: AnyView(LobbyStats())
            )

            if !helper.connected {
                HelperDownBanner()
            }
            if !loc.ssidUnlocked {
                LocationBanner()
            }
            CutStatusBanner()

            ZStack {
                ForceGraph(hovered: $hovered, dragging: $dragging)
                ZoneOverlay(hovered: $hovered, dragging: $dragging)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(Brand.surface)
                    .overlay(
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .stroke(Brand.hairline, lineWidth: 0.75)
                    )
            )
            // Pulsing cut-orange outline on the canvas itself when blocking.
            // Subtle but persistent — communicates "this whole surface is
            // currently engaged in a cut" without being chrome noise.
            .pulsingBorder(active: store.blocking,
                           color: Brand.cut, radius: 14, lineWidth: 1.2)
        }
    }
}

enum DropZone { case trust, cut }

// MARK: Banners

struct HelperDownBanner: View {
    @EnvironmentObject var helper: HelperClient
    var body: some View {
        BrandCard(padding: 14) {
            HStack(spacing: 12) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(Brand.cut)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Helper not connected")
                        .font(BrandFont.heading(13, weight: .semibold))
                    Text("Scanning, blocking, and throughput need the privileged helper. " +
                         "Status: \(helper.statusText).")
                        .bodyStyle(11, muted: true)
                }
                Spacer()
                Button("Reinstall") {
                    Task {
                        try? await helper.install()
                        helper.connect()
                    }
                }
                .buttonStyle(GhostButton(tint: Brand.cut))
            }
        }
    }
}

/// Session state describes targeting, not a measurement of lost Internet access.
struct CutStatusBanner: View {
    @EnvironmentObject var store: AppStore
    var body: some View {
        switch store.cutStatus {
        case .unsupportedAP:
            BrandCard(padding: 14) {
                HStack(spacing: 12) {
                    Image(systemName: "wifi.exclamationmark")
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundStyle(Brand.warning)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Direct device control unavailable")
                            .font(BrandFont.heading(13, weight: .semibold))
                        Text("Use your router's access controls when direct device targeting is unavailable.")
                            .bodyStyle(11, muted: true)
                    }
                    Spacer()
                }
            }
        case .noTargets:
            BrandCard(padding: 14) {
                HStack(spacing: 12) {
                    Image(systemName: "circle.dashed")
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundStyle(Brand.muted)
                    Text("Armed — waiting for eligible IPv4 devices and a resolved gateway. New devices are included automatically.")
                        .bodyStyle(12, muted: true)
                    Spacer()
                }
            }
        case .engaged:
            Text("IPv4 targeting active. IPv6 access is not blocked; router access controls are needed for complete Internet blocking.")
                .bodyStyle(12, muted: true)
        case .idle:
            EmptyView()
        }
    }
}

struct LocationBanner: View {
    @EnvironmentObject var loc: LocationGate
    @EnvironmentObject var coord: AppCoordinator
    var body: some View {
        BrandCard(padding: 14) {
            HStack(spacing: 12) {
                Image(systemName: "location.fill.viewfinder")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(Brand.warning)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Wi-Fi name hidden by macOS")
                        .font(BrandFont.heading(13, weight: .semibold))
                    Text("On macOS 14+, apps need Location permission to read SSIDs. " +
                         "Wifi Mancer never reads your location — it just unlocks the name.")
                        .bodyStyle(11, muted: true)
                }
                Spacer()
                Button(loc.status == .denied ? "Open Settings" : "Allow") {
                    loc.request()
                    coord.refreshContext()
                }
                .buttonStyle(GhostButton(tint: Brand.warning))
            }
        }
    }
}

private struct LobbyStats: View {
    @EnvironmentObject var store: AppStore
    var body: some View {
        HStack(spacing: 12) {
            Pill(text: "\(store.allowlistedDevices.count) trusted",
                 color: Brand.trust, icon: "checkmark.shield.fill")
            Pill(text: store.blocking
                    ? "\(store.armedTargetIPv4s.count) targeted"
                    : "\(store.blockedDevices.count) untrusted",
                 color: Brand.cut,
                 icon: "bolt.slash.fill")
        }
    }
}

// MARK: Edge zones overlay

private struct ZoneOverlay: View {
    @Binding var hovered: DropZone?
    @Binding var dragging: Bool

    var body: some View {
        GeometryReader { geo in
            ZStack {
                // Left = Trust
                ZoneSide(
                    side: .leading,
                    title: "Trust",
                    icon: "checkmark.shield.fill",
                    color: Brand.trust,
                    active: dragging,
                    glow: hovered == .trust
                )
                .frame(width: max(120, geo.size.width * 0.22))
                .frame(maxHeight: .infinity)
                .frame(maxWidth: .infinity, alignment: .leading)

                // Right = Cut
                ZoneSide(
                    side: .trailing,
                    title: "Cut",
                    icon: "bolt.slash.fill",
                    color: Brand.cut,
                    active: dragging,
                    glow: hovered == .cut
                )
                .frame(width: max(120, geo.size.width * 0.22))
                .frame(maxHeight: .infinity)
                .frame(maxWidth: .infinity, alignment: .trailing)
            }
        }
        .allowsHitTesting(false)
    }
}

private struct ZoneSide: View {
    enum Side { case leading, trailing }
    let side: Side
    let title: String
    let icon: String
    let color: Color
    let active: Bool
    let glow: Bool

    var body: some View {
        let g = LinearGradient(
            colors: [color.opacity(glow ? 0.32 : (active ? 0.14 : 0.05)), Color.clear],
            startPoint: side == .leading ? .leading : .trailing,
            endPoint:   side == .leading ? .trailing : .leading
        )
        ZStack(alignment: side == .leading ? .leading : .trailing) {
            Rectangle().fill(g)
            VStack(spacing: 8) {
                Image(systemName: icon)
                    .font(.system(size: 22, weight: .bold))
                    .foregroundStyle(color)
                Text(title)
                    .font(BrandFont.heading(13, weight: .semibold))
                    .foregroundStyle(color)
            }
            .padding(20)
            .frame(maxHeight: .infinity)
        }
        .opacity(active ? 1.0 : 0.55)
        .animation(Motion.smooth, value: active)
        .animation(Motion.smooth, value: glow)
    }
}

// MARK: Force-directed graph

private struct ForceGraph: View {
    @EnvironmentObject var store: AppStore
    @Binding var hovered: DropZone?
    @Binding var dragging: Bool
    @State private var nodes: [GraphNode] = []

    var body: some View {
        GeometryReader { geo in
            ZStack {
                // TimelineView ticks the canvas at ~30 Hz so the cut spoke
                // dashes appear to flow even though SwiftUI isn't redrawing
                // the rest of the graph. Cheap — Canvas is GPU-accelerated.
                TimelineView(.animation) { tl in
                    let phase = CGFloat(tl.date.timeIntervalSinceReferenceDate
                                            .truncatingRemainder(dividingBy: 1.5)) / 1.5

                    Canvas { ctx, _ in
                        let center = geo.size.center
                        for n in nodes where !n.isCenter {
                            var path = Path()
                            path.move(to: center)
                            path.addLine(to: n.position)

                            if n.isCut {
                                // Dashed marching line on cut spokes — reads
                                // as "data flow being chopped." 8-on-8-off
                                // pattern moves outward at ~6 px/sec.
                                let dash: [CGFloat] = [8, 8]
                                let dashCycle: CGFloat = 16  // sum of dash array
                                let style = StrokeStyle(
                                    lineWidth: 1.6, lineCap: .round,
                                    dash: dash,
                                    dashPhase: -phase * dashCycle
                                )
                                ctx.stroke(path,
                                           with: .color(n.color.opacity(0.55)),
                                           style: style)
                            } else if n.isAllowlisted {
                                ctx.stroke(path,
                                           with: .color(n.color.opacity(0.40)),
                                           lineWidth: 1.0)
                            } else {
                                ctx.stroke(path,
                                           with: .color(n.color.opacity(0.30)),
                                           lineWidth: 1.0)
                            }
                        }
                    }
                }

                if let gw = nodes.first(where: { $0.isCenter }) {
                    NodeView(node: gw)
                        .position(geo.size.center)
                }

                ForEach(nodes.filter { !$0.isCenter }) { node in
                    NodeView(node: node)
                        .position(node.position)
                        .gesture(
                            DragGesture(minimumDistance: 1, coordinateSpace: .local)
                                .onChanged { v in
                                    if let i = nodes.firstIndex(where: { $0.id == node.id }) {
                                        nodes[i].position = v.location
                                        dragging = true
                                        hovered  = zone(for: v.location, in: geo.size)
                                    }
                                }
                                .onEnded { v in
                                    let z = zone(for: v.location, in: geo.size)
                                    handleDrop(zone: z, mac: node.id)
                                    dragging = false
                                    hovered  = nil
                                    layout(size: geo.size)
                                }
                        )
                }
            }
            .onAppear { rebuild(size: geo.size) }
            .onChange(of: geo.size) { _, size in
                // Window resize must replace the previous canvas coordinates
                // immediately; animating from them can leave nodes offscreen.
                rebuild(size: size, animated: false)
            }
            .onChange(of: store.devices) { _, _ in rebuild(size: geo.size) }
            .onChange(of: store.profile) { _, _ in rebuild(size: geo.size) }
            .onChange(of: store.pulseTrigger) { _, _ in rebuild(size: geo.size) }
            // Engage / Idle changes the whole palette: in idle the graph
            // looks peaceful (neutral nodes) regardless of allowlist; in
            // engaged it splits trust/cut. Without this the toggle did
            // nothing visible until the next 5-second scan tick rebuilt.
            .onChange(of: store.blocking) { _, _ in rebuild(size: geo.size) }
            .onChange(of: store.armedTargetIPv4s) { _, _ in rebuild(size: geo.size) }
        }
    }

    private func zone(for p: CGPoint, in size: CGSize) -> DropZone? {
        let edge = max(120, size.width * 0.22)
        if p.x <= edge                   { return .trust }
        if p.x >= size.width - edge      { return .cut }
        return nil
    }

    private func handleDrop(zone: DropZone?, mac: MACAddress) {
        guard let zone, let d = store.devices.first(where: { $0.mac == mac }) else { return }
        guard !d.isSelf, !d.isGateway else { return }
        switch zone {
        case .trust:
            if !d.isAllowlisted {
                store.toggleAllowlist(for: d)
                store.toast("Trusted \(d.displayName)")
            } else {
                store.toast("Already trusted")
            }
        case .cut:
            if d.isAllowlisted {
                store.toggleAllowlist(for: d)
                store.toast("Untrusted \(d.displayName)")
            } else {
                store.toast("Already untrusted")
            }
        }
    }

    private func rebuild(size: CGSize, animated: Bool = true) {
        var newNodes: [GraphNode] = []
        if let gw = store.gatewayDevice {
            newNodes.append(GraphNode(id: gw.mac, label: "Gateway", isCenter: true,
                                      isSelf: false, isAllowlisted: true,
                                      isCut: false, kind: .router,
                                      position: size.center, color: Brand.info,
                                      details: details(for: gw)))
        } else {
            newNodes.append(GraphNode(id: MACAddress(bytes: [0,0,0,0,0,0]),
                                      label: "Gateway", isCenter: true, isSelf: false,
                                      isAllowlisted: true, isCut: false, kind: .router,
                                      position: size.center, color: Brand.info,
                                      details: "Gateway\nRouter · Network gateway"))
        }
        var i = 0
        let others = store.devices.filter { !$0.isGateway }
        let engaged = store.blocking
        for d in others {
            let p = LobbyGraphLayout.position(index: i, count: others.count, size: size)
            let isAllow = store.profile.allowlist.contains(where: { $0.mac == d.mac })
                          || d.isSelf || d.isGateway
            // Orange marks only devices accepted by the helper's live session.
            let color: Color
            let isCut: Bool
            if d.isSelf {
                color = Brand.light; isCut = false
            } else if !engaged {
                color = isAllow ? Brand.trust.opacity(0.85) : Brand.info.opacity(0.7)
                isCut = false
            } else if isAllow {
                color = Brand.trust; isCut = false
            } else if d.ipv4.map(store.armedTargetIPv4s.contains) == true {
                color = Brand.cut; isCut = true
            } else {
                color = Brand.info.opacity(0.7); isCut = false
            }
            newNodes.append(GraphNode(id: d.mac, label: d.displayName,
                                      isCenter: false, isSelf: d.isSelf,
                                      isAllowlisted: isAllow, isCut: isCut,
                                      kind: d.kind,
                                      position: p, color: color, details: details(for: d)))
            i += 1
        }
        if animated {
            withAnimation(Motion.drift) { self.nodes = newNodes }
        } else {
            self.nodes = newNodes
        }
    }

    private func layout(size: CGSize) { rebuild(size: size) }

    private func details(for device: Device) -> String {
        let type: String
        switch device.kind {
        case .thisMac: type = "This Mac"
        case .applish: type = "Apple device"
        case .iphone: type = "iPhone"
        case .ipad: type = "iPad"
        case .tv: type = "TV"
        case .iot: type = "IoT device"
        case .mediaReceiver: type = "Media receiver"
        case .gamingConsole: type = "Game console"
        default: type = device.kind.rawValue.capitalized
        }
        var lines = [device.displayName, "\(type) · \(device.classificationSource)"]
        if device.kind == .unknown {
            lines.append("Device type unknown. Showing a generic network-device icon.")
        }
        if let model = device.displayModel { lines.append("Model: \(model)") }
        if let ip = device.ipv4 { lines.append("IP: \(ip)") }
        return lines.joined(separator: "\n")
    }
}

private struct GraphNode: Identifiable, Equatable {
    let id: MACAddress
    let label: String
    let isCenter: Bool
    let isSelf: Bool
    let isAllowlisted: Bool
    let isCut: Bool
    let kind: DeviceKind
    var position: CGPoint
    let color: Color
    let details: String
}

private struct NodeView: View {
    let node: GraphNode
    @State private var hover = false
    /// Drives the slow pulse on cut nodes — toggles every ~1.1s via a
    /// repeating animation. Initial value matters: setting it to `false` and
    /// flipping `true` `.onAppear` lets SwiftUI run the implicit animation.
    @State private var pulsePhase: Bool = false

    var body: some View {
        let dim: CGFloat = node.isCenter ? 84 : 56
        VStack(spacing: 6) {
            ZStack {
                // Outer halo on cut nodes — "this is being severed" pulse.
                // The phase ramps farther and the line wobbles wider so the
                // motion reads from across the room, not just up close.
                if node.isCut {
                    Circle()
                        .stroke(node.color.opacity(pulsePhase ? 0.04 : 0.7),
                                lineWidth: pulsePhase ? 18 : 5)
                        .frame(width: dim, height: dim)
                        .blur(radius: pulsePhase ? 8 : 0.5)
                        .scaleEffect(pulsePhase ? 1.18 : 1.0)
                }
                // Subtle steady ring on trusted nodes — a quiet green halo
                // confirms "you've vouched for this device." Trust shouldn't
                // pulse like cut does (that would confuse the two states).
                if node.isAllowlisted, !node.isCenter {
                    Circle()
                        .stroke(Brand.trust.opacity(0.35), lineWidth: 4)
                        .frame(width: dim + 6, height: dim + 6)
                        .blur(radius: 3)
                }
                Circle()
                    .fill(node.color.opacity(0.18))
                    .frame(width: dim, height: dim)
                Circle()
                    .stroke(node.color, lineWidth: node.isCenter ? 2.5 : 1.5)
                    .frame(width: dim, height: dim)
                Image(systemName: node.kind.sfSymbol)
                    .font(.system(size: node.isCenter ? 24 : 18, weight: .semibold))
                    .foregroundStyle(node.color)
            }
            .scaleEffect(hover ? 1.08 : 1.0)
            .shadow(
                color: node.color.opacity(node.isCut ? (pulsePhase ? 0.5 : 0.2) : 0.35),
                radius: hover ? 18 : (node.isCut ? (pulsePhase ? 22 : 10) : 10)
            )
            Text(node.label)
                .bodyStyle(11, muted: true)
                .lineLimit(1)
                .frame(maxWidth: 100)
        }
        .help(node.details)
        .onHover { hover = $0 }
        .animation(Motion.smooth, value: hover)
        .onAppear {
            guard node.isCut else { return }
            withAnimation(.easeInOut(duration: 1.1).repeatForever(autoreverses: true)) {
                pulsePhase = true
            }
        }
        .onChange(of: node.isCut) { _, cut in
            // When the toggle flips this node into/out of cut state, sync
            // the pulse so the visual matches the new role.
            if cut {
                withAnimation(.easeInOut(duration: 1.1).repeatForever(autoreverses: true)) {
                    pulsePhase = true
                }
            } else {
                withAnimation(.easeOut(duration: 0.3)) { pulsePhase = false }
            }
        }
    }
}

extension CGSize {
    var center: CGPoint { CGPoint(x: width / 2, y: height / 2) }
}
