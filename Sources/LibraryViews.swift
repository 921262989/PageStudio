import SwiftUI
import UniformTypeIdentifiers
import PencilKit

// MARK: - 书架上的弹窗

enum LibrarySheet: Identifiable {
    case settings
    case photoImport
    case edit(Book)

    var id: String {
        switch self {
        case .settings:     return "settings"
        case .photoImport:  return "photoImport"
        case .edit(let b):  return "edit-\(b.id.uuidString)"
        }
    }
}

struct LibraryView: View {
    @EnvironmentObject private var library: LibraryStore
    @EnvironmentObject private var settingsStore: AppSettingsStore
    @StateObject private var layerStore = LayerStore()

    @State private var path = NavigationPath()
    @State private var showNewBookAlert = false
    @State private var newBookTitle = ""
    @State private var carouselIndex = 0

    @State private var activeSheet: LibrarySheet?

    /// 上滑出来的那三个按钮
    @State private var actionBook: Book?
    @State private var showActionMenu = false
    @State private var showMoreMenu = false

    /// 加密
    @State private var lockBook: Book?
    @State private var lockInput = ""
    @State private var showLockPrompt = false
    @State private var setLockBook: Book?
    @State private var newLockInput = ""
    @State private var showSetLockPrompt = false

    /// 导出 PDF
    @State private var exportURL: URL?
    @State private var showExportShare = false
    @State private var busyText: String?

    private var theme: ReaderTheme { settingsStore.settings.readerTheme }

    var body: some View {
        NavigationStack(path: $path) {
            ZStack {
                ReaderBackground(theme: theme)

                Group {
                    if library.books.isEmpty {
                        emptyState
                    } else {
                        shelf
                    }
                }

                if let busyText {
                    busyOverlay(busyText)
                }
            }
            .navigationTitle("我的书架")
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button { activeSheet = .settings } label: {
                        Image(systemName: "gearshape")
                    }
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Menu {
                        Button {
                            newBookTitle = ""
                            showNewBookAlert = true
                        } label: {
                            Label("新建空白画册", systemImage: "book")
                        }

                        Divider()

                        Button {
                            activeSheet = .photoImport
                        } label: {
                            Label("批量导入图片", systemImage: "photo.stack")
                        }
                    } label: {
                        Image(systemName: "plus")
                    }
                }
            }
            .navigationDestination(for: UUID.self) { id in
                BookReaderView(bookID: id)
            }
            .alert("新建画册", isPresented: $showNewBookAlert) {
                TextField("画册名称", text: $newBookTitle)
                Button("取消", role: .cancel) {}
                Button("创建") {
                    library.createBook(title: newBookTitle)
                    carouselIndex = 0
                }
            }
        }
        // 上滑：三个按钮
        .confirmationDialog(actionBook?.title ?? "画册",
                            isPresented: $showActionMenu,
                            titleVisibility: .visible) {
            Button("菜单") { showMoreMenu = true }
            Button("编辑") {
                if let b = actionBook { activeSheet = .edit(b) }
            }
            Button("删除", role: .destructive) {
                if let b = actionBook { library.delete(b) }
            }
            Button("取消", role: .cancel) { }
        }
        // 菜单展开
        .confirmationDialog("菜单",
                            isPresented: $showMoreMenu,
                            titleVisibility: .visible) {
            Button(BookLock.isLocked(actionBook?.id ?? UUID()) ? "关闭密码" : "设置密码") {
                guard let b = actionBook else { return }
                if BookLock.isLocked(b.id) {
                    BookLock.setPassword(nil, for: b.id)
                } else {
                    setLockBook = b
                    newLockInput = ""
                    showSetLockPrompt = true
                }
            }
            Button("复制画册") {
                if let b = actionBook {
                    let copy = library.duplicate(b)
                    if let idx = library.books.firstIndex(where: { $0.id == copy.id }) {
                        carouselIndex = idx
                    }
                }
            }
            Button("导出 PDF") {
                if let b = actionBook { exportPDF(b) }
            }
            Button("取消", role: .cancel) { }
        }
        // 设置密码
        .alert("设置密码", isPresented: $showSetLockPrompt) {
            SecureField("输入密码", text: $newLockInput)
            Button("取消", role: .cancel) { }
            Button("确定") {
                if let b = setLockBook,
                   !newLockInput.trimmingCharacters(in: .whitespaces).isEmpty {
                    BookLock.setPassword(newLockInput, for: b.id)
                }
                setLockBook = nil
                newLockInput = ""
            }
        } message: {
            Text("下次打开这本画册需要输入密码。")
        }
        // 打开加密画册
        .alert("请输入密码", isPresented: $showLockPrompt) {
            SecureField("密码", text: $lockInput)
            Button("取消", role: .cancel) {
                lockBook = nil
                lockInput = ""
            }
            Button("打开") {
                if let b = lockBook, BookLock.verify(lockInput, for: b.id) {
                    path.append(b.id)
                }
                lockBook = nil
                lockInput = ""
            }
        }
        .sheet(item: $activeSheet) { sheet in
            switch sheet {
            case .settings:
                SettingsView()
                    .environmentObject(settingsStore)

            case .photoImport:
                PhotoImportSheet()
                    .environmentObject(library)

            case .edit(let book):
                BookEditView(book: book)
                    .environmentObject(library)
            }
        }
        .sheet(isPresented: $showExportShare) {
            if let exportURL {
                ShareSheet(items: [exportURL])
            }
        }
        .preferredColorScheme(.dark)
        .onChange(of: library.books.count) { count in
            carouselIndex = min(max(carouselIndex, 0), max(count - 1, 0))
        }
    }

    // MARK: - 书架

    private var shelf: some View {
        VStack(spacing: 0) {
            BookCarousel(books: library.books,
                         index: $carouselIndex,
                         onOpen: { book in
                             if BookLock.isLocked(book.id) {
                                 lockBook = book
                                 lockInput = ""
                                 showLockPrompt = true
                             } else {
                                 path.append(book.id)
                             }
                         },
                         onSwipeUp: { book in
                             actionBook = book
                             showActionMenu = true
                         })
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            currentBookInfo
        }
    }

    @ViewBuilder
    private var currentBookInfo: some View {
        if library.books.indices.contains(carouselIndex) {
            let book = library.books[carouselIndex]
            VStack(spacing: 4) {
                HStack(spacing: 6) {
                    Text(book.title)
                        .font(.headline)
                        .lineLimit(1)
                        .foregroundStyle(.white)

                    if BookLock.isLocked(book.id) {
                        Image(systemName: "lock.fill")
                            .font(.caption)
                            .foregroundStyle(.white.opacity(0.7))
                    }
                }

                HStack(spacing: 6) {
                    Text("\(book.pages.count) 页")
                    if !book.outline.isEmpty {
                        Text("·")
                        Text("\(book.outline.count) 条目")
                    }
                }
                .font(.caption)
                .foregroundStyle(.white.opacity(0.7))

                Text("上滑封面可打开菜单")
                    .font(.caption2)
                    .foregroundStyle(.white.opacity(0.45))
                    .padding(.top, 2)
            }
            .padding(.horizontal, 24)
            .padding(.bottom, 24)
        }
    }

    private var emptyState: some View {
        VStack(spacing: 18) {
            Image(systemName: "books.vertical")
                .font(.system(size: 56))
                .foregroundStyle(.white.opacity(0.5))

            Text("书架还是空的")
                .font(.title3)
                .foregroundStyle(.white)

            Button("新建第一本画册") {
                newBookTitle = ""
                showNewBookAlert = true
            }
            .buttonStyle(.borderedProminent)

            Button("批量导入图片") {
                activeSheet = .photoImport
            }
            .buttonStyle(.bordered)
            .tint(.white)
        }
    }

    @ViewBuilder
    private func busyOverlay(_ text: String) -> some View {
        ZStack {
            Color.black.opacity(0.55).ignoresSafeArea()
            VStack(spacing: 14) {
                ProgressView()
                Text(text)
                    .font(.footnote)
                    .foregroundStyle(.white)
            }
            .padding(26)
            .background(.ultraThinMaterial,
                        in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        }
    }

    // MARK: - 导出 PDF

    private func exportPDF(_ book: Book) {
        busyText = "正在导出 PDF…"

        DispatchQueue.main.async {
            let url = PDFExporter.export(book: book,
                                         layerStore: layerStore,
                                         theme: theme)
            busyText = nil

            guard let url else { return }
            exportURL = url
            showExportShare = true
        }
    }
}

// MARK: - 分享面板

struct ShareSheet: UIViewControllerRepresentable {
    let items: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }

    func updateUIViewController(_ controller: UIActivityViewController,
                                context: Context) { }
}

// MARK: - 编辑画册（名称 / 封面 / 内页样式）

struct BookEditView: View {
    @EnvironmentObject private var library: LibraryStore
    @Environment(\.dismiss) private var dismiss

    let book: Book

    @State private var title: String
    @State private var rule: PageRuleStyle
    @State private var showCoverPicker = false
    @State private var draftBook: Book

    init(book: Book) {
        self.book = book
        _title = State(initialValue: book.title)
        _rule = State(initialValue: PageRuleStore.load(for: book.id))
        _draftBook = State(initialValue: book)
    }

    private let previewSize = CGSize(width: 150, height: 210)

    var body: some View {
        NavigationStack {
            Form {
                Section("名称") {
                    TextField("画册名称", text: $title)
                        .onChange(of: title) { newValue in
                            draftBook.title = newValue
                            library.update(draftBook)
                        }
                }

                Section("封面") {
                    HStack(spacing: 16) {
                        NotebookCoverView(book: draftBook, width: 88)

                        VStack(alignment: .leading, spacing: 8) {
                            Text(draftBook.customCoverImage == nil
                                 ? draftBook.coverStyle.displayName
                                 : "自定义图片")
                                .font(.subheadline)
                            Button {
                                showCoverPicker = true
                            } label: {
                                Label("更换封面", systemImage: "paintpalette")
                            }
                            .buttonStyle(.bordered)
                        }
                        Spacer()
                    }
                    .padding(.vertical, 4)
                }

                Section("内页样式") {
                    Picker("样式", selection: $rule.kind) {
                        ForEach(PageRuleKind.allCases) { kind in
                            Label(kind.displayName, systemImage: kind.systemImage)
                                .tag(kind)
                        }
                    }
                    .pickerStyle(.segmented)
                    .onChange(of: rule.kind) { _ in saveRule() }

                    if rule.kind != .none {
                        VStack(alignment: .leading, spacing: 6) {
                            HStack {
                                Text("间距")
                                Spacer()
                                Text("\(Int(rule.spacing))")
                                    .foregroundStyle(.secondary)
                                    .monospacedDigit()
                            }
                            Slider(value: $rule.spacing, in: 12...80, step: 1)
                                .onChange(of: rule.spacing) { _ in saveRule() }
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
                                .onChange(of: rule.lineWidth) { _ in saveRule() }
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
                                .onChange(of: rule.opacity) { _ in saveRule() }
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
                            // PaperView 的 theme 本来就是可选参数，直接不传即可
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
                }
            }
            .navigationTitle("编辑画册")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("完成") {
                        library.update(draftBook)
                        dismiss()
                    }
                }
            }
            .sheet(isPresented: $showCoverPicker) {
                CoverPickerView(
                    bookID: draftBook.id,
                    initialStyle: draftBook.coverStyle,
                    hasCustomImage: draftBook.customCoverImage != nil,
                    onStyle: { style in
                        draftBook.coverStyle = style
                        library.update(draftBook)
                    },
                    onCustomImage: { name in
                        draftBook.customCoverImage = name
                        library.update(draftBook)
                    }
                )
            }
        }
    }

    private var colorBinding: Binding<Color> {
        Binding(
            get: { rule.color },
            set: { newValue in
                rule.colorHex = newValue.hexString
                saveRule()
            }
        )
    }

    private func saveRule() {
        PageRuleStore.save(rule, for: book.id)
    }
}
