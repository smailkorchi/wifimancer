import SwiftUI

struct ProfilesView: View {
    @EnvironmentObject var store: AppStore

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            SectionHeader(
                "Profiles",
                subtitle: "Per-network settings · allowlist · block mode"
            )

            HStack(alignment: .top, spacing: 18) {
                BrandCard(padding: 0) {
                    VStack(alignment: .leading, spacing: 0) {
                        Text("Networks")
                            .bodyStyle(11, weight: .semibold, muted: true)
                            .padding(.horizontal, 16).padding(.top, 14).padding(.bottom, 8)

                        ScrollView {
                            LazyVStack(spacing: 0) {
                                ForEach(store.profiles) { p in
                                    ProfileRow(profile: p, selected: p.ssid == store.profile.ssid)
                                        .onTapGesture { store.profile = p }
                                        .contextMenu {
                                            Button(role: .destructive) {
                                                store.deleteProfile(ssid: p.ssid)
                                            } label: { Text("Delete profile") }
                                        }
                                    Divider().background(Brand.hairline).padding(.horizontal, 14)
                                }
                            }
                        }
                    }
                }
                .frame(width: 280)

                ProfileEditor()
            }
        }
    }
}

private struct ProfileRow: View {
    @EnvironmentObject var store: AppStore
    let profile: NetworkProfile
    let selected: Bool
    @State private var hover = false
    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "wifi")
                .foregroundStyle(selected ? Brand.cut : Brand.muted)
            VStack(alignment: .leading, spacing: 2) {
                Text(profile.ssid).bodyStyle(13, weight: .semibold)
                Text("\(profile.allowlist.count) trusted · \(profile.blockMode.label)")
                    .bodyStyle(11, muted: true)
            }
            Spacer()
            if hover {
                Button {
                    store.deleteProfile(ssid: profile.ssid)
                } label: {
                    Image(systemName: "trash")
                        .font(.system(size: 12))
                        .foregroundStyle(Brand.cut)
                }
                .buttonStyle(.borderless)
                .help("Delete profile")
            }
        }
        .padding(.horizontal, 14).padding(.vertical, 10)
        .background((selected || hover) ? Brand.surfaceHi : Color.clear)
        .contentShape(Rectangle())
        .onHover { hover = $0 }
        .animation(Motion.snap, value: hover)
    }
}

private struct ProfileEditor: View {
    @EnvironmentObject var store: AppStore

    var body: some View {
        BrandCard(padding: 18) {
            VStack(alignment: .leading, spacing: 16) {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(store.profile.ssid).display(18, weight: .semibold)
                        Text("\(store.profile.allowlist.count) trusted devices")
                            .bodyStyle(12, muted: true)
                    }
                    Spacer()
                    Pill(text: store.profile.blockMode.label,
                         color: Brand.cut, icon: "bolt.slash.fill")
                }

                Divider().background(Brand.hairline)

                // Block mode
                VStack(alignment: .leading, spacing: 8) {
                    Text("Block mode").bodyStyle(12, weight: .semibold, muted: true)
                    Picker("", selection: Binding(
                        get: { store.profile.blockMode },
                        set: { store.profile.blockMode = $0; store.upsertCurrentProfile() })) {
                        ForEach(BlockMode.allCases, id: \.self) { m in
                            Text(m.label).tag(m)
                        }
                    }
                    .pickerStyle(.segmented)
                }

                // Toggles
                Text("IPv6 blocking unavailable — use router access controls.")
                    .bodyStyle(13, muted: true)
                Toggle(isOn: Binding(
                    get: { store.profile.autoBlockHogs },
                    set: { store.profile.autoBlockHogs = $0; store.upsertCurrentProfile() })) {
                    Text("Auto-cut bandwidth hogs (>5 Mbps for 30s)").bodyStyle(13)
                }
                Toggle(isOn: Binding(
                    get: { store.profile.notifyOnNewDevice },
                    set: { store.profile.notifyOnNewDevice = $0; store.upsertCurrentProfile() })) {
                    Text("Notify when new device joins").bodyStyle(13)
                }

                Divider().background(Brand.hairline)

                HStack {
                    Text("Allowlist").bodyStyle(12, weight: .semibold, muted: true)
                    Spacer()
                    Text("\(store.profile.allowlist.count) entries").bodyStyle(11, muted: true)
                }

                ManualAllowAdder()

                if store.profile.allowlist.isEmpty {
                    Text("No trusted devices yet — drop one in Lobby, click Trust on Devices, or add a MAC manually above.")
                        .bodyStyle(12, muted: true)
                } else {
                    ScrollView {
                        LazyVStack(spacing: 8) {
                            ForEach(store.profile.allowlist) { entry in
                                HStack {
                                    Text(entry.nickname ?? entry.mac.description).bodyStyle(13)
                                    Spacer()
                                    Text(entry.mac.description).mono(11, muted: true)
                                    Button {
                                        store.removeAllowEntry(mac: entry.mac)
                                    } label: { Image(systemName: "minus.circle") }
                                    .buttonStyle(.borderless)
                                }
                                .padding(.horizontal, 12).padding(.vertical, 8)
                                .background(RoundedRectangle(cornerRadius: 8).fill(Brand.surfaceHi))
                            }
                        }
                    }
                    .frame(maxHeight: 240)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

private struct ManualAllowAdder: View {
    @EnvironmentObject var store: AppStore
    @State private var macText: String = ""
    @State private var nick: String = ""
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                TextField("aa:bb:cc:dd:ee:ff", text: $macText)
                    .textFieldStyle(.plain)
                    .font(BrandFont.mono(12))
                    .padding(.horizontal, 10).padding(.vertical, 8)
                    .background(
                        RoundedRectangle(cornerRadius: 8).fill(Brand.surfaceHi)
                            .overlay(RoundedRectangle(cornerRadius: 8).stroke(Brand.hairline))
                    )
                    .frame(width: 180)
                TextField("nickname (optional)", text: $nick)
                    .textFieldStyle(.plain)
                    .font(BrandFont.body(12))
                    .padding(.horizontal, 10).padding(.vertical, 8)
                    .background(
                        RoundedRectangle(cornerRadius: 8).fill(Brand.surfaceHi)
                            .overlay(RoundedRectangle(cornerRadius: 8).stroke(Brand.hairline))
                    )
                Button { add() } label: {
                    HStack(spacing: 4) { Image(systemName: "plus"); Text("Add") }
                }
                .buttonStyle(GhostButton(tint: Brand.trust))
            }
            if let e = error {
                Text(e).bodyStyle(11).foregroundStyle(Brand.cut)
            }
        }
    }

    private func add() {
        guard let mac = MACAddress(macText.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            error = "Invalid MAC — expected aa:bb:cc:dd:ee:ff"
            return
        }
        store.addAllowEntry(mac: mac, nickname: nick.isEmpty ? nil : nick)
        macText = ""; nick = ""; error = nil
    }
}
