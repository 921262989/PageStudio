import SwiftUI
import PencilKit
import UIKit

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

    var alpha: CGFloat { self == .marker ? 0.45 : 1.0 }
    var widthMultiplier: CGFloat { self == .marker ? 2.4 : 1.0 }
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
    case precise
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
    case hairline, thin, light, medium, bold, heavy

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

    var dotSize: CGFloat {
        switch self {
        case .hairline: return 5
        case .thin:     return 8
        case .light:    return 11
        case .medium:   return 15
        case .bold:     return 20
        case .heavy:    return 24
        }
    }
}

// MARK: - 橡皮的粗细（4 档）

enum EraserWidth: String, CaseIterable, Identifiable, Codable {
    case small, medium, large, huge

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

// MARK: - 预设颜色（精简到 6 个）

enum PenColorPreset: String, CaseIterable, Identifiable {
    case black
    case red
    case blue
    case green
    case yellow
    case white

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .black:  return "黑"
        case .red:    return "红"
        case .blue:   return "蓝"
        case .green:  return "绿"
        case .yellow: return "黄"
        case .white:  return "白"
        }
    }

    var color: Color {
        switch self {
        case .black:  return Color(white: 0.06)
        case .red:    return Color(red: 0.86, green: 0.16, blue: 0.16)
        case .blue:   return Color(red: 0.12, green: 0.36, blue: 0.88)
        case .green:  return Color(red: 0.13, green: 0.62, blue: 0.30)
        case .yellow: return Color(red: 0.96, green: 0.75, blue: 0.08)
        case .white:  return Color(white: 0.97)
        }
    }

    var hex: String {
        switch self {
        case .black:  return "#0F0F0F"
        case .red:    return "#DB2929"
        case .blue:   return "#1F5CE0"
        case .green:  return "#219E4D"
        case .yellow: return "#F5BF14"
        case .white:  return "#F7F7F7"
        }
    }
}

// MARK: - 用户自定义颜色（可固定到笔刷栏）

struct SavedBrushColor: Identifiable, Codable, Hashable {
    var id: UUID = UUID()
    var hex: String

    var color: Color {
        Color(hex: hex) ?? Color(white: 0.06)
    }
}

// MARK: - Color ←→ HEX

extension Color {
    init?(hex: String) {
        var s = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.hasPrefix("#") { s.removeFirst() }
        guard s.count == 6, let value = UInt32(s, radix: 16) else { return nil }
        let r = Double((value >> 16) & 0xFF) / 255.0
        let g = Double((value >> 8) & 0xFF) / 255.0
        let b = Double(value & 0xFF) / 255.0
        self = Color(red: r, green: g, blue: b)
    }

    var hexString: String {
        let ui = UIColor(self)
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        guard ui.getRed(&r, green: &g, blue: &b, alpha: &a) else { return "#0F0F0F" }
        let ri = Int((r * 255).rounded())
        let gi = Int((g * 255).rounded())
        let bi = Int((b * 255).rounded())
        return String(format: "#%02X%02X%02X", ri, gi, bi)
    }
}

// MARK: - 工具签名（必须稳定）

/// ⚠️ 不能用 Color 的 description —— 它不稳定。
/// 画布工具被反复重设，正是笔迹「画上去一个样、几秒后另一个样」的元凶之一。
func stableColorKey(_ color: Color) -> String {
    color.hexString
}
