import SwiftUI
import PencilKit
import UIKit

struct DrawingCanvas: UIViewRepresentable {

    // 几何
    /// 画布内容尺寸（逻辑跨页，固定）
    let canvasSize: CGSize
    /// 屏幕上实际占的尺寸（点）。UIScrollView 的 frame 就是它。
    let viewportSize: CGSize
    /// 初始横向偏移，单位是「逻辑坐标」
    var initialOffsetX: CGFloat = 0
    /// 屏幕上跨页占的点尺寸（吸色用）
    let displaySize: CGSize

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

    /// 「100%」对应的 zoomScale
    private var fitScale: CGFloat {
        guard canvasSize.height > 0, viewportSize.height > 0 else { return 1 }
        let raw = viewportSize.height / canvasSize.height
        guard raw.isFinite, raw > 0 else { return 1 }
        return min(max(raw, 0.02), 6)
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(onDrawingChanged: onDrawingChanged,
                    onDrawingStateChanged: onDrawingStateChanged,
                    onPickColor: onPickColor,
                    onZoomChanged: onZoomChanged)
    }

    func makeUIView(context: Context) -> UIScrollView {
        let fit = fitScale

        let scroll = UIScrollView()
        scroll.frame = CGRect(origin: .zero, size: viewportSize)
        scroll.backgroundColor = .clear
        scroll.isOpaque = false
        scroll.contentInsetAdjustmentBehavior = .never
        scroll.bounces = false
        scroll.bouncesZoom = false
        scroll.showsHorizontalScrollIndicator = false
        scroll.showsVerticalScrollIndicator = false
        scroll.delegate = context.coordinator

        // 缩放范围：fit = 100%
        scroll.minimumZoomScale = fit
        scroll.maximumZoomScale = fit * 6
        scroll.setZoomScale(fit, animated: false)

        // ⚠️⚠️ 关键：把系统自带的 pinch / pan 全部关掉。
        //
        // 系统自带的这两个手势，delegate 在 UIKit 内部是私有对象：
        //   · 给它设自定义 delegate → 立刻抛异常 → 闪退（之前那个崩溃）
        //   · 不设 delegate       → 它争不过 PKCanvasView 的画图手势 → 双指完全没反应
        //
        // 两条路都是死的，所以干脆不用它们，下面自己造两个。
        scroll.pinchGestureRecognizer?.isEnabled = false
        scroll.panGestureRecognizer.isEnabled = false

        let canvas = PKCanvasView()
        canvas.frame = CGRect(origin: .zero, size: canvasSize)
        canvas.bounds = CGRect(origin: .zero, size: canvasSize)
        canvas.backgroundColor = .clear
        canvas.isOpaque = false
        canvas.drawing = initialDrawing
        canvas.tool = tool
        canvas.drawingPolicy = pencilOnly ? .pencilOnly : .anyInput

        // 画布自身的滚动 / 缩放全部关掉，避免和外层抢
        canvas.isScrollEnabled = false
        canvas.minimumZoomScale = 1
        canvas.maximumZoomScale = 1
        canvas.alwaysBounceVertical = false
        canvas.alwaysBounceHorizontal = false
        canvas.pinchGestureRecognizer?.isEnabled = false
        canvas.panGestureRecognizer.isEnabled = false

        canvas.delegate = context.coordinator

        scroll.addSubview(canvas)
        scroll.contentSize = canvasSize

        context.coordinator.scroll = scroll
        context.coordinator.canvas = canvas
        context.coordinator.lastToolSignature = toolSignature

        applyInitialOffset(scroll, fit: fit, animated: false, in: context.coordinator)

        // MARK: 双指捏合 → 缩放（自己造的手势，可以安全设 delegate）
        let pinch = UIPinchGestureRecognizer(
            target: context.coordinator,
            action: #selector(Coordinator.handlePinch(_:))
        )
        pinch.delegate = context.coordinator
        pinch.cancelsTouchesInView = false
        pinch.delaysTouchesBegan = false
        scroll.addGestureRecognizer(pinch)
        context.coordinator.customPinch = pinch

        // MARK: 双指拖动 → 平移（同样自己造）
        let twoPan = UIPanGestureRecognizer(
            target: context.coordinator,
            action: #selector(Coordinator.handleTwoFingerPan(_:))
        )
        twoPan.minimumNumberOfTouches = 2
        twoPan.maximumNumberOfTouches = 2
        twoPan.delegate = context.coordinator
        twoPan.cancelsTouchesInView = false
        twoPan.delaysTouchesBegan = false
        scroll.addGestureRecognizer(twoPan)
        context.coordinator.twoFingerPan = twoPan

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
        rapidUndo.allowableMovement = 60
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

        let fit = fitScale

        context.coordinator.onDrawingChanged = onDrawingChanged
        context.coordinator.onDrawingStateChanged = onDrawingStateChanged
        context.coordinator.onPickColor = onPickColor
        context.coordinator.onZoomChanged = onZoomChanged
        context.coordinator.book = book
        context.coordinator.spreadIndex = spreadIndex
        context.coordinator.displaySize = displaySize

        // 视口尺寸变化（横竖屏 / 单双页切换 / 进入编辑模式时内边距变化）
        if scroll.bounds.size != viewportSize {
            scroll.frame = CGRect(origin: .zero, size: viewportSize)
            scroll.bounds = CGRect(origin: .zero, size: viewportSize)
            scroll.minimumZoomScale = fit
            scroll.maximumZoomScale = fit * 6
            scroll.setZoomScale(fit, animated: false)
            applyInitialOffset(scroll, fit: fit, animated: false, in: context.coordinator)
            context.coordinator.publishZoom(1, force: true)
        }

        if canvas.bounds.size != canvasSize {
            canvas.frame = CGRect(origin: .zero, size: canvasSize)
            canvas.bounds = CGRect(origin: .zero, size: canvasSize)
            scroll.contentSize = canvasSize
        }

        // 初始偏移变化（单页模式左右页切换）
        let wantedOffset = clampedOffset(fit: scroll.zoomScale)
        if abs(context.coordinator.lastAppliedOffsetX - wantedOffset) > 0.5 {
            scroll.setZoomScale(fit, animated: false)
            scroll.contentOffset = CGPoint(x: wantedOffset, y: 0)
            context.coordinator.lastAppliedOffsetX = wantedOffset
            context.coordinator.publishZoom(1, force: true)
        }

        let policy: PKCanvasViewDrawingPolicy = pencilOnly ? .pencilOnly : .anyInput
        if canvas.drawingPolicy != policy {
            canvas.drawingPolicy = policy
        }

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
            DispatchQueue.main.async {
                onDrawingChanged(PKDrawing())
            }
        }
        if context.coordinator.lastZoomResetTrigger != zoomResetTrigger {
            context.coordinator.lastZoomResetTrigger = zoomResetTrigger
            scroll.setZoomScale(fit, animated: false)
            scroll.contentOffset = CGPoint(x: clampedOffset(fit: fit), y: 0)
            context.coordinator.publishZoom(1, force: true)
        }
        if context.coordinator.lastZoomInTrigger != zoomInTrigger {
            context.coordinator.lastZoomInTrigger = zoomInTrigger
            context.coordinator.zoom(by: 1.3)
        }
        if context.coordinator.lastZoomOutTrigger != zoomOutTrigger {
            context.coordinator.lastZoomOutTrigger = zoomOutTrigger
            context.coordinator.zoom(by: 1 / 1.3)
        }

        let on = gesturesEnabled
        context.coordinator.twoFingerTap?.isEnabled = on && twoFingerUndo
        context.coordinator.rapidUndoGesture?.isEnabled = on && twoFingerLongPressUndo
        context.coordinator.threeFingerTap?.isEnabled = on && threeFingerRedo
        context.coordinator.fourFingerTap?.isEnabled = on && fourFingerClear
        context.coordinator.eyedropperGesture?.isEnabled =
            on && longPressEyedropper && pencilOnly

        // 缩放 / 平移是基础能力，永远开启，不受手势总开关影响
        context.coordinator.customPinch?.isEnabled = true
        context.coordinator.twoFingerPan?.isEnabled = true
    }

    // MARK: - 偏移换算

    /// initialOffsetX 是逻辑坐标；这里换算成当前 zoomScale 下的 contentOffset.x
    private func clampedOffset(fit: CGFloat) -> CGFloat {
        let z = max(fit, 0.0001)
        let wanted = initialOffsetX * z
        let maxOffset = max(canvasSize.width * z - viewportSize.width, 0)
        return min(max(wanted, 0), maxOffset)
    }

    private func applyInitialOffset(_ scroll: UIScrollView,
                                    fit: CGFloat,
                                    animated: Bool,
                                    in coordinator: Coordinator) {
        let x = clampedOffset(fit: fit)
        if animated {
            scroll.setContentOffset(CGPoint(x: x, y: 0), animated: true)
        } else {
            scroll.contentOffset = CGPoint(x: x, y: 0)
        }
        coordinator.lastAppliedOffsetX = x
        coordinator.initialOffsetX = initialOffsetX
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
        var lastAppliedOffsetX: CGFloat = -1

        weak var customPinch: UIPinchGestureRecognizer?
        weak var twoFingerPan: UIPanGestureRecognizer?
        weak var twoFingerTap: UITapGestureRecognizer?
        weak var rapidUndoGesture: UILongPressGestureRecognizer?
        weak var threeFingerTap: UITapGestureRecognizer?
        weak var fourFingerTap: UITapGestureRecognizer?
        weak var eyedropperGesture: UILongPressGestureRecognizer?

        private var rapidUndoTimer: Timer?
        private var pinchStartScale: CGFloat = 1
        private var panStartOffset: CGPoint = .zero
        private var canvasInteractionSuspended = false

        /// 上一次已经回传给 SwiftUI 的缩放倍率（去重用）
        private var lastReportedRatio: CGFloat = -1

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

        func scrollViewDidZoom(_ scrollView: UIScrollView) {
            reportZoom(scrollView)
        }

        func scrollViewDidEndZooming(_ scrollView: UIScrollView,
                                     with view: UIView?,
                                     atScale scale: CGFloat) {
            let fit = scrollView.minimumZoomScale
            let ratio = fit > 0 ? scale / fit : 1

            // 接近 100% 就吸回去
            if abs(ratio - 1) < 0.06, ratio != 1 {
                scrollView.setZoomScale(fit, animated: true)
            }
            reportZoom(scrollView)
        }

        /// 读取缩放倍率 → 数值保护 → 排队到下一个 runloop 再回传 SwiftUI。
        private func reportZoom(_ scrollView: UIScrollView) {
            let fit = scrollView.minimumZoomScale
            guard fit > 0, fit.isFinite else { return }

            var ratio = scrollView.zoomScale / fit
            guard ratio.isFinite else { return }
            ratio = min(max(ratio, 0.02), 12)

            publishZoom(ratio)
        }

        /// 统一出口：所有缩放倍率都从这里出去，保证在 SwiftUI 更新事务之外送达。
        func publishZoom(_ ratio: CGFloat, force: Bool = false) {
            guard ratio.isFinite else { return }
            if !force {
                guard abs(ratio - lastReportedRatio) > 0.004 else { return }
            }
            lastReportedRatio = ratio

            DispatchQueue.main.async { [weak self] in
                self?.onZoomChanged(ratio)
            }
        }

        /// 以当前缩放为基准精确缩放（± 按钮用）
        func zoom(by factor: CGFloat) {
            guard let scroll else { return }
            let target = min(max(scroll.zoomScale * factor,
                                 scroll.minimumZoomScale),
                             scroll.maximumZoomScale)
            guard target.isFinite,
                  abs(target - scroll.zoomScale) > 0.0001 else { return }
            scroll.setZoomScale(target, animated: true)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
                guard let self, let s = self.scroll else { return }
                self.reportZoom(s)
            }
        }

        // MARK: 双指捏合（自己造的手势）

        @objc func handlePinch(_ g: UIPinchGestureRecognizer) {
            guard let scroll, let canvas else { return }

            switch g.state {
            case .began:
                pinchStartScale = scroll.zoomScale
                suspendCanvasInteraction(true)
                UIImpactFeedbackGenerator(style: .light).impactOccurred()

            case .changed:
                let minS = scroll.minimumZoomScale
                let maxS = scroll.maximumZoomScale
                let target = pinchStartScale * g.scale
                guard target.isFinite else { return }
                let clamped = min(max(target, minS), maxS)
                scroll.setZoomScale(clamped, animated: false)
                canvas.bounds.size = canvasSizeOf(canvas)

            case .ended, .cancelled, .failed:
                suspendCanvasInteraction(false)
                if let s = self.scroll { reportZoom(s) }

            default:
                break
            }
        }

        // MARK: 双指拖动（自己造的手势）

        @objc func handleTwoFingerPan(_ g: UIPanGestureRecognizer) {
            guard let scroll, let canvas else { return }

            switch g.state {
            case .began:
                panStartOffset = scroll.contentOffset
                suspendCanvasInteraction(true)

            case .changed:
                let t = g.translation(in: scroll)
                guard t.x.isFinite, t.y.isFinite else { return }

                let scale = scroll.zoomScale
                let contentW = canvas.bounds.width * scale
                let contentH = canvas.bounds.height * scale
                let maxX = max(contentW - scroll.bounds.width, 0)
                let maxY = max(contentH - scroll.bounds.height, 0)

                let x = min(max(panStartOffset.x - t.x, 0), maxX)
                let y = min(max(panStartOffset.y - t.y, 0), maxY)
                scroll.contentOffset = CGPoint(x: x, y: y)

            case .ended, .cancelled, .failed:
                suspendCanvasInteraction(false)

            default:
                break
            }
        }

        /// 捏合 / 平移进行中时，暂时挂起画布自身的触摸，
        /// 避免「两指按下去，第一根手指在纸上留下一道线」。
        private func suspendCanvasInteraction(_ suspend: Bool) {
            guard let canvas else { return }
            guard canvasInteractionSuspended != suspend else { return }
            canvasInteractionSuspended = suspend
            canvas.isUserInteractionEnabled = !suspend
        }

        private func canvasSizeOf(_ canvas: PKCanvasView) -> CGSize {
            canvas.bounds.size
        }

        // MARK: 手势优先级

        func gestureRecognizer(_ g: UIGestureRecognizer,
                               shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool {
            // ⚠️ 必须是 true。
            // PKCanvasView 的画图手势会争夺所有触摸，只有明确声明「可以同时识别」，
            // 我们自己造的捏合 / 双指拖动才能在画布上方正常工作。
            true
        }

        func gestureRecognizer(_ g: UIGestureRecognizer,
                               shouldRequireFailureOf other: UIGestureRecognizer) -> Bool {
            false
        }

        func gestureRecognizer(_ g: UIGestureRecognizer,
                               shouldBeRequiredToFailBy other: UIGestureRecognizer) -> Bool {
            false
        }

        // MARK: PKCanvasView

        func canvasViewDrawingDidChange(_ canvasView: PKCanvasView) {
            let drawing = canvasView.drawing
            DispatchQueue.main.async { [weak self] in
                self?.onDrawingChanged(drawing)
            }
        }

        func canvasViewDidBeginUsingTool(_ canvasView: PKCanvasView) {
            onDrawingStateChanged(true)
        }

        func canvasViewDidEndUsingTool(_ canvasView: PKCanvasView) {
            onDrawingStateChanged(false)
        }

        // MARK: 手势动作

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
            DispatchQueue.main.async { [weak self] in
                self?.onDrawingChanged(PKDrawing())
            }
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
                DispatchQueue.main.async { [weak self] in
                    self?.onPickColor(picked)
                }
                UIImpactFeedbackGenerator(style: .rigid).impactOccurred()
            }
        }
    }
}
