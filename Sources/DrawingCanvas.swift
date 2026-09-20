import SwiftUI
import PencilKit
import UIKit

/// PencilKit 画布的 SwiftUI 封装。
///
/// 两层结构：
/// - 外层 `UIScrollView`：双指捏合缩放 / 双指平移（1×–6×）+ 各种手势
/// - 内层 `PKCanvasView`：笔迹绘制
struct DrawingCanvas: UIViewRepresentable {

    // 几何
    let canvasSize: CGSize      // 逻辑跨页尺寸（固定，与屏幕无关）
    let displaySize: CGSize     // 这个跨页在屏幕上实际占的点尺寸（吸色用）

    // 上下文（吸色需要）
    let book: Book
    let spreadIndex: Int

    // 绘制
    let initialDrawing: PKDrawing
    let pencilOnly: Bool
    let tool: PKTool
    let toolSignature: String

    let undoTrigger: Int
    let redoTrigger: Int
    let clearTrigger: Int
    let zoomResetTrigger: Int

    // 手势开关
    let gesturesEnabled: Bool
    let twoFingerUndo: Bool
    let twoFingerLongPressUndo: Bool
    let threeFingerRedo: Bool
    let fourFingerClear: Bool
    let longPressEyedropper: Bool

    // 回调
    let onDrawingChanged: (PKDrawing) -> Void
    let onDrawingStateChanged: (Bool) -> Void
    let onPickColor: (Color) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onDrawingChanged: onDrawingChanged,
                    onDrawingStateChanged: onDrawingStateChanged,
                    onPickColor: onPickColor)
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

        // MARK: 双指轻点 → 撤销
        let twoTap = UITapGestureRecognizer(
            target: context.coordinator,
            action: #selector(Coordinator.handleTwoFingerTap)
        )
        twoTap.numberOfTapsRequired = 1
        twoTap.numberOfTouchesRequired = 2
        twoTap.cancelsTouchesInView = false
        twoTap.delegate = context.coordinator
        scroll.addGestureRecognizer(twoTap)
        context.coordinator.twoFingerTap = twoTap

        // MARK: 双指长按 → 连续撤销
        let rapidUndo = UILongPressGestureRecognizer(
            target: context.coordinator,
            action: #selector(Coordinator.handleRapidUndo(_:))
        )
        rapidUndo.numberOfTouchesRequired = 2
        rapidUndo.minimumPressDuration = 0.45
        rapidUndo.allowableMovement = 24
        rapidUndo.cancelsTouchesInView = false
        rapidUndo.delegate = context.coordinator
        scroll.addGestureRecognizer(rapidUndo)
        context.coordinator.rapidUndoGesture = rapidUndo

        // 轻点优先：短按走轻点，长按走连撤
        twoTap.require(toFail: rapidUndo)

        // MARK: 三指轻点 → 重做
        let threeTap = UITapGestureRecognizer(
            target: context.coordinator,
            action: #selector(Coordinator.handleThreeFingerTap)
        )
        threeTap.numberOfTapsRequired = 1
        threeTap.numberOfTouchesRequired = 3
        threeTap.cancelsTouchesInView = false
        threeTap.delegate = context.coordinator
        scroll.addGestureRecognizer(threeTap)
        context.coordinator.threeFingerTap = threeTap

        // MARK: 四指轻点 → 清空
        let fourTap = UITapGestureRecognizer(
            target: context.coordinator,
            action: #selector(Coordinator.handleFourFingerTap)
        )
        fourTap.numberOfTapsRequired = 1
        fourTap.numberOfTouchesRequired = 4
        fourTap.cancelsTouchesInView = false
        fourTap.delegate = context.coordinator
        scroll.addGestureRecognizer(fourTap)
        context.coordinator.fourFingerTap = fourTap

        // MARK: 单指长按 → 吸色
        let eyedropper = UILongPressGestureRecognizer(
            target: context.coordinator,
            action: #selector(Coordinator.handleEyedropper(_:))
        )
        eyedropper.numberOfTouchesRequired = 1
        eyedropper.minimumPressDuration = 0.5
        eyedropper.allowableMovement = 12
        eyedropper.cancelsTouchesInView = false
        eyedropper.delegate = context.coordinator
        scroll.addGestureRecognizer(eyedropper)
        context.coordinator.eyedropperGesture = eyedropper

        return scroll
    }

    func updateUIView(_ scroll: UIScrollView, context: Context) {
        guard let canvas = context.coordinator.canvas else { return }

        context.coordinator.onDrawingChanged = onDrawingChanged
        context.coordinator.onDrawingStateChanged = onDrawingStateChanged
        context.coordinator.onPickColor = onPickColor
        context.coordinator.book = book
        context.coordinator.spreadIndex = spreadIndex
        context.coordinator.displaySize = displaySize

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

        // ⚠️ 只在签名真的变了才重设工具，否则会打断正在进行的笔迹
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

        // 手势开关
        let on = gesturesEnabled
        context.coordinator.twoFingerTap?.isEnabled = on && twoFingerUndo
        context.coordinator.rapidUndoGesture?.isEnabled = on && twoFingerLongPressUndo
        context.coordinator.threeFingerTap?.isEnabled = on && threeFingerRedo
        context.coordinator.fourFingerTap?.isEnabled = on && fourFingerClear
        // 吸色在「手指也能画」模式下会跟绘制打架，只在「仅笔」模式启用
        context.coordinator.eyedropperGesture?.isEnabled =
            on && longPressEyedropper && pencilOnly
    }

    // MARK: - Coordinator

    final class Coordinator: NSObject,
                             PKCanvasViewDelegate,
                             UIScrollViewDelegate,
                             UIGestureRecognizerDelegate {

        var onDrawingChanged: (PKDrawing) -> Void
        var onDrawingStateChanged: (Bool) -> Void
        var onPickColor: (Color) -> Void

        weak var scroll: UIScrollView?
        weak var canvas: PKCanvasView?

        var book: Book?
        var spreadIndex: Int = 0
        var displaySize: CGSize = .zero

        var lastToolSignature: String = ""
        var lastUndoTrigger: Int = 0
        var lastRedoTrigger: Int = 0
        var lastClearTrigger: Int = 0
        var lastZoomResetTrigger: Int = 0

        weak var twoFingerTap: UITapGestureRecognizer?
        weak var rapidUndoGesture: UILongPressGestureRecognizer?
        weak var threeFingerTap: UITapGestureRecognizer?
        weak var fourFingerTap: UITapGestureRecognizer?
        weak var eyedropperGesture: UILongPressGestureRecognizer?

        private var rapidUndoTimer: Timer?

        init(onDrawingChanged: @escaping (PKDrawing) -> Void,
             onDrawingStateChanged: @escaping (Bool) -> Void,
             onPickColor: @escaping (Color) -> Void) {
            self.onDrawingChanged = onDrawingChanged
            self.onDrawingStateChanged = onDrawingStateChanged
            self.onPickColor = onPickColor
        }

        deinit {
            rapidUndoTimer?.invalidate()
        }

        // MARK: UIScrollView

        func viewForZooming(in scrollView: UIScrollView) -> UIView? {
            canvas
        }

        // MARK: PKCanvasView

        func canvasViewDrawingDidChange(_ canvasView: PKCanvasView) {
            onDrawingChanged(canvasView.drawing)
        }

        func canvasViewDidBeginUsingTool(_ canvasView: PKCanvasView) {
            onDrawingStateChanged(true)
        }

        func canvasViewDidEndUsingTool(_ canvasView: PKCanvasView) {
            onDrawingStateChanged(false)
        }

        // MARK: 手势

        func gestureRecognizer(_ g: UIGestureRecognizer,
                               shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool {
            true
        }

        @objc func handleTwoFingerTap() {
            guard let canvas else { return }
            canvas.undoManager?.undo()
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
        }

        @objc func handleRapidUndo(_ g: UILongPressGestureRecognizer) {
            switch g.state {
            case .began:
                startRapidUndo()
            case .ended, .cancelled, .failed:
                stopRapidUndo()
            default:
                break
            }
        }

        private func startRapidUndo() {
            stopRapidUndo()
            guard let canvas else { return }
            canvas.undoManager?.undo()
            UIImpactFeedbackGenerator(style: .medium).impactOccurred()

            let timer = Timer.scheduledTimer(withTimeInterval: 0.18, repeats: true) {
                [weak self] _ in
                guard let self, let canvas = self.canvas else { return }
                canvas.undoManager?.undo()
                UIImpactFeedbackGenerator(style: .light).impactOccurred()
            }
            rapidUndoTimer = timer
        }

        private func stopRapidUndo() {
            rapidUndoTimer?.invalidate()
            rapidUndoTimer = nil
        }

        @objc func handleThreeFingerTap() {
            guard let canvas else { return }
            canvas.undoManager?.redo()
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
        }

        @objc func handleFourFingerTap() {
            guard let canvas else { return }
            canvas.drawing = PKDrawing()
            onDrawingChanged(PKDrawing())
            UIImpactFeedbackGenerator(style: .heavy).impactOccurred()
        }

        @objc func handleEyedropper(_ g: UILongPressGestureRecognizer) {
            guard g.state == .began else { return }
            guard let canvas, let book else { return }

            let local = g.location(in: canvas)
            let logical = DrawingGeometry.spreadSize(ratio: book.pageAspectRatio)
            guard logical.width > 0, logical.height > 0 else { return }

            let nx = min(max(local.x / logical.width, 0), 0.999)
            let ny = min(max(local.y / logical.height, 0), 0.999)

            let spreads = SpreadLayout.spreads(for: book)
            guard spreads.indices.contains(spreadIndex) else { return }
            let spread = spreads[spreadIndex]

            let size = displaySize.width > 1
                ? displaySize
                : CGSize(width: logical.width, height: logical.height)

            if let picked = ColorSampler.sample(book: book,
                                                spread: spread,
                                                displaySize: size,
                                                drawing: canvas.drawing,
                                                atNormalized: CGPoint(x: nx, y: ny)) {
                onPickColor(picked)
                UIImpactFeedbackGenerator(style: .rigid).impactOccurred()
            }
        }
    }
}
