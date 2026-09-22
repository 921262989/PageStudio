import SwiftUI
import PencilKit
import PhotosUI
import UniformTypeIdentifiers

// MARK: - 页面缩略图

struct PageThumbnailView: View {
    let book: Book
    let pageIndex: Int
    let width: CGFloat
    let height: CGFloat
    let theme: ReaderTheme

    @State private var inkImage: UIImage?

    private var spreadIndex: Int {
        SpreadLayout.spreadIndex(containingPage: pageIndex, in: book)
    }

    private var isRightPage: Bool {
        guard let s = SpreadLayout.spread(containingPage: pageIndex, in: book) else {
            return false
        }
        return SpreadLayout.visualSides(of: s,
                                        binding: book.bindingDirection).right == pageIndex
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
                               showDrawing: false,
                               theme: theme,
                               bordered: false)
            }
            .overlay(alignment: .topLeading) {
                if let inkImage {
                    Image(uiImage: inkImage)
                        .resizable()
                        .interpolation(.high)
                        .frame(width: width * 2, height: height)
                        .offset(x: isRightPage ? -width : 0)
                }
            }
            .clipped()
            .background(PaperStyle.fill)
            .overlay(Rectangle().stroke(PaperStyle.border, lineWidth: 0.5))
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
            return d.image(from: CGRect(origin: .zero, size: logical), scale: 1.5)
        }.value
        inkImage = img
    }
}

// MARK: - 总页面面板

struct ThumbnailPanelView: View {
    let currentPageIndex: Int
    let theme: ReaderTheme
    let onSelect: (Int) -> Void
    let onChange: (Book) -> Void

    @Environment(\.dismiss) private var dismiss

    @State private var working: Book
    @State private var isSelecting = false
    @State private var selection: Set<Int> = []
    @State private var confirmDelete = false
    @State private var toast: String? = nil

    // 拖拽排序
    @State private var draggingIndex: Int? = nil
    @State private var dropTarget: Int? = nil

    // 在某页后插入
    @State private var insertAfterIndex: Int? = nil
    @State private var showPhotoPicker = false
    @State private var photoItems: [PhotosPickerItem] = []
    @State private var isImporting = false

    private let columns = [GridItem(.adaptive(minimum: 118, maximum: 180), spacing: 14)]

    init(book: Book,
         currentPageIndex: Int,
         theme: ReaderTheme,
         onSelect: @escaping (Int) -> Void,
         onChange: @escaping (Book) -> Void) {
        self.currentPageIndex = currentPageIndex
        self.theme = theme
        self.onSelect = onSelect
        self.onChange = onChange
        _working = State(initialValue: book)
    }

    var body: some View {
        NavigationStack {
            gridArea
                .navigationTitle("总页面 · \(working.pages.count) 页")
                .navigationBarTitleDisplayMode(.inline)
                .safeAreaInset(edge: .bottom) {
                    if isSelecting { selectionBar }
                }
                .toolbar { toolbarItems }
                .confirmationDialog("删除 \(selection.count) 页？",
                                    isPresented: $confirmDelete,
                                    titleVisibility: .visible) {
                    Button("删除", role: .destructive) { performDelete() }
                    Button("取消", role: .cancel) { }
                } message: {
                    Text("笔迹是按「跨页位置」保存的。删除页面会改变后续页面与笔迹的对应关系。")
                }
                .photosPicker(isPresented: $showPhotoPicker,
                              selection: $photoItems,
                              maxSelectionCount: 50,
                              matching: .images)
                .onChange(of: photoItems) { items in
                    guard !items.isEmpty else { return }
                    Task { await insertFromPhotos(items) }
                }
                .overlay(alignment: .top) { toastView }
                .overlay { importingOverlay }
        }
    }

    // MARK: - 网格

    private var gridArea: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVGrid(columns: columns, spacing: 18) {
                    ForEach(Array(working.pages.enumerated()),
                            id: \.element.id) { idx, _ in
                        cell(idx)
                    }
                }
                .padding(16)
            }
            .onAppear {
                proxy.scrollTo(currentPageIndex, anchor: .center)
            }
        }
    }

    // ⚠️ ToolbarItem 不是 View，必须用 @ToolbarContentBuilder
    @ToolbarContentBuilder
    private var toolbarItems: some ToolbarContent {
        ToolbarItem(placement: .navigationBarLeading) {
            if isSelecting {
                Button("取消") { exitSelection() }
            } else {
                Button("关闭") { dismiss() }
            }
        }

        ToolbarItem(placement: .navigationBarTrailing) {
            if isSelecting {
                Button(selection.count == working.pages.count
                       ? "取消全选" : "全选") {
                    if selection.count == working.pages.count {
                        selection.removeAll()
                    } else {
                        selection = Set(working.pages.indices)
                    }
                }
            } else {
                Button("选择") { isSelecting = true }
            }
        }
    }

    @ViewBuilder
    private var toastView: some View {
        if let toast {
            Text(toast)
                .font(.footnote)
                .foregroundStyle(.white)
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .background(Color.black.opacity(0.78), in: Capsule())
                .padding(.top, 8)
                .transition(.move(edge: .top).combined(with: .opacity))
        }
    }

    @ViewBuilder
    private var importingOverlay: some View {
        if isImporting {
            ZStack {
                Color.black.opacity(0.4).ignoresSafeArea()
                VStack(spacing: 12) {
                    ProgressView()
                    Text("正在插入…")
                        .font(.footnote)
                        .foregroundStyle(.white)
                }
                .padding(22)
                .background(.ultraThinMaterial,
                            in: RoundedRectangle(cornerRadius: 14,
                                                 style: .continuous))
            }
        }
    }

    // MARK: - 单元格
    //
    // ⚠️ 拆成几个小函数。之前拖拽、下拉、右键菜单全堆在一个表达式里，
    //    Swift 的类型检查器会报 "unable to type-check in reasonable time"。

    @ViewBuilder
    private func cell(_ idx: Int) -> some View {
        let selected = selection.contains(idx)
        let isDragging = (draggingIndex == idx)
        let isTarget = (dropTarget == idx)

        VStack(spacing: 6) {
            thumbnail(idx: idx,
                      selected: selected,
                      isTarget: isTarget,
                      isDragging: isDragging)
            caption(idx: idx, isTarget: isTarget)
        }
        .contentShape(Rectangle())
        .onTapGesture { handleTap(idx) }
        .onDrag {
            draggingIndex = idx
            return NSItemProvider(object: "\(idx)" as NSString)
        } preview: {
            dragPreview(idx: idx)
        }
        .dropDestination(for: String.self) { items, _ in
            handleDrop(items, onto: idx)
        } isTargeted: { targeted in
            if targeted {
                dropTarget = idx
            } else if dropTarget == idx {
                dropTarget = nil
            }
        }
        .contextMenu { menuItems(idx: idx) }
        .id(idx)
    }

    @ViewBuilder
    private func thumbnail(idx: Int,
                           selected: Bool,
                           isTarget: Bool,
                           isDragging: Bool) -> some View {
        PageThumbnailView(book: working,
                          pageIndex: idx,
                          width: 124,
                          height: 124 * working.pageAspectRatio,
                          theme: theme)
            .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .stroke(borderColor(selected: selected,
                                        isTarget: isTarget,
                                        idx: idx),
                            lineWidth: (selected || isTarget) ? 3 : 2)
            }
            .overlay(alignment: .topLeading) {
                if isSelecting {
                    checkBadge(selected: selected)
                }
            }
            .shadow(color: .black.opacity(0.12), radius: 3, y: 2)
            .opacity(isDragging ? 0.35 : 1)
    }

    @ViewBuilder
    private func checkBadge(selected: Bool) -> some View {
        Image(systemName: selected ? "checkmark.circle.fill" : "circle")
            .font(.system(size: 20))
            .foregroundStyle(selected ? Color.accentColor : Color.white)
            .shadow(color: .black.opacity(0.5), radius: 2)
            .padding(5)
    }

    @ViewBuilder
    private func caption(idx: Int, isTarget: Bool) -> some View {
        HStack(spacing: 4) {
            Text("\(idx + 1)")
                .font(.caption.monospacedDigit())
                .foregroundStyle(idx == currentPageIndex
                                 ? Color.accentColor : Color.secondary)

            if draggingIndex != nil && isTarget {
                Image(systemName: "arrow.right.to.line")
                    .font(.caption2)
                    .foregroundStyle(Color.accentColor)
            }
        }
    }

    @ViewBuilder
    private func dragPreview(idx: Int) -> some View {
        PageThumbnailView(book: working,
                          pageIndex: idx,
                          width: 92,
                          height: 92 * working.pageAspectRatio,
                          theme: theme)
            .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
            .opacity(0.9)
    }

    @ViewBuilder
    private func menuItems(idx: Int) -> some View {
        if !isSelecting {
            Button {
                insertBlank(after: idx)
            } label: {
                Label("在此页后插入空白页", systemImage: "plus.rectangle")
            }

            Button {
                beginInsertPhotos(after: idx)
            } label: {
                Label("在此页后插入照片", systemImage: "photo.badge.plus")
            }

            Button {
                beginInsertFiles(after: idx)
            } label: {
                Label("在此页后插入文件 / PDF", systemImage: "folder.badge.plus")
            }

            Divider()

            Button {
                addToOutline([idx])
            } label: {
                Label("添加到大纲", systemImage: "list.bullet.indent")
            }

            Button {
                isSelecting = true
                selection = [idx]
            } label: {
                Label("开始选择", systemImage: "checkmark.circle")
            }

            Divider()

            Button(role: .destructive) {
                selection = [idx]
                confirmDelete = true
            } label: {
                Label("删除此页", systemImage: "trash")
            }
        }
    }

    private func borderColor(selected: Bool, isTarget: Bool, idx: Int) -> Color {
        if selected { return Color.accentColor }
        if isTarget { return Color.accentColor }
        if idx == currentPageIndex { return Color.accentColor.opacity(0.45) }
        return .clear
    }

    private func handleTap(_ idx: Int) {
        if isSelecting {
            toggleSelection(idx)
        } else {
            onSelect(idx)
            dismiss()
        }
    }

    private func handleDrop(_ items: [String], onto idx: Int) -> Bool {
        defer {
            draggingIndex = nil
            dropTarget = nil
        }
        guard let first = items.first,
              let from = Int(first),
              from != idx else { return false }
        movePage(from: from, to: idx)
        return true
    }

    // MARK: - 底部批量操作栏

    private var selectionBar: some View {
        HStack(spacing: 14) {
            Text("已选 \(selection.count) 页")
                .font(.footnote)
                .foregroundStyle(.secondary)

            Spacer()

            Button {
                addToOutline(Array(selection))
                exitSelection()
            } label: {
                Label("加入大纲", systemImage: "list.bullet.indent")
            }
            .disabled(selection.isEmpty)

            Button(role: .destructive) {
                confirmDelete = true
            } label: {
                Label("删除", systemImage: "trash")
            }
            .disabled(selection.isEmpty)
        }
        .buttonStyle(.bordered)
        .padding(.horizontal, 18)
        .padding(.vertical, 10)
        .background(.bar)
    }

    // MARK: - 选择

    private func toggleSelection(_ idx: Int) {
        if selection.contains(idx) {
            selection.remove(idx)
        } else {
            selection.insert(idx)
        }
    }

    private func exitSelection() {
        isSelecting = false
        selection.removeAll()
    }

    // MARK: - 拖拽排序（单页移动；笔迹不动）

    private func movePage(from: Int, to: Int) {
        guard working.pages.indices.contains(from),
              working.pages.indices.contains(to),
              from != to else { return }

        var updated = working
        let page = updated.pages.remove(at: from)
        let clamped = min(max(to, 0), updated.pages.count)
        updated.pages.insert(page, at: clamped)

        working = updated
        onChange(updated)
        showToast("第 \(from + 1) 页 → 第 \(to + 1) 位")
    }

    // MARK: - 插入

    private func insertBlank(after idx: Int) {
        insertPages([Page.blank()], after: idx)
    }

    private func beginInsertPhotos(after idx: Int) {
        insertAfterIndex = idx
        photoItems = []
        showPhotoPicker = true
    }

    private func beginInsertFiles(after idx: Int) {
        insertAfterIndex = idx

        DocumentPickerService.present(types: [.image, .pdf],
                                      allowsMultiple: true) { urls in
            guard !urls.isEmpty else { return }
            Task { await insertFromFiles(urls) }
        }
    }

    private func insertFromPhotos(_ items: [PhotosPickerItem]) async {
        guard let target = insertAfterIndex else { return }

        await MainActor.run { isImporting = true }

        var newPages: [Page] = []
        for item in items {
            guard let data = try? await item.loadTransferable(type: Data.self) else {
                continue
            }
            let ext = ImageFileType.fileExtension(for: data)
            if let name = try? FileStorage.saveImageData(data,
                                                         preferredExtension: ext) {
                newPages.append(Page.image(fileName: name))
            }
        }

        await MainActor.run {
            isImporting = false
            photoItems = []
            insertAfterIndex = nil
            guard !newPages.isEmpty else {
                showToast("没有读到照片")
                return
            }
            insertPages(newPages, after: target)
        }
    }

    private func insertFromFiles(_ urls: [URL]) async {
        guard let target = insertAfterIndex else { return }
        await MainActor.run { insertAfterIndex = nil }

        await MainActor.run { isImporting = true }

        var newPages: [Page] = []

        for url in urls {
            let accessing = url.startAccessingSecurityScopedResource()
            defer { if accessing { url.stopAccessingSecurityScopedResource() } }

            let ext = url.pathExtension.lowercased()

            if ext == "pdf" {
                let dest = FileStorage.documents
                    .appendingPathComponent("insert-\(UUID().uuidString).pdf")
                guard (try? FileManager.default.copyItem(at: url, to: dest)) != nil else {
                    continue
                }

                let total = PDFImporter.pageCount(url: dest)
                for i in 0..<total {
                    let page: Page? = await withCheckedContinuation { cont in
                        DispatchQueue.global(qos: .userInitiated).async {
                            autoreleasepool {
                                guard let image = PDFImporter.renderPage(url: dest,
                                                                         index: i,
                                                                         maxPixel: 2400),
                                      let data = image.jpegData(compressionQuality: 0.9),
                                      let name = try? FileStorage.saveImageData(
                                          data,
                                          preferredExtension: "jpg"
                                      ) else {
                                    cont.resume(returning: nil)
                                    return
                                }
                                cont.resume(returning: Page.image(fileName: name))
                            }
                        }
                    }
                    if let page { newPages.append(page) }
                }

                try? FileManager.default.removeItem(at: dest)
                continue
            }

            guard let data = try? Data(contentsOf: url) else { continue }
            let fileExt = ext.isEmpty
                ? ImageFileType.fileExtension(for: data)
                : ext

            if let name = try? FileStorage.saveImageData(data,
                                                         preferredExtension: fileExt) {
                newPages.append(Page.image(fileName: name))
            }
        }

        await MainActor.run {
            isImporting = false
            guard !newPages.isEmpty else {
                showToast("没有插入任何内容")
                return
            }
            insertPages(newPages, after: target)
        }
    }

    /// 在指定页之后插入若干页；大纲里在该页之后的条目页码整体后移。
    private func insertPages(_ pages: [Page], after idx: Int) {
        guard working.pages.indices.contains(idx), !pages.isEmpty else { return }

        var updated = working
        updated.pages.insert(contentsOf: pages, at: idx + 1)

        updated.outline = updated.outline.map { item in
            var it = item
            if item.pageIndex > idx {
                it.pageIndex += pages.count
            }
            return it
        }

        working = updated
        onChange(updated)
        showToast("已插入 \(pages.count) 页")
    }

    // MARK: - 大纲 / 删除

    private func addToOutline(_ indices: [Int]) {
        guard !indices.isEmpty else { return }
        var updated = working
        for idx in indices.sorted() {
            var item = OutlineItem()
            item.title = "第 \(idx + 1) 页"
            item.pageIndex = idx
            item.level = 0
            updated.outline.append(item)
        }
        working = updated
        onChange(updated)
        showToast("已加入大纲 \(indices.count) 条")
    }

    private func performDelete() {
        let indices = selection.sorted()
        guard !indices.isEmpty else { return }

        var updated = working

        for idx in indices where updated.pages.indices.contains(idx) {
            if let name = updated.pages[idx].imageFileName {
                FileStorage.deleteImage(named: name)
            }
        }

        updated.pages = updated.pages.enumerated()
            .filter { !selection.contains($0.offset) }
            .map { $0.element }

        updated.outline = updated.outline.map { item in
            var it = item
            let removedBefore = indices.filter { $0 < item.pageIndex }.count
            it.pageIndex = min(max(item.pageIndex - removedBefore, 0),
                               max(updated.pages.count - 1, 0))
            return it
        }

        if updated.pages.isEmpty {
            updated.pages = [Page.blank()]
        }

        working = updated
        onChange(updated)
        exitSelection()
        showToast("已删除 \(indices.count) 页")
    }

    private func showToast(_ text: String) {
        withAnimation { toast = text }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.6) {
            withAnimation { toast = nil }
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
                                      if let idx = items.firstIndex(where: {
                                          $0.id == newItem.id
                                      }) {
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
                        let trimmed = title
                            .trimmingCharacters(in: .whitespacesAndNewlines)
                        updated.title = trimmed.isEmpty ? "未命名条目" : trimmed
                        updated.level = level
                        updated.pageIndex = min(max(pageIndex, 0),
                                                max(pageCount - 1, 0))
                        onSave(updated)
                        dismiss()
                    }
                }
            }
        }
    }
}
