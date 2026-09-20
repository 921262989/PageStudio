import SwiftUI
import PencilKit

// MARK: - 进度条（按百分比跳页）

struct ScrubberView: View {
    let count: Int
    let index: Int
    @Binding var scrubbing: Int?
    let onCommit: (Int) -> Void

    @State private var dragProgress: Double? = nil

    var body: some View {
        GeometryReader { geo in
            let w = max(geo.size.width, 1)
            let safeCount = max(count, 1)
            let baseProgress: Double = safeCount <= 1
                ? 0
                : Double(min(max(index, 0), safeCount - 1)) / Double(safeCount - 1)
            let shown = dragProgress ?? baseProgress
            let knobX = min(max(w * shown - 9, 0), max(w - 18, 0))

            ZStack(alignment: .leading) {
                Capsule()
                    .fill(Color.white.opacity(0.22))
                    .frame(height: 5)

                Capsule()
                    .fill(Color.white.opacity(0.88))
                    .frame(width: max(4, w * shown), height: 5)

                Circle()
                    .fill(Color.white)
                    .frame(width: 18, height: 18)
                    .shadow(color: .black.opacity(0.45), radius: 4)
                    .offset(x: knobX)
            }
            .frame(maxHeight: .infinity, alignment: .center)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        let p = min(max(value.location.x / w, 0), 1)
                        dragProgress = p
                        scrubbing = Int((p * Double(safeCount - 1)).rounded())
                    }
                    .onEnded { value in
                        let p = min(max(value.location.x / w, 0), 1)
                        let target = Int((p * Double(safeCount - 1)).rounded())
                        dragProgress = nil
                        scrubbing = nil
                        onCommit(target)
                    }
            )
        }
        .frame(height: 26)
    }
}

// MARK: - 页面缩略图

struct PageThumbnailView: View {
    let book: Book
    let pageIndex: Int
    let width: CGFloat
    let height: CGFloat

    @State private var inkImage: UIImage?

    private var spreadIndex: Int {
        SpreadLayout.spreadIndex(containingPage: pageIndex, in: book)
    }

    private var isRightPage: Bool {
        guard let s = SpreadLayout.spread(containingPage: pageIndex, in: book) else {
            return false
        }
        return SpreadLayout.visualSides(of: s, binding: book.bindingDirection).right == pageIndex
    }

    var body: some View {
        Color.clear
            .frame(width: width, height: height)
            .overlay(alignment: .topLeading) {
                SinglePageView(book: book,
                               pageIndex: pageIndex,
                               pageWidth: width,
                               pageHeight: height,
                               drawingRevision: 0,
                               showDrawing: false)
            }
            .overlay(alignment: .topLeading) {
                if let inkImage {
                    Image(uiImage: inkImage)
                        .resizable()
                        .frame(width: width * 2, height: height)
                        .offset(x: isRightPage ? -width : 0)
                }
            }
            .clipped()
            .background(Color(white: 0.97))
            .overlay(
                Rectangle().stroke(Color.black.opacity(0.10), lineWidth: 1)
            )
            .task(id: "\(book.id.uuidString)-\(spreadIndex)") {
                await loadInk()
            }
    }

    private func loadInk() async {
        let logical = DrawingGeometry.spreadSize(ratio: book.pageAspectRatio)
        let url = FileStorage.drawingURL(bookId: book.id, spreadIndex: spreadIndex)
        let img = await Task.detached(priority: .utility) { () -> UIImage? in
            guard let data = try? Data(contentsOf: url),
                  let d = try? PKDrawing(data: data),
                  !d.strokes.isEmpty else { return nil }
            return d.image(from: CGRect(origin: .zero, size: logical), scale: 1)
        }.value
        inkImage = img
    }
}

// MARK: - 总页面面板

struct ThumbnailPanelView: View {
    let book: Book
    let currentPageIndex: Int
    let onSelect: (Int) -> Void

    @Environment(\.dismiss) private var dismiss

    private let columns = [GridItem(.adaptive(minimum: 120, maximum: 190), spacing: 14)]

    var body: some View {
        NavigationStack {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVGrid(columns: columns, spacing: 18) {
                        ForEach(Array(book.pages.enumerated()), id: \.element.id) { idx, _ in
                            Button {
                                onSelect(idx)
                                dismiss()
                            } label: {
                                VStack(spacing: 6) {
                                    PageThumbnailView(book: book,
                                                      pageIndex: idx,
                                                      width: 124,
                                                      height: 124 * book.pageAspectRatio)
                                    .clipShape(RoundedRectangle(cornerRadius: 4,
                                                                style: .continuous))
                                    .overlay(
                                        RoundedRectangle(cornerRadius: 4, style: .continuous)
                                            .stroke(idx == currentPageIndex
                                                    ? Color.accentColor
                                                    : Color.clear,
                                                    lineWidth: 3)
                                    )
                                    .shadow(color: .black.opacity(0.12),
                                            radius: 3, y: 2)

                                    Text("\(idx + 1)")
                                        .font(.caption.monospacedDigit())
                                        .foregroundStyle(idx == currentPageIndex
                                                         ? Color.accentColor
                                                         : Color.secondary)
                                }
                            }
                            .buttonStyle(.plain)
                            .id(idx)
                        }
                    }
                    .padding(16)
                }
                .onAppear {
                    proxy.scrollTo(currentPageIndex, anchor: .center)
                }
            }
            .navigationTitle("总页面 · \(book.pages.count) 页")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("关闭") { dismiss() }
                }
            }
        }
    }
}

// MARK: - 大纲面板

struct OutlinePanelView: View {
    let book: Book
    let currentPageIndex: Int
    let onJump: (Int) -> Void
    let onChange: (Book) -> Void

    @Environment(\.dismiss) private var dismiss

    @State private var items: [OutlineItem] = []
    @State private var isEditing = false
    @State private var editingItem: OutlineItem?
    @State private var didLoad = false

    var body: some View {
        NavigationStack {
            List {
                if items.isEmpty {
                    Section {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("还没有大纲")
                                .font(.headline)
                            Text("点右上角 + 把当前页（第 \(currentPageIndex + 1) 页）添加为目录条目。之后可以改标题、设层级、拖动排序。")
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        }
                        .padding(.vertical, 6)
                    }
                }

                ForEach(items.indices, id: \.self) { i in
                    outlineRow(i)
                }
                .onDelete { offsets in
                    items.remove(atOffsets: offsets)
                    commit()
                }
                .onMove { source, dest in
                    items.move(fromOffsets: source, toOffset: dest)
                    commit()
                }
            }
            .environment(\.editMode, .constant(isEditing ? .active : .inactive))
            .navigationTitle("大纲")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("关闭") { dismiss() }
                }
                ToolbarItemGroup(placement: .navigationBarTrailing) {
                    Button {
                        isEditing.toggle()
                    } label: {
                        Text(isEditing ? "完成" : "编辑")
                    }
                    Button {
                        addCurrentPage()
                    } label: {
                        Image(systemName: "plus")
                    }
                }
            }
            .sheet(item: $editingItem) { item in
                OutlineItemEditor(item: item,
                                  pageCount: book.pages.count,
                                  onSave: { newItem in
                                      if let idx = items.firstIndex(where: { $0.id == newItem.id }) {
                                          items[idx] = newItem
                                          commit()
                                      }
                                  })
            }
            .onAppear {
                guard !didLoad else { return }
                didLoad = true
                items = book.outline
            }
        }
    }

    @ViewBuilder
    private func outlineRow(_ i: Int) -> some View {
        let item = items[i]
        HStack(spacing: 8) {
            if item.level > 0 {
                Rectangle()
                    .fill(Color.clear)
                    .frame(width: CGFloat(item.level) * 22)
            }

            Button {
                if isEditing {
                    editingItem = item
                } else {
                    onJump(item.pageIndex)
                    dismiss()
                }
            } label: {
                HStack {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(item.title)
                            .foregroundStyle(.primary)
                        Text("第 \(item.pageIndex + 1) 页")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    if !isEditing {
                        Image(systemName: "arrow.turn.down.right")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                    }
                }
            }
            .buttonStyle(.plain)

            if isEditing {
                Button {
                    editingItem = item
                } label: {
                    Image(systemName: "slider.horizontal.3")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
        }
    }

    private func addCurrentPage() {
        var item = OutlineItem()
        item.title = "第 \(currentPageIndex + 1) 页"
        item.pageIndex = currentPageIndex
        item.level = 0
        items.append(item)
        commit()
        editingItem = item
    }

    private func commit() {
        var updated = book
        updated.outline = items
        onChange(updated)
    }
}

// MARK: - 大纲条目编辑器

struct OutlineItemEditor: View {
    let item: OutlineItem
    let pageCount: Int
    let onSave: (OutlineItem) -> Void

    @Environment(\.dismiss) private var dismiss

    @State private var title: String
    @State private var level: Int
    @State private var pageIndex: Int

    init(item: OutlineItem, pageCount: Int, onSave: @escaping (OutlineItem) -> Void) {
        self.item = item
        self.pageCount = pageCount
        self.onSave = onSave
        _title = State(initialValue: item.title)
        _level = State(initialValue: item.level)
        _pageIndex = State(initialValue: item.pageIndex)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("标题") {
                    TextField("条目名称", text: $title)
                }

                Section("层级") {
                    Picker("层级", selection: $level) {
                        Text("一级").tag(0)
                        Text("二级").tag(1)
                    }
                    .pickerStyle(.segmented)
                }

                Section("跳转到") {
                    Stepper("第 \(pageIndex + 1) 页",
                            value: $pageIndex,
                            in: 0...max(pageCount - 1, 0))
                }
            }
            .navigationTitle("编辑条目")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("取消") { dismiss() }
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("保存") {
                        var updated = item
                        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
                        updated.title = trimmed.isEmpty ? "未命名条目" : trimmed
                        updated.level = level
                        updated.pageIndex = min(max(pageIndex, 0), max(pageCount - 1, 0))
                        onSave(updated)
                        dismiss()
                    }
                }
            }
        }
    }
}
