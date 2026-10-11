import SwiftUI

/// Router / gateway operations panel. Rendered inside `DeviceInspector`
/// when the inspected device is the LAN gateway. Surfaces the actions
/// most pen-tester / network-admin workflows want from the gateway:
///   - one-click open of the admin web UI
///   - default-credential cheatsheet keyed off the device's vendor
///   - a "try default creds" handoff into the Arsenal attack chain
///   - a "DNS / WAN / port-forward" recon link
///
/// Default-credential mapping is best-effort. Users still need to test
/// because ISP-customized firmware often changes them. We surface the
/// model name we detected so the operator can cross-reference.
struct RouterAdminPanel: View {
    let device: Device
    @EnvironmentObject var store: AppStore
    @StateObject private var arsenal = ArsenalStore.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header
            actions
            credentialsSection
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Brand.surfaceLo.opacity(0.85))
                .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .stroke(Brand.signal.opacity(0.45), lineWidth: 0.75))
        )
    }

    // MARK: header

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: "wifi.router.fill")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Brand.signal)
            Text("ROUTER / GATEWAY")
                .font(BrandFont.heading(11, weight: .bold))
                .tracking(2.0).foregroundStyle(Brand.signal)
            Spacer()
            if let v = device.vendor, !v.isEmpty {
                Text(v)
                    .font(BrandFont.heading(10, weight: .medium))
                    .foregroundStyle(Brand.muted)
                    .lineLimit(1)
            }
        }
    }

    // MARK: actions

    @ViewBuilder
    private var actions: some View {
        VStack(spacing: 6) {
            actionRow(
                "Open admin panel in browser",
                icon: "globe",
                tint: Brand.info
            ) { openAdmin() }

            actionRow(
                "Spray default credentials (active)",
                icon: "key.fill",
                tint: Brand.cut
            ) { handoffArsenal(attackId: "router.creds.spray") }

            actionRow(
                "Probe SNMP communities",
                icon: "antenna.radiowaves.left.and.right",
                tint: Brand.armed
            ) { handoffArsenal(attackId: "router.snmp") }

            actionRow(
                "List UPnP / IGD port-mappings",
                icon: "network",
                tint: Brand.muted
            ) { handoffArsenal(attackId: "router.upnp") }
        }
    }

    private func actionRow(_ text: String,
                           icon: String,
                           tint: Color,
                           action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 9) {
                Image(systemName: icon)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(tint)
                    .frame(width: 14)
                Text(text)
                    .font(BrandFont.heading(12, weight: .medium))
                    .foregroundStyle(Brand.subtle)
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(Brand.empty)
            }
            .padding(.horizontal, 10).padding(.vertical, 7)
            .background(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .stroke(tint.opacity(0.35), lineWidth: 0.75)
            )
        }
        .buttonStyle(.plain)
    }

    // MARK: credentials

    private var credentialsSection: some View {
        let creds = RouterDefaultCredentials.lookup(
            vendor: device.vendor, model: device.deviceModel)
        return VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Text("DEFAULT CREDENTIALS")
                    .font(BrandFont.heading(9, weight: .bold))
                    .tracking(1.6).foregroundStyle(Brand.mutedDim)
                if !creds.isEmpty {
                    Text("· \(creds.count) known")
                        .font(BrandFont.heading(9, weight: .semibold))
                        .foregroundStyle(Brand.cut)
                }
                Spacer()
            }
            if creds.isEmpty {
                Text("No vendor match in cheatsheet — try the Arsenal sweep.")
                    .bodyStyle(11, muted: true)
            } else {
                ForEach(Array(creds.enumerated()), id: \.offset) { _, c in
                    credentialRow(user: c.user, pass: c.pass, note: c.note)
                }
            }
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Brand.dark.opacity(0.6))
                .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .stroke(Brand.hairline, lineWidth: 0.5))
        )
    }

    private func credentialRow(user: String, pass: String, note: String?) -> some View {
        HStack(spacing: 8) {
            Text(user)
                .font(BrandFont.mono(11)).foregroundStyle(Brand.signal)
            Text("/")
                .font(BrandFont.mono(11)).foregroundStyle(Brand.mutedDim)
            Text(pass)
                .font(BrandFont.mono(11)).foregroundStyle(Brand.cut)
                .textSelection(.enabled)
            if let n = note {
                Text("· \(n)")
                    .font(BrandFont.body(10))
                    .foregroundStyle(Brand.mutedDim)
                    .lineLimit(1)
            }
            Spacer()
            Button {
                let pb = NSPasteboard.general
                pb.clearContents()
                pb.setString("\(user):\(pass)", forType: .string)
            } label: {
                Image(systemName: "doc.on.doc")
                    .font(.system(size: 9))
                    .foregroundStyle(Brand.mutedDim)
            }
            .buttonStyle(.plain)
        }
        .padding(.vertical, 2)
    }

    // MARK: actions impl

    private func openAdmin() {
        guard let ip = device.ipv4 else { return }
        // Most modern routers redirect HTTP→HTTPS automatically; start
        // with HTTP so the OS doesn't prompt for a self-signed cert
        // until the redirect lands.
        if let url = URL(string: "http://\(ip)/") {
            NSWorkspace.shared.open(url)
        }
    }

    private func handoffArsenal(attackId: String) {
        guard let attack = AttackCatalog.all.first(where: { $0.id == attackId }) else {
            // Fall back to opening the Arsenal page focused on the router category
            arsenal.selectedCategory = .router
            arsenal.setTarget(device)
            withAnimation(Motion.smooth) { store.tab = .arsenal }
            return
        }
        arsenal.setTarget(device)
        arsenal.selectAttack(attack)
        withAnimation(Motion.smooth) { store.tab = .arsenal }
    }
}

// MARK: - default-credential cheatsheet

/// Static lookup table of well-known default credentials for common
/// home / SMB router vendors. Sourced from each vendor's published
/// quick-start docs and historical leaks (RouterPasswords.com etc.).
/// Models specific enough get their own row; otherwise the generic
/// vendor-default block applies.
enum RouterDefaultCredentials {

    struct Entry: Hashable {
        let user: String
        let pass: String
        let note: String?
    }

    static func lookup(vendor: String?, model: String?) -> [Entry] {
        let v = (vendor ?? "").lowercased()
        let m = (model  ?? "").lowercased()
        var out: [Entry] = []

        if v.contains("huawei") || m.contains("hg") || m.contains("f6600") || m.contains("hg6") {
            out += [
                .init(user: "telecomadmin", pass: "admintelecom", note: "Huawei superuser (factory)"),
                .init(user: "root",         pass: "admin",        note: nil),
                .init(user: "admin",        pass: "admin",        note: nil),
                .init(user: "admin",        pass: "Huawei@2012",  note: "older firmware"),
                .init(user: "support",      pass: "theworldhasnoz", note: "BSNL OEM"),
            ]
        }
        if v.contains("zte") || m.contains("zxhn") {
            out += [
                .init(user: "admin",  pass: "admin",   note: nil),
                .init(user: "user",   pass: "user",    note: nil),
                .init(user: "root",   pass: "Zte521",  note: "factory shell"),
            ]
        }
        if v.contains("tp-link") || v.contains("tplink") {
            out += [
                .init(user: "admin", pass: "admin",  note: "pre-2018 default"),
                .init(user: "admin", pass: "1234",   note: nil),
            ]
        }
        if v.contains("d-link") {
            out += [
                .init(user: "admin", pass: "",       note: "blank password"),
                .init(user: "admin", pass: "admin",  note: nil),
                .init(user: "user",  pass: "user",   note: nil),
            ]
        }
        if v.contains("netgear") {
            out += [
                .init(user: "admin",  pass: "password", note: "factory default"),
                .init(user: "admin",  pass: "1234",     note: "older firmware"),
            ]
        }
        if v.contains("linksys") {
            out += [
                .init(user: "admin",  pass: "admin",    note: nil),
                .init(user: "",       pass: "admin",    note: "blank user"),
            ]
        }
        if v.contains("asus") {
            out += [
                .init(user: "admin",  pass: "admin",    note: nil),
            ]
        }
        if v.contains("cisco") {
            out += [
                .init(user: "cisco",  pass: "cisco",    note: nil),
                .init(user: "admin",  pass: "admin",    note: nil),
            ]
        }
        if v.contains("mikrotik") {
            out += [
                .init(user: "admin",  pass: "",         note: "pre-RouterOS 6.49"),
            ]
        }
        if v.contains("ubiquiti") || v.contains("unifi") {
            out += [
                .init(user: "ubnt",   pass: "ubnt",     note: nil),
            ]
        }
        if v.contains("technicolor") || m.contains("tg") {
            out += [
                .init(user: "admin",  pass: "admin",    note: nil),
                .init(user: "user",   pass: "user",     note: nil),
            ]
        }
        if v.contains("fritz") || m.contains("fritz!box") {
            out += [
                .init(user: "admin",  pass: "1234",     note: "older models only"),
            ]
        }
        if v.contains("xiaomi") {
            out += [
                .init(user: "admin",  pass: "admin",    note: nil),
                .init(user: "root",   pass: "root",     note: "factory shell"),
            ]
        }

        // Generic vendor-agnostic fallbacks. Order matters — these are
        // tried after vendor-specific ones in the operator's head.
        if out.isEmpty {
            out += [
                .init(user: "admin", pass: "admin",    note: nil),
                .init(user: "admin", pass: "password", note: nil),
                .init(user: "admin", pass: "1234",     note: nil),
                .init(user: "admin", pass: "",         note: "blank"),
                .init(user: "root",  pass: "root",     note: nil),
            ]
        }
        return out
    }
}
