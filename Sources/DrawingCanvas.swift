import SwiftUI
import PencilKit

// MARK: - 笔类型 / 颜色 / 粗细

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

enum PenColor: String, CaseIterable {
    case black, red, blue, green, orange, purple

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

enum PenWidth: Double, CaseIterable {
    case thin = 2
    case medium = 6
    case thick = 14

    var dotSize: CGFloat {
        switch self {
        case .thin:   return 6
        case .medium: return 11
        case .thick:  return 17
        }
    }
}

// MARK: - 画布

/// PencilKit 画布的 SwiftUI 封装。
///
/// ⚠️ `canvasSize` 永远传「逻辑跨页尺寸」（DrawingGeometry.spreadSize），
/// 与屏幕大小无关。显示时由外层 scaleEffect 缩放。
struct DrawingCanvas: UIViewRepresentable {

    let canvasSize: CGSize
    let initialDrawing: PKDrawing
    let pencilOnly: Bool
    let tool: PKTool
    let undoTrigger: Int
    let redoTrigger: Int
    let clearTrigger: Int
    let onDrawingChanged: (PKDrawing) -> Void
    /// 正在落笔 / 抬笔 —— 用来避免烘焙图和实时画布重影
    let onDrawingStateChanged: (Bool) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onDrawingChanged: onDrawingChanged,
                    onDrawingStateChanged: onDrawingStateChanged)
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
        context.coordinator.onDrawingStateChanged = onDrawingStateChanged

        if canvas.bounds.size != canvasSize {
            canvas.frame = CGRect(origin: .zero, size: canvasSize)
            canvas.bounds = CGRect(origin: .zero, size: canvasSize)
        }

        let policy: PKCanvasViewDrawingPolicy = pencilOnly ? .pencilOnly : .anyInput
        if canvas.drawingPolicy != policy {
            canvas.drawingPolicy = policy
        }

        if context.coordinator.lastToolSignature != toolSignature {
            canvas.tool = tool
            context.coordinator.lastToolSignature = toolSignature
        }

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
        "\(pencilOnly)-\(tool)"
    }

    final class Coordinator: NSObject, PKCanvasViewDelegate {
        var onDrawingChanged: (PKDrawing) -> Void
        var onDrawingStateChanged: (Bool) -> Void
        var lastToolSignature: String = ""
        var lastUndoTrigger: Int = 0
        var lastRedoTrigger: Int = 0
        var lastClearTrigger: Int = 0

        init(onDrawingChanged: @escaping (PKDrawing) -> Void,
             onDrawingStateChanged: @escaping (Bool) -> Void) {
            self.onDrawingChanged = onDrawingChanged
            self.onDrawingStateChanged = onDrawingStateChanged
        }

        func canvasViewDrawingDidChange(_ canvasView: PKCanvasView) {
            onDrawingChanged(canvasView.drawing)
        }

        func canvasViewDidBeginUsingTool(_ canvasView: PKCanvasView) {
            onDrawingStateChanged(true)
        }

        func canvasViewDidEndUsingTool(_ canvasView: PKCanvasView) {
            onDrawingStateChanged(false)
        }
    }
}
