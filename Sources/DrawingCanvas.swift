import SwiftUI
import PencilKit
import UIKit

struct DrawingCanvas: UIViewRepresentable {

    // 几何
    let canvasSize: CGSize
    let viewportSize: CGSize
    var initialOffsetX: CGFloat = 0
    let displaySize: CGSize

    /// 纸张位图（白纸 + 左右页图片）
    var paperImage: UIImage? = nil

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

    // 翻页（编辑界面已停用）
    var pagePanEnabled: Bool = false
    var pageTapEnabled: Bool = false
    var onPagePanChanged: (CGFloat) -> Void = { _ in }
    var onPagePanEnded: (CGFloat, CGFloat) -> Void = { _, _ in }
    var onPageTap: (CGFloat) -> Void = { _ in }

    // 回调
    let onDrawingChanged: (PKDrawing) -> Void
    let onDrawingStateChanged: (Bool) -> Void
    let onPickColor: (Color) -> Void
    var onZoomChanged: (CGFloat) -> Void = { _ in }

    static let fingerOnly: [NSNumber] = [
        NSNumber(value: UITouch.TouchType.direct.rawValue)
    ]

    static let maxFingerRadius: CGFloat = 24

    /// 双指按住超过这么久，就把撤回类手势全禁掉
    static let twoFingerHoldThreshold: TimeInterval = 0.3

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

        scroll.isScrollEnabled = false
        scroll.bounces = false
        scroll.bouncesZoom = false
        scroll.showsHorizontalScrollIndicator = false
        scroll.showsVerticalScrollIndicator = false
        scroll.delegate = context.coordinator

        scroll.panGestureRecognizer.isEnabled = false
        scroll.panGestureRecognizer.allowedTouchTypes = Self.fingerOnly
        scroll.pinchGestureRecognizer?.isEnabled = false
        scroll.pinchGestureRecognizer?.allowedTouchTypes = Self.fingerOnly

        scroll.minimumZoomScale = fit
        scroll.maximumZoomScale = fit * 6
        scroll.setZoomScale(fit, animated: false)

        let container = UIView(frame: CGRect(origin: .zero, size: canvasSize))
        container.backgroundColor = .clear
        container.clipsToBounds = true

        if let paperImage {
            let paper = UIImageView(image: paperImage)
            paper.frame = CGRect(origin: .zero, size: canvasSize)
            paper.contentMode = .scaleToFill
            paper.isUserInteractionEnabled = false
            container.addSubview(paper)
            context.coordinator.paperView = paper
        }

        let canvas = PKCanvasView()
        canvas.frame = CGRect(origin: .zero, size: canvasSize)
        canvas.bounds = CGRect(origin: .zero, size: canvasSize)
        canvas.backgroundColor = .clear
        canvas.isOpaque = false
        canvas.overrideUserInterfaceStyle = .light

        canvas.drawing = initialDrawing
        canvas.tool = tool
        canvas.drawingPolicy = pencilOnly ? .pencilOnly : .anyInput

        canvas.isScrollEnabled = false
        canvas.minimumZoomScale = 1
        canvas.maximumZoomScale = 1
        canvas.alwaysBounceVertical = false
        canvas.alwaysBounceHorizontal = false
        canvas.panGestureRecognizer.isEnabled = false
        canvas.panGestureRecognizer.allowedTouchTypes = Self.fingerOnly
        canvas.pinchGestureRecognizer?.isEnabled = false
        canvas.pinchGestureRecognizer?.allowedTouchTypes = Self.fingerOnly

        canvas.delegate = context.coordinator
        canvas.drawingGestureRecognizer.delegate = context.coordinator

        container.addSubview(canvas)

        scroll.addSubview(container)
        scroll.contentSize = canvasSize

        context.coordinator.scroll = scroll
        context.coordinator.canvas = canvas
        context.coordinator.container = container
        context.coordinator.pencilOnly = pencilOnly
        context.coordinator.lastToolSignature = toolSignature
        context.coordinator.initialOffsetX = initialOffsetX
        context.coordinator.lastInitialOffsetX = initialOffsetX

        applyInitialOffset(scroll, fit: fit, animated: false, in: context.coordinator)

        // MARK: 双指「接触探针」
        // ⚠️ 这是这次的关键：只要两根手指碰到屏幕（还没移动），
        //    就立刻让画布的绘制手势让开 —— 不等捏合被识别，
        //    否则切了笔之后，绘制手势会抢先把触摸吃掉，缩放就没了。
        let probe = UILongPressGestureRecognizer(
            target: context.coordinator,
            action: #selector(Coordinator.handleTwoFingerProbe(_:))
        )
        probe.numberOfTouchesRequired = 2
        probe.minimumPressDuration = 0
        probe.allowableMovement = .greatestFiniteMagnitude
        probe.cancelsTouchesInView = false
        probe.delegate = context.coordinator
        probe.allowedTouchTypes = Self.fingerOnly
        scroll.addGestureRecognizer(probe)
        context.coordinator.twoFingerProbe = probe

        // MARK: 双指捏合 → 缩放
        let pinch = UIPinchGestureRecognizer(
            target: context.coordinator,
            action: #selector(Coordinator.handlePinch(_:))
        )
        pinch.delegate = context.coordinator
        pinch.cancelsTouchesInView = false
        pinch.delaysTouchesBegan = false
        pinch.allowedTouchTypes = Self.fingerOnly
        scroll.addGestureRecognizer(pinch)
        context.coordinator.customPinch = pinch

        // MARK: 双指拖动 → 平移
        let twoPan = UIPanGestureRecognizer(
            target: context.coordinator,
            action: #selector(Coordinator.handleTwoFingerPan(_:))
        )
        twoPan.minimumNumberOfTouches = 2
        twoPan.maximumNumberOfTouches = 2
        twoPan.delegate = context.coordinator
        twoPan.cancelsTouchesInView = false
        twoPan.delaysTouchesBegan = false
        twoPan.allowedTouchTypes = Self.fingerOnly
        scroll.addGestureRecognizer(twoPan)
        context.coordinator.twoFingerPan = twoPan

        // MARK: 单指拖动 → 翻页（编辑界面已停用）
        let pagePan = UIPanGestureRecognizer(
            target: context.coordinator,
            action: #selector(Coordinator.handlePagePan(_:))
        )
        pagePan.minimumNumberOfTouches = 1
        pagePan.maximumNumberOfTouches = 1
        pagePan.delegate = context.coordinator
        pagePan.cancelsTouchesInView = false
        pagePan.delaysTouchesBegan = false
        pagePan.allowedTouchTypes = Self.fingerOnly
        pagePan.isEnabled = false
        scroll.addGestureRecognizer(pagePan)
        context.coordinator.pagePan = pagePan

        // MARK: 单指点击 → 边缘翻页（编辑界面已停用）
        let pageTap = UITapGestureRecognizer(
            target: context.coordinator,
            action: #selector(Coordinator.handlePageTap(_:))
        )
        pageTap.numberOfTapsRequired = 1
        pageTap.numberOfTouchesRequired = 1
        pageTap.cancelsTouchesInView = false
        pageTap.delegate = context.coordinator
        pageTap.allowedTouchTypes = Self.fingerOnly
        pageTap.isEnabled = false
        scroll.addGestureRecognizer(pageTap)
        context.coordinator.pageTap = pageTap

        // MARK: 双指轻点 → 撤销
        let twoTap = UITapGestureRecognizer(
            target: context.coordinator,
            action: #selector(Coordinator.handleTwoFingerTap)
        )
        twoTap.numberOfTapsRequired = 1
        twoTap.numberOfTouchesRequired = 2
        twoTap.cancelsTouchesInView = false
        twoTap.delegate = context.coordinator
        twoTap.allowedTouchTypes = Self.fingerOnly
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
        rapidUndo.allowedTouchTypes = Self.fingerOnly
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
        threeTap.allowedTouchTypes = Self.fingerOnly
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
        fourTap.allowedTouchTypes = Self.fingerOnly
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
        eyedropper.allowedTouchTypes = Self.fingerOnly
        scroll.addGestureRecognizer(eyedropper)
        context.coordinator.eyedropperGesture = eyedropper

        return scroll
    }

    func updateUIView(_ scroll: UIScrollView, context: Context) {
        guard let canvas = context.coordinator.canvas else { return }

        let fit = fitScale

        scroll.isScrollEnabled = false
        scroll.panGestureRecognizer.isEnabled = false
        scroll.pinchGestureRecognizer?.isEnabled = false
        canvas.isScrollEnabled = false
        canvas.panGestureRecognizer.isEnabled = false
        canvas.pinchGestureRecognizer?.isEnabled = false

        context.coordinator.onDrawingChanged = onDrawingChanged
        context.coordinator.onDrawingStateChanged = onDrawingStateChanged
        context.coordinator.onPickColor = onPickColor
        context.coordinator.onZoomChanged = onZoomChanged
        context.coordinator.book = book
        context.coordinator.spreadIndex = spreadIndex
        context.coordinator.displaySize = displaySize
        context.coordinator.pencilOnly = pencilOnly
        context.coordinator.onPagePanChanged = onPagePanChanged
        context.coordinator.onPagePanEnded = onPagePanEnded
        context.coordinator.onPageTap = onPageTap
        context.coordinator.pagePanWanted = pagePanEnabled
        context.coordinator.pageTapWanted = pageTapEnabled

        // 记下设置，供双指结束后按原样恢复
        context.coordinator.switches.gesturesEnabled = gesturesEnabled
        context.coordinator.switches.twoFingerUndo = twoFingerUndo
        context.coordinator.switches.twoFingerLongPressUndo = twoFingerLongPressUndo
        context.coordinator.switches.threeFingerRedo = threeFingerRedo
        context.coordinator.switches.fourFingerClear = fourFingerClear
        context.coordinator.switches.longPressEyedropper = longPressEyedropper
        context.coordinator.switches.pencilOnly = pencilOnly

        if let paper = context.coordinator.paperView {
            if paper.image !== paperImage {
                paper.image = paperImage
            }
        }

        let viewportChanged =
            abs(scroll.bounds.width - viewportSize.width) > 0.5 ||
            abs(scroll.bounds.height - viewportSize.height) > 0.5

        if viewportChanged {
            scroll.frame = CGRect(origin: .zero, size: viewportSize)
            scroll.bounds = CGRect(origin: .zero, size: viewportSize)
            scroll.minimumZoomScale = fit
            scroll.maximumZoomScale = fit * 6
            scroll.setZoomScale(fit, animated: false)
            scroll.contentOffset = CGPoint(x: clampedOffset(fit: fit), y: 0)
            context.coordinator.lastAppliedOffsetX = scroll.contentOffset.x
            context.coordinator.lastInitialOffsetX = initialOffsetX
            context.coordinator.publishZoom(1, force: true)
        }

        if abs(canvas.bounds.width - canvasSize.width) > 0.5 ||
           abs(canvas.bounds.height - canvasSize.height) > 0.5 {
            canvas.frame = CGRect(origin: .zero, size: canvasSize)
            canvas.bounds = CGRect(origin: .zero, size: canvasSize)
            scroll.contentSize = canvasSize
        }

        if let container = context.coordinator.container,
           abs(container.bounds.width - canvasSize.width) > 0.5 ||
           abs(container.bounds.height - canvasSize.height) > 0.5 {
            container.frame = CGRect(origin: .zero, size: canvasSize)
            container.bounds = CGRect(origin: .zero, size: canvasSize)
            context.coordinator.paperView?.frame = CGRect(origin: .zero,
                                                          size: canvasSize)
            scroll.contentSize = canvasSize
        }

        if abs(context.coordinator.lastInitialOffsetX - initialOffsetX) > 0.5 {
            context.coordinator.lastInitialOffsetX = initialOffsetX

            let z = scroll.zoomScale
            let maxOffset = max(canvasSize.width * z - viewportSize.width, 0)
            let x = min(max(initialOffsetX * z, 0), maxOffset)
            scroll.contentOffset = CGPoint(x: x, y: 0)
            context.coordinator.lastAppliedOffsetX = x
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

        context.coordinator.customPinch?.isEnabled = true
        context.coordinator.twoFingerPan?.isEnabled = true
        context.coordinator.twoFingerProbe?.isEnabled = true

        context.coordinator.syncPageGestures()
        context.coordinator.applyGestureSwitches()

        // 兜底：既没在缩放/平移，也没有双指按着 → 绘制手势必须是开着的
        if !context.coordinator.isTransforming,
           !context.coordinator.twoFingerTouching {
            context.coordinator.forceEnableDrawing()
        }
    }

    // MARK: - 偏移换算

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

        struct GestureSwitches {
            var gesturesEnabled = true
            var twoFingerUndo = true
            var twoFingerLongPressUndo = true
            var threeFingerRedo = true
            var fourFingerClear = true
            var longPressEyedropper = true
            var pencilOnly = false
        }

        var switches = GestureSwitches()

        var onDrawingChanged: (PKDrawing) -> Void
        var onDrawingStateChanged: (Bool) -> Void
        var onPickColor: (Color) -> Void
        var onZoomChanged: (CGFloat) -> Void

        var onPagePanChanged: (CGFloat) -> Void = { _ in }
        var onPagePanEnded: (CGFloat, CGFloat) -> Void = { _, _ in }
        var onPageTap: (CGFloat) -> Void = { _ in }

        weak var scroll: UIScrollView?
        weak var canvas: PKCanvasView?
        weak var container: UIView?
        weak var paperView: UIImageView?

        var book: Book?
        var spreadIndex: Int = 0
        var displaySize: CGSize = .zero
        var initialOffsetX: CGFloat = 0
        var pencilOnly: Bool = false

        /// 屏幕上是否有两根手指按着（还没抬）
        private(set) var twoFingerTouching: Bool = false
        /// 双指按住是否已经超过阈值
        private(set) var twoFingerHeldLong: Bool = false
        private(set) var isTransforming: Bool = false

        var pagePanWanted: Bool = false
        var pageTapWanted: Bool = false

        var lastToolSignature: String = ""
        var lastUndoTrigger: Int = 0
        var lastRedoTrigger: Int = 0
        var lastClearTrigger: Int = 0
        var lastZoomResetTrigger: Int = 0
        var lastZoomInTrigger: Int = 0
        var lastZoomOutTrigger: Int = 0
        var lastAppliedOffsetX: CGFloat = -1
        var lastInitialOffsetX: CGFloat = -1

        weak var twoFingerProbe: UILongPressGestureRecognizer?
        weak var customPinch: UIPinchGestureRecognizer?
        weak var twoFingerPan: UIPanGestureRecognizer?
        weak var pagePan: UIPanGestureRecognizer?
        weak var pageTap: UITapGestureRecognizer?
        weak var twoFingerTap: UITapGestureRecognizer?
        weak var rapidUndoGesture: UILongPressGestureRecognizer?
        weak var threeFingerTap: UITapGestureRecognizer?
        weak var fourFingerTap: UITapGestureRecognizer?
        weak var eyedropperGesture: UILongPressGestureRecognizer?

        private var rapidUndoTimer: Timer?
        private var twoFingerHoldTimer: Timer?
        private var pinchStartScale: CGFloat = 1
        private var panStartOffset: CGPoint = .zero

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
            twoFingerHoldTimer?.invalidate()
        }

        func syncPageGestures() {
            pagePan?.isEnabled = false
            pageTap?.isEnabled = false
        }

        // MARK: 手势总开关
        //
        // 双指按着（超过阈值）或正在缩放/平移 → 除双指手势本身，全部停用。

        func applyGestureSwitches() {
            let on = switches.gesturesEnabled
                && !isTransforming
                && !twoFingerHeldLong

            twoFingerTap?.isEnabled = on && switches.twoFingerUndo
            rapidUndoGesture?.isEnabled = on && switches.twoFingerLongPressUndo
            threeFingerTap?.isEnabled = on && switches.threeFingerRedo
            fourFingerTap?.isEnabled = on && switches.fourFingerClear
            eyedropperGesture?.isEnabled =
                on && switches.longPressEyedropper && switches.pencilOnly
        }

        // MARK: 双指「接触探针」
        //
        // 两根手指一碰到屏幕：
        //   1. 立刻让画布的绘制手势让开（不等捏合被识别），
        //      否则切笔之后它会把触摸抢走，缩放就失效了；
        //   2. 开始计时，按住超过 0.3 秒就把撤回 / 重做 / 清空全禁掉，
        //      这样双指缩放时按多久都不会误撤图；
        //      想撤回就快速轻点一下（0.3 秒内）。

        @objc func handleTwoFingerProbe(_ g: UILongPressGestureRecognizer) {
            switch g.state {
            case .began:
                twoFingerTouching = true

                if let canvas {
                    let s = canvas.drawingGestureRecognizer.state
                    if s != .began && s != .changed {
                        canvas.drawingGestureRecognizer.isEnabled = false
                    }
                }

                twoFingerHoldTimer?.invalidate()
                twoFingerHoldTimer = Timer.scheduledTimer(
                    withTimeInterval: DrawingCanvas.twoFingerHoldThreshold,
                    repeats: false
                ) { [weak self] _ in
                    guard let self else { return }
                    self.twoFingerHeldLong = true
                    self.applyGestureSwitches()
                }

                applyGestureSwitches()

            case .ended, .cancelled, .failed:
                twoFingerTouching = false
                twoFingerHeldLong = false
                twoFingerHoldTimer?.invalidate()
                twoFingerHoldTimer = nil

                canvas?.drawingGestureRecognizer.isEnabled = true
                applyGestureSwitches()

            default:
                break
            }
        }

        func forceEnableDrawing() {
            guard let canvas else { return }
            if !canvas.drawingGestureRecognizer.isEnabled {
                canvas.drawingGestureRecognizer.isEnabled = true
            }
        }

        // MARK: 触摸过滤

        func gestureRecognizer(_ g: UIGestureRecognizer,
                               shouldReceive touch: UITouch) -> Bool {
            if let canvas, g === canvas.drawingGestureRecognizer {
                return true
            }

            if touch.type != .direct { return false }

            if g is UIPanGestureRecognizer || g is UIPinchGestureRecognizer {
                if touch.majorRadius > DrawingCanvas.maxFingerRadius { return false }
            }

            return true
        }

        // MARK: 缩放

        func viewForZooming(in scrollView: UIScrollView) -> UIView? {
            container ?? canvas
        }

        func scrollViewDidZoom(_ scrollView: UIScrollView) {
            reportZoom(scrollView)
        }

        func scrollViewDidEndZooming(_ scrollView: UIScrollView,
                                     with view: UIView?,
                                     atScale scale: CGFloat) {
            reportZoom(scrollView)
        }

        private func reportZoom(_ scrollView: UIScrollView) {
            let fit = scrollView.minimumZoomScale
            guard fit > 0, fit.isFinite else { return }

            var ratio = scrollView.zoomScale / fit
            guard ratio.isFinite else { return }
            ratio = min(max(ratio, 0.02), 12)

            publishZoom(ratio)
        }

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

        // MARK: 双指捏合

        @objc func handlePinch(_ g: UIPinchGestureRecognizer) {
            guard let scroll else { return }

            switch g.state {
            case .began:
                pinchStartScale = scroll.zoomScale
                isTransforming = true
                applyGestureSwitches()

            case .changed:
                let minS = scroll.minimumZoomScale
                let maxS = scroll.maximumZoomScale
                let target = pinchStartScale * g.scale
                guard target.isFinite else { return }
                let clamped = min(max(target, minS), maxS)
                scroll.setZoomScale(clamped, animated: false)

            case .ended, .cancelled, .failed:
                isTransforming = false
                canvas?.drawingGestureRecognizer.isEnabled = true
                applyGestureSwitches()
                if let s = self.scroll { reportZoom(s) }

            default:
                break
            }
        }

        // MARK: 双指拖动

        @objc func handleTwoFingerPan(_ g: UIPanGestureRecognizer) {
            guard let scroll, let canvas else { return }

            switch g.state {
            case .began:
                panStartOffset = scroll.contentOffset
                isTransforming = true
                applyGestureSwitches()

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
                isTransforming = false
                canvas.drawingGestureRecognizer.isEnabled = true
                applyGestureSwitches()

            default:
                break
            }
        }

        // MARK: 手指翻页（编辑界面已停用）

        @objc func handlePagePan(_ g: UIPanGestureRecognizer) {
            guard let scroll else { return }

            switch g.state {
            case .changed:
                onPagePanChanged(g.translation(in: scroll).x)

            case .ended, .cancelled:
                let dx = g.translation(in: scroll).x
                let vx = g.velocity(in: scroll).x
                onPagePanEnded(dx, dx + vx * 0.35)

            default:
                break
            }
        }

        @objc func handlePageTap(_ g: UITapGestureRecognizer) {
            guard let scroll else { return }
            onPageTap(g.location(in: scroll).x)
        }

        // MARK: 手势优先级

        func gestureRecognizer(_ g: UIGestureRecognizer,
                               shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool {
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
            forceEnableDrawing()
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
