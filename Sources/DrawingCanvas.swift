import SwiftUI
import PencilKit

/// 笔的类型
enum PenKind: String, CaseIterable {
    case pen
    case marker
    case pencil
    case eraser

    var systemImage: String {
        switch self {
        case .pen:    return "pencil.tip"
        case .marker: return "highlighter"
        case .pencil: return "pencil"
        case .eraser: return "eraser"
        }
    }

    var displayName: String {
        switch self {
        case .pen:    return "钢笔"
        case .marker: return "马克笔"
        case .pencil: return "铅笔"
        case .eraser: return "橡皮"
        }
    }
}

/// 笔的颜色
enum PenColor: String, CaseIterable {
    case black
    case red
    case blue
    case green
    case orange
    case purple

    var color: Color {
        switch self {
        case .black:  return .black
        case .red:    return Color(red: 0.85, green: 0.16, blue: 0.16)
        case .blue:   return Color(red: 0.10, green: 0.35, blue: 0.85)
        case .green:  return Color(red: 0.10, green: 0.60, blue: 0.30)
        case .orange: return Color(red: 0.95, green: 0.55, blue: 0.10)
        case .purple: return Color(red: 0.55, green: 0.25, blue: 0.80)
        }
    }
}

/// 笔的粗细
enum PenWidth: Double, CaseIterable {
    case thin = 2
    case medium = 6
    case thick = 14

    /// 工具栏小圆点的视觉尺寸
    var dotSize: CGFloat {
        switch self {
        case .thin:   return 6
        case .medium: return 11
        case .thick:  return 17
        }
    }
}

/// PencilKit 画布的 SwiftUI 封装。
///
/// ⚠️ 核心设计：传入的 `canvasSize` 永远是 **跨页尺寸**（宽 = 单页宽 × 2）。
/// 单页模式下由外层裁剪显示其中一半，笔迹坐标在两种模式下完全一致。
struct DrawingCanvas: UIViewRepresentable {

    let canvasSize: CGSize
    let initialDrawing: PKDrawing
    let pencilOnly: Bool
    let tool: PKTool
    /// 每次自增都会让画布执行一次撤销
    let undoTrigger: Int
    let redoTrigger: Int
    let clearTrigger: Int
    let onDrawingChanged: (PKDrawing) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onDrawingChanged: onDrawingChanged)
    }

    func makeUIView(context: Context) -> PKCanvasView {
        let canvas = PKCanvasView()
        canvas.frame = CGRect(origin: .zero, size: canvasSize)
        canvas.bounds = CGRect(origin: .zero, size: canvasSize)

        canvas.backgroundColor = .clear
        canvas.isOpaque = false
        canvas.drawing = initialDrawing
        canvas.tool = tool
        canvas.drawingPolicy = pencilOnly ? .pencilOnly : .anyInput

        // 画布自身不滚动、不缩放 —— 视图缩放由外层负责
        canvas.isScrollEnabled = false
        canvas.minimumZoomScale = 1
        canvas.maximumZoomScale = 1
        canvas.alwaysBounceVertical = false
        canvas.alwaysBounceHorizontal = false

        canvas.delegate = context.coordinator
        return canvas
    }

    func updateUIView(_ canvas: PKCanvasView, context: Context) {
        context.coordinator.onDrawingChanged = onDrawingChanged

        // 尺寸变了（比如横竖屏切换）就更新
        if canvas.bounds.size != canvasSize {
            canvas.frame = CGRect(origin: .zero, size: canvasSize)
            canvas.bounds = CGRect(origin: .zero, size: canvasSize)
        }

        // 笔模式
        let policy: PKCanvasViewDrawingPolicy = pencilOnly ? .pencilOnly : .anyInput
        if canvas.drawingPolicy != policy {
            canvas.drawingPolicy = policy
        }

        // 工具
        if context.coordinator.lastToolSignature != toolSignature {
            canvas.tool = tool
            context.coordinator.lastToolSignature = toolSignature
        }

        // 撤销 / 重做 / 清除
        if context.coordinator.lastUndoTrigger != undoTrigger {
            context.coordinator.lastUndoTrigger = undoTrigger
            canvas.undoManager?.undo()
        }
        if context.coordinator.lastRedoTrigger != redoTrigger {
            context.coordinator.lastRedoTrigger = redoTrigger
            canvas.undoManager?.redo()
        }
        if context.coordinator.lastClearTrigger != clearTrigger {
            context.coordinator.lastClearTrigger = clearTrigger
            canvas.drawing = PKDrawing()
            onDrawingChanged(PKDrawing())
        }
    }

    private var toolSignature: String {
        "\(pencilOnly)-\(String(describing: type(of: tool)))-\(tool)"
    }

    final class Coordinator: NSObject, PKCanvasViewDelegate {
        var onDrawingChanged: (PKDrawing) -> Void
        var lastToolSignature: String = ""
        var lastUndoTrigger: Int = 0
        var lastRedoTrigger: Int = 0
        var lastClearTrigger: Int = 0

        init(onDrawingChanged: @escaping (PKDrawing) -> Void) {
            self.onDrawingChanged = onDrawingChanged
        }

        func canvasViewDrawingDidChange(_ canvasView: PKCanvasView) {
            onDrawingChanged(canvasView.drawing)
        }
    }
}
