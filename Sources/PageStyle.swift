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
    /// 间距，单位是逻辑坐标（页高 1000），和笔迹用同一套坐标
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
            let lw = max(CGFloat(style.lineWidth) * k, 0.4)
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

// MARK: - 内页样式编辑器

struct PageStyleEditor: View {
    @Environment(\.dismiss) private var dismiss

    let bookID: UUID
    let bookTitle: String

    @State private var rule: PageRuleStyle

    init(bookID: UUID, bookTitle: String) {
        self.bookID = bookID
        self.bookTitle = bookTitle
        _rule = State(initialValue: PageRuleStore.load(for: bookID))
    }

    private let previewSize = CGSize(width: 160, height: 224)

    var body: some View {
        NavigationStack {
            Form {
                Section("样式") {
                    Picker("样式", selection: $rule.kind) {
                        ForEach(PageRuleKind.allCases) { kind in
                            Text(kind.displayName).tag(kind)
                        }
                    }
                    .pickerStyle(.segmented)
                    .onChange(of: rule.kind) { _ in save() }
                }

                if rule.kind != .none {
                    Section("调整") {
                        VStack(alignment: .leading, spacing: 6) {
                            HStack {
                                Text("间距")
                                Spacer()
                                Text("\(Int(rule.spacing))")
                                    .foregroundStyle(.secondary)
                                    .monospacedDigit()
                            }
                            Slider(value: $rule.spacing, in: 12...90, step: 1)
                                .onChange(of: rule.spacing) { _ in save() }
                        }

                        VStack(alignment: .leading, spacing: 6) {
                            HStack {
                                Text("粗细")
                                Spacer()
                                Text(String(format: "%.1f", rule.lineWidth))
                                    .foregroundStyle(.secondary)
                                    .monospacedDigit()
                            }
                            Slider(value: $rule.lineWidth, in: 0.4...4, step: 0.1)
                                .onChange(of: rule.lineWidth) { _ in save() }
                        }

                        VStack(alignment: .leading, spacing: 6) {
                            HStack {
                                Text("浓淡")
                                Spacer()
                                Text("\(Int(rule.opacity * 100))%")
                                    .foregroundStyle(.secondary)
                                    .monospacedDigit()
                            }
                            Slider(value: $rule.opacity, in: 0.08...1.0)
                                .onChange(of: rule.opacity) { _ in save() }
                        }

                        HStack {
                            Text("颜色")
                            Spacer()
                            ColorPicker("", selection: colorBinding,
                                        supportsOpacity: false)
                                .labelsHidden()
                        }
                    }
                }

                Section("预览") {
                    HStack {
                        Spacer()
                        ZStack {
                            PaperView()

                            if rule.kind != .none {
                                PageRuleLayer(style: rule, pageSize: previewSize)
                            }
                        }
                        .frame(width: previewSize.width, height: previewSize.height)
                        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                        .overlay(
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .stroke(PaperStyle.border, lineWidth: 0.5)
                        )
                        Spacer()
                    }
                    .padding(.vertical, 6)
                }
            }
            .navigationTitle("内页样式")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("关闭") { dismiss() }
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("完成") {
                        save()
                        dismiss()
                    }
                }
            }
        }
    }

    private var colorBinding: Binding<Color> {
        Binding(
            get: { rule.color },
            set: { newValue in
                rule.colorHex = newValue.hexString
                save()
            }
        )
    }

    private func save() {
        PageRuleStore.save(rule, for: bookID)
    }
}
