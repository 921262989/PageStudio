import SwiftUI
import UIKit

/// 把 UIPageViewController 的 `.pageCurl` 转场包成 SwiftUI 组件。
///
/// ⚠️ 这是本 App「像翻真书」的核心。
/// 每一次翻动作用在一个完整单元上：双页模式 = 一个跨页，单页模式 = 一个页面。
/// 卷页动画、跟手拖拽、阴影与透视全部由系统提供，观感与 iBooks 同级。
struct CurlPageController<Content: View>: UIViewControllerRepresentable {

    let pageCount: Int
    @Binding var currentIndex: Int
    let onTapLeft: () -> Void
    let onTapRight: () -> Void
    let content: (Int) -> Content

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

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

        // 让 pageCurl 的视觉尺寸等于我们给的 frame，而不是整个屏幕
        pvc.view.clipsToBounds = true

        if pageCount > 0 {
            let clamped = min(max(currentIndex, 0), pageCount - 1)
            let host = context.coordinator.makeHost(index: clamped)
            pvc.setViewControllers([host], direction: .forward, animated: false)
        }

        // 点击左右边缘翻页（与 pageCurl 的手势共存）
        let tap = UITapGestureRecognizer(target: context.coordinator,
                                         action: #selector(Coordinator.handleTap(_:)))
        tap.cancelsTouchesInView = false
        tap.delegate = context.coordinator
        pvc.view.addGestureRecognizer(tap)

        return pvc
    }

    func updateUIViewController(_ pvc: UIPageViewController, context: Context) {
        context.coordinator.parent = self
        context.coordinator.refreshContents()

        guard pageCount > 0 else { return }

        let visible = pvc.viewControllers?.first
        let visibleIndex = visible.flatMap { context.coordinator.index(of: $0) } ?? -1
        let target = min(max(currentIndex, 0), pageCount - 1)

        if visibleIndex != target {
            let direction: UIPageViewController.NavigationDirection =
                target >= visibleIndex ? .forward : .reverse
            let host = context.coordinator.makeHost(index: target)
            pvc.setViewControllers([host], direction: direction, animated: true)
        }
    }

    // MARK: - Coordinator

    final class Coordinator: NSObject,
                             UIPageViewControllerDataSource,
                             UIPageViewControllerDelegate,
                             UIGestureRecognizerDelegate {

        var parent: CurlPageController
        private var hosts: [Int: UIHostingController<Content>] = [:]

        init(_ parent: CurlPageController) {
            self.parent = parent
        }

        // MARK: 创建 / 缓存页面

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

        /// 数据变了（比如导入图片、笔迹更新）时刷新已缓存页面
        func refreshContents() {
            for (index, host) in hosts where index < parent.pageCount {
                host.rootView = parent.content(index)
            }
        }

        /// 只保留当前页附近的缓存，防止页数多时内存膨胀
        private func trim(around index: Int) {
            for key in hosts.keys where abs(key - index) > 2 {
                hosts[key] = nil
            }
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

        // MARK: 翻页结束

        func pageViewController(_ pvc: UIPageViewController,
                                didFinishAnimating finished: Bool,
                                previousViewControllers: [UIViewController],
                                transitionCompleted completed: Bool) {
            guard completed,
                  let visible = pvc.viewControllers?.first,
                  let i = index(of: visible) else { return }
            trim(around: i)
            DispatchQueue.main.async {
                self.parent.currentIndex = i
            }
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

        // 让 tap 与 pageCurl 手势共存
        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                               shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool {
            true
        }
    }
}
