import SwiftUI

struct DevicesView: View {
    @EnvironmentObject var store: AppStore
    @State private var query: String = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            SectionHeader(
                "Devices",
                subtitle: "\(store.devices.count) total · \(store.allowlistedDevices.count) trusted · \(store.blockedDevices.count) cut",
                trailing: AnyView(searchField)
            )

            BrandCard(padding: 0) {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(filtered) { d in
                            DeviceRow(device: d)
                            Divider().background(Brand.hairline).padding(.horizontal, 14)
                        }
                    }
                }
                .frame(minHeight: 480)
            }
        }
    }

    private var filtered: [Device] {
        guard !query.isEmpty else { return store.devices }
        let q = query.lowercased()
        return store.devices.filter {
            $0.displayName.lowercased().contains(q)
            || $0.mac.description.contains(q)
            || ($0.ipv4 ?? "").contains(q)
        }
    }

    private var searchField: AnyView {
        AnyView(
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass").foregroundStyle(Brand.muted)
                TextField("filter", text: $query)
                    .textFieldStyle(.plain)
                    .font(BrandFont.body(13))
            }
            .padding(.horizontal, 12).padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: 8).fill(Brand.surface)
                    .overlay(RoundedRectangle(cornerRadius: 8).stroke(Brand.hairline))
            )
            .frame(width: 220)
        )
    }
}

private struct DeviceRow: View {
    @EnvironmentObject var store: AppStore
    @EnvironmentObject var coord: AppCoordinator
    let device: Device
    @State private var hover = false
    @State private var working = false

    var body: some View {
        HStack(spacing: 14) {
            Circle()
                .fill(badgeColor.opacity(0.18))
                .overlay(Circle().stroke(badgeColor, lineWidth: 1.5))
                .overlay(Image(systemName: device.kind.sfSymbol).font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(badgeColor))
                .frame(width: 36, height: 36)

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 8) {
                    Text(device.displayName).bodyStyle(14, weight: .semibold)
                    if device.isSelf { Pill(text: "You", color: Brand.info, icon: "person.fill") }
                    if device.isGateway { Pill(text: "Gateway", color: Brand.info, icon: "wifi.router") }
                    if isTrusted && !device.isSelf && !device.isGateway {
                        Pill(text: "Trusted", color: Brand.trust, icon: "checkmark.shield.fill")
                    }
                    if !isTrusted && !device.isSelf && !device.isGateway {
                        Pill(text: "Cut", color: Brand.cut, icon: "bolt.slash.fill")
                    }
                    if device.threatScore > 60 {
                        Pill(text: "Suspicious", color: Brand.warning, icon: "exclamationmark.triangle.fill")
                    }
                }
                HStack(spacing: 10) {
                    if let ip = device.ipv4 { Text(ip).mono(11, muted: true) }
                    Text(device.mac.description).mono(11, muted: true)
                    if let v = device.vendor { Text(v).bodyStyle(11, muted: true) }
                }
            }
            Spacer()
            Text(device.bandwidthPretty)
                .mono(12)
                .foregroundStyle(device.bandwidthBps > 1_000_000 ? Brand.warning : Brand.muted)

            if !device.isSelf && !device.isGateway {
                Button {
                    Task { await toggle() }
                } label: {
                    HStack(spacing: 6) {
                        if working {
                            ProgressView().controlSize(.small)
                        } else {
                            Image(systemName: isTrusted
                                  ? "bolt.slash.fill" : "checkmark.shield.fill")
                                .font(.system(size: 11, weight: .semibold))
                        }
                        Text(working ? "…" : (isTrusted ? "Cut" : "Trust"))
                    }
                }
                .buttonStyle(GhostButton(tint: isTrusted ? Brand.cut : Brand.trust))
                .disabled(working)
                .animation(Motion.snap, value: working)
                .animation(Motion.snap, value: isTrusted)
            }
        }
        .padding(.horizontal, 16).padding(.vertical, 12)
        .background(hover ? Brand.surfaceHi : Color.clear)
        .onHover { hover = $0 }
        .animation(Motion.snap, value: hover)
    }

    private var isTrusted: Bool {
        store.profile.allowlist.contains(where: { $0.mac == device.mac })
        || device.isSelf || device.isGateway
    }

    private func toggle() async {
        working = true
        store.toggleAllowlist(for: device)
        // push allowlist + recompute spoof targets in the helper, optimistic
        await coord.resyncSpoofTargets()
        working = false
    }

    private var badgeColor: Color {
        if device.isSelf      { return Brand.info }
        if device.isGateway   { return Brand.info }
        if isTrusted          { return Brand.trust }
        return Brand.cut
    }

}
