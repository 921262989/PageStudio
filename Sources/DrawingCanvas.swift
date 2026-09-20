import SwiftUI
import PencilKit
import UIKit

/// PencilKit 画布的 SwiftUI 封装。
///
/// ⚠️ 两层结构：
/// - 外层 `UIScrollView`：负责用户的双指捏合缩放 / 双指平移（1×–6×）
/// - 内层 `PKCanvasView`：负责笔迹绘制
///
/// `canvasSize` 永远传「逻辑跨页尺寸」（DrawingGeometry.spreadSize），
/// 与屏幕大小、缩放倍率都无关，所以笔迹坐标永远稳定。
struct DrawingCanvas: UIViewRepresentable {

    let canvasSize: CGSize
    let initialDrawing: PKDrawing
    let pencilOnly: Bool
    let tool: PKTool
    /// 工具签名。只有它变了才会重设 canvas.tool。
    /// 频繁重设工具会打断笔迹渲染，所以必须由调用方提供一个「稳定的」字符串。
    let toolSignature: String

    let undoTrigger: Int
    let redoTrigger: Int
    let clearTrigger: Int
    let zoomResetTrigger: Int

    let onDrawingChanged: (PKDrawing) -> Void
    let onDrawingStateChanged: (Bool) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onDrawingChanged: onDrawingChanged,
                    onDrawingStateChanged: onDrawingStateChanged)
    }

    func makeUIView(context: Context) -> UIScrollView {
        let scroll = UIScrollView()
        scroll.backgroundColor = .clear
        scroll.isOpaque = false
        scroll.contentInsetAdjustmentBehavior = .never
        scroll.minimumZoomScale = 1
        scroll.maximumZoomScale = 6
        scroll.bouncesZoom = true
        scroll.showsHorizontalScrollIndicator = false
        scroll.showsVerticalScrollIndicator = false
        scroll.delegate = context.coordinator
        // 单指留给画笔，双指才平移/缩放
        scroll.panGestureRecognizer.minimumNumberOfTouches = 2
        scroll.delaysContentTouches = false
        scroll.canCancelContentTouches = false

        let canvas = PKCanvasView()
        canvas.frame = CGRect(origin: .zero, size: canvasSize)
        canvas.bounds = CGRect(origin: .zero, size: canvasSize)
        canvas.backgroundColor = .clear
        canvas.isOpaque = false
        canvas.drawing = initialDrawing
        canvas.tool = tool
        canvas.drawingPolicy = pencilOnly ? .pencilOnly : .anyInput

        // 画布自身不滚动 —— 缩放交给外层
        canvas.isScrollEnabled = false
        canvas.minimumZoomScale = 1
        canvas.maximumZoomScale = 1
        canvas.alwaysBounceVertical = false
        canvas.alwaysBounceHorizontal = false

        canvas.delegate = context.coordinator

        scroll.addSubview(canvas)
        scroll.contentSize = canvasSize

        context.coordinator.scroll = scroll
        context.coordinator.canvas = canvas
        context.coordinator.lastToolSignature = toolSignature
        context.coordinator.lastPencilOnly = pencilOnly
        return scroll
    }

    func updateUIView(_ scroll: UIScrollView, context: Context) {
        guard let canvas = context.coordinator.canvas else { return }

        context.coordinator.onDrawingChanged = onDrawingChanged
        context.coordinator.onDrawingStateChanged = onDrawingStateChanged

        if canvas.bounds.size != canvasSize {
            canvas.frame = CGRect(origin: .zero, size: canvasSize)
            canvas.bounds = CGRect(origin: .zero, size: canvasSize)
            scroll.contentSize = canvasSize
            scroll.setZoomScale(1, animated: false)
            scroll.contentOffset = .zero
        }

        let policy: PKCanvasViewDrawingPolicy = pencilOnly ? .pencilOnly : .anyInput
        if canvas.drawingPolicy != policy {
            canvas.drawingPolicy = policy
        }

        // ⚠️ 只在签名真的变了才重设工具
        if context.coordinator.lastToolSignature != toolSignature {
            context.coordinator.lastToolSignature = toolSignature
            canvas.tool = tool
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
        if context.coordinator.lastZoomResetTrigger != zoomResetTrigger {
            context.coordinator.lastZoomResetTrigger = zoomResetTrigger
            scroll.setZoomScale(1, animated: true)
            scroll.setContentOffset(.zero, animated: true)
        }
        context.coordinator.lastPencilOnly = pencilOnly
    }

    final class Coordinator: NSObject, PKCanvasViewDelegate, UIScrollViewDelegate {
        var onDrawingChanged: (PKDrawing) -> Void
        var onDrawingStateChanged: (Bool) -> Void

        weak var scroll: UIScrollView?
        weak var canvas: PKCanvasView?

        var lastToolSignature: String = ""
        var lastUndoTrigger: Int = 0
        var lastRedoTrigger: Int = 0
        var lastClearTrigger: Int = 0
        var lastZoomResetTrigger: Int = 0
        var lastPencilOnly: Bool?

        init(onDrawingChanged: @escaping (PKDrawing) -> Void,
             onDrawingStateChanged: @escaping (Bool) -> Void) {
            self.onDrawingChanged = onDrawingChanged
            self.onDrawingStateChanged = onDrawingStateChanged
        }

        // UIScrollView 缩放的目标视图
        func viewForZooming(in scrollView: UIScrollView) -> UIView? {
            canvas
        }

        // PKCanvasView
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
