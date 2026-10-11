import SwiftUI

enum Brand {

    // MARK: Anthropic palette (locked tokens)

    static let dark       = Color(hex: 0x141413)
    static let surface    = Color(hex: 0x1c1b19)
    static let surfaceHi  = Color(hex: 0x232220)
    static let surfaceLo  = Color(hex: 0x0e0d0c)

    static let light      = Color(hex: 0xfaf9f5)
    static let muted      = Color(hex: 0xb0aea5)
    static let mutedDim   = Color(hex: 0x6f6e68)
    static let subtle     = Color(hex: 0xe8e6dc)
    static let hairline   = Color(hex: 0x2c2b29)

    static let cut        = Color(hex: 0xd97757)   // orange — destructive
    static let cutDim     = Color(hex: 0x6e3a26)
    static let trust      = Color(hex: 0x788c5d)   // green — allowlisted
    static let trustDim   = Color(hex: 0x3d4730)
    static let info       = Color(hex: 0x6a9bcc)   // blue — neutral
    static let infoDim    = Color(hex: 0x355068)

    static let warning    = Color(hex: 0xe0a96d)
    static let danger     = Color(hex: 0xc14d3f)

    // MARK: state tokens (Recon era — added for the data-dense UI)

    /// Out-of-scope refusal, hostile / unauthorized target. Use sparingly:
    /// only on rows the engagement scope explicitly rejected, never on
    /// "unknown" devices. Saturated to demand attention.
    static let threat     = Color(hex: 0xe04d3a)
    static let threatDim  = Color(hex: 0x4a1a14)

    /// "Engaged but contained" — used by per-device cut indicators when the
    /// cut is *armed* against this device specifically. Distinct from `cut`,
    /// which is the global cut-engagement signal in the chrome.
    static let armed      = Color(hex: 0xd99a4c)
    static let armedDim   = Color(hex: 0x533819)

    /// Live recon signal — packets observed, mDNS responses, scan tick.
    /// Cool to read against the warm-earth chrome without ever competing
    /// with `cut` for the operator's eye.
    static let signal     = Color(hex: 0x6dbabd)
    static let signalDim  = Color(hex: 0x224a4c)

    /// Locally-administered MAC marker (iOS / Android privacy randomization).
    /// Rendered on the row as a discreet pip — the device is real, but its
    /// hardware identity is intentionally obscured by the OS.
    static let privacy    = Color(hex: 0x9a8bb4)

    /// Any field that is *empty* — IP without hostname, MAC without vendor,
    /// service without banner. Always rendered with `.empty` rather than
    /// "—" or blank, so the operator can see at a glance whether the data
    /// pipeline ran or not.
    static let empty      = Color(hex: 0x4a4944)

    // MARK: Gradients

    static let bgGradient = LinearGradient(
        colors: [Color(hex: 0x0e0d0c), Color(hex: 0x141413), Color(hex: 0x1a1917)],
        startPoint: .topLeading, endPoint: .bottomTrailing
    )

    static let cutGradient = LinearGradient(
        colors: [cut, Color(hex: 0xb35a3b)],
        startPoint: .top, endPoint: .bottom
    )

    static let trustGradient = LinearGradient(
        colors: [trust, Color(hex: 0x556b3d)],
        startPoint: .top, endPoint: .bottom
    )

    static let infoGradient = LinearGradient(
        colors: [info, Color(hex: 0x4a7aa6)],
        startPoint: .top, endPoint: .bottom
    )

    // MARK: Shadows

    static let shadowSoft = (color: Color.black.opacity(0.45), radius: 24.0, x: 0.0, y: 12.0)
    static let shadowSnap = (color: Color.black.opacity(0.6),  radius: 8.0,  x: 0.0, y: 4.0)
}

extension Color {
    init(hex: UInt32, alpha: Double = 1.0) {
        let r = Double((hex >> 16) & 0xff) / 255.0
        let g = Double((hex >> 8)  & 0xff) / 255.0
        let b = Double( hex        & 0xff) / 255.0
        self.init(.sRGB, red: r, green: g, blue: b, opacity: alpha)
    }
}
