import SwiftUI

/// Recon — the new ultimate-density device view.
///
/// Replaces the role of the old DevicesView + Lobby table. Layout:
///
///   ┌────────────────────────────────────────────────────────────────┐
///   │  STATS  ·  filter chips  ·  search                             │  header
///   ├────────────────────────────┬───────────────────────────────────┤
///   │ device list                │ inspector (selected device)       │
///   │  - DeviceRowCard           │   - identity                       │
///   │  - DeviceRowCard           │   - addressing                     │
///   │  - DeviceRowCard           │   - relation                       │
///   │  - …                       │   - live signal                    │
///   │                            │   - actions                        │
///   └────────────────────────────┴───────────────────────────────────┘
struct ReconView: View {

    @EnvironmentObject var store: AppStore
    @State private var selectedID: String?
    @State private var search: String = ""
    @State private var filter: Filter = .all

    enum Filter: String, CaseIterable, Identifiable {
        case all, peers, allowlisted, cut, threats, privateMAC
        var id: String { rawValue }
        var label: String {
            switch self {
            case .all:         "All"
            case .peers:       "Peers"
            case .allowlisted: "Allowed"
            case .cut:         "Cut"
            case .threats:     "Threats"
            case .privateMAC:  "Private MAC"
            }
        }
        var icon: String {
            switch self {
            case .all:         "circle.grid.3x3.fill"
            case .peers:       "person.3.fill"
            case .allowlisted: "checkmark.seal.fill"
            case .cut:         "scissors"
            case .threats:     "exclamationmark.triangle.fill"
            case .privateMAC:  "eye.slash.fill"
            }
        }
    }

    var body: some View {
        GeometryReader { geometry in
            let sideBySide = geometry.size.width - 36 >= 1_100
            VStack(spacing: 14) {
                statsHeader
                filterBar
                let layout = sideBySide
                    ? AnyLayout(HStackLayout(alignment: .top, spacing: 14))
                    : AnyLayout(VStackLayout(spacing: 14))
                layout {
                    deviceList
                        .frame(minWidth: 0, maxWidth: .infinity, maxHeight: .infinity)
                    if let dev = selectedDevice {
                        DeviceInspector(
                            device: dev,
                            cutEngaged: store.blocking && !dev.isAllowlisted && !dev.isSelf && !dev.isGateway,
                            serviceTypes: services(for: dev),
                            addressConflict: store.hasAddressConflict(dev),
                            onToggleAllowlist: { store.toggleAllowlist(for: dev) }
                        )
                        .frame(width: sideBySide ? 360 : nil,
                               height: sideBySide ? nil : 280)
                        .transition(.opacity)
                    }
                }
                .animation(Motion.smooth, value: selectedID)
            }
            .padding(18)
        }
    }

    // MARK: header

    private var statsHeader: some View {
        HStack(alignment: .firstTextBaseline, spacing: 24) {
            VStack(alignment: .leading, spacing: 4) {
                Text("RECON")
                    .font(BrandFont.heading(11, weight: .bold))
                    .tracking(3.0)
                    .foregroundStyle(Brand.mutedDim)
                Text(store.context?.ssid ?? "Detached")
                    .font(BrandFont.heading(28, weight: .bold))
                    .tracking(-0.6)
                    .foregroundStyle(Brand.light)
                    .lineLimit(1)
            }
            .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
            Spacer()
            statTile("Devices",  value: "\(filtered.count)", color: Brand.light)
            statTile("Peers",    value: "\(peerCount)",      color: Brand.signal)
            statTile("Allowed",  value: "\(allowedCount)",   color: Brand.trust)
            statTile("Cut",      value: "\(cutCount)",       color: store.blocking ? Brand.cut : Brand.empty,
                     pulsing: store.blocking)
            statTile("Threats",  value: "\(threatCount)",    color: threatCount > 0 ? Brand.threat : Brand.empty)
        }
    }

    private func statTile(_ label: String, value: String, color: Color, pulsing: Bool = false) -> some View {
        VStack(alignment: .trailing, spacing: 3) {
            Text(label)
                .font(BrandFont.heading(9, weight: .semibold))
                .tracking(1.6)
                .foregroundStyle(Brand.mutedDim)
            HStack(spacing: 6) {
                if pulsing { BreathingDot(color: color, intensity: 2.2, period: 1.1) }
                Text(value)
                    .font(BrandFont.mono(20))
                    .foregroundStyle(color)
                    .contentTransition(.numericText(value: Double(value) ?? 0))
                    .animation(Motion.smooth, value: value)
            }
        }
        .frame(minWidth: 70)
    }

    private var filterBar: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 8) {
                HStack(spacing: 8) { filterButtons }
                    .fixedSize(horizontal: true, vertical: false)
                Spacer(minLength: 8)
                searchField.frame(width: 260)
            }
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) { filterButtons }
                searchField
            }
        }
    }

    private var filterButtons: some View {
        ForEach(Filter.allCases) { f in
            Button(action: { withAnimation(Motion.snap) { filter = f } }) {
                HStack(spacing: 6) {
                    Image(systemName: f.icon).font(.system(size: 10, weight: .semibold))
                    Text(f.label).font(BrandFont.heading(11, weight: .semibold))
                }
                .padding(.horizontal, 11)
                .padding(.vertical, 6)
                .foregroundStyle(filter == f ? Brand.light : Brand.muted)
                .background(
                    Capsule()
                        .fill(filter == f ? Brand.surfaceHi : Color.clear)
                        .overlay(Capsule().stroke(filter == f ? Brand.muted.opacity(0.6) : Brand.hairline,
                                                 lineWidth: 0.75))
                )
            }
            .buttonStyle(.plain)
        }
    }

    private var searchField: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(Brand.mutedDim)
            TextField("filter mac, ip, vendor, model…", text: $search)
                .textFieldStyle(.plain)
                .font(BrandFont.mono(12))
                .foregroundStyle(Brand.subtle)
                .frame(minWidth: 0, maxWidth: .infinity)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(
            Capsule()
                .fill(Brand.surfaceLo)
                .overlay(Capsule().stroke(Brand.hairline, lineWidth: 0.75))
        )
    }

    // MARK: list

    private var deviceList: some View {
        ScrollView {
            LazyVStack(spacing: 8) {
                ForEach(filtered) { d in
                    DeviceRowCard(
                        device: d,
                        isSelected: selectedID == d.id,
                        cutEngaged: store.blocking && !d.isAllowlisted && !d.isSelf && !d.isGateway,
                        serviceTypes: services(for: d),
                        addressConflict: store.hasAddressConflict(d),
                        onTap: {
                            withAnimation(Motion.smooth) {
                                selectedID = (selectedID == d.id) ? nil : d.id
                            }
                        },
                        onAllowToggle: { store.toggleAllowlist(for: d) }
                    )
                    .transition(.asymmetric(
                        insertion: .move(edge: .leading).combined(with: .opacity),
                        removal: .opacity
                    ))
                }
                if filtered.isEmpty {
                    emptyState
                }
            }
            .padding(.bottom, 12)
        }
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: filter == .threats ? "shield.lefthalf.filled" : "antenna.radiowaves.left.and.right.slash")
                .font(.system(size: 32, weight: .light))
                .foregroundStyle(Brand.empty)
            Text(filter == .all ? "Waiting for first scan…" : "No matches for \(filter.label)")
                .bodyStyle(12, muted: true)
        }
        .frame(maxWidth: .infinity, minHeight: 160)
    }

    // MARK: data

    private var filtered: [Device] {
        let base: [Device] = store.devices
        let stage: [Device] = base.filter { d in
            switch filter {
            case .all:         return true
            case .peers:       return !d.isSelf && !d.isGateway
            case .allowlisted: return d.isAllowlisted
            case .cut:         return store.blocking && !d.isAllowlisted && !d.isSelf && !d.isGateway
            case .threats:     return d.threatScore >= 40
            case .privateMAC:  return d.mac.isLocallyAdministered && !d.isSelf
            }
        }
        let q = search.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !q.isEmpty else { return stage }
        return stage.filter { d in
            d.displayName.lowercased().contains(q)
            || d.mac.description.lowercased().contains(q)
            || (d.ipv4 ?? "").lowercased().contains(q)
            || (d.vendor ?? "").lowercased().contains(q)
            || (d.deviceModel ?? "").lowercased().contains(q)
            || (d.hostname ?? "").lowercased().contains(q)
        }
    }

    private var selectedDevice: Device? {
        guard let id = selectedID else { return nil }
        return store.devices.first { $0.id == id }
    }

    private var peerCount:    Int { store.devices.filter { !$0.isSelf && !$0.isGateway }.count }
    private var allowedCount: Int { store.devices.filter { $0.isAllowlisted && !$0.isSelf && !$0.isGateway }.count }
    private var cutCount: Int {
        guard store.blocking else { return 0 }
        return store.devices.filter { !$0.isAllowlisted && !$0.isSelf && !$0.isGateway }.count
    }
    private var threatCount: Int { store.devices.filter { $0.threatScore >= 40 }.count }

    /// Pulls the set of mDNS service types the App-side enricher has
    /// observed for this device's IPv4. Empty when nothing has resolved
    /// yet — the row simply omits the "N svc" tag, never renders zero.
    private func services(for device: Device) -> Set<String> {
        return Set(device.identification?.services ?? [])
    }
}
