import SwiftUI

/// Full per-device dossier rendered in the Recon side panel.
///
/// Surfaces every field we have on `Device` plus contextual actions. The
/// philosophy is "no signal hidden": if the data exists in the model, it
/// has a row here. Empty fields render as `Brand.empty` placeholders so
/// the operator can read pipeline health at a glance.
struct DeviceInspector: View {
    let device: Device
    let cutEngaged: Bool
    /// mDNS service types observed for this device's IPv4 — surfaced as
    /// chips in the SERVICES section so the operator sees what protocols
    /// are advertised even when the device hasn't been port-scanned yet.
    var serviceTypes: Set<String> = []
    var addressConflict = false
    var onToggleAllowlist: () -> Void = {}

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                header
                if device.ipv4 != nil { AttackActionPad(device: device) }
                if device.isGateway   { RouterAdminPanel(device: device) }
                identitySection
                addressingSection
                if !serviceTypes.isEmpty { servicesSection }
                relationSection
                signalSection
                actionsSection
            }
            .padding(20)
        }
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Brand.surface)
                .overlay(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .stroke(Brand.hairline, lineWidth: 0.75)
                )
        )
    }

    // MARK: sections

    private var header: some View {
        HStack(spacing: 14) {
            ZStack {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(Brand.surfaceLo)
                Image(systemName: device.kind.sfSymbol)
                    .font(.system(size: 28, weight: .medium))
                    .foregroundStyle(headerTint)
            }
            .frame(width: 60, height: 60)
            VStack(alignment: .leading, spacing: 4) {
                Text(device.displayName)
                    .font(BrandFont.heading(20, weight: .semibold))
                    .foregroundStyle(Brand.light)
                    .lineLimit(2)
                if let m = device.displayModel, !m.isEmpty {
                    Text(m)
                        .bodyStyle(13, muted: true)
                        .lineLimit(1)
                } else if let v = device.vendor, !v.isEmpty {
                    Text(v)
                        .bodyStyle(13, muted: true)
                        .lineLimit(1)
                }
            }
            Spacer()
        }
    }

    private var identitySection: some View {
        Section(title: "IDENTITY") {
            row("MAC", value: device.mac.description.uppercased(), mono: true)
            row("Maker", value: device.identification?.manufacturer ?? "")
            row("Adapter", value: device.vendor ?? "")
            row("Model", value: device.displayModel ?? "")
            row("Hostname", value: device.hostname ?? "")
            row("Class", value: classLabel(device.kind))
            row("Class via", value: device.classificationSource)
            row("Identity via", value: device.identification?.source ?? "No advertised identity")
            if let seen = device.identification?.observedAt {
                row("Identity seen", value: relativeDate(seen))
            }
            row("MAC type", value: device.mac.isLocallyAdministered
                ? "locally administered (private)"
                : "globally administered")
        }
    }

    private var addressingSection: some View {
        Section(title: "ADDRESSING") {
            row("IPv4", value: device.ipv4 ?? "", mono: true)
            if addressConflict {
                Text("Multiple MAC addresses claim this IP. Identity is unresolved.")
                    .bodyStyle(12, muted: true)
                    .foregroundStyle(Brand.warning)
            }
            if device.ipv6.isEmpty {
                row("IPv6", value: "")
            } else {
                ForEach(device.ipv6.indices, id: \.self) { i in
                    row(i == 0 ? "IPv6" : " ", value: device.ipv6[i], mono: true)
                }
            }
        }
    }

    private var relationSection: some View {
        Section(title: "RELATION") {
            HStack(spacing: 8) {
                if device.isSelf       { Pill(text: "THIS MAC", color: Brand.info, icon: "macbook") }
                if device.isGateway    { Pill(text: "GATEWAY",  color: Brand.signal, icon: "arrow.up.forward.app.fill") }
                if device.isAllowlisted{ Pill(text: "ALLOWED",  color: Brand.trust, icon: "checkmark.seal.fill") }
                if cutEngaged && !device.isAllowlisted && !device.isSelf && !device.isGateway {
                    Pill(text: "CUT", color: Brand.cut, icon: "scissors")
                }
                if device.mac.isLocallyAdministered && !device.isSelf {
                    Pill(text: "PRIVATE MAC", color: Brand.privacy, icon: "eye.slash.fill")
                }
                Spacer()
            }
            row("First seen", value: relativeDate(device.firstSeen))
            row("Last seen", value: relativeDate(device.lastSeen))
            if let blocked = device.blockedSince {
                row("Cut since", value: relativeDate(blocked))
            }
            if device.threatScore > 0 {
                row("Threat score", value: "\(device.threatScore)/100")
            }
        }
    }

    private var servicesSection: some View {
        Section(title: "SERVICES (\(serviceTypes.count))") {
            // Wrapped chips — one per advertised mDNS service type. The
            // type strings come straight off the wire ("_airplay._tcp.")
            // and we display them stripped of underscores and trailing
            // dots so they read as actual protocol names.
            FlowLayout(spacing: 6) {
                ForEach(Array(serviceTypes).sorted(), id: \.self) { t in
                    Pill(text: prettifyServiceType(t), color: serviceTint(t), icon: serviceIcon(t))
                }
            }
        }
    }

    private func prettifyServiceType(_ raw: String) -> String {
        var s = raw
        if s.hasSuffix(".") { s.removeLast() }
        if s.hasPrefix("_")  { s.removeFirst() }
        if let r = s.range(of: "._") {
            return String(s[..<r.lowerBound]).uppercased()
        }
        return s.uppercased()
    }

    private func serviceTint(_ raw: String) -> Color {
        switch raw {
        case let t where t.contains("_airplay"), let t where t.contains("_raop"):
            return Brand.info
        case let t where t.contains("_smb"), let t where t.contains("_afp"):
            return Brand.warning
        case let t where t.contains("_ssh"), let t where t.contains("_sftp"):
            return Brand.signal
        case let t where t.contains("_http"):
            return Brand.signal
        case let t where t.contains("_rfb"):
            return Brand.armed
        case let t where t.contains("_googlecast"):
            return Brand.cut
        case let t where t.contains("_printer"), let t where t.contains("_ipp"):
            return Brand.muted
        case let t where t.contains("_homekit"):
            return Brand.trust
        default:
            return Brand.muted
        }
    }

    private func serviceIcon(_ raw: String) -> String {
        switch raw {
        case let t where t.contains("_airplay"):     "airplayvideo"
        case let t where t.contains("_raop"):        "music.note"
        case let t where t.contains("_smb"):         "folder.fill"
        case let t where t.contains("_afp"):         "folder.fill"
        case let t where t.contains("_ssh"):         "terminal.fill"
        case let t where t.contains("_sftp"):        "folder.badge.gearshape"
        case let t where t.contains("_http"):        "globe"
        case let t where t.contains("_rfb"):         "rectangle.on.rectangle"
        case let t where t.contains("_googlecast"):  "tv.fill"
        case let t where t.contains("_printer"),
             let t where t.contains("_ipp"):         "printer.fill"
        case let t where t.contains("_homekit"):     "house.fill"
        case let t where t.contains("_companion"):   "iphone"
        case let t where t.contains("_spotify"):     "music.note.list"
        default: "network"
        }
    }

    private var signalSection: some View {
        Section(title: "LIVE SIGNAL") {
            HStack {
                Text("Throughput")
                    .bodyStyle(12, muted: true)
                Spacer()
                Text(device.bandwidthPretty)
                    .font(BrandFont.mono(13))
                    .foregroundStyle(device.bandwidthBps > 1 ? Brand.signal : Brand.empty)
            }
            let mbps = max(0, device.bandwidthBps * 8 / 1_000_000)
            let pct = min(1.0, mbps / 100.0)
            RoundedRectangle(cornerRadius: 2)
                .fill(Brand.hairline)
                .frame(height: 5)
                .overlay(alignment: .leading) {
                    GeometryReader { geo in
                        RoundedRectangle(cornerRadius: 2)
                            .fill(Brand.signal)
                            .frame(width: geo.size.width * pct, height: 5)
                    }
                    .frame(height: 5)
                }
        }
    }

    private var actionsSection: some View {
        Section(title: "ACTIONS") {
            VStack(spacing: 8) {
                actionButton("Open in Finder via SMB", systemImage: "folder.fill")
                actionButton("Open SSH session",       systemImage: "terminal.fill")
                actionButton("Open in browser (HTTP)", systemImage: "globe")
                actionButton(device.isAllowlisted ? "Remove from allowlist" : "Add to allowlist",
                             systemImage: device.isAllowlisted ? "minus.circle.fill" : "plus.circle.fill",
                             tint: device.isAllowlisted ? Brand.cut : Brand.trust,
                             action: onToggleAllowlist)
            }
        }
    }

    // MARK: helpers

    private struct Section<Content: View>: View {
        let title: String
        @ViewBuilder var content: () -> Content
        var body: some View {
            VStack(alignment: .leading, spacing: 10) {
                Text(title)
                    .font(BrandFont.heading(10, weight: .semibold))
                    .tracking(2.0)
                    .foregroundStyle(Brand.mutedDim)
                content()
            }
            .padding(14)
            .background(
                RoundedRectangle(cornerRadius: 11, style: .continuous)
                    .fill(Brand.surfaceHi.opacity(0.6))
                    .overlay(
                        RoundedRectangle(cornerRadius: 11, style: .continuous)
                            .stroke(Brand.hairline, lineWidth: 0.5)
                    )
            )
        }
    }

    @ViewBuilder
    private func row(_ label: String, value: String, mono: Bool = false) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(label)
                .bodyStyle(12, muted: true)
                .frame(width: 90, alignment: .leading)
            if value.isEmpty {
                Text("—")
                    .font(mono ? BrandFont.mono(12) : BrandFont.body(12))
                    .foregroundStyle(Brand.empty)
            } else {
                Text(value)
                    .font(mono ? BrandFont.mono(12) : BrandFont.body(12))
                    .foregroundStyle(Brand.subtle)
                    .textSelection(.enabled)
                    .lineLimit(2)
            }
            Spacer()
        }
    }

    private func actionButton(_ text: String,
                              systemImage: String,
                              tint: Color = Brand.muted,
                              action: @escaping () -> Void = {}) -> some View {
        Button(action: action) {
            HStack {
                Image(systemName: systemImage)
                    .font(.system(size: 12, weight: .medium))
                Text(text)
                    .font(BrandFont.heading(13, weight: .medium))
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(Brand.empty)
            }
            .foregroundStyle(tint)
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .stroke(tint.opacity(0.35), lineWidth: 0.75)
            )
        }
        .buttonStyle(.plain)
    }

    private var headerTint: Color {
        if device.isSelf       { return Brand.info }
        if device.isGateway    { return Brand.signal }
        if device.isAllowlisted{ return Brand.trust }
        if cutEngaged          { return Brand.cut }
        return Brand.muted
    }

    private func classLabel(_ k: DeviceKind) -> String {
        switch k {
        case .router:        return "Router / Gateway"
        case .thisMac:       return "This Mac"
        case .laptop:        return "Laptop"
        case .desktop:       return "Desktop"
        case .applish:       return "Apple device"
        case .iphone:        return "iPhone"
        case .ipad:          return "iPad"
        case .watch:         return "Apple Watch"
        case .audio:         return "Apple audio"
        case .phone:         return "Phone"
        case .tv:            return "TV / set-top"
        case .speaker:       return "Speaker / smart hub"
        case .mediaReceiver: return "Media receiver"
        case .camera:        return "IP camera"
        case .printer:       return "Printer"
        case .gamingConsole: return "Gaming console"
        case .iot:           return "IoT device"
        case .light:         return "Smart light"
        case .sensor:        return "Sensor"
        case .unknown:       return "Unknown"
        }
    }

    private func relativeDate(_ d: Date) -> String {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .abbreviated
        return f.localizedString(for: d, relativeTo: .now)
    }
}
