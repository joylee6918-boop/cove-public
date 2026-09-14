import SwiftUI

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
