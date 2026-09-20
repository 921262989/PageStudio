import SwiftUI

// MARK: - 纸张样式（固定，永不随主题变化）

/// 纸张永远是白纸。主题只改「书桌」的颜色。
enum PaperStyle {
    static let fill = Color(red: 0.99, green: 0.985, blue: 0.97)
    static let edgeShadow = Color.black.opacity(0.09)
    static let border = Color.black.opacity(0.10)
    static let spineLine = Color.black.opacity(0.22)
    static let flipDimming: Double = 0.10

    static let fillRGB: (r: CGFloat, g: CGFloat, b: CGFloat) = (0.99, 0.985, 0.97)
}

// MARK: - 阅读背景主题（已调亮）

enum ReaderTheme: String, Codable, CaseIterable, Identifiable {
    case classic
    case inkBlack
    case deepTeal
    case midnightBlue
    case forest
    case plum
    case wine
    case slate

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .classic:      return "深灰"
        case .inkBlack:     return "墨黑"
        case .deepTeal:     return "深青"
        case .midnightBlue: return "午夜蓝"
        case .forest:       return "墨绿"
        case .plum:         return "深紫"
        case .wine:         return "酒红"
        case .slate:        return "石板"
        }
    }

    /// 桌面渐变（上 → 下）。比上一版整体亮了一档。
    var backgroundColors: [Color] {
        switch self {
        case .classic:
            return [Color(white: 0.25), Color(white: 0.15)]
        case .inkBlack:
            return [Color(white: 0.14), Color(white: 0.06)]
        case .deepTeal:
            return [Color(red: 0.09, green: 0.19, blue: 0.20),
                    Color(red: 0.04, green: 0.11, blue: 0.12)]
        case .midnightBlue:
            return [Color(red: 0.12, green: 0.16, blue: 0.27),
                    Color(red: 0.05, green: 0.08, blue: 0.16)]
        case .forest:
            return [Color(red: 0.11, green: 0.19, blue: 0.14),
                    Color(red: 0.05, green: 0.12, blue: 0.09)]
        case .plum:
            return [Color(red: 0.20, green: 0.12, blue: 0.23),
                    Color(red: 0.10, green: 0.06, blue: 0.12)]
        case .wine:
            return [Color(red: 0.23, green: 0.10, blue: 0.14),
                    Color(red: 0.12, green: 0.05, blue: 0.08)]
        case .slate:
            return [Color(red: 0.23, green: 0.24, blue: 0.26),
                    Color(red: 0.13, green: 0.14, blue: 0.15)]
        }
    }
}
