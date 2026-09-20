import SwiftUI

/// 一张刚性纸的翻转视图。
///
/// 绕装订边做 3D 平转：纸不弯曲、不卷曲，翻过去后平摊在另一侧。
/// 正面朝观察者时显示 `front`；转过 90° 后显示 `back`，并自动做水平镜像抵消，
/// 让背面的内容以正确方向呈现。
///
/// `angle` 单位为度：
/// - `anchor == .leading` 时用负值（绕左边缘往左翻）
/// - `anchor == .trailing` 时用正值（绕右边缘往右翻）
struct FlipCard<Front: View, Back: View>: View {
    let front: Front
    let back: Back
    let angle: Double
    let anchor: UnitPoint
    let perspective: CGFloat
    /// 背面压暗程度（0 = 不压暗）
    let dimming: Double
    /// 纸张底色，铺在内容之下，避免透视时透出背景
    let paperColor: Color
    let borderColor: Color

    private var showingBack: Bool { abs(angle) > 90 }

    /// 0 → 1 → 0：旋转到侧面时阴影最强
    private var tiltStrength: Double {
        let r = abs(angle) * .pi / 180
        return abs(sin(r))
    }

    var body: some View {
        ZStack {
            if showingBack {
                back
                    .scaleEffect(x: -1, y: 1)
                    .overlay(paperColor.opacity(dimming))
            } else {
                front
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(paperColor)
        .overlay(
            Rectangle().stroke(borderColor, lineWidth: 0.5)
        )
        .clipped()
        .rotation3DEffect(
            .degrees(angle),
            axis: (x: 0, y: 1, z: 0),
            anchor: anchor,
            perspective: perspective
        )
        .shadow(color: .black.opacity(0.42 * tiltStrength),
                radius: 20 * tiltStrength,
                x: anchor == .leading ? 8 * tiltStrength : -8 * tiltStrength,
                y: 5 * tiltStrength)
    }
}
