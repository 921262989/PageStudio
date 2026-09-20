import SwiftUI
import PencilKit

// MARK: - 笔的种类

enum PenKind: String, CaseIterable, Identifiable, Codable {
    case pen
    case marker
    case pencil

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .pen:    return "钢笔"
        case .marker: return "荧光笔"
        case .pencil: return "铅笔"
        }
    }

    var systemImage: String {
        switch self {
        case .pen:    return "pencil.tip"
        case .marker: return "highlighter"
        case .pencil: return "pencil"
        }
    }

    var inkType: PKInk.InkType {
        switch self {
        case .pen:    return .pen
        case .marker: return .marker
        case .pencil: return .pencil
        }
    }

    /// 荧光笔需要透明叠加，其余不透明
    var alpha: CGFloat {
        self == .marker ? 0.45 : 1.0
    }

    /// 荧光笔的勾线宽度需要放大，否则太细
    var widthMultiplier: CGFloat {
        self == .marker ? 2.4 : 1.0
    }
}

// MARK: - 当前工具

enum ActiveTool: Hashable {
    case brush(PenKind)
    case eraser

    var isEraser: Bool {
        if case .eraser = self { return true }
        return false
    }
}

// MARK: - 橡皮种类

enum EraserKind: String, CaseIterable, Identifiable, Codable {
    /// 精确橡皮：只擦掉笔尖划过的位置（一根笔画可能被擦成两段）
    case precise
    /// 矢量橡皮：碰到哪一笔，整笔消失
    case vector

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .precise: return "精确橡皮"
        case .vector:  return "矢量橡皮"
        }
    }

    var descriptionText: String {
        switch self {
        case .precise: return "只擦掉笔尖经过的位置"
        case .vector:  return "碰到哪一笔，整笔一起消失"
        }
    }

    var systemImage: String {
        switch self {
        case .precise: return "eraser"
        case .vector:  return "eraser.line.dashed"
        }
    }

    var pkType: PKEraserTool.EraserType {
        switch self {
        case .precise: return .bitmap
        case .vector:  return .vector
        }
    }
}

// MARK: - 笔的粗细（6 档）

enum PenWidth: String, CaseIterable, Identifiable, Codable {
    case hairline
    case thin
    case light
    case medium
    case bold
    case heavy

    var id: String { rawValue }

    var value: CGFloat {
        switch self {
        case .hairline: return 1.5
        case .thin:     return 3
        case .light:    return 6
        case .medium:   return 11
        case .bold:     return 18
        case .heavy:    return 30
        }
    }

    var displayName: String {
        switch self {
        case .hairline: return "极细"
        case .thin:     return "细"
        case .light:    return "偏细"
        case .medium:   return "中"
        case .bold:     return "粗"
        case .heavy:    return "极粗"
        }
    }

    /// 工具栏小圆点的视觉大小
    var dotSize: CGFloat {
        switch self {
        case .hairline: return 4
        case .thin:     return 7
        case .light:    return 10
        case .medium:   return 14
        case .bold:     return 19
        case .heavy:    return 24
        }
    }
}

// MARK: - 橡皮的粗细（4 档）

enum EraserWidth: String, CaseIterable, Identifiable, Codable {
    case small
    case medium
    case large
    case huge

    var id: String { rawValue }

    var value: CGFloat {
        switch self {
        case .small:  return 12
        case .medium: return 28
        case .large:  return 55
        case .huge:   return 100
        }
    }

    var displayName: String {
        switch self {
        case .small:  return "小"
        case .medium: return "中"
        case .large:  return "大"
        case .huge:   return "特大"
        }
    }

    var dotSize: CGFloat {
        switch self {
        case .small:  return 10
        case .medium: return 16
        case .large:  return 22
        case .huge:   return 28
        }
    }
}

// MARK: - 预设颜色

enum PenColorPreset: String, CaseIterable, Identifiable {
    case black
    case graphite
    case gray
    case red
    case orange
    case yellow
    case green
    case teal
    case blue
    case indigo
    case purple
    case pink
    case brown
    case white

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .black:    return "黑"
        case .graphite: return "石墨"
        case .gray:     return "灰"
        case .red:      return "红"
        case .orange:   return "橙"
        case .yellow:   return "黄"
        case .green:    return "绿"
        case .teal:     return "青"
        case .blue:     return "蓝"
        case .indigo:   return "靛"
        case .purple:   return "紫"
        case .pink:     return "粉"
        case .brown:    return "棕"
        case .white:    return "白"
        }
    }

    var color: Color {
        switch self {
        case .black:    return Color(white: 0.05)
        case .graphite: return Color(white: 0.25)
        case .gray:     return Color(white: 0.55)
        case .red:      return Color(red: 0.88, green: 0.16, blue: 0.16)
        case .orange:   return Color(red: 0.96, green: 0.52, blue: 0.10)
        case .yellow:   return Color(red: 0.97, green: 0.80, blue: 0.10)
        case .green:    return Color(red: 0.13, green: 0.66, blue: 0.33)
        case .teal:     return Color(red: 0.10, green: 0.66, blue: 0.66)
        case .blue:     return Color(red: 0.12, green: 0.40, blue: 0.90)
        case .indigo:   return Color(red: 0.30, green: 0.24, blue: 0.78)
        case .purple:   return Color(red: 0.60, green: 0.26, blue: 0.85)
        case .pink:     return Color(red: 0.94, green: 0.38, blue: 0.62)
        case .brown:    return Color(red: 0.55, green: 0.38, blue: 0.24)
        case .white:    return Color(white: 0.97)
        }
    }
}

// MARK: - 颜色稳定性

/// 把颜色转成一个稳定的字符串。用于判断"工具是否真的变了"。
/// ⚠️ 不能用 Color 的 description —— 它不稳定，会导致画布工具被反复重设，
/// 而反复重设工具正是笔迹"画上去一个样、几秒后另一个样"的元凶之一。
func stableColorKey(_ color: Color) -> String {
    let ui = UIColor(color)
    var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
    if ui.getRed(&r, green: &g, blue: &b, alpha: &a) {
        return String(format: "%.3f_%.3f_%.3f_%.3f", r, g, b, a)
    }
    return "unknown"
}
