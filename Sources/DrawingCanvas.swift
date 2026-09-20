import SwiftUI
import PencilKit
import UIKit

struct DrawingCanvas: UIViewRepresentable {

    // 几何
    let canvasSize: CGSize              // 画布内容尺寸（逻辑跨页，固定）
    var viewportSize: CGSize? = nil     // 可见窗口尺寸。nil = 与画布同大
    var initialOffsetX: CGFloat = 0     // 初始横向偏移（单页模式用）
    let displaySize: CGSize             // 屏幕上占的点尺寸（吸色用）

    // 上下文
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
    var zoomInTrigger: Int = 0
    var zoomOutTrigger: Int = 0

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
    var onZoomChanged: (CGFloat) -> Void = { _ in }

    private var effectiveViewport: CGSize {
        let v = viewportSize ?? canvasSize
        return CGSize(width: max(v.width, 1), height: max(v.height, 1))
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(onDrawingChanged: onDrawingChanged,
                    onDrawingStateChanged: onDrawingStateChanged,
                    onPickColor: onPickColor,
                    onZoomChanged: onZoomChanged)
    }

    func makeUIView(context: Context) -> UIScrollView {
        let viewport = effectiveViewport

        let scroll = UIScrollView()
        scroll.frame = CGRect(origin: .zero, size: viewport)
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
        scroll.contentSize = canvasSize

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

        // 初始偏移（单页模式看右半页）
        let maxOffset = max(canvasSize.width - viewport.width, 0)
        let startX = min(max(initialOffsetX, 0), maxOffset)
        scroll.contentOffset = CGPoint(x: startX, y: 0)

        context.coordinator.scroll = scroll
        context.coordinator.canvas = canvas
        context.coordinator.lastToolSignature = toolSignature
        context.coordinator.lastInitialOffsetX = startX
        context.coordinator.initialOffsetX = startX

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

        let viewport = effectiveViewport

        context.coordinator.onDrawingChanged = onDrawingChanged
        context.coordinator.onDrawingStateChanged = onDrawingStateChanged
        context.coordinator.onPickColor = onPickColor
        context.coordinator.onZoomChanged = onZoomChanged
        context.coordinator.book = book
        context.coordinator.spreadIndex = spreadIndex
        context.coordinator.displaySize = displaySize

        // 视口尺寸变化（横竖屏切换）
        if scroll.bounds.size != viewport {
            scroll.frame = CGRect(origin: .zero, size: viewport)
            scroll.bounds = CGRect(origin: .zero, size: viewport)
        }

        if canvas.bounds.size != canvasSize {
            canvas.frame = CGRect(origin: .zero, size: canvasSize)
            canvas.bounds = CGRect(origin: .zero, size: canvasSize)
            scroll.contentSize = canvasSize
            scroll.setZoomScale(1, animated: false)
        }

        // 初始偏移变化（单页模式左右页切换）
        let maxOffset = max(canvasSize.width - viewport.width, 0)
        let wantedX = min(max(initialOffsetX, 0), maxOffset)
        if abs(context.coordinator.lastInitialOffsetX - wantedX) > 0.5 {
            context.coordinator.lastInitialOffsetX = wantedX
            scroll.setZoomScale(1, animated: false)
            scroll.contentOffset = CGPoint(x: wantedX, y: 0)
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
            scroll.setContentOffset(CGPoint(x: wantedX, y: 0), animated: true)
        }
        if context.coordinator.lastZoomInTrigger != zoomInTrigger {
            context.coordinator.lastZoomInTrigger = zoomInTrigger
            context.coordinator.zoom(by: 1.25)
        }
        if context.coordinator.lastZoomOutTrigger != zoomOutTrigger {
            context.coordinator.lastZoomOutTrigger = zoomOutTrigger
            context.coordinator.zoom(by: 0.8)
        }

        // 手势开关
        let on = gesturesEnabled
        context.coordinator.twoFingerTap?.isEnabled = on && twoFingerUndo
        context.coordinator.rapidUndoGesture?.isEnabled = on && twoFingerLongPressUndo
        context.coordinator.threeFingerTap?.isEnabled = on && threeFingerRedo
        context.coordinator.fourFingerTap?.isEnabled = on && fourFingerClear
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
        var onZoomChanged: (CGFloat) -> Void

        weak var scroll: UIScrollView?
        weak var canvas: PKCanvasView?

        var book: Book?
        var spreadIndex: Int = 0
        var displaySize: CGSize = .zero
        var initialOffsetX: CGFloat = 0

        var lastToolSignature: String = ""
        var lastUndoTrigger: Int = 0
        var lastRedoTrigger: Int = 0
        var lastClearTrigger: Int = 0
        var lastZoomResetTrigger: Int = 0
        var lastZoomInTrigger: Int = 0
        var lastZoomOutTrigger: Int = 0
        var lastInitialOffsetX: CGFloat = -1

        weak var twoFingerTap: UITapGestureRecognizer?
        weak var rapidUndoGesture: UILongPressGestureRecognizer?
        weak var threeFingerTap: UITapGestureRecognizer?
        weak var fourFingerTap: UITapGestureRecognizer?
        weak var eyedropperGesture: UILongPressGestureRecognizer?

        private var rapidUndoTimer: Timer?

        init(onDrawingChanged: @escaping (PKDrawing) -> Void,
             onDrawingStateChanged: @escaping (Bool) -> Void,
             onPickColor: @escaping (Color) -> Void,
             onZoomChanged: @escaping (CGFloat) -> Void) {
            self.onDrawingChanged = onDrawingChanged
            self.onDrawingStateChanged = onDrawingStateChanged
            self.onPickColor = onPickColor
            self.onZoomChanged = onZoomChanged
        }

        deinit {
            rapidUndoTimer?.invalidate()
        }

        // MARK: 缩放

        func viewForZooming(in scrollView: UIScrollView) -> UIView? {
            canvas
        }

        /// 以视口中心为锚点精确缩放
        func zoom(by factor: CGFloat) {
            guard let scroll else { return }
            let target = min(max(scroll.zoomScale * factor, scroll.minimumZoomScale),
                             scroll.maximumZoomScale)
            guard abs(target - scroll.zoomScale) > 0.001 else { return }
            scroll.setZoomScale(target, animated: true)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.28) { [weak self] in
                guard let self, let scroll = self.scroll else { return }
                self.onZoomChanged(scroll.zoomScale)
            }
        }

        func scrollViewDidZoom(_ scrollView: UIScrollView) {
            onZoomChanged(scrollView.zoomScale)
        }

        func scrollViewDidEndZooming(_ scrollView: UIScrollView,
                                     with view: UIView?,
                                     atScale scale: CGFloat) {
            // 接近 1× 就吸附回去，避免留下 1.03× 这种尴尬倍率
            if abs(scale - 1) < 0.06, scale != 1 {
                scrollView.setZoomScale(1, animated: true)
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.28) { [weak self] in
                    guard let self, let scroll = self.scroll else { return }
                    self.onZoomChanged(scroll.zoomScale)
                }
            } else {
                onZoomChanged(scrollView.zoomScale)
            }
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
            guard let canvas, let book, let scroll else { return }

            // location 在画布坐标系里；画布原点可能被 contentOffset 偏移，
            // 但 location(in:) 已自动处理过，所以直接用。
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
            _ = scroll
        }
    }
}
