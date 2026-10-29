import SwiftUI

/// Glass belongs to the control layer, not message bubbles or health content.
/// Keep native text/hold gestures untouched; do not add interactive glass here.
struct CoveGlassControlSurface<S: Shape>: ViewModifier {
    let shape: S
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var contrast

    func body(content: Content) -> some View {
        if reduceTransparency || contrast == .increased {
            content
                .background(CoveStyle.card, in: shape)
                .overlay(shape.stroke(CoveStyle.secondaryText, lineWidth: 1).allowsHitTesting(false))
        } else {
            content.glassEffect(.regular, in: shape)
        }
    }
}

/// Mother-of-pearl is a surface, not a white blur over the content. The clear
/// native glass supplies refraction; a restrained nacre layer sits *behind* text.
/// No interactive glass is used for a non-interactive content panel.
private struct CovePearlCardSurface: ViewModifier {
    let emphasized: Bool
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.colorScheme) private var scheme

    private var shape: RoundedRectangle {
        RoundedRectangle(cornerRadius: emphasized ? 30 : 22, style: .continuous)
    }

    func body(content: Content) -> some View {
        content
            .background {
                Group {
                    if reduceTransparency || contrast == .increased {
                        shape.fill(emphasized ? CoveStyle.pearlCardEmphasized : CoveStyle.pearlCard)
                    } else {
                        shape.fill(CoveStyle.pearlCard.opacity(scheme == .dark ? 0.88 : (emphasized ? 0.46 : 0.58)))
                            .overlay {
                                if emphasized {
                                    shape.fill(CoveStyle.nacreGradient).opacity(scheme == .dark ? 0.16 : 0.50)
                                }
                            }
                            .glassEffect(.clear, in: shape)
                    }
                }
                .shadow(color: CoveStyle.pearlShadow.opacity(emphasized ? 0.10 : 0.035),
                        radius: emphasized ? 18 : 8, x: 0, y: emphasized ? 8 : 3)
                .allowsHitTesting(false)
            }
            .overlay {
                Group {
                    if reduceTransparency || contrast == .increased {
                        shape.strokeBorder(CoveStyle.pearlBorderStrong, lineWidth: 1)
                    } else {
                        shape.strokeBorder(CoveStyle.nacreEdge, lineWidth: emphasized ? 1.3 : 0.7)
                        shape.inset(by: 2).strokeBorder(
                            LinearGradient(colors: [.white.opacity(emphasized ? 0.65 : 0.24), .clear, CoveStyle.pearlIce.opacity(0.35)],
                                           startPoint: .topLeading, endPoint: .bottomTrailing), lineWidth: 0.5)
                    }
                }.allowsHitTesting(false).accessibilityHidden(true)
            }
    }
}

/// A tiny pearl, lit from the upper left: cool core, rose/lilac reflected rim,
/// and a pinpoint highlight. Vector-native and deliberately never animated.
struct CovePearlBead: View {
    var diameter: CGFloat = 12
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        Circle()
            .fill(RadialGradient(
                colors: [.white, CoveStyle.pearlMilk, CoveStyle.pearlIce, CoveStyle.pearlLilac],
                center: .init(x: 0.30, y: 0.23), startRadius: 0, endRadius: diameter * 0.82))
            .overlay {
                Circle().fill(CoveStyle.nacreGradient).opacity(0.32)
                Circle().strokeBorder(CoveStyle.nacreEdge, lineWidth: 0.6)
                Circle().fill(.white.opacity(0.90))
                    .frame(width: diameter * 0.22, height: diameter * 0.16)
                    .blur(radius: diameter * 0.04)
                    .offset(x: -diameter * 0.17, y: -diameter * 0.21)
            }
            .frame(width: diameter, height: diameter)
            .shadow(color: CoveStyle.pearlShadow.opacity(scheme == .dark ? 0.35 : 0.20), radius: 1.5, x: 0, y: 1.5)
            .accessibilityHidden(true)
            .allowsHitTesting(false)
    }
}

/// Opt-in keeps these shared modules unchanged outside the Home page.
struct CoveHomeModuleSurface: ViewModifier {
    let enabled: Bool
    func body(content: Content) -> some View {
        if enabled { content.covePearlCard() }
        else { content.background(CoveStyle.card, in: RoundedRectangle(cornerRadius: 14)) }
    }
}

extension View {
    /// Applies Cove's non-interactive pearl material to a content card.
    /// Callers remain responsible for padding and button semantics.
    func covePearlCard(emphasized: Bool = false) -> some View {
        modifier(CovePearlCardSurface(emphasized: emphasized))
    }
}

// Shared warm palette, based on 用户's pink Telegram reference.
enum CoveStyle {
    static let accent = adaptive(0xE45698, 0xF296C1)
    static let teal = accent // Compatibility for existing controls.
    static let accentText = adaptive(0xA82E63, 0xF5A3CC)
    static let text = adaptive(0x36232F, 0xFAEDF4)
    static let secondaryText = adaptive(0x886675, 0xC5A6B9)
    static let background = adaptive(0xFFF0F5, 0x251922)
    static let card = adaptive(0xFFFCFD, 0x33232F)
    static let chatBackground = adaptive(0xFCEBF2, 0x261B25)
    static let incoming = adaptive(0xFFFCFD, 0x392937)
    static let softAccent = adaptive(0xFADDEB, 0x47283B)
    static let border = adaptive(0xE9CEDB, 0x634456)
    static let dateBackground = adaptive(0xFFFCFD, 0x33232F).opacity(0.90)
    static let dateText = secondaryText
    static let error = adaptive(0xBE294A, 0xFF9BB0)
    static let terminalBackground = adaptive(0xFFF7FA, 0x211820)
    static let terminalText = text
    static let terminalAccent = accentText

    // Nacre: icy blue, soft pink and silver-lilac, never an opaque pink wash.
    // The opaque card colors are also the accessibility fallback for transparency.
    static let pearlCanvas = adaptive(0xF7F7F5, 0x241920)
    static let pearlIce = adaptive(0xC9E4F4, 0x8BACCA)
    static let pearlBlush = adaptive(0xF4D5E5, 0xC68DAF)
    static let pearlLilac = adaptive(0xC9C2E2, 0x8C81AC)
    static let pearlMilk = adaptive(0xFFF9F3, 0xE9E4EC)
    static let pearlInk = adaptive(0x302C42, 0xF5F0FA)
    static let pearlSecondary = adaptive(0x565164, 0xD1CBDE)
    static let nacreGradient = AngularGradient(
        colors: [pearlIce, pearlMilk, pearlBlush, pearlLilac, pearlMilk, pearlIce],
        center: .init(x: 0.30, y: 0.18), startAngle: .degrees(-35), endAngle: .degrees(325))
    static let nacreEdge = AngularGradient(
        colors: [.white.opacity(0.95), pearlIce.opacity(0.9), pearlLilac.opacity(0.7),
                 .white.opacity(0.85), pearlBlush.opacity(0.8), .white.opacity(0.95)],
        center: .center, startAngle: .degrees(-90), endAngle: .degrees(270))
    static let pearlCard = adaptive(0xFAFAF8, 0x34242F)
    static let pearlCardEmphasized = adaptive(0xFFFDFD, 0x3D2937)
    static let pearlHairline = adaptive(0xFFFFFF, 0x795267).opacity(0.82)
    static let pearlBorderStrong = adaptive(0xCDBFC8, 0x93667D)
    static let pearlShadow = adaptive(0x6C6170, 0x120B10)

    static func outgoing(_ dark: Bool) -> Color {
        Color(uiColor: uiColor(dark ? 0x49303D : 0xFCE3ED))
    }
    static func adaptive(_ light: UInt32, _ dark: UInt32) -> Color {
        Color(uiColor: UIColor { uiColor($0.userInterfaceStyle == .dark ? dark : light) })
    }
    private static func uiColor(_ hex: UInt32) -> UIColor {
        UIColor(red: CGFloat((hex >> 16) & 255) / 255, green: CGFloat((hex >> 8) & 255) / 255, blue: CGFloat(hex & 255) / 255, alpha: 1)
    }
}
