import SwiftUI

/// High-density device row for the Recon list.
///
/// Single visible row carries everything the operator needs to triage a
/// host at a glance:
///
///   ┌────────┬────────────────────────────────────────────┬──────────┐
///   │  ICON  │ PRIMARY name + relation pip                │ BANDWIDTH│
///   │  + img │ SECONDARY model • vendor • IP4 • IP6 • MAC │  + state │
///   └────────┴────────────────────────────────────────────┴──────────┘
///
/// Class icon left (40 pt), data column center, signal column right.
/// The whole row tints subtly based on relation (self / gateway /
/// allowlisted / blocked / threat) so a 12-row list reads as a small map
/// rather than a uniform stripe.
struct DeviceRowCard: View {
    let device: Device
    let isSelected: Bool
    let cutEngaged: Bool
    /// mDNS service types observed for this device's IPv4. Populated by
    /// the App-side enricher and passed in from the parent so the row
    /// stays a pure value view.
    var serviceTypes: Set<String> = []
    var addressConflict = false
    var onTap: () -> Void = {}
    var onAllowToggle: () -> Void = {}

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 14) {
                classGlyph
                primary
                Spacer(minLength: 8)
                signalColumn
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 11)
            .frame(minHeight: 68)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(rowFill)
                    .overlay(
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .stroke(rowStroke, lineWidth: isSelected ? 1.25 : 0.75)
                    )
            )
            .overlay(alignment: .leading) { relationStripe }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // MARK: pieces

    private var classGlyph: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(Brand.surfaceLo)
                .overlay(
                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .stroke(Brand.hairline, lineWidth: 0.75)
                )
            Image(systemName: device.kind.sfSymbol)
                .font(.system(size: 18, weight: .medium))
                .foregroundStyle(glyphTint)
        }
        .frame(width: 44, height: 44)
    }

    private var primary: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Text(device.displayName)
                    .font(BrandFont.heading(14, weight: .semibold))
                    .foregroundStyle(Brand.light)
                    .lineLimit(1)
                relationPip
                if addressConflict {
                    Pill(text: "IP CONFLICT", color: Brand.warning, icon: "exclamationmark.triangle.fill")
                }
                if device.mac.isLocallyAdministered, !device.isSelf, !device.isGateway {
                    Pill(text: "PRIVATE MAC", color: Brand.privacy, icon: "eye.slash.fill")
                }
            }
            secondaryLine
        }
    }

    @ViewBuilder
    private var secondaryLine: some View {
        HStack(spacing: 8) {
            if let m = device.displayModel, !m.isEmpty {
                Text(m).font(BrandFont.body(11)).foregroundStyle(Brand.muted).lineLimit(1)
                Text("·").foregroundStyle(Brand.empty)
            }
            if let v = device.identification?.manufacturer ?? device.vendor, !v.isEmpty {
                Text(v).font(BrandFont.body(11)).foregroundStyle(Brand.muted).lineLimit(1)
                Text("·").foregroundStyle(Brand.empty)
            }
            if let ip = device.ipv4 {
                Text(ip).font(BrandFont.mono(11)).foregroundStyle(Brand.subtle.opacity(0.85))
            } else {
                Text("no ipv4").font(BrandFont.mono(11)).foregroundStyle(Brand.empty)
            }
            if !device.ipv6.isEmpty {
                Text("· +ipv6")
                    .font(BrandFont.mono(11))
                    .foregroundStyle(Brand.signal.opacity(0.65))
            }
            if !serviceTypes.isEmpty {
                Text("· \(serviceTypes.count) svc")
                    .font(BrandFont.mono(11))
                    .foregroundStyle(Brand.signal.opacity(0.85))
            }
            Spacer(minLength: 0)
            Text(device.mac.description.uppercased())
                .font(BrandFont.mono(11))
                .foregroundStyle(Brand.muted.opacity(0.75))
                .lineLimit(1)
        }
    }

    private var signalColumn: some View {
        HStack(spacing: 12) {
            VStack(alignment: .trailing, spacing: 3) {
                Text(device.bandwidthPretty)
                    .font(BrandFont.mono(11))
                    .foregroundStyle(bandwidthColor)
                bandwidthMeter
            }
            stateDot
        }
        .frame(minWidth: 96, alignment: .trailing)
    }

    private var bandwidthMeter: some View {
        let mbps = max(0, device.bandwidthBps * 8 / 1_000_000)
        let pct = min(1.0, mbps / 100.0)  // 100 Mbps full
        return RoundedRectangle(cornerRadius: 1.5)
            .fill(Brand.hairline)
            .frame(width: 60, height: 3)
            .overlay(alignment: .leading) {
                RoundedRectangle(cornerRadius: 1.5)
                    .fill(bandwidthColor)
                    .frame(width: 60 * pct, height: 3)
            }
    }

    private var stateDot: some View {
        Group {
            if device.isSelf {
                BreathingDot(color: Brand.info, intensity: 1.4, period: 2.6)
            } else if device.isGateway {
                BreathingDot(color: Brand.signal, intensity: 1.6, period: 2.0)
            } else if device.isAllowlisted {
                Circle().fill(Brand.trust).frame(width: 8, height: 8)
            } else if cutEngaged {
                BreathingDot(color: Brand.cut, intensity: 2.4, period: 1.2)
            } else {
                Circle().fill(Brand.empty).frame(width: 8, height: 8)
            }
        }
        .frame(width: 12)
    }

    // MARK: tint logic

    private var rowFill: Color {
        if device.isSelf       { return Brand.info.opacity(0.06) }
        if device.isGateway    { return Brand.signal.opacity(0.05) }
        if device.isAllowlisted{ return Brand.trust.opacity(0.06) }
        if cutEngaged          { return Brand.cut.opacity(0.07) }
        return Brand.surface
    }

    private var rowStroke: Color {
        if isSelected { return Brand.light.opacity(0.55) }
        if device.isSelf       { return Brand.info.opacity(0.35) }
        if device.isGateway    { return Brand.signal.opacity(0.35) }
        if device.isAllowlisted{ return Brand.trust.opacity(0.45) }
        if cutEngaged          { return Brand.cut.opacity(0.55) }
        return Brand.hairline
    }

    private var glyphTint: Color {
        if device.isSelf       { return Brand.info }
        if device.isGateway    { return Brand.signal }
        if device.isAllowlisted{ return Brand.trust }
        if cutEngaged          { return Brand.cut }
        return Brand.muted
    }

    private var bandwidthColor: Color {
        device.bandwidthBps > 1 ? Brand.signal : Brand.empty
    }

    @ViewBuilder
    private var relationPip: some View {
        if device.isSelf {
            Pill(text: "THIS MAC", color: Brand.info, icon: "macbook")
        } else if device.isGateway {
            Pill(text: "GATEWAY", color: Brand.signal, icon: "arrow.up.forward.app.fill")
        } else if device.isAllowlisted {
            Pill(text: "ALLOWED", color: Brand.trust, icon: "checkmark.seal.fill")
        } else if cutEngaged {
            Pill(text: "CUT", color: Brand.cut, icon: "scissors")
        }
    }

    @ViewBuilder
    private var relationStripe: some View {
        let color: Color =
            device.isSelf       ? Brand.info :
            device.isGateway    ? Brand.signal :
            device.isAllowlisted ? Brand.trust :
            cutEngaged          ? Brand.cut :
            .clear
        Rectangle()
            .fill(color)
            .frame(width: 2)
            .padding(.vertical, 8)
            .clipShape(RoundedRectangle(cornerRadius: 1, style: .continuous))
    }
}
