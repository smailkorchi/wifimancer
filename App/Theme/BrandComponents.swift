import SwiftUI

// MARK: Card

struct BrandCard<Content: View>: View {
    var padding: CGFloat = 18
    var radius: CGFloat = 14
    @ViewBuilder let content: () -> Content

    var body: some View {
        content()
            .padding(padding)
            .background(
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .fill(Brand.surface)
                    .overlay(
                        RoundedRectangle(cornerRadius: radius, style: .continuous)
                            .stroke(Brand.hairline, lineWidth: 0.75)
                    )
            )
            .shadow(color: Brand.shadowSoft.color,
                    radius: Brand.shadowSoft.radius,
                    x: Brand.shadowSoft.x, y: Brand.shadowSoft.y)
    }
}

// MARK: Button styles

struct PrimaryButton: ButtonStyle {
    var tint: Color = Brand.cut
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(BrandFont.heading(13, weight: .semibold))
            .foregroundStyle(Brand.light)
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(tint.opacity(configuration.isPressed ? 0.75 : 1.0))
            )
            .scaleEffect(configuration.isPressed ? 0.97 : 1.0)
            .animation(Motion.snap, value: configuration.isPressed)
    }
}

struct GhostButton: ButtonStyle {
    var tint: Color = Brand.muted
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(BrandFont.heading(13, weight: .medium))
            .foregroundStyle(tint)
            .padding(.horizontal, 14)
            .padding(.vertical, 9)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .stroke(Brand.hairline, lineWidth: 1)
                    .background(
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .fill(configuration.isPressed ? Brand.surfaceHi : Color.clear)
                    )
            )
            .animation(Motion.snap, value: configuration.isPressed)
    }
}

// MARK: Brand toggle switch

/// Custom on/off switch that visually persists state, animates smoothly,
/// and uses brand tokens. Use this instead of plain `Toggle` whenever the
/// state needs to read as a primary "engaged / paused" indicator.
struct BrandSwitch: View {
    @Binding var isOn: Bool
    var onColor: Color = Brand.cut
    var offColor: Color = Brand.mutedDim
    var label: (on: String, off: String) = ("On", "Off")
    var compact: Bool = false

    var body: some View {
        Button {
            withAnimation(Motion.smooth) { isOn.toggle() }
        } label: {
            HStack(spacing: 10) {
                ZStack(alignment: isOn ? .trailing : .leading) {
                    Capsule()
                        .fill((isOn ? onColor : offColor).opacity(0.28))
                        .frame(width: compact ? 42 : 52, height: compact ? 24 : 30)
                    Capsule()
                        .stroke((isOn ? onColor : offColor).opacity(0.8), lineWidth: 1)
                        .frame(width: compact ? 42 : 52, height: compact ? 24 : 30)
                    Circle()
                        .fill(isOn ? onColor : Brand.muted)
                        .frame(width: compact ? 18 : 22, height: compact ? 18 : 22)
                        .padding(.horizontal, 4)
                        .shadow(color: (isOn ? onColor : .black).opacity(0.4),
                                radius: 6, x: 0, y: 2)
                }
                .animation(Motion.smooth, value: isOn)
                if !compact {
                    Text(isOn ? label.on : label.off)
                        .font(BrandFont.heading(13, weight: .semibold))
                        .foregroundStyle(isOn ? onColor : Brand.muted)
                        .contentTransition(.opacity)
                }
            }
        }
        .buttonStyle(.plain)
    }
}

// MARK: Pill / Tag

struct Pill: View {
    let text: String
    var color: Color = Brand.muted
    var icon: String? = nil

    var body: some View {
        HStack(spacing: 6) {
            if let icon { Image(systemName: icon).font(.system(size: 10, weight: .semibold)) }
            Text(text).font(BrandFont.heading(11, weight: .medium))
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 4)
        .foregroundStyle(color)
        .background(
            Capsule().fill(color.opacity(0.12))
                .overlay(Capsule().stroke(color.opacity(0.35), lineWidth: 1))
        )
    }
}

// MARK: Signal bars

struct SignalBars: View {
    let level: Int          // 0..4
    let color: Color

    var body: some View {
        HStack(alignment: .bottom, spacing: 2) {
            ForEach(0..<4, id: \.self) { i in
                RoundedRectangle(cornerRadius: 1)
                    .fill(i < level ? color : Brand.hairline)
                    .frame(width: 3, height: 4 + CGFloat(i) * 3)
            }
        }
    }
}

// MARK: Section header

struct SectionHeader: View {
    let title: String
    let subtitle: String?
    var trailing: AnyView? = nil

    init(_ title: String, subtitle: String? = nil, trailing: AnyView? = nil) {
        self.title = title; self.subtitle = subtitle; self.trailing = trailing
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 6) {
                Text(title)
                    .font(BrandFont.heading(26, weight: .bold))
                    .tracking(-0.6)
                    .foregroundStyle(Brand.light)
                if let s = subtitle {
                    Text(s)
                        .bodyStyle(12, muted: true)
                        .tracking(0.1)
                }
            }
            Spacer()
            trailing
        }
    }
}

// MARK: Ambient backdrop (drifting orbs)

struct AmbientBackdrop: View {
    @EnvironmentObject var store: AppStore
    @State private var t: CGFloat = 0
    @State private var pulseT: CGFloat = 0

    var body: some View {
        let cutActive = store.blocking

        ZStack {
            Brand.bgGradient.ignoresSafeArea()
            // Two slow-drifting orbs in muted accent tones. When Cut is
            // engaged, the cut orb *intensifies* and breathes — the entire
            // app's ambient lighting shifts to communicate "we're severing
            // connections right now." When idle, both orbs sit quietly.
            Canvas { ctx, size in
                func orb(_ x: CGFloat, _ y: CGFloat, _ r: CGFloat, _ c: Color, _ a: Double) {
                    let rect = CGRect(x: x - r, y: y - r, width: r * 2, height: r * 2)
                    ctx.opacity = a
                    ctx.addFilter(.blur(radius: 90))
                    ctx.fill(Path(ellipseIn: rect), with: .color(c))
                    ctx.opacity = 1
                }
                let w = size.width, h = size.height
                let p = t
                let breath = 0.5 + 0.5 * sin(pulseT * .pi * 2)

                let cutOpacity   = cutActive ? (0.10 + 0.10 * breath) : 0.06
                let cutRadius    = cutActive ? (340 + 60 * breath)     : 300
                let infoOpacity  = cutActive ? 0.025 : 0.05

                orb(w * (0.18 + 0.04 * cos(p)),
                    h * (0.28 + 0.04 * sin(p)),
                    cutRadius, Brand.cut, cutOpacity)
                orb(w * (0.82 + 0.03 * sin(p * 0.7)),
                    h * (0.72 + 0.04 * cos(p)),
                    340, Brand.info, infoOpacity)
            }
            .ignoresSafeArea()
            .onAppear {
                withAnimation(.linear(duration: 28).repeatForever(autoreverses: false)) {
                    t = .pi * 2
                }
                withAnimation(.linear(duration: 2.4).repeatForever(autoreverses: false)) {
                    pulseT = 1
                }
            }
            .animation(Motion.smooth, value: cutActive)
        }
    }
}
