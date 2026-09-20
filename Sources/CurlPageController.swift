import SwiftUI
import UIKit

/// UIPageViewController 的 `.pageCurl` 转场封装。
/// 系统级仿真卷页（iBooks 同款），支持跟手拖拽。
struct CurlPageController<Content: View>: UIViewControllerRepresentable {

    let pageCount: Int
    @Binding var currentIndex: Int
    /// false = 禁用翻页（手指＋笔模式下交给画布）
    let interactivePaging: Bool
    let onTapLeft: () -> Void
    let onTapRight: () -> Void
    let content: (Int) -> Content

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeUIViewController(context: Context) -> UIPageViewController {
        let pvc = UIPageViewController(
            transitionStyle: .pageCurl,
            navigationOrientation: .horizontal,
            options: nil
        )
        pvc.dataSource = context.coordinator
        pvc.delegate = context.coordinator
        pvc.isDoubleSided = false
        pvc.view.backgroundColor = .clear
        pvc.view.isOpaque = false
        pvc.view.clipsToBounds = true

        if pageCount > 0 {
            let clamped = min(max(currentIndex, 0), pageCount - 1)
            pvc.setViewControllers([context.coordinator.makeHost(index: clamped)],
                                   direction: .forward,
                                   animated: false)
        }

        let tap = UITapGestureRecognizer(target: context.coordinator,
                                         action: #selector(Coordinator.handleTap(_:)))
        tap.cancelsTouchesInView = false
        tap.delegate = context.coordinator
        pvc.view.addGestureRecognizer(tap)

        context.coordinator.pagingEnabled = interactivePaging
        return pvc
    }

    func updateUIViewController(_ pvc: UIPageViewController, context: Context) {
        context.coordinator.parent = self
        context.coordinator.refreshContents()
        context.coordinator.applyPagingState(to: pvc, enabled: interactivePaging)

        guard pageCount > 0, !context.coordinator.isAnimating else { return }

        let visibleIndex = pvc.viewControllers?.first
            .flatMap { context.coordinator.index(of: $0) } ?? -1
        let target = min(max(currentIndex, 0), pageCount - 1)

        if visibleIndex != target {
            let direction: UIPageViewController.NavigationDirection =
                target >= visibleIndex ? .forward : .reverse
            pvc.setViewControllers([context.coordinator.makeHost(index: target)],
                                   direction: direction,
                                   animated: visibleIndex >= 0)
        }
    }

    // MARK: - Coordinator

    final class Coordinator: NSObject,
                             UIPageViewControllerDataSource,
                             UIPageViewControllerDelegate,
                             UIGestureRecognizerDelegate {

        var parent: CurlPageController
        var isAnimating = false
        var pagingEnabled = true

        private var hosts: [Int: UIHostingController<Content>] = [:]

        init(_ parent: CurlPageController) {
            self.parent = parent
        }

        // MARK: 页面缓存

        func makeHost(index: Int) -> UIHostingController<Content> {
            if let existing = hosts[index] { return existing }
            let host = UIHostingController(rootView: parent.content(index))
            host.view.backgroundColor = .clear
            host.view.isOpaque = false
            hosts[index] = host
            return host
        }

        func index(of vc: UIViewController) -> Int? {
            hosts.first(where: { $0.value === vc })?.key
        }

        func refreshContents() {
            for (index, host) in hosts where index < parent.pageCount {
                host.rootView = parent.content(index)
            }
        }

        private func trim(around index: Int) {
            for key in hosts.keys where abs(key - index) > 2 {
                hosts[key] = nil
            }
        }

        // MARK: 翻页开关

        func applyPagingState(to pvc: UIPageViewController, enabled: Bool) {
            guard pagingEnabled != enabled else { return }
            pagingEnabled = enabled

            if enabled {
                pvc.dataSource = self
                pvc.delegate = self
            } else {
                pvc.dataSource = nil
                pvc.delegate = nil
            }
            setTouchGestures(enabled: enabled, in: pvc.view)
        }

        private func setTouchGestures(enabled: Bool, in view: UIView) {
            for g in view.gestureRecognizers ?? [] {
                if g is UITapGestureRecognizer { continue }
                g.isEnabled = enabled
            }
            for sub in view.subviews { setTouchGestures(enabled: enabled, in: sub) }
        }

        // MARK: 数据源

        func pageViewController(_ pvc: UIPageViewController,
                                viewControllerBefore vc: UIViewController) -> UIViewController? {
            guard let i = index(of: vc), i > 0 else { return nil }
            return makeHost(index: i - 1)
        }

        func pageViewController(_ pvc: UIPageViewController,
                                viewControllerAfter vc: UIViewController) -> UIViewController? {
            guard let i = index(of: vc), i < parent.pageCount - 1 else { return nil }
            return makeHost(index: i + 1)
        }

        // MARK: 转场

        func pageViewController(_ pvc: UIPageViewController,
                                willTransitionTo pendingViewControllers: [UIViewController]) {
            isAnimating = true
        }

        func pageViewController(_ pvc: UIPageViewController,
                                didFinishAnimating finished: Bool,
                                previousViewControllers: [UIViewController],
                                transitionCompleted completed: Bool) {
            isAnimating = false
            guard completed,
                  let visible = pvc.viewControllers?.first,
                  let i = index(of: visible) else { return }
            trim(around: i)
            DispatchQueue.main.async { self.parent.currentIndex = i }
        }

        // MARK: 边缘点击

        @objc func handleTap(_ gesture: UITapGestureRecognizer) {
            guard let view = gesture.view else { return }
            let location = gesture.location(in: view)
            let width = view.bounds.width
            let edge = max(width / 5, 60)

            if location.x < edge {
                DispatchQueue.main.async { self.parent.onTapLeft() }
            } else if location.x > width - edge {
                DispatchQueue.main.async { self.parent.onTapRight() }
            }
        }

        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                               shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool {
            true
        }
    }
}
