import SwiftUI

/// 阅读区主题。同时定义「阅读背景」与「纸张」的颜色。
enum ReaderTheme: String, Codable, CaseIterable, Identifiable {
    case classic        // 经典：米白纸 + 深灰背景
    case warmSepia      // 暖褐：米黄纸 + 暗棕背景（护眼）
    case night          // 暗夜：深灰纸 + 近黑背景
    case inkBlack       // 墨黑：黑纸 + 纯黑背景
    case deepTeal       // 深青：青灰纸 + 深青背景
    case midnightBlue   // 午夜蓝
    case forest         // 森林绿
    case slate          // 石板灰

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .classic:      return "经典"
        case .warmSepia:    return "暖褐"
        case .night:        return "暗夜"
        case .inkBlack:     return "墨黑"
        case .deepTeal:     return "深青"
        case .midnightBlue: return "午夜蓝"
        case .forest:       return "森林"
        case .slate:        return "石板"
        }
    }

    /// 是否深色主题。决定纸张边缘、书脊线、翻页压暗等用亮还是用暗。
    var isDark: Bool {
        switch self {
        case .classic, .warmSepia: return false
        default: return true
        }
    }

    /// 阅读区背景渐变（上 → 下）
    var backgroundColors: [Color] {
        switch self {
        case .classic:
            return [Color(white: 0.17), Color(white: 0.07)]
        case .warmSepia:
            return [Color(red: 0.21, green: 0.17, blue: 0.13),
                    Color(red: 0.11, green: 0.09, blue: 0.07)]
        case .night:
            return [Color(white: 0.10), Color(white: 0.02)]
        case .inkBlack:
            return [Color(white: 0.05), Color.black]
        case .deepTeal:
            return [Color(red: 0.04, green: 0.13, blue: 0.14),
                    Color(red: 0.01, green: 0.05, blue: 0.06)]
        case .midnightBlue:
            return [Color(red: 0.06, green: 0.09, blue: 0.18),
                    Color(red: 0.02, green: 0.03, blue: 0.08)]
        case .forest:
            return [Color(red: 0.06, green: 0.13, blue: 0.09),
                    Color(red: 0.02, green: 0.06, blue: 0.04)]
        case .slate:
            return [Color(red: 0.16, green: 0.17, blue: 0.19),
                    Color(red: 0.08, green: 0.09, blue: 0.10)]
        }
    }

    /// 纸张底色
    var paperColor: Color {
        switch self {
        case .classic:      return Color(red: 0.99, green: 0.985, blue: 0.97)
        case .warmSepia:    return Color(red: 0.96, green: 0.93, blue: 0.87)
        case .night:        return Color(red: 0.16, green: 0.16, blue: 0.17)
        case .inkBlack:     return Color(red: 0.09, green: 0.09, blue: 0.10)
        case .deepTeal:     return Color(red: 0.10, green: 0.20, blue: 0.21)
        case .midnightBlue: return Color(red: 0.11, green: 0.14, blue: 0.24)
        case .forest:       return Color(red: 0.11, green: 0.19, blue: 0.14)
        case .slate:        return Color(red: 0.22, green: 0.23, blue: 0.25)
        }
    }

    /// 纸张内侧边缘的压暗（浅色主题用）
    var paperEdgeShadow: Color {
        isDark ? Color.black.opacity(0.55) : Color.black.opacity(0.09)
    }

    /// 书脊那条细线的颜色
    var spineLineColor: Color {
        isDark ? Color.white.opacity(0.22) : Color.black.opacity(0.22)
    }

    /// 纸张轮廓描边
    var paperBorderColor: Color {
        isDark ? Color.white.opacity(0.07) : Color.black.opacity(0.10)
    }

    /// 硬纸板翻过去后，背面的压暗程度
    var flipDimming: Double {
        isDark ? 0.26 : 0.10
    }

    /// 深色主题下，页码/进度条等 UI 用色
    var chromeForeground: Color {
        isDark ? Color.white : Color.white
    }
}
