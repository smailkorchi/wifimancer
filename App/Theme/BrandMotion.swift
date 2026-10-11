import SwiftUI

enum Motion {

    // Springs — physical, never linear
    static let snap     = Animation.spring(response: 0.32, dampingFraction: 0.78, blendDuration: 0)
    static let smooth   = Animation.spring(response: 0.45, dampingFraction: 0.82, blendDuration: 0)
    static let breath   = Animation.spring(response: 0.9,  dampingFraction: 0.62, blendDuration: 0)
    static let drift    = Animation.spring(response: 1.3,  dampingFraction: 0.85, blendDuration: 0)

    // Pulse loop
    static func pulse(_ duration: Double = 1.6) -> Animation {
        .easeInOut(duration: duration).repeatForever(autoreverses: true)
    }

    // Stagger helper
    static func staggered(index: Int, base: Double = 0.04) -> Animation {
        .spring(response: 0.45, dampingFraction: 0.82).delay(Double(index) * base)
    }
}

// Subtle continuous breathing for status dots. `intensity` controls how
// aggressively the dot pulses — calm for idle states, urgent (faster +
// larger ring) when cut is engaged. The ring expands from 1× → `intensity`,
// fading out as it grows.
struct BreathingDot: View {
    let color: Color
    var intensity: CGFloat = 2.4
    var period: Double = 1.4
    @State private var on = false
    var body: some View {
        Circle()
            .fill(color)
            .frame(width: 8, height: 8)
            .overlay(
                Circle()
                    .stroke(color.opacity(0.6), lineWidth: 2)
                    .scaleEffect(on ? intensity : 1.0)
                    .opacity(on ? 0.0 : 0.7)
            )
            .onAppear {
                withAnimation(Motion.pulse(period)) { on = true }
            }
    }
}

/// Pulsing rectangular border — wraps any view to make it command attention
/// while a state is active. Used by BlockToggle when Cut is engaged so the
/// whole panel feels charged, and by cut device nodes in the Lobby graph.
struct PulsingBorder: ViewModifier {
    let active: Bool
    var color: Color = Brand.cut
    var radius: CGFloat = 14
    var lineWidth: CGFloat = 1.5
    @State private var phase: CGFloat = 0
    func body(content: Content) -> some View {
        content
            .overlay(
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .stroke(color.opacity(active ? (0.4 + 0.4 * phase) : 0),
                            lineWidth: lineWidth)
                    .blur(radius: active ? 0.5 + 1.0 * phase : 0)
                    .allowsHitTesting(false)
            )
            .shadow(color: color.opacity(active ? 0.30 * phase : 0),
                    radius: active ? 14 : 0)
            .onAppear { if active { startLoop() } }
            .onChange(of: active) { _, on in if on { startLoop() } else { phase = 0 } }
    }
    private func startLoop() {
        phase = 0
        withAnimation(.easeInOut(duration: 1.3).repeatForever(autoreverses: true)) {
            phase = 1
        }
    }
}

extension View {
    func pulsingBorder(active: Bool,
                       color: Color = Brand.cut,
                       radius: CGFloat = 14,
                       lineWidth: CGFloat = 1.5) -> some View {
        modifier(PulsingBorder(active: active, color: color,
                               radius: radius, lineWidth: lineWidth))
    }
}

/// Brief, full-width engagement flash. Driven by an external trigger Int —
/// every increment fires one short cut-orange wash that sweeps across the
/// app, so the user *feels* the moment Cut engages instead of staring at a
/// silent toggle. Subtle enough to be read as confirmation, not chrome.
struct EngagementFlash: View {
    let trigger: Int
    var color: Color = Brand.cut
    @State private var alpha: Double = 0
    var body: some View {
        Rectangle()
            .fill(
                LinearGradient(colors: [color.opacity(0.0),
                                        color.opacity(0.18),
                                        color.opacity(0.0)],
                               startPoint: .top, endPoint: .bottom)
            )
            .opacity(alpha)
            .allowsHitTesting(false)
            .onChange(of: trigger) { _, _ in
                alpha = 1
                withAnimation(.easeOut(duration: 0.55)) { alpha = 0 }
            }
    }
}

// Particle dissolve when a device gets cut
struct DissolveParticles: View {
    let color: Color
    let trigger: Bool
    @State private var phase: CGFloat = 0

    var body: some View {
        Canvas { ctx, size in
            let count = 28
            for i in 0..<count {
                let t = CGFloat(i) / CGFloat(count)
                let angle = t * .pi * 2
                let r = phase * 60
                let x = size.width / 2 + cos(angle) * r
                let y = size.height / 2 + sin(angle) * r
                let alpha = max(0, 1 - phase)
                ctx.fill(
                    Path(ellipseIn: CGRect(x: x - 2, y: y - 2, width: 4, height: 4)),
                    with: .color(color.opacity(alpha))
                )
            }
        }
        .onChange(of: trigger) { _, _ in
            phase = 0
            withAnimation(.easeOut(duration: 0.7)) { phase = 1 }
        }
    }
}
