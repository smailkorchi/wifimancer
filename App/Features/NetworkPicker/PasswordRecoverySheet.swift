import SwiftUI

/// Sheet for recovering a Wi-Fi password on an UNKNOWN (never-joined)
/// network.
///
/// macOS doesn't expose another network's PSK to a third-party app —
/// that's by design. What this sheet does:
///   1. Pattern-match the SSID/BSSID against `WiFiPasswordRecovery`'s
///      ISP/vendor profiles
///   2. Show high-confidence candidates first (BSSID-derived defaults
///      for Inwi, TP-Link, BT Home Hub, etc.)
///   3. For each candidate offer one-click "Try" — calls `WiFiClient.join`
///      which sends the PSK to airportd; success means the password
///      is actually correct
///   4. If no derivation applies, hand off to the Arsenal handshake
///      capture / WPS pixie-dust pipeline (which DOES need a radio
///      in monitor mode and is the right path for non-default PSKs)
///
/// This is honest software: it tells the operator what's possible and
/// surfaces the candidates we can compute. No magic recovery.
struct PasswordRecoverySheet: View {
    let network: WiFiNetwork
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject var store: AppStore
    @StateObject private var arsenal = ArsenalStore.shared
    @State private var result: WiFiPasswordRecovery.Result = .init(
        profile: nil, candidates: [], needsHandshakeCrack: false)
    @State private var trying: WiFiPasswordRecovery.Candidate?
    @State private var workingPassword: String?
    @State private var failedCandidates: Set<String> = []
    @State private var customAttempts: [String: Bool] = [:]   // password → tried-result

    private let wifi = WiFiClient.shared

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().background(Brand.hairline)
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    summaryCard
                    if let p = workingPassword { successCard(password: p) }
                    if !result.candidates.isEmpty { candidatesCard }
                    if result.needsHandshakeCrack { handshakeCard }
                    realityCard
                }
                .padding(20)
            }
        }
        .frame(minWidth: 620, idealWidth: 720, minHeight: 520, idealHeight: 640)
        .background(Brand.dark)
        .onAppear { compute() }
    }

    private func compute() {
        result = WiFiPasswordRecovery.candidates(
            ssid: network.ssid, bssid: network.bssid)
    }

    // MARK: header

    private var header: some View {
        HStack(spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(Brand.armed.opacity(0.18))
                    .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .stroke(Brand.armed.opacity(0.5), lineWidth: 1))
                Image(systemName: "key.viewfinder")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(Brand.armed)
            }
            .frame(width: 42, height: 42)
            VStack(alignment: .leading, spacing: 2) {
                Text("Recover password")
                    .font(BrandFont.heading(16, weight: .semibold))
                    .foregroundStyle(Brand.light)
                Text(network.ssid)
                    .font(BrandFont.mono(11))
                    .foregroundStyle(Brand.cut)
            }
            Spacer()
            Button { dismiss() } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 20))
                    .foregroundStyle(Brand.muted)
            }
            .buttonStyle(.plain)
            .keyboardShortcut(.escape, modifiers: [])
        }
        .padding(20)
        .background(Brand.surface)
    }

    // MARK: cards

    private var summaryCard: some View {
        InsetCard(title: result.profile == nil ? "DETECTION" : "DETECTED",
                  tint: result.profile == nil ? Brand.muted : Brand.signal) {
            VStack(alignment: .leading, spacing: 6) {
                if let p = result.profile {
                    HStack(spacing: 6) {
                        Pill(text: p.region, color: Brand.info, icon: "globe")
                        Text(p.name)
                            .font(BrandFont.heading(14, weight: .semibold))
                            .foregroundStyle(Brand.light)
                    }
                    Text(p.note)
                        .bodyStyle(12).foregroundStyle(Brand.subtle)
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    Text("No ISP/vendor pattern matched this SSID.")
                        .bodyStyle(13).foregroundStyle(Brand.subtle)
                    Text("Default-PSK calculators don't apply. Real recovery requires capturing a handshake and cracking it offline — see below.")
                        .bodyStyle(11, muted: true)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if let bssid = network.bssid, !bssid.isEmpty {
                    HStack(spacing: 4) {
                        Text("BSSID")
                            .font(BrandFont.heading(9, weight: .bold))
                            .tracking(1.5).foregroundStyle(Brand.mutedDim)
                        Text(bssid)
                            .font(BrandFont.mono(11))
                            .foregroundStyle(Brand.muted)
                            .textSelection(.enabled)
                    }
                }
            }
        }
    }

    private func successCard(password: String) -> some View {
        InsetCard(title: "PASSWORD FOUND", tint: Brand.trust) {
            HStack(spacing: 10) {
                Image(systemName: "checkmark.seal.fill")
                    .font(.system(size: 18))
                    .foregroundStyle(Brand.trust)
                VStack(alignment: .leading, spacing: 1) {
                    Text(password)
                        .font(BrandFont.mono(15))
                        .foregroundStyle(Brand.light)
                        .textSelection(.enabled)
                    Text("Joined \(network.ssid) — PSK confirmed.")
                        .bodyStyle(11, muted: true)
                }
                Spacer()
                Button {
                    let pb = NSPasteboard.general
                    pb.clearContents(); pb.setString(password, forType: .string)
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "doc.on.doc").font(.system(size: 11))
                        Text("copy").font(BrandFont.heading(11, weight: .semibold))
                    }
                    .foregroundStyle(Brand.trust)
                    .padding(.horizontal, 10).padding(.vertical, 5)
                    .background(Capsule().stroke(Brand.trust, lineWidth: 0.75))
                }
                .buttonStyle(.plain)
            }
        }
    }

    private var candidatesCard: some View {
        InsetCard(title: "CANDIDATES — \(result.candidates.count)", tint: Brand.cut) {
            VStack(alignment: .leading, spacing: 6) {
                ForEach(sortedCandidates) { c in
                    candidateRow(c)
                }
                Text("Click TRY to attempt the password against this network. We use the macOS Wi-Fi join API — success = PSK confirmed.")
                    .bodyStyle(11, muted: true)
                    .padding(.top, 6)
            }
        }
    }

    private var sortedCandidates: [WiFiPasswordRecovery.Candidate] {
        result.candidates.sorted { $0.confidence > $1.confidence }
    }

    private func candidateRow(_ c: WiFiPasswordRecovery.Candidate) -> some View {
        let triedFailed = failedCandidates.contains(c.id)
        let isWorking = workingPassword == c.password
        let isTrying  = trying?.id == c.id
        let confTint: Color = {
            switch c.confidence {
            case .high: Brand.trust
            case .medium: Brand.armed
            case .low: Brand.muted
            }
        }()
        return HStack(spacing: 10) {
            // confidence dot
            Circle()
                .fill(confTint)
                .frame(width: 8, height: 8)
            VStack(alignment: .leading, spacing: 1) {
                Text(c.password)
                    .font(BrandFont.mono(13))
                    .foregroundStyle(isWorking ? Brand.trust : Brand.light)
                    .textSelection(.enabled)
                Text(c.label)
                    .font(BrandFont.body(10))
                    .foregroundStyle(Brand.mutedDim)
            }
            Spacer()
            if isWorking {
                Pill(text: "WORKS", color: Brand.trust, icon: "checkmark.seal.fill")
            } else if triedFailed {
                Pill(text: "FAILED", color: Brand.threat, icon: "xmark.octagon.fill")
            }
            Button {
                let pb = NSPasteboard.general
                pb.clearContents(); pb.setString(c.password, forType: .string)
            } label: {
                Image(systemName: "doc.on.doc")
                    .font(.system(size: 10)).foregroundStyle(Brand.mutedDim)
            }
            .buttonStyle(.plain)
            Button { tryCandidate(c) } label: {
                HStack(spacing: 4) {
                    if isTrying {
                        ProgressView().controlSize(.mini)
                    } else {
                        Image(systemName: "play.fill").font(.system(size: 9, weight: .bold))
                    }
                    Text(isTrying ? "trying" : "TRY")
                        .font(BrandFont.heading(10, weight: .bold))
                        .tracking(0.8)
                }
                .foregroundStyle(Brand.light)
                .padding(.horizontal, 9).padding(.vertical, 4)
                .background(Capsule().fill(isTrying ? Brand.muted : Brand.cut))
            }
            .buttonStyle(.plain)
            .disabled(isTrying || isWorking)
        }
        .padding(.horizontal, 8).padding(.vertical, 5)
        .background(
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(isWorking ? Brand.trust.opacity(0.08) : Brand.dark.opacity(0.5))
                .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .stroke(isWorking ? Brand.trust.opacity(0.5) : Brand.hairline, lineWidth: 0.5))
        )
    }

    private var handshakeCard: some View {
        InsetCard(title: "REAL RECOVERY — HANDSHAKE + CRACK", tint: Brand.threat) {
            VStack(alignment: .leading, spacing: 8) {
                Text("If the candidate list is empty or none worked, the only path is to capture a 4-way WPA handshake (or PMKID) and crack it offline. This requires:")
                    .bodyStyle(12).foregroundStyle(Brand.subtle)
                    .fixedSize(horizontal: false, vertical: true)
                bulletRow("A Wi-Fi adapter in monitor mode (Kali built-in or USB Alfa)")
                bulletRow("Range to the target AP — at least one client connected (or use PMKID)")
                bulletRow("A wordlist + GPU/CPU time for hashcat")
                HStack(spacing: 8) {
                    Button {
                        handoffArsenal(attackId: "wifi.handshake.capture")
                    } label: {
                        HStack(spacing: 5) {
                            Image(systemName: "antenna.radiowaves.left.and.right")
                                .font(.system(size: 11))
                            Text("Open: Handshake capture")
                                .font(BrandFont.heading(11, weight: .semibold))
                        }
                        .foregroundStyle(Brand.light)
                        .padding(.horizontal, 12).padding(.vertical, 6)
                        .background(Capsule().fill(Brand.threat))
                    }
                    .buttonStyle(.plain)
                    Button {
                        handoffArsenal(attackId: "wifi.pmkid.attack")
                    } label: {
                        HStack(spacing: 5) {
                            Image(systemName: "bolt.horizontal.fill")
                                .font(.system(size: 11))
                            Text("Open: PMKID attack")
                                .font(BrandFont.heading(11, weight: .semibold))
                        }
                        .foregroundStyle(Brand.threat)
                        .padding(.horizontal, 12).padding(.vertical, 6)
                        .background(Capsule().stroke(Brand.threat, lineWidth: 0.75))
                    }
                    .buttonStyle(.plain)
                    Button {
                        handoffArsenal(attackId: "wifi.wps.pixie")
                    } label: {
                        HStack(spacing: 5) {
                            Image(systemName: "sparkles")
                                .font(.system(size: 11))
                            Text("Open: WPS Pixie-dust")
                                .font(BrandFont.heading(11, weight: .semibold))
                        }
                        .foregroundStyle(Brand.armed)
                        .padding(.horizontal, 12).padding(.vertical, 6)
                        .background(Capsule().stroke(Brand.armed, lineWidth: 0.75))
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    private var realityCard: some View {
        InsetCard(title: "REALITY CHECK", tint: Brand.muted) {
            VStack(alignment: .leading, spacing: 4) {
                Text("macOS does not expose a third-party API to read another network's PSK. There is no \"reveal password\" path that bypasses Apple's design.")
                    .bodyStyle(11, muted: true)
                    .fixedSize(horizontal: false, vertical: true)
                Text("What you see above is the legitimate set: pattern-matching defaults + handing the real attack work off to the Arsenal handshake-capture pipeline.")
                    .bodyStyle(11, muted: true)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func bulletRow(_ s: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "circle.fill")
                .font(.system(size: 4))
                .foregroundStyle(Brand.threat)
                .padding(.top, 7)
            Text(s).bodyStyle(12).foregroundStyle(Brand.subtle)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: actions

    private func tryCandidate(_ c: WiFiPasswordRecovery.Candidate) {
        trying = c
        let ssid = network.ssid
        let pw = c.password
        Task.detached(priority: .userInitiated) {
            do {
                try await wifi.join(ssid: ssid, password: pw)
                // The macOS join call returns success even when the PSK
                // is rejected sometimes (it queues the request).
                // Wait briefly, then check the actual current SSID to
                // confirm.
                try? await Task.sleep(nanoseconds: 1_500_000_000)
                let actual = await wifi.currentSSIDAsync()
                await MainActor.run {
                    if actual == ssid {
                        workingPassword = pw
                    } else {
                        failedCandidates.insert(c.id)
                    }
                    trying = nil
                }
            } catch {
                await MainActor.run {
                    failedCandidates.insert(c.id)
                    trying = nil
                }
            }
        }
    }

    private func handoffArsenal(attackId: String) {
        // Pre-load the picked Wi-Fi network as the wireless target in
        // the Arsenal store, then open the corresponding attack. The
        // ArsenalView reads `selectedWiFi` for wireless-category attacks
        // and renders the BSSID/SSID/channel chip — not LAN devices.
        arsenal.setWiFiTarget(network)
        if let attack = AttackCatalog.all.first(where: { $0.id == attackId }) {
            arsenal.selectedCategory = .wireless
            arsenal.selectAttack(attack)
        }
        dismiss()
        withAnimation(Motion.smooth) { store.tab = .arsenal }
    }
}

// MARK: - small reusable

private struct InsetCard<Content: View>: View {
    let title: String
    let tint: Color
    @ViewBuilder var content: () -> Content
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title)
                .font(BrandFont.heading(10, weight: .bold))
                .tracking(2.0).foregroundStyle(tint)
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
