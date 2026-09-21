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

    /// 荧光笔需要透明叠加，其余不透明（透明度由 BrushSettings.opacity 控制）
    var baseAlpha: CGFloat { self == .marker ? 1.0 : 1.0 }

    /// 勾线宽度的倍率。
    /// 荧光笔原来是 1.6（怕太细看不见），实测偏粗，
    /// 现在改成 1.0 —— 想更细就去画笔面板里把「粗细」往左拉。
    var widthMultiplier: CGFloat { 1.0 }
}

// MARK: - 单支笔的设置

struct BrushSettings: Codable, Equatable, Hashable {
    /// 粗细（pt）
    var width: Double
    /// 不透明度 0.05 ~ 1.0
    var opacity: Double

    static func standard(for kind: PenKind) -> BrushSettings {
        switch kind {
        case .pen:    return BrushSettings(width: 10, opacity: 1.0)
        case .marker: return BrushSettings(width: 30, opacity: 0.38)
        case .pencil: return BrushSettings(width: 10, opacity: 1.0)
        }
    }

    var clampedWidth: CGFloat {
        CGFloat(min(max(width, 1), 60))
    }

    var clampedOpacity: CGFloat {
        CGFloat(min(max(opacity, 0.05), 1.0))
    }
}

// MARK: - 三支笔的设置集合

struct BrushPreset: Codable, Equatable {
    var pen: BrushSettings = BrushSettings.standard(for: .pen)
    var marker: BrushSettings = BrushSettings.standard(for: .marker)
    var pencil: BrushSettings = BrushSettings.standard(for: .pencil)

    func settings(for kind: PenKind) -> BrushSettings {
        switch kind {
        case .pen:    return pen
        case .marker: return marker
        case .pencil: return pencil
        }
    }

    mutating func update(_ value: BrushSettings, for kind: PenKind) {
        switch kind {
        case .pen:    pen = value
        case .marker: marker = value
        case .pencil: pencil = value
        }
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

    var brushKind: PenKind? {
        if case .brush(let k) = self { return k }
        return nil
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

    var shortName: String {
        switch self {
        case .precise: return "精确"
        case .vector:  return "矢量"
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

// MARK: - 橡皮粗细

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

// MARK: - 预设颜色（6 个）

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

// MARK: - 用户自定义颜色

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
func stableColorKey(_ color: Color) -> String {
    color.hexString
}
