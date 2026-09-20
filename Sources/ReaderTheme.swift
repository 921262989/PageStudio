import SwiftUI

// MARK: - 纸张样式（固定，永不随主题变化）

/// 纸张永远是白纸。主题只改「书桌」的颜色。
enum PaperStyle {
    static let fill = Color(red: 0.99, green: 0.985, blue: 0.97)
    static let edgeShadow = Color.black.opacity(0.09)
    static let border = Color.black.opacity(0.10)
    static let spineLine = Color.black.opacity(0.22)
    /// 硬纸板翻过去后，背面的压暗程度
    static let flipDimming: Double = 0.10

    /// 吸色时用作底色的纸 RGB
    static let fillRGB: (r: CGFloat, g: CGFloat, b: CGFloat) = (0.99, 0.985, 0.97)
}

// MARK: - 阅读背景主题

/// ⚠️ 主题只改「本子背后的背景颜色」，不碰纸张。
enum ReaderTheme: String, Codable, CaseIterable, Identifiable {
    case classic        // 深灰（默认）
    case inkBlack       // 纯黑
    case deepTeal       // 深青
    case midnightBlue   // 午夜蓝
    case forest         // 墨绿
    case plum           // 深紫
    case wine           // 酒红
    case slate          // 石板

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .classic:      return "深灰"
        case .inkBlack:     return "纯黑"
        case .deepTeal:     return "深青"
        case .midnightBlue: return "午夜蓝"
        case .forest:       return "墨绿"
        case .plum:         return "深紫"
        case .wine:         return "酒红"
        case .slate:        return "石板"
        }
    }

    /// 桌面渐变（上 → 下）
    var backgroundColors: [Color] {
        switch self {
        case .classic:
            return [Color(white: 0.17), Color(white: 0.07)]
        case .inkBlack:
            return [Color(white: 0.06), Color.black]
        case .deepTeal:
            return [Color(red: 0.04, green: 0.13, blue: 0.14),
                    Color(red: 0.01, green: 0.05, blue: 0.06)]
        case .midnightBlue:
            return [Color(red: 0.07, green: 0.10, blue: 0.20),
                    Color(red: 0.02, green: 0.03, blue: 0.09)]
        case .forest:
            return [Color(red: 0.06, green: 0.13, blue: 0.09),
                    Color(red: 0.02, green: 0.05, blue: 0.04)]
        case .plum:
            return [Color(red: 0.14, green: 0.07, blue: 0.17),
                    Color(red: 0.05, green: 0.02, blue: 0.07)]
        case .wine:
            return [Color(red: 0.17, green: 0.05, blue: 0.09),
                    Color(red: 0.07, green: 0.02, blue: 0.04)]
        case .slate:
            return [Color(red: 0.17, green: 0.18, blue: 0.20),
                    Color(red: 0.08, green: 0.09, blue: 0.10)]
        }
    }
}
