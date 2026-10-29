import SwiftUI

/// Shared presentation primitives for Cove's “Pearl Living” language.
/// Pink carries action; ice blue carries calm/read-only data. Nacre is reserved
/// for one hero per page so ordinary content stays quiet and legible.
enum CovePearlLayout {
    static let pageInset: CGFloat = 20
    static let sectionSpacing: CGFloat = 24
    static let cardPadding: CGFloat = 18
    static let contentSpacing: CGFloat = 16
    static let compactSpacing: CGFloat = 8
    static let heroRadius: CGFloat = 30
    static let cardRadius: CGFloat = 22
    static let controlRadius: CGFloat = 14
}

extension CoveStyle {
    static let dataBlue = adaptive(0x6D9DB7, 0x9CC8DD)
    static let dataBlueSoft = adaptive(0xE4F1F7, 0x29404B)
    static let dataLilac = adaptive(0x988DBD, 0xBEB3DF)
    static let success = adaptive(0x427C68, 0x8BC8AE)
    static let warning = adaptive(0xA26A30, 0xE1B77B)
}

struct CovePearlHero<Content: View>: View {
    @ViewBuilder let content: () -> Content

    var body: some View {
        content()
            .padding(24)
            .frame(maxWidth: .infinity, alignment: .leading)
            .covePearlCard(emphasized: true)
    }
}

struct CovePearlSectionTitle<Trailing: View>: View {
    let title: String
    @ViewBuilder let trailing: () -> Trailing

    init(_ title: String, @ViewBuilder trailing: @escaping () -> Trailing) {
        self.title = title
        self.trailing = trailing
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(title)
                .font(.system(.title3, design: .default).weight(.semibold))
                .foregroundStyle(CoveStyle.pearlInk)
            Spacer(minLength: 0)
            trailing()
        }
    }
}

extension CovePearlSectionTitle where Trailing == EmptyView {
    init(_ title: String) { self.init(title) { EmptyView() } }
}

struct CovePearlProgressBar: View {
    let value: Double?
    var tint: Color = CoveStyle.accent

    private var boundedValue: Double { min(1, max(0, value ?? 0)) }

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule().fill(CoveStyle.pearlBorderStrong.opacity(0.20))
                if value != nil {
                    Capsule().fill(tint)
                        .frame(width: proxy.size.width * boundedValue)
                }
            }
        }
        .frame(height: 6)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("进度")
        .accessibilityValue(value.map { $0.formatted(.percent.precision(.fractionLength(0))) } ?? "未设置")
    }
}

struct CovePearlFeatureIcon: View {
    let symbol: String
    var tint: Color = CoveStyle.accentText

    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: 16, weight: .medium))
            .foregroundStyle(tint)
            .frame(width: 34, height: 34)
            .background(tint.opacity(0.10), in: Circle())
            .accessibilityHidden(true)
    }
}

struct CovePearlPrimaryButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var enabled
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.body.weight(.semibold))
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity, minHeight: 50)
            .background(enabled ? CoveStyle.accent : CoveStyle.secondaryText.opacity(0.35),
                        in: RoundedRectangle(cornerRadius: CovePearlLayout.controlRadius, style: .continuous))
            .scaleEffect(configuration.isPressed && !reduceMotion ? 0.985 : 1)
            .opacity(configuration.isPressed ? 0.90 : 1)
            .animation(reduceMotion ? nil : .easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

struct CovePearlInsetPanel<Content: View>: View {
    @ViewBuilder let content: () -> Content

    var body: some View {
        content()
            .padding(CovePearlLayout.contentSpacing)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(CoveStyle.pearlMilk.opacity(0.48),
                        in: RoundedRectangle(cornerRadius: CovePearlLayout.controlRadius, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: CovePearlLayout.controlRadius, style: .continuous)
                    .strokeBorder(CoveStyle.pearlBorderStrong.opacity(0.22), lineWidth: 0.5)
                    .allowsHitTesting(false)
            }
    }
}
