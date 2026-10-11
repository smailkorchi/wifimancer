import SwiftUI

struct NetworksView: View {
    @EnvironmentObject var coord: AppCoordinator
    @EnvironmentObject var store: AppStore
    @EnvironmentObject var helper: HelperClient
    @EnvironmentObject var loc: LocationGate
    @StateObject private var wifi = WiFiClient.shared

    @State private var nets: [WiFiNetwork] = []
    @State private var loading: Bool = false
    @State private var selected: WiFiNetwork?
    @State private var password: String = ""
    @State private var showPassword: Bool = false
    @State private var joining: Bool = false
    /// SSID currently being joined — drives the inline row spinner so a silent
    /// tap-to-rejoin (no sheet) still shows progress, and so the sheet can
    /// indicate which AP it's negotiating with.
    @State private var joiningSSID: String? = nil
    @State private var hiddenSheet: Bool = false
    @State private var hiddenSSID: String = ""
    @State private var hiddenPassword: String = ""
    @State private var query: String = ""
    /// Cached SSID. We DON'T call `wifi.currentSSID()` from inside `body`
    /// because on macOS 26 that read can synchronously block on the wifi
    /// xpc client mutex when airportd is busy (e.g. recovering from an ARP
    /// disruption). Reading it inside body would freeze the entire app.
    @State private var currentSSIDCached: String? = nil

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                SectionHeader(
                    "Networks",
                    subtitle: subtitle,
                    trailing: AnyView(headerButtons)
                )

                if !loc.ssidUnlocked { LocationBanner() }

                currentCard

                if !filtered(known).isEmpty {
                    listCard(title: "Known Networks",
                             subtitle: "Saved on this Mac · tap to rejoin",
                             items: filtered(known),
                             knownStyle: true)
                }

                if !filtered(other).isEmpty {
                    listCard(title: "Other Networks",
                             subtitle: nil,
                             items: filtered(other),
                             knownStyle: false)
                }

                if nets.isEmpty && !loading { emptyState }
            }
            .padding(.bottom, 24)
        }
        .task {
            // Refresh the cached SSID off the body path — calling currentSSID
            // synchronously inside `body` blocks the app when airportd is slow.
            await refreshCurrentSSID()
            await rescan()
        }
        .sheet(item: $selected) { net in joinSheet(for: net) }
        .sheet(isPresented: $hiddenSheet) { hiddenSheetBody }
    }

    private func refreshCurrentSSID() async {
        // The previous version did `Task.detached { MainActor.run { currentSSID() } }`
        // which still hopped back to main and blocked there if airportd's xpc
        // was wedged — the same freeze we hit when airportd was SIGSTOP'd.
        // `currentSSIDAsync` reads CoreWLAN entirely off the main actor and
        // bails after a 3s timeout, so a stuck wifid is now a graceful
        // "SSID unknown" instead of a permanent freeze.
        currentSSIDCached = await wifi.currentSSIDAsync()
    }

    // MARK: data slicing

    private var known: [WiFiNetwork] { nets.filter { $0.isKnown } }
    private var other: [WiFiNetwork] { nets.filter { !$0.isKnown } }

    private func filtered(_ list: [WiFiNetwork]) -> [WiFiNetwork] {
        guard !query.isEmpty else { return list }
        let q = query.lowercased()
        return list.filter { $0.ssid.lowercased().contains(q) }
    }

    private var subtitle: String {
        let k = known.count, o = other.count
        if nets.isEmpty { return loading ? "Scanning…" : "No networks in range" }
        return "\(k) known · \(o) other"
    }

    // MARK: header

    private var headerButtons: AnyView {
        AnyView(
            HStack(spacing: 8) {
                if !nets.isEmpty {
                    HStack(spacing: 6) {
                        Image(systemName: "magnifyingglass").foregroundStyle(Brand.muted)
                        TextField("filter", text: $query)
                            .textFieldStyle(.plain)
                            .font(BrandFont.body(12))
                    }
                    .padding(.horizontal, 10).padding(.vertical, 6)
                    .frame(width: 160)
                    .background(
                        RoundedRectangle(cornerRadius: 8).fill(Brand.surfaceHi)
                            .overlay(RoundedRectangle(cornerRadius: 8).stroke(Brand.hairline))
                    )
                }
                Button { hiddenSheet = true } label: {
                    HStack(spacing: 6) { Image(systemName: "wifi.exclamationmark"); Text("Hidden") }
                }
                .buttonStyle(GhostButton())

                Button {
                    Task { await rescan() }
                } label: {
                    HStack(spacing: 6) {
                        if loading { ProgressView().controlSize(.small) }
                        else       { Image(systemName: "arrow.clockwise") }
                        Text("Rescan")
                    }
                }
                .buttonStyle(GhostButton())
            }
        )
    }

    // MARK: connected card

    @ViewBuilder
    private var currentCard: some View {
        if let ssid = currentSSIDCached ?? store.context?.ssid {
            BrandCard(padding: 16) {
                HStack(spacing: 14) {
                    ZStack {
                        Circle().fill(Brand.trust.opacity(0.18)).frame(width: 40, height: 40)
                        Image(systemName: "wifi").foregroundStyle(Brand.trust)
                    }
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 6) {
                            Text(ssid).display(16, weight: .semibold)
                            Pill(text: "Connected", color: Brand.trust, icon: "checkmark")
                        }
                        if let ctx = store.context {
                            Text("\(ctx.subnetCIDR) · \(ctx.ipv6Active ? "v4 + v6" : "v4")")
                                .bodyStyle(11, muted: true)
                        }
                    }
                    Spacer()
                    Button("Disconnect") {
                        wifi.disassociate()
                        Task {
                            try? await Task.sleep(nanoseconds: 800_000_000)
                            await rescan()
                        }
                    }
                    .buttonStyle(GhostButton(tint: Brand.cut))
                }
            }
        }
    }

    // MARK: list card

    private func listCard(title: String,
                          subtitle: String?,
                          items: [WiFiNetwork],
                          knownStyle: Bool) -> some View {
        BrandCard(padding: 0) {
            VStack(spacing: 0) {
                HStack {
                    Text(title).bodyStyle(12, weight: .semibold, muted: true)
                    if let s = subtitle {
                        Text("·").bodyStyle(11, muted: true)
                        Text(s).bodyStyle(11, muted: true)
                    }
                    Spacer()
                    Text("\(items.count)").bodyStyle(11, muted: true)
                }
                .padding(.horizontal, 16).padding(.top, 14).padding(.bottom, 8)

                LazyVStack(spacing: 0) {
                    ForEach(items) { net in
                        NetworkRow(net: net,
                                   knownStyle: knownStyle,
                                   isJoining: joiningSSID == net.ssid)
                            .onTapGesture {
                                guard joiningSSID == nil else { return }
                                tap(net)
                            }
                            .contextMenu {
                                if wifi.hasOurOwnPassword(for: net.ssid) {
                                    Button("Forget saved password") {
                                        wifi.forgetPassword(for: net.ssid)
                                    }
                                }
                            }
                        Divider().background(Brand.hairline).padding(.horizontal, 14)
                    }
                }
            }
        }
    }

    private var emptyState: some View {
        BrandCard(padding: 22) {
            VStack(spacing: 10) {
                Image(systemName: loading ? "antenna.radiowaves.left.and.right" : "wifi.slash")
                    .font(.system(size: 28))
                    .foregroundStyle(Brand.muted)
                Text(loading ? "Scanning Wi-Fi…" : "No networks in range")
                    .bodyStyle(13, muted: true)
                if !loc.ssidUnlocked && !loading {
                    Text("Grant Location permission so macOS reveals nearby SSIDs.")
                        .bodyStyle(11, muted: true)
                        .multilineTextAlignment(.center)
                }
            }
            .frame(maxWidth: .infinity)
        }
    }

    // MARK: actions

    private func rescan() async {
        loading = true
        defer { loading = false }
        nets = (try? await wifi.scan()) ?? []
        store.wifiList = nets          // keep store in sync so Arsenal Wi-Fi picker has data
    }

    private func tap(_ net: WiFiNetwork) {
        if net.isCurrent { return }            // already connected
        if !net.security.requiresPassword {
            join(ssid: net.ssid, password: nil)
            return
        }
        // Tap-to-rejoin: silent only when we have our own saved password.
        // For networks where macOS has the password but we don't, the sheet
        // shows immediately — there's no programmatic way for a third-party
        // app to read airportd's keychain (macOS ACL hard-gates it). After
        // the user types the password once, we save it and every subsequent
        // tap on that network is silent.
        if wifi.hasOurOwnPassword(for: net.ssid) {
            join(ssid: net.ssid, password: nil, fallbackTo: net)
        } else {
            selected = net
            password = ""
        }
    }

    private func join(ssid: String, password: String?, fallbackTo net: WiFiNetwork? = nil) {
        joining = true
        joiningSSID = ssid
        Task {
            defer { joiningSSID = nil }
            do {
                try await wifi.join(ssid: ssid, password: password)
                store.toast("Joined \(ssid)")
                selected = nil
                // Wait for L3 to stabilize on the new network, then push a
                // full context refresh into the store. The previous version
                // called detectContext() but threw the result away, leaving
                // the sidebar / Lobby header / current-SSID badge stuck on
                // the previous network until the next 5s scan tick.
                try? await Task.sleep(nanoseconds: 1_500_000_000)
                coord.refreshContext()
                await refreshCurrentSSID()
                await rescan()
            } catch {
                let nsErr = error as NSError
                // Code 7 = "linked briefly but didn't stabilize" — usually
                // macOS auto-join policy yanking us off a disabled network.
                // The saved password is probably fine; surface the real
                // reason instead of re-prompting (which would feel broken
                // since the user just typed it correctly).
                if nsErr.domain == "WiFiClient" && nsErr.code == 7 {
                    store.toast(nsErr.localizedDescription)
                } else if password == nil, let net {
                    // Truly no usable password — drop into the sheet quietly.
                    // The sheet itself is the prompt; no toast needed.
                    selected = net
                    self.password = ""
                } else {
                    store.toast("Join failed: \(error.localizedDescription)")
                }
            }
            joining = false
        }
    }

    // MARK: sheets

    private func joinSheet(for net: WiFiNetwork) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Join \(net.ssid)").display(20, weight: .semibold)
            Text(net.security.label + " · " + net.band).bodyStyle(12, muted: true)
            HStack {
                Group {
                    if showPassword { TextField("Password", text: $password) }
                    else            { SecureField("Password", text: $password) }
                }
                .textFieldStyle(.roundedBorder)
                .font(BrandFont.mono(13))
                .disabled(joining)
                Button { showPassword.toggle() } label: {
                    Image(systemName: showPassword ? "eye.slash" : "eye")
                }
                .buttonStyle(.borderless)
                .disabled(joining)
            }

            // Progress strip while we wait on the WPA handshake — the verify
            // budget is up to ~17.5s, so the user gets visible motion the
            // whole time instead of a frozen-looking sheet.
            if joining {
                HStack(spacing: 8) {
                    ProgressView()
                        .controlSize(.small)
                        .progressViewStyle(.circular)
                        .tint(Brand.info)
                    Text("Negotiating with \(net.ssid)…")
                        .bodyStyle(12, muted: true)
                }
                ProgressView()
                    .progressViewStyle(.linear)
                    .tint(Brand.info)
            }

            HStack {
                Button("Cancel") { selected = nil }
                    .buttonStyle(GhostButton())
                    .disabled(joining)
                Spacer()
                Button {
                    join(ssid: net.ssid, password: password)
                } label: {
                    HStack(spacing: 6) {
                        if joining {
                            ProgressView()
                                .controlSize(.small)
                                .progressViewStyle(.circular)
                                .tint(.white)
                        }
                        Text(joining ? "Joining…" : "Join")
                    }
                }
                .buttonStyle(PrimaryButton(tint: Brand.trust))
                .disabled(joining || password.isEmpty)
            }
        }
        .padding(22).frame(width: 380).background(Brand.surface)
    }

    private var hiddenSheetBody: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Join hidden network").display(20, weight: .semibold)
            Text("Type the SSID exactly — case-sensitive.").bodyStyle(12, muted: true)
            TextField("SSID", text: $hiddenSSID)
                .textFieldStyle(.roundedBorder).font(BrandFont.mono(13))
            SecureField("Password", text: $hiddenPassword)
                .textFieldStyle(.roundedBorder).font(BrandFont.mono(13))
            HStack {
                Button("Cancel") {
                    hiddenSheet = false; hiddenSSID = ""; hiddenPassword = ""
                }.buttonStyle(GhostButton())
                Spacer()
                Button("Join") {
                    let ssid = hiddenSSID
                    let pw = hiddenPassword.isEmpty ? nil : hiddenPassword
                    hiddenSheet = false; hiddenSSID = ""; hiddenPassword = ""
                    join(ssid: ssid, password: pw)
                }
                .buttonStyle(PrimaryButton(tint: Brand.trust))
                .disabled(hiddenSSID.isEmpty)
            }
        }
        .padding(22).frame(width: 380).background(Brand.surface)
    }
}

// MARK: row

private struct NetworkRow: View {
    let net: WiFiNetwork
    let knownStyle: Bool
    var isJoining: Bool = false
    @State private var hover = false
    @State private var revealedPassword: String? = nil
    @State private var revealError: String? = nil
    @State private var revealing: Bool = false
    @State private var passwordCopied: Bool = false
    @State private var recoverySheetOpen: Bool = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 14) {
                SignalBars(level: net.bars,
                           color: net.isCurrent ? Brand.trust : (knownStyle ? Brand.info : Brand.muted))
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 8) {
                        Text(net.ssid).bodyStyle(14, weight: .semibold)
                        if net.isCurrent {
                            Pill(text: "Current", color: Brand.trust, icon: "checkmark")
                        } else if isJoining {
                            Pill(text: "Joining…", color: Brand.info, icon: "arrow.triangle.2.circlepath")
                        }
                    }
                    HStack(spacing: 8) {
                        Text(net.security.label).bodyStyle(11, muted: true)
                        if !net.band.isEmpty {
                            Text("·").bodyStyle(11, muted: true)
                            Text(net.band).bodyStyle(11, muted: true)
                        }
                        Text("·").bodyStyle(11, muted: true)
                        Text("\(net.rssi) dBm").bodyStyle(11, muted: true)
                    }
                }
                Spacer()
                if isJoining {
                    ProgressView().controlSize(.small)
                        .progressViewStyle(.circular).tint(Brand.info)
                } else if net.isKnown && net.security.requiresPassword {
                    revealButton
                } else if !net.isKnown && net.security.requiresPassword {
                    recoverButton
                } else {
                    Image(systemName: net.security.requiresPassword ? "lock.fill" : "lock.open.fill")
                        .foregroundStyle(net.security.requiresPassword ? Brand.muted : Brand.trust)
                        .font(.system(size: 12))
                }
            }
            if revealedPassword != nil || revealError != nil {
                passwordPanel.padding(.top, 6)
            }
        }
        .padding(.horizontal, 16).padding(.vertical, 12)
        .background(isJoining ? Brand.surfaceHi : (hover ? Brand.surfaceHi : Color.clear))
        .contentShape(Rectangle())
        .onHover { hover = $0 }
        .animation(Motion.snap, value: hover)
        .animation(Motion.snap, value: isJoining)
        .animation(Motion.smooth, value: revealedPassword)
        .animation(Motion.smooth, value: revealError)
    }

    private var revealButton: some View {
        Button(action: revealPassword) {
            HStack(spacing: 5) {
                if revealing {
                    ProgressView().controlSize(.mini)
                } else {
                    Image(systemName: revealedPassword == nil ? "key.fill" : "eye.slash.fill")
                        .font(.system(size: 10, weight: .semibold))
                }
                Text(revealedPassword == nil ? "Reveal password" : "Hide")
                    .font(BrandFont.heading(11, weight: .semibold))
            }
            .foregroundStyle(Brand.cut)
            .padding(.horizontal, 9).padding(.vertical, 5)
            .background(
                Capsule()
                    .stroke(Brand.cut.opacity(0.55), lineWidth: 0.75)
                    .background(Capsule().fill(Brand.cut.opacity(0.08)))
            )
        }
        .buttonStyle(.plain)
        .disabled(revealing)
    }

    private var recoverButton: some View {
        Button { recoverySheetOpen = true } label: {
            HStack(spacing: 5) {
                Image(systemName: "key.viewfinder")
                    .font(.system(size: 10, weight: .semibold))
                Text("Recover")
                    .font(BrandFont.heading(11, weight: .semibold))
            }
            .foregroundStyle(Brand.armed)
            .padding(.horizontal, 9).padding(.vertical, 5)
            .background(
                Capsule()
                    .stroke(Brand.armed.opacity(0.55), lineWidth: 0.75)
                    .background(Capsule().fill(Brand.armed.opacity(0.08)))
            )
        }
        .buttonStyle(.plain)
        .sheet(isPresented: $recoverySheetOpen) {
            PasswordRecoverySheet(network: net)
        }
    }

    @ViewBuilder
    private var passwordPanel: some View {
        if let pwd = revealedPassword {
            HStack(spacing: 8) {
                Image(systemName: "lock.fill")
                    .font(.system(size: 11)).foregroundStyle(Brand.cut)
                Text("PSK")
                    .font(BrandFont.heading(10, weight: .bold))
                    .tracking(1.4).foregroundStyle(Brand.mutedDim)
                Text(pwd)
                    .font(BrandFont.mono(13))
                    .foregroundStyle(Brand.light)
                    .textSelection(.enabled)
                Spacer()
                Button {
                    let pb = NSPasteboard.general
                    pb.clearContents(); pb.setString(pwd, forType: .string)
                    passwordCopied = true
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.4) { passwordCopied = false }
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: passwordCopied ? "checkmark" : "doc.on.doc")
                            .font(.system(size: 10))
                        Text(passwordCopied ? "copied" : "copy")
                            .font(BrandFont.heading(10, weight: .semibold))
                    }
                    .foregroundStyle(passwordCopied ? Brand.trust : Brand.muted)
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 10).padding(.vertical, 7)
            .background(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(Brand.dark)
                    .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .stroke(Brand.cut.opacity(0.4), lineWidth: 0.75))
            )
        } else if let err = revealError {
            HStack(spacing: 6) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 11)).foregroundStyle(Brand.armed)
                Text(err).bodyStyle(11).foregroundStyle(Brand.armed)
                Spacer()
            }
            .padding(.horizontal, 10).padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(Brand.armed.opacity(0.1))
                    .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .stroke(Brand.armed.opacity(0.4), lineWidth: 0.75))
            )
        }
    }

    private func revealPassword() {
        if revealedPassword != nil {
            revealedPassword = nil
            revealError = nil
            return
        }
        revealing = true
        revealError = nil
        let ssid = net.ssid
        Task.detached(priority: .userInitiated) {
            do {
                let pwd = try await WiFiPasswordReader.shared.password(for: ssid)
                await MainActor.run {
                    revealedPassword = pwd
                    revealing = false
                }
            } catch {
                await MainActor.run {
                    revealError = (error as? WiFiPasswordReader.Failure)?.errorDescription
                                ?? error.localizedDescription
                    revealing = false
                }
            }
        }
    }
}

// FlowLayout — kept around in case other views still reference it.
struct FlowLayout: Layout {
    var spacing: CGFloat = 6
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxW = proposal.width ?? .infinity
        var x: CGFloat = 0, y: CGFloat = 0, lineH: CGFloat = 0
        for v in subviews {
            let s = v.sizeThatFits(.unspecified)
            if x + s.width > maxW { x = 0; y += lineH + spacing; lineH = 0 }
            x += s.width + spacing
            lineH = max(lineH, s.height)
        }
        return CGSize(width: maxW, height: y + lineH)
    }
    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let maxW = bounds.width
        var x: CGFloat = bounds.minX, y: CGFloat = bounds.minY, lineH: CGFloat = 0
        for v in subviews {
            let s = v.sizeThatFits(.unspecified)
            if x + s.width > bounds.minX + maxW {
                x = bounds.minX; y += lineH + spacing; lineH = 0
            }
            v.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(s))
            x += s.width + spacing
            lineH = max(lineH, s.height)
        }
    }
}
