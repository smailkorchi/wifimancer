import SwiftUI
import UniformTypeIdentifiers

/// Top-level "Arsenal" page. Two-pane layout:
///   1. Left rail: categories + skill filter (compact, 200 px)
///   2. Main: clean 3-column grid of attack cards for the selected
///      category. Each card shows just the title, tier badge, and a
///      destructive icon if the attack changes target state.
///
/// Clicking a card opens `AttackDetailSheet` as a modal — full
/// explainer, target picker, optional audio-file picker, command
/// preview, authorize toggle, big RUN button with phase loader, and
/// live output. This pattern fixes the prior "everything-on-one-page"
/// density problem: progressive disclosure means a glance shows
/// 20 attacks instead of 4.
struct ArsenalView: View {
    @EnvironmentObject var store: AppStore
    @StateObject private var arsenal = ArsenalStore.shared

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            CategoriesRail(arsenal: arsenal)
                .frame(width: 210)

            AttackGridPane(arsenal: arsenal, store: store)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .sheet(isPresented: $arsenal.detailOpen) {
            if let a = arsenal.selectedAttack {
                AttackDetailSheet(attack: a, arsenal: arsenal, store: store)
            }
        }
    }
}

// MARK: - Categories rail

private struct CategoriesRail: View {
    @ObservedObject var arsenal: ArsenalStore

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("ARSENAL")
                .font(BrandFont.heading(11, weight: .bold))
                .tracking(2.0)
                .foregroundStyle(Brand.cut)
            Text("\(AttackCatalog.all.count) tools")
                .font(BrandFont.heading(11, weight: .semibold))
                .foregroundStyle(Brand.muted)
                .padding(.top, -8)

            // Search inline at the top of the rail
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(Brand.mutedDim)
                TextField("search", text: $arsenal.searchText)
                    .textFieldStyle(.plain)
                    .font(BrandFont.body(11))
                    .foregroundStyle(Brand.light)
            }
            .padding(.horizontal, 8).padding(.vertical, 5)
            .background(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(Brand.surfaceLo)
                    .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .stroke(Brand.hairline, lineWidth: 0.5))
            )

            ScrollView {
                VStack(alignment: .leading, spacing: 3) {
                    Text("CATEGORY")
                        .font(BrandFont.heading(9, weight: .bold))
                        .tracking(1.6)
                        .foregroundStyle(Brand.mutedDim)
                        .padding(.top, 4)
                    CategoryRow(label: "All",
                                icon: "square.grid.2x2.fill",
                                tint: Brand.muted,
                                count: AttackCatalog.all.count,
                                selected: arsenal.selectedCategory == nil) {
                        arsenal.selectedCategory = nil
                    }
                    ForEach(orderedCategories, id: \.self) { cat in
                        let n = AttackCatalog.all.filter { $0.category == cat }.count
                        CategoryRow(label: categoryLabel(cat),
                                    icon: categoryIcon(cat),
                                    tint: categoryTint(cat),
                                    count: n,
                                    selected: arsenal.selectedCategory == cat) {
                            arsenal.selectedCategory = cat
                        }
                    }

                    Text("SKILL")
                        .font(BrandFont.heading(9, weight: .bold))
                        .tracking(1.6)
                        .foregroundStyle(Brand.mutedDim)
                        .padding(.top, 12)
                    SkillRow(label: "Any", tint: Brand.muted,
                             selected: arsenal.selectedSkill == nil) {
                        arsenal.selectedSkill = nil
                    }
                    SkillRow(label: "Beginner", tint: Brand.signal,
                             selected: arsenal.selectedSkill == .beginner) {
                        arsenal.selectedSkill = .beginner
                    }
                    SkillRow(label: "Intermediate", tint: Brand.armed,
                             selected: arsenal.selectedSkill == .intermediate) {
                        arsenal.selectedSkill = .intermediate
                    }
                    SkillRow(label: "Advanced", tint: Brand.cut,
                             selected: arsenal.selectedSkill == .advanced) {
                        arsenal.selectedSkill = .advanced
                    }
                }
            }
        }
        .padding(14)
        .frame(maxHeight: .infinity, alignment: .topLeading)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Brand.surface)
                .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .stroke(Brand.hairline, lineWidth: 0.75))
        )
    }
}

// MARK: - Attack grid

private struct AttackGridPane: View {
    @ObservedObject var arsenal: ArsenalStore
    @ObservedObject var store: AppStore

    private var columns: [GridItem] {
        [GridItem(.adaptive(minimum: 240, maximum: 320), spacing: 12, alignment: .top)]
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            // Header: chosen category + result count + reset
            HStack(spacing: 10) {
                if let cat = arsenal.selectedCategory {
                    Image(systemName: categoryIcon(cat))
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(categoryTint(cat))
                    Text(categoryLabel(cat).uppercased())
                        .font(BrandFont.heading(13, weight: .bold))
                        .tracking(1.4)
                        .foregroundStyle(Brand.light)
                } else {
                    Image(systemName: "burst.fill")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(Brand.cut)
                    Text("ALL TOOLS")
                        .font(BrandFont.heading(13, weight: .bold))
                        .tracking(1.4)
                        .foregroundStyle(Brand.light)
                }
                let filtered = arsenal.filteredAttacks()
                Text("· \(filtered.count)")
                    .font(BrandFont.heading(12, weight: .semibold))
                    .foregroundStyle(Brand.cut)
                Spacer()
                if arsenal.selectedCategory != nil || arsenal.selectedSkill != nil || !arsenal.searchText.isEmpty {
                    Button {
                        arsenal.selectedCategory = nil
                        arsenal.selectedSkill = nil
                        arsenal.searchText = ""
                    } label: {
                        Text("clear filters")
                            .font(BrandFont.heading(10, weight: .semibold))
                            .foregroundStyle(Brand.muted)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 4)

            ScrollView {
                let filtered = arsenal.filteredAttacks()
                if filtered.isEmpty {
                    VStack(spacing: 8) {
                        Image(systemName: "magnifyingglass")
                            .font(.system(size: 28, weight: .light))
                            .foregroundStyle(Brand.mutedDim)
                        Text("No tools match")
                            .bodyStyle(12, muted: true)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.top, 60)
                } else {
                    LazyVGrid(columns: columns, alignment: .leading, spacing: 12) {
                        ForEach(filtered) { a in
                            AttackCard(attack: a) {
                                arsenal.selectAttack(a)
                            }
                        }
                    }
                    .padding(.horizontal, 4)
                    .padding(.bottom, 16)
                }
            }
        }
        .padding(16)
        .frame(maxHeight: .infinity, alignment: .topLeading)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Brand.surface)
                .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .stroke(Brand.hairline, lineWidth: 0.75))
        )
    }
}

// MARK: - Attack card (in-grid)

private struct AttackCard: View {
    let attack: Attack
    let action: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .top) {
                    ZStack {
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .fill(categoryTint(attack.category).opacity(0.16))
                        Image(systemName: toolIcon(attack))
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(categoryTint(attack.category))
                    }
                    .frame(width: 30, height: 30)
                    Spacer()
                    if attack.danger == .destructive {
                        Image(systemName: "exclamationmark.shield.fill")
                            .font(.system(size: 11))
                            .foregroundStyle(Brand.threat)
                    }
                }
                Text(attack.title)
                    .font(BrandFont.heading(13, weight: .semibold))
                    .foregroundStyle(Brand.light)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                Text(attack.description)
                    .font(BrandFont.body(11))
                    .foregroundStyle(Brand.muted)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                Spacer(minLength: 0)
                HStack(spacing: 4) {
                    TinyBadge(text: attack.tier.label, color: tierTint(attack.tier))
                    if attack.executor == .kaliRange {
                        TinyBadge(text: "RF-RANGE", color: Brand.armed)
                    } else {
                        TinyBadge(text: attack.skill.label, color: skillTint(attack.skill))
                    }
                    Spacer(minLength: 0)
                    if attack.requiresAudioFile {
                        Image(systemName: "music.note")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(Brand.info)
                    }
                    Image(systemName: attack.executor == .local ? "macbook" :
                          attack.executor == .kaliRange ? "antenna.radiowaves.left.and.right" :
                          "server.rack")
                        .font(.system(size: 9))
                        .foregroundStyle(attack.executor == .kaliRange ? Brand.armed : Brand.mutedDim)
                }
            }
            .padding(12)
            .frame(height: 138, alignment: .topLeading)
            .frame(maxWidth: .infinity, alignment: .topLeading)
            .background(
                RoundedRectangle(cornerRadius: 11, style: .continuous)
                    .fill(hover ? Brand.surfaceHi : Brand.surfaceLo)
                    .overlay(
                        RoundedRectangle(cornerRadius: 11, style: .continuous)
                            .stroke(hover ? categoryTint(attack.category).opacity(0.45) : Brand.hairline,
                                    lineWidth: 0.75)
                    )
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
        .animation(Motion.snap, value: hover)
    }
}

// MARK: - Detail sheet

private struct AttackDetailSheet: View {
    let attack: Attack
    @ObservedObject var arsenal: ArsenalStore
    @ObservedObject var store: AppStore
    @State private var showFilePicker = false
    @State private var showExplainer = true
    @State private var showCommand = false

    private let wifi = WiFiClient.shared

    func triggerWiFiScan() async {
        guard store.wifiList.isEmpty else { return }
        let nets = (try? await wifi.scan()) ?? []
        await MainActor.run { store.wifiList = nets }
    }

    var body: some View {
        VStack(spacing: 0) {
            sheetHeader
            Divider().background(Brand.hairline)
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    badgesRow
                    if showExplainer { explainerCard }
                    if attack.requiresAudioFile { audioFileCard }
                    targetCard
                    runCard
                    outputCard
                    if !attack.nextSteps.isEmpty { nextStepsCard }
                    commandCard
                }
                .padding(20)
            }
        }
        .frame(minWidth: 760, idealWidth: 880, minHeight: 600, idealHeight: 760)
        .background(Brand.dark)
        .fileImporter(isPresented: $showFilePicker,
                      allowedContentTypes: audioContentTypes,
                      allowsMultipleSelection: false) { result in
            if case .success(let urls) = result, let u = urls.first {
                arsenal.audioFileURL = u
            }
        }
    }

    private var audioContentTypes: [UTType] {
        var t: [UTType] = [.audio, .mp3]
        if let aac = UTType("public.aac-audio") { t.append(aac) }
        if let m4a = UTType("public.mpeg-4-audio") { t.append(m4a) }
        return t
    }

    // MARK: header

    private var sheetHeader: some View {
        HStack(alignment: .top, spacing: 14) {
            ZStack {
                RoundedRectangle(cornerRadius: 11, style: .continuous)
                    .fill(categoryTint(attack.category).opacity(0.18))
                    .overlay(RoundedRectangle(cornerRadius: 11, style: .continuous)
                        .stroke(categoryTint(attack.category).opacity(0.6), lineWidth: 1))
                Image(systemName: toolIcon(attack))
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundStyle(categoryTint(attack.category))
            }
            .frame(width: 50, height: 50)

            VStack(alignment: .leading, spacing: 2) {
                Text(attack.title)
                    .font(BrandFont.heading(18, weight: .semibold))
                    .foregroundStyle(Brand.light)
                    .lineLimit(2)
                HStack(spacing: 6) {
                    Text(attack.tool)
                        .font(BrandFont.mono(11))
                        .foregroundStyle(Brand.signal)
                    Text("·")
                        .foregroundStyle(Brand.mutedDim)
                    Text(categoryLabel(attack.category))
                        .font(BrandFont.heading(11, weight: .medium))
                        .foregroundStyle(Brand.muted)
                }
            }
            Spacer()
            Button { arsenal.dismissDetail() } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 22, weight: .regular))
                    .foregroundStyle(Brand.muted)
            }
            .buttonStyle(.plain)
            .keyboardShortcut(.escape, modifiers: [])
        }
        .padding(20)
        .background(Brand.surface)
    }

    // MARK: badges

    private var badgesRow: some View {
        FlowLayout(spacing: 6) {
            Pill(text: attack.tier.label, color: tierTint(attack.tier), icon: tierIcon(attack.tier))
            Pill(text: attack.skill.label, color: skillTint(attack.skill), icon: "graduationcap.fill")
            Pill(text: attack.danger.label, color: dangerTint(attack.danger), icon: "exclamationmark.shield.fill")
            Pill(text: attack.noise.label, color: noiseTint(attack.noise), icon: "waveform")
            Pill(text: {
                    switch attack.executor {
                    case .local:     "RUNS LOCAL"
                    case .kaliRange: "KALI — RF IN RANGE"
                    default:         "RUNS ON KALI"
                    }
                 }(),
                 color: attack.executor == .local ? Brand.info :
                        attack.executor == .kaliRange ? Brand.armed : Brand.signal,
                 icon: attack.executor == .local ? "macbook" :
                       attack.executor == .kaliRange ? "antenna.radiowaves.left.and.right" :
                       "server.rack")
            if attack.aptPackage != nil || attack.brewPackage != nil {
                Pill(text: "AUTO-INSTALL", color: Brand.trust, icon: "shippingbox.fill")
            }
        }
    }

    // MARK: explainer

    private var explainerCard: some View {
        InsetCard(title: "WHAT THIS DOES", tint: Brand.info,
                  trailing: { collapseToggle($showExplainer) }) {
            Text(attack.explainer.isEmpty ? attack.description : attack.explainer)
                .bodyStyle(13)
                .foregroundStyle(Brand.subtle)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: audio file picker

    private var audioFileCard: some View {
        InsetCard(title: "AUDIO FILE", tint: Brand.cut, trailing: { EmptyView() }) {
            HStack(alignment: .center, spacing: 12) {
                ZStack {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(Brand.cut.opacity(0.14))
                    Image(systemName: arsenal.audioFileURL == nil ? "music.note" : "waveform")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(Brand.cut)
                }
                .frame(width: 38, height: 38)

                VStack(alignment: .leading, spacing: 2) {
                    if let url = arsenal.audioFileURL {
                        Text(url.lastPathComponent)
                            .font(BrandFont.heading(13, weight: .semibold))
                            .foregroundStyle(Brand.light)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Text(url.deletingLastPathComponent().path)
                            .font(BrandFont.mono(10))
                            .foregroundStyle(Brand.mutedDim)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    } else {
                        Text("No file picked")
                            .font(BrandFont.heading(13, weight: .semibold))
                            .foregroundStyle(Brand.muted)
                        Text("Falls back to ~/Downloads/faaah.mp3")
                            .font(BrandFont.body(10))
                            .foregroundStyle(Brand.mutedDim)
                    }
                }
                Spacer()
                Button { showFilePicker = true } label: {
                    HStack(spacing: 5) {
                        Image(systemName: "folder.fill").font(.system(size: 11))
                        Text(arsenal.audioFileURL == nil ? "Pick" : "Change")
                            .font(BrandFont.heading(11, weight: .semibold))
                    }
                    .foregroundStyle(Brand.light)
                    .padding(.horizontal, 12).padding(.vertical, 6)
                    .background(Capsule().fill(Brand.cut))
                }
                .buttonStyle(.plain)
                if arsenal.audioFileURL != nil {
                    Button { arsenal.audioFileURL = nil } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 16))
                            .foregroundStyle(Brand.mutedDim)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    // MARK: target

    @ViewBuilder
    private var targetCard: some View {
        if attack.category == .wireless {
            wirelessTargetCard
        } else {
            lanTargetCard
        }
    }

    /// Wireless target picker — shows nearby Wi-Fi networks (not LAN
    /// devices) because wireless attacks consume BSSID/ESSID/channel,
    /// not an IP address.
    private var wirelessTargetCard: some View {
        let nets = store.wifiList.sorted { $0.rssi > $1.rssi }
        return InsetCard(title: "WI-FI TARGET — \(nets.count) in range",
                         tint: Brand.signal, trailing: { EmptyView() }) {
            if nets.isEmpty {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Scanning nearby Wi-Fi…")
                        .bodyStyle(11, muted: true)
                }
                .padding(.vertical, 4)
                .task { await triggerWiFiScan() }
            } else {
                FlowLayout(spacing: 6) {
                    ForEach(nets) { n in
                        WiFiTargetChip(network: n,
                                       selected: arsenal.selectedWiFi?.id == n.id) {
                            arsenal.setWiFiTarget(n)
                        }
                    }
                }
                if let sel = arsenal.selectedWiFi {
                    HStack(spacing: 6) {
                        Image(systemName: "antenna.radiowaves.left.and.right")
                            .font(.system(size: 10)).foregroundStyle(Brand.signal)
                        Text("Selected:")
                            .font(BrandFont.heading(10, weight: .bold))
                            .tracking(1.4).foregroundStyle(Brand.mutedDim)
                        Text(sel.ssid)
                            .font(BrandFont.heading(11, weight: .semibold))
                            .foregroundStyle(Brand.light)
                        if let b = sel.bssid {
                            Text("·").foregroundStyle(Brand.mutedDim)
                            Text(b).font(BrandFont.mono(10)).foregroundStyle(Brand.muted)
                        }
                        if sel.channel > 0 {
                            Text("·").foregroundStyle(Brand.mutedDim)
                            Text("ch \(sel.channel)").font(BrandFont.mono(10)).foregroundStyle(Brand.muted)
                        }
                        Spacer()
                    }
                    .padding(.top, 6)
                }
            }
        }
    }

    private var lanTargetCard: some View {
        let compatible = arsenal.compatibleTargets(from: store.devices)
        let targetLabel = attack.requiresAudioFile ? "available" : "compatible"
        return InsetCard(title: "TARGET — \(compatible.count) \(targetLabel)",
                         tint: Brand.signal, trailing: { EmptyView() }) {
            if compatible.isEmpty {
                Text("No devices on this LAN match this attack's class set.")
                    .bodyStyle(11, muted: true)
                    .padding(.vertical, 4)
            } else {
                FlowLayout(spacing: 6) {
                    ForEach(compatible) { d in
                        TargetChip(device: d,
                                   selected: arsenal.selectedTarget?.id == d.id,
                                   addressConflict: store.hasAddressConflict(d)) {
                            arsenal.setSelectedTargetAndPreview(d)
                        }
                    }
                }
            }
        }
    }

    // MARK: run

    private var runCard: some View {
        InsetCard(title: runCardTitle, tint: runCardTint, trailing: { EmptyView() }) {
            VStack(alignment: .leading, spacing: 12) {
                // Range gate — shown only for kaliRange attacks
                if attack.executor == .kaliRange {
                    kaliRangeGate
                }
                HStack(spacing: 10) {
                    Toggle(isOn: $arsenal.attackAuthorized) {
                        Text("I am authorized to run this against the target")
                            .font(BrandFont.heading(12, weight: .medium))
                            .foregroundStyle(arsenal.attackAuthorized ? Brand.cut : Brand.muted)
                    }
                    .toggleStyle(.checkbox)
                    Spacer()
                    runButton
                }
                if case .running = arsenal.status {
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text(arsenal.phase.isEmpty ? "Running…" : arsenal.phase)
                            .font(BrandFont.heading(12, weight: .semibold))
                            .foregroundStyle(Brand.signal)
                            .contentTransition(.opacity)
                        Spacer()
                    }
                    .padding(.horizontal, 12).padding(.vertical, 8)
                    .background(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .fill(Brand.signal.opacity(0.12))
                            .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .stroke(Brand.signal.opacity(0.4), lineWidth: 0.75))
                    )
                }
            }
        }
    }

    @ViewBuilder
    private var kaliRangeGate: some View {
        let state = arsenal.kaliRangeState
        let targetBSSID = arsenal.selectedWiFi?.bssid
        VStack(alignment: .leading, spacing: 8) {
            // Manual confirmation toggle — the user knows better than iw dev
            HStack(spacing: 10) {
                Toggle(isOn: $arsenal.kaliRangeConfirmed) {
                    VStack(alignment: .leading, spacing: 1) {
                        Text("Kali Linux is physically next to the target AP")
                            .font(BrandFont.heading(12, weight: .medium))
                            .foregroundStyle(arsenal.kaliRangeConfirmed ? Brand.armed : Brand.muted)
                        Text("Requires a monitor-mode Wi-Fi adapter (Alfa AWUS036ACM, Panda PAU09, etc.) attached to Kali")
                            .font(BrandFont.body(10))
                            .foregroundStyle(Brand.mutedDim)
                    }
                }
                .toggleStyle(.checkbox)
                Spacer()
                // Optional probe button — verifies adapter + BSSID visibility, but doesn't block the toggle
                Button { arsenal.probeKaliRange() } label: {
                    HStack(spacing: 4) {
                        if case .probing = state {
                            ProgressView().controlSize(.mini)
                        } else {
                            Image(systemName: "scope").font(.system(size: 9, weight: .bold))
                        }
                        Text("VERIFY ADAPTER").font(BrandFont.heading(9, weight: .bold)).tracking(0.8)
                    }
                    .foregroundStyle(Brand.muted)
                    .padding(.horizontal, 9).padding(.vertical, 4)
                    .background(Capsule().stroke(Brand.muted.opacity(0.5), lineWidth: 0.75))
                }
                .buttonStyle(.plain)
                .disabled(state == .probing)
            }
            // Probe result shown below, non-blocking
            if state != .unknown {
                HStack(spacing: 6) {
                    Image(systemName: probeIcon(state, targetBSSID: targetBSSID))
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(probeTint(state, targetBSSID: targetBSSID))
                    Text(rangeStatusLine(state, targetBSSID: targetBSSID))
                        .font(BrandFont.body(10))
                        .foregroundStyle(Brand.mutedDim)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .padding(.horizontal, 10).padding(.vertical, 9)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(arsenal.kaliRangeConfirmed ? Brand.armed.opacity(0.08) : Brand.surfaceLo)
                .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .stroke(arsenal.kaliRangeConfirmed ? Brand.armed.opacity(0.45) : Brand.hairline,
                            lineWidth: 0.75))
        )
    }

    private func probeIcon(_ state: ArsenalStore.RangeState, targetBSSID: String?) -> String {
        switch state {
        case .probing:   return "waveform"
        case .inRange(_, _):
            return arsenal.kaliRangeSees(bssid: targetBSSID) ? "checkmark.circle.fill" : "exclamationmark.triangle.fill"
        case .notInRange: return "antenna.radiowaves.left.and.right.slash"
        case .unknown:    return "scope"
        }
    }

    private func probeTint(_ state: ArsenalStore.RangeState, targetBSSID: String?) -> Color {
        switch state {
        case .probing:   return Brand.signal
        case .inRange:   return arsenal.kaliRangeSees(bssid: targetBSSID) ? Brand.trust : Brand.armed
        case .notInRange: return Brand.threat
        case .unknown:   return Brand.muted
        }
    }

    private func rangeStatusLine(_ state: ArsenalStore.RangeState,
                                  targetBSSID: String?) -> String {
        switch state {
        case .unknown:   return ""
        case .probing:   return "Scanning via iw dev… (~10 s)"
        case .inRange(let iface, let vis):
            let seen = arsenal.kaliRangeSees(bssid: targetBSSID)
            if seen { return "✓ Kali (\(iface)) sees target BSSID — \(vis.count) APs total" }
            return "Kali (\(iface)) has adapter (\(vis.count) APs) but target BSSID not audible yet — move Kali closer or wait for beacon"
        case .notInRange(let reason):
            if reason.contains("NOIFACE") || reason.contains("no wireless") || reason.contains("exit 2") {
                return "No wireless adapter detected on Kali. Attach a USB monitor-mode adapter (Alfa AWUS036ACM) and re-probe."
            }
            return "Kali unreachable via SSH: \(reason). Check Tailscale."
        }
    }

    private var runCardTitle: String {
        switch arsenal.status {
        case .idle:    return "RUN"
        case .running: return "RUNNING — \(arsenal.phase.isEmpty ? "in progress" : arsenal.phase.lowercased())"
        case .finished(_, let code): return code == 0 ? "RUN — DONE" : "RUN — FAILED (exit \(code))"
        }
    }
    private var runCardTint: Color {
        switch arsenal.status {
        case .idle:    return Brand.cut
        case .running: return Brand.signal
        case .finished(_, let code): return code == 0 ? Brand.trust : Brand.threat
        }
    }

    private var runButton: some View {
        let hasTarget: Bool = attack.category == .wireless
            ? (arsenal.selectedWiFi != nil)
            : (arsenal.selectedTarget != nil)
        // kaliRange attacks additionally require the user to confirm Kali is nearby
        let kaliGateOk: Bool = attack.executor != .kaliRange || arsenal.kaliRangeConfirmed
        let canRun = arsenal.attackAuthorized && hasTarget && kaliGateOk
        let running: Bool = {
            if case .running = arsenal.status { return true }
            return false
        }()
        return Button {
            if running { arsenal.cancelCurrent() }
            else       { arsenal.runSelected() }
        } label: {
            HStack(spacing: 6) {
                if running {
                    Image(systemName: "stop.fill").font(.system(size: 11, weight: .bold))
                    Text("STOP").font(BrandFont.heading(12, weight: .bold)).tracking(1.5)
                } else {
                    Image(systemName: "play.fill").font(.system(size: 11, weight: .bold))
                    Text("RUN").font(BrandFont.heading(12, weight: .bold)).tracking(1.5)
                }
            }
            .foregroundStyle(canRun || running ? Brand.light : Brand.mutedDim)
            .padding(.horizontal, 22).padding(.vertical, 8)
            .background(
                Capsule()
                    .fill(running ? Brand.threat : (canRun ? Brand.cut : Brand.surfaceHi))
            )
        }
        .buttonStyle(.plain)
        .disabled(!canRun && !running)
    }

    // MARK: output

    private var outputCard: some View {
        InsetCard(title: "OUTPUT", tint: Brand.signal,
                  trailing: { outputCardTrailing }) {
            if arsenal.lines.isEmpty {
                Text("(no output yet)")
                    .bodyStyle(11, muted: true)
                    .padding(.vertical, 6)
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 1) {
                            ForEach(arsenal.lines) { l in
                                Text(l.text)
                                    .font(BrandFont.mono(11))
                                    .foregroundStyle(lineColor(l))
                                    .textSelection(.enabled)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .id(l.id)
                            }
                        }
                        .padding(8)
                    }
                    .frame(height: 280)
                    .background(
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .fill(Brand.dark)
                            .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous)
                                .stroke(Brand.hairline, lineWidth: 0.5))
                    )
                    .onChange(of: arsenal.lines.count) { _, _ in
                        if let last = arsenal.lines.last {
                            withAnimation(Motion.snap) {
                                proxy.scrollTo(last.id, anchor: .bottom)
                            }
                        }
                    }
                }
            }
        }
    }

    private func lineColor(_ l: AttackPadModel.OutputLine) -> Color {
        if l.isStderr { return Brand.threat.opacity(0.85) }
        // Highlight phase-tag lines so the eye finds them quickly
        let s = l.text
        if s.contains("[HIT]")    { return Brand.trust }
        if s.contains("[MISS]")   { return Brand.armed }
        if s.contains("[RESULT]") { return Brand.cut }
        if s.contains("[PROBE]") || s.contains("[TRY]") { return Brand.signal }
        return Brand.subtle
    }

    @ViewBuilder
    private var outputCardTrailing: some View {
        HStack(spacing: 8) {
            Text("\(arsenal.lines.count) lines")
                .font(BrandFont.mono(10))
                .foregroundStyle(Brand.mutedDim)
            if !arsenal.lines.isEmpty {
                Button(action: arsenal.clearOutput) {
                    Text("clear")
                        .font(BrandFont.heading(10, weight: .semibold))
                        .foregroundStyle(Brand.mutedDim)
                }
                .buttonStyle(.plain)
            }
        }
    }

    // MARK: next steps

    private var nextStepsCard: some View {
        InsetCard(title: "NEXT STEPS", tint: Brand.trust, trailing: { EmptyView() }) {
            VStack(alignment: .leading, spacing: 6) {
                ForEach(Array(attack.nextSteps.enumerated()), id: \.offset) { _, s in
                    HStack(alignment: .top, spacing: 8) {
                        Image(systemName: "arrow.turn.down.right")
                            .font(.system(size: 10, weight: .bold))
                            .foregroundStyle(Brand.trust)
                        Text(s)
                            .bodyStyle(12)
                            .foregroundStyle(Brand.subtle)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
    }

    // MARK: command (collapsed by default)

    private var commandCard: some View {
        InsetCard(title: "COMMAND (advanced)", tint: Brand.muted,
                  trailing: { collapseToggle($showCommand) }) {
            if showCommand {
                VStack(alignment: .leading, spacing: 6) {
                    if arsenal.commandPreview.isEmpty {
                        Text("(pick a target — the command renders against it)")
                            .bodyStyle(11, muted: true)
                    } else {
                        Text(arsenal.commandPreview)
                            .font(BrandFont.mono(10))
                            .foregroundStyle(Brand.subtle)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(8)
                            .background(
                                RoundedRectangle(cornerRadius: 6, style: .continuous)
                                    .fill(Brand.dark)
                                    .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous)
                                        .stroke(Brand.hairline, lineWidth: 0.5))
                            )
                        Button {
                            let pb = NSPasteboard.general
                            pb.clearContents()
                            pb.setString(arsenal.commandPreview, forType: .string)
                        } label: {
                            HStack(spacing: 4) {
                                Image(systemName: "doc.on.doc").font(.system(size: 10))
                                Text("copy").font(BrandFont.heading(10, weight: .semibold))
                            }
                            .foregroundStyle(Brand.muted)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
    }

    private func collapseToggle(_ binding: Binding<Bool>) -> some View {
        Button { binding.wrappedValue.toggle() } label: {
            Image(systemName: binding.wrappedValue ? "chevron.up" : "chevron.down")
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(Brand.muted)
        }
        .buttonStyle(.plain)
    }
}

// MARK: - small reusable views

private struct InsetCard<Content: View, Trailing: View>: View {
    let title: String
    let tint: Color
    @ViewBuilder var trailing: () -> Trailing
    @ViewBuilder var content: () -> Content
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(title)
                    .font(BrandFont.heading(10, weight: .bold))
                    .tracking(2.0)
                    .foregroundStyle(tint)
                Spacer()
                trailing()
            }
            content()
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 11, style: .continuous)
                .fill(Brand.surface.opacity(0.7))
                .overlay(
                    RoundedRectangle(cornerRadius: 11, style: .continuous)
                        .stroke(tint.opacity(0.25), lineWidth: 0.75)
                )
        )
    }
}

private struct CategoryRow: View {
    let label: String
    let icon: String
    let tint: Color
    let count: Int
    let selected: Bool
    let action: () -> Void
    @State private var hover = false
    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: icon)
                    .font(.system(size: 12, weight: selected ? .bold : .medium))
                    .foregroundStyle(selected ? tint : Brand.muted)
                    .frame(width: 18)
                Text(label)
                    .font(BrandFont.heading(12, weight: selected ? .semibold : .medium))
                    .foregroundStyle(selected ? Brand.light : Brand.muted)
                Spacer()
                Text("\(count)")
                    .font(BrandFont.mono(10))
                    .foregroundStyle(selected ? tint : Brand.mutedDim)
            }
            .padding(.horizontal, 9).padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(selected ? tint.opacity(0.14) : (hover ? Brand.surfaceLo : .clear))
                    .overlay(
                        RoundedRectangle(cornerRadius: 7, style: .continuous)
                            .stroke(selected ? tint.opacity(0.45) : .clear, lineWidth: 1)
                    )
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
    }
}

private struct SkillRow: View {
    let label: String
    let tint: Color
    let selected: Bool
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Circle()
                    .fill(selected ? tint : tint.opacity(0.3))
                    .frame(width: 7, height: 7)
                Text(label)
                    .font(BrandFont.heading(11, weight: selected ? .semibold : .medium))
                    .foregroundStyle(selected ? Brand.light : Brand.muted)
                Spacer()
            }
            .padding(.horizontal, 9).padding(.vertical, 4)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(selected ? tint.opacity(0.12) : .clear)
            )
        }
        .buttonStyle(.plain)
    }
}

private struct TargetChip: View {
    let device: Device
    let selected: Bool
    var addressConflict = false
    let action: () -> Void
    @State private var hover = false
    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: device.kind.sfSymbol)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(selected ? Brand.cut : Brand.muted)
                VStack(alignment: .leading, spacing: 0) {
                    Text(device.displayName == device.ipv4 ? "Unknown device" : device.displayName)
                        .font(BrandFont.heading(11, weight: selected ? .semibold : .medium))
                        .foregroundStyle(selected ? Brand.light : Brand.subtle)
                        .lineLimit(1)
                    if let model = device.displayModel, model != device.displayName {
                        Text(model)
                            .font(BrandFont.body(9))
                            .foregroundStyle(Brand.muted)
                            .lineLimit(1)
                    }
                    Text((device.ipv4 ?? device.mac.description)
                         + (addressConflict ? " · IP conflict · " + String(device.mac.description.suffix(8)) : ""))
                        .font(BrandFont.mono(9))
                        .foregroundStyle(addressConflict ? Brand.warning : Brand.mutedDim)
                        .lineLimit(1)
                }
            }
            .padding(.horizontal, 9).padding(.vertical, 5)
            .background(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(selected ? Brand.cut.opacity(0.14) : (hover ? Brand.surfaceLo : Brand.surface))
                    .overlay(
                        RoundedRectangle(cornerRadius: 7, style: .continuous)
                            .stroke(selected ? Brand.cut.opacity(0.5) : Brand.hairline, lineWidth: 0.75)
                    )
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("\(device.classificationSource)\n\(device.identification?.manufacturer ?? device.vendor ?? "Unknown maker")\n\(device.mac.description)")
        .onHover { hover = $0 }
    }
}

private struct WiFiTargetChip: View {
    let network: WiFiNetwork
    let selected: Bool
    let action: () -> Void
    @State private var hover = false
    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: signalIcon)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(selected ? Brand.cut : signalTint)
                VStack(alignment: .leading, spacing: 0) {
                    HStack(spacing: 4) {
                        Text(network.ssid.isEmpty ? "<hidden>" : network.ssid)
                            .font(BrandFont.heading(11, weight: selected ? .semibold : .medium))
                            .foregroundStyle(selected ? Brand.light : Brand.subtle)
                            .lineLimit(1)
                        if network.security.requiresPassword {
                            Image(systemName: "lock.fill")
                                .font(.system(size: 8))
                                .foregroundStyle(Brand.mutedDim)
                        }
                    }
                    HStack(spacing: 4) {
                        if let b = network.bssid {
                            Text(b)
                                .font(BrandFont.mono(9))
                                .foregroundStyle(Brand.mutedDim)
                                .lineLimit(1)
                        }
                        if network.channel > 0 {
                            Text("ch\(network.channel)")
                                .font(BrandFont.mono(9))
                                .foregroundStyle(Brand.mutedDim)
                        }
                    }
                }
            }
            .padding(.horizontal, 9).padding(.vertical, 5)
            .background(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(selected ? Brand.cut.opacity(0.14) : (hover ? Brand.surfaceLo : Brand.surface))
                    .overlay(
                        RoundedRectangle(cornerRadius: 7, style: .continuous)
                            .stroke(selected ? Brand.cut.opacity(0.5) : Brand.hairline, lineWidth: 0.75)
                    )
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
    }

    private var signalIcon: String {
        switch network.bars {
        case 4: "wifi"
        case 3: "wifi"
        case 2: "wifi"
        case 1: "wifi.exclamationmark"
        default: "wifi.slash"
        }
    }
    private var signalTint: Color {
        if network.rssi > -55 { return Brand.trust }
        if network.rssi > -70 { return Brand.signal }
        if network.rssi > -85 { return Brand.armed }
        return Brand.threat
    }
}

private struct TinyBadge: View {
    let text: String
    let color: Color
    var body: some View {
        Text(text)
            .font(BrandFont.heading(8, weight: .bold))
            .tracking(0.8)
            .foregroundStyle(color)
            .padding(.horizontal, 5).padding(.vertical, 2)
            .background(
                RoundedRectangle(cornerRadius: 3, style: .continuous)
                    .fill(color.opacity(0.14))
                    .overlay(
                        RoundedRectangle(cornerRadius: 3, style: .continuous)
                            .stroke(color.opacity(0.35), lineWidth: 0.5)
                    )
            )
    }
}

// MARK: - shared helpers (file-private)

private let orderedCategories: [Attack.Category] = [
    .recon, .web, .smb, .ssh, .camera, .router,
    .ad, .wireless, .media, .password, .printer,
    .iot, .dns, .bluetooth, .mobile, .mitm, .exploit
]

private func categoryLabel(_ c: Attack.Category) -> String {
    switch c {
    case .recon: "Recon"
    case .web: "Web"
    case .smb: "SMB / Windows"
    case .ssh: "SSH"
    case .camera: "Camera"
    case .router: "Router"
    case .ad: "Active Directory"
    case .wireless: "Wireless"
    case .media: "Media (TV / Speakers)"
    case .password: "Password"
    case .printer: "Printer"
    case .iot: "IoT"
    case .dns: "DNS"
    case .bluetooth: "Bluetooth"
    case .mobile: "Mobile"
    case .mitm: "MITM"
    case .exploit: "Exploits / CVEs"
    }
}

private func categoryIcon(_ c: Attack.Category) -> String {
    switch c {
    case .recon: "scope"
    case .web: "globe"
    case .smb: "folder.fill"
    case .ssh: "terminal.fill"
    case .camera: "video.fill"
    case .router: "wifi.router.fill"
    case .ad: "person.2.crop.square.stack.fill"
    case .wireless: "antenna.radiowaves.left.and.right"
    case .media: "tv.fill"
    case .password: "key.fill"
    case .printer: "printer.fill"
    case .iot: "lightbulb.fill"
    case .dns: "network"
    case .bluetooth: "wave.3.right.circle.fill"
    case .mobile: "iphone"
    case .mitm: "arrow.left.and.right.righttriangle.left.righttriangle.right.fill"
    case .exploit: "burst.fill"
    }
}

private func categoryTint(_ c: Attack.Category) -> Color {
    switch c {
    case .recon, .dns: Brand.signal
    case .web, .ad: Brand.info
    case .smb, .ssh: Brand.armed
    case .camera, .media: Brand.cut
    case .router, .iot: Brand.trust
    case .wireless, .bluetooth, .mobile: Brand.privacy
    case .password, .exploit: Brand.threat
    case .printer: Brand.muted
    case .mitm: Brand.armed
    }
}
private func tierTint(_ t: Attack.Tier) -> Color {
    switch t { case .quick: Brand.signal; case .heavy: Brand.armed; case .slow: Brand.cut }
}
private func tierIcon(_ t: Attack.Tier) -> String {
    switch t { case .quick: "bolt.fill"; case .heavy: "flame.fill"; case .slow: "hourglass" }
}
private func skillTint(_ s: Attack.Skill) -> Color {
    switch s { case .beginner: Brand.signal; case .intermediate: Brand.armed; case .advanced: Brand.cut }
}
private func dangerTint(_ d: Attack.Danger) -> Color {
    switch d {
    case .passive: Brand.trust
    case .observation: Brand.info
    case .intrusive: Brand.armed
    case .destructive: Brand.threat
    }
}
private func noiseTint(_ n: Attack.Noise) -> Color {
    switch n {
    case .silent: Brand.trust
    case .quiet: Brand.info
    case .loud: Brand.armed
    case .veryLoud: Brand.threat
    }
}

/// Per-tool icon for the card thumbnail. Falls back to category icon
/// for tools we haven't curated. Higher specificity = better at-a-glance.
private func toolIcon(_ a: Attack) -> String {
    switch a.tool {
    case "nmap":         "scope"
    case "hydra":        "key.fill"
    case "nikto":        "shield.lefthalf.filled"
    case "ffuf",
         "feroxbuster":  "magnifyingglass.circle.fill"
    case "wpscan":       "globe.badge.chevron.backward"
    case "netexec",
         "smbclient":    "folder.fill"
    case "responder":    "wave.3.right"
    case "curl":         "arrow.down.circle"
    case "onesixtyone":  "antenna.radiowaves.left.and.right"
    case "upnpc":        "network"
    case "searchsploit": "doc.text.magnifyingglass"
    case "whatweb":      "info.circle"
    case "atvremote":    "appletv.fill"
    case "catt":         "tv.fill"
    case "sonos":        "speaker.wave.3.fill"
    case "dns-sd":       "antenna.radiowaves.left.and.right.circle.fill"
    case "ffmpeg":       "film"
    case "say":          "waveform.and.mic"
    case "adb":          "iphone.gen3"
    case "hcitool",
         "system_profiler": "wave.3.right.circle"
    case "etherwake":    "power"
    case "mosquitto_sub": "lightbulb.fill"
    case "coap-client":  "lightbulb.fill"
    case "python3":      "lightbulb.fill"
    case "ipptool",
         "lpr":          "printer.fill"
    case "praeda":       "printer.fill"
    case "nc":           "terminal"
    case "bettercap":    "arrow.left.and.right.righttriangle.left.righttriangle.right.fill"
    case "dig",
         "mtr":          "network"
    case "subfinder",
         "dnsx":         "globe.americas.fill"
    case "iw",
         "reaver":       "antenna.radiowaves.left.and.right"
    case "hashcat",
         "john":         "key.fill"
    case "impacket":     "person.2.crop.square.stack.fill"
    default:             categoryIcon(a.category)
    }
}
