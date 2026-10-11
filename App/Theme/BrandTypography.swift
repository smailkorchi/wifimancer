import SwiftUI

enum BrandFont {

    static let displayName = "Poppins"
    static let bodyName    = "Lora"
    static let monoName    = "SF Mono"

    static func heading(_ size: CGFloat, weight: Font.Weight = .semibold) -> Font {
        let registered = NSFont(name: displayName, size: size) != nil
        return registered
            ? Font.custom(displayName, size: size).weight(weight)
            : Font.system(size: size, weight: weight, design: .default)
    }

    static func body(_ size: CGFloat = 14, weight: Font.Weight = .regular) -> Font {
        let registered = NSFont(name: bodyName, size: size) != nil
        return registered
            ? Font.custom(bodyName, size: size).weight(weight)
            : Font.system(size: size, weight: weight, design: .serif)
    }

    static func mono(_ size: CGFloat = 12) -> Font {
        Font.system(size: size, weight: .regular, design: .monospaced)
    }
}

struct DisplayText: ViewModifier {
    let size: CGFloat
    let weight: Font.Weight
    func body(content: Content) -> some View {
        content
            .font(BrandFont.heading(size, weight: weight))
            .tracking(-0.5)
            .foregroundStyle(Brand.light)
    }
}

struct BodyText: ViewModifier {
    let size: CGFloat
    let weight: Font.Weight
    let muted: Bool
    func body(content: Content) -> some View {
        content
            .font(BrandFont.body(size, weight: weight))
            .foregroundStyle(muted ? Brand.muted : Brand.light)
    }
}

struct MonoText: ViewModifier {
    let size: CGFloat
    let muted: Bool
    func body(content: Content) -> some View {
        content
            .font(BrandFont.mono(size))
            .foregroundStyle(muted ? Brand.muted : Brand.light)
    }
}

extension View {
    func display(_ size: CGFloat = 32, weight: Font.Weight = .semibold) -> some View {
        modifier(DisplayText(size: size, weight: weight))
    }
    func bodyStyle(_ size: CGFloat = 14, weight: Font.Weight = .regular, muted: Bool = false) -> some View {
        modifier(BodyText(size: size, weight: weight, muted: muted))
    }
    func mono(_ size: CGFloat = 12, muted: Bool = false) -> some View {
        modifier(MonoText(size: size, muted: muted))
    }
}

enum FontRegistrar {
    static func register() {
        let names = ["Poppins-Regular", "Poppins-Medium", "Poppins-SemiBold", "Poppins-Bold",
                     "Lora-Regular", "Lora-Medium", "Lora-SemiBold", "Lora-Italic"]
        for name in names {
            guard let url = Bundle.main.url(forResource: name, withExtension: "ttf")
                       ?? Bundle.main.url(forResource: name, withExtension: "otf") else { continue }
            CTFontManagerRegisterFontsForURL(url as CFURL, .process, nil)
        }
    }
}
