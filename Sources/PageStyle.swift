import SwiftUI

// MARK: - 内页样式

enum PageRuleKind: String, Codable, CaseIterable, Identifiable {
    case none, lines, grid, dots

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .none:  return "空白"
        case .lines: return "横线"
        case .grid:  return "方格"
        case .dots:  return "点阵"
        }
    }

    var systemImage: String {
        switch self {
        case .none:  return "minus"
        case .lines: return "text.alignleft"
        case .grid:  return "squareshape.split.3x3"
        case .dots:  return "circle.grid.3x3"
        }
    }
}

struct PageRuleStyle: Codable, Equatable {
    var kind: PageRuleKind = .none
    /// 间距，单位是逻辑坐标（页高 1000），和笔迹同一套坐标
    var spacing: Double = 32
    var lineWidth: Double = 1
    var colorHex: String = "#C8D0DA"
    var opacity: Double = 0.75

    static let blank = PageRuleStyle()

    var color: Color { Color(hex: colorHex) ?? Color(white: 0.78) }
}

enum PageRuleStore {
    static func key(for bookID: UUID) -> String { "pageRule-\(bookID.uuidString)" }

    static func load(for bookID: UUID) -> PageRuleStyle {
        guard let data = UserDefaults.standard.data(forKey: key(for: bookID)),
              let decoded = try? JSONDecoder().decode(PageRuleStyle.self, from: data)
        else { return .blank }
        return decoded
    }

    static func save(_ style: PageRuleStyle, for bookID: UUID) {
        guard let data = try? JSONEncoder().encode(style) else { return }
        UserDefaults.standard.set(data, forKey: key(for: bookID))
    }
}

// MARK: - 把样式画在纸上

struct PageRuleLayer: View {
    let style: PageRuleStyle
    let pageSize: CGSize

    /// 逻辑坐标 → 屏幕点
    private var k: CGFloat {
        pageSize.height / DrawingGeometry.logicalPageHeight
    }

    var body: some View {
        Canvas { ctx, size in
            guard style.kind != .none else { return }

            let step = max(CGFloat(style.spacing) * k, 4)
            let lw = max(CGFloat(style.lineWidth) * k, 0.5)
            let ink = style.color.opacity(min(max(style.opacity, 0.05), 1))

            switch style.kind {
            case .none:
                break

            case .lines:
                var y = step
                while y < size.height {
                    var p = Path()
                    p.move(to: CGPoint(x: 0, y: y))
                    p.addLine(to: CGPoint(x: size.width, y: y))
                    ctx.stroke(p, with: .color(ink), lineWidth: lw)
                    y += step
                }

            case .grid:
                var y = step
                while y < size.height {
                    var p = Path()
                    p.move(to: CGPoint(x: 0, y: y))
                    p.addLine(to: CGPoint(x: size.width, y: y))
                    ctx.stroke(p, with: .color(ink), lineWidth: lw)
                    y += step
                }
                var x = step
                while x < size.width {
                    var p = Path()
                    p.move(to: CGPoint(x: x, y: 0))
                    p.addLine(to: CGPoint(x: x, y: size.height))
                    ctx.stroke(p, with: .color(ink), lineWidth: lw)
                    x += step
                }

            case .dots:
                let r = max(lw * 1.2, 1.2)
                var y = step
                while y < size.height {
                    var x = step
                    while x < size.width {
                        let rect = CGRect(x: x - r, y: y - r,
                                          width: r * 2, height: r * 2)
                        ctx.fill(Path(ellipseIn: rect), with: .color(ink))
                        x += step
                    }
                    y += step
                }
            }
        }
        .allowsHitTesting(false)
    }
}

// MARK: - 画册密码锁

enum BookLock {
    static func key(for bookID: UUID) -> String { "lock-\(bookID.uuidString)" }

    static func isLocked(_ bookID: UUID) -> Bool {
        guard let s = UserDefaults.standard.string(forKey: key(for: bookID)) else { return false }
        return !s.isEmpty
    }

    static func setPassword(_ password: String?, for bookID: UUID) {
        let k = key(for: bookID)
        if let password, !password.trimmingCharacters(in: .whitespaces).isEmpty {
            UserDefaults.standard.set(hash(password), forKey: k)
        } else {
            UserDefaults.standard.removeObject(forKey: k)
        }
    }

    static func verify(_ password: String, for bookID: UUID) -> Bool {
        guard let stored = UserDefaults.standard.string(forKey: key(for: bookID)) else {
            return true
        }
        return stored == hash(password)
    }

    /// 简单哈希，够防手滑就够了
    private static func hash(_ s: String) -> String {
        var h: UInt64 = 1469598103934665603
        for b in s.utf8 {
            h ^= UInt64(b)
            h = h &* 1099511628211
        }
        return String(h, radix: 16)
    }
}
