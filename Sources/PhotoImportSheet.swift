import SwiftUI
import PhotosUI
import UIKit

/// 批量导入图片时的排版方式
enum PhotoImportLayout: String, CaseIterable, Identifiable {
    /// 每张图占一页
    case onePerPage
    /// 每张图占一个完整跨页（"两页一张"）
    case onePerSpread

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .onePerPage:   return "每张占一页"
        case .onePerSpread: return "每张占一个跨页"
        }
    }

    var descriptionText: String {
        switch self {
        case .onePerPage:   return "每张图片单独一页，双页模式左右各一张"
        case .onePerSpread: return "每张图片横向铺满整个跨页，适合宽幅图"
        }
    }

    var occupiesSpread: Bool {
        self == .onePerSpread
    }
}

struct PhotoImportSheet: View {
    @EnvironmentObject private var library: LibraryStore
    @Environment(\.dismiss) private var dismiss

    @State private var items: [PhotosPickerItem] = []
    @State private var layout: PhotoImportLayout = .onePerPage
    @State private var useFirstAsCover = true
    @State private var bookTitle = ""

    @State private var isImporting = false
    @State private var progress: Double = 0
    @State private var finishedCount = 0
    @State private var errorText: String? = nil
    @State private var finished = false
    @State private var createdBookTitle: String = ""

    var body: some View {
        NavigationStack {
            Form {
                // MARK: 选图
                Section {
                    PhotosPicker(selection: $items,
                                 maxSelectionCount: 500,
                                 matching: .images) {
                        HStack {
                            Label(items.isEmpty ? "选择图片" : "重新选择",
                                  systemImage: "photo.on.rectangle.angled")
                            Spacer()
                            if !items.isEmpty {
                                Text("已选 \(items.count) 张")
                                    .font(.footnote)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                    .disabled(isImporting)
                } header: {
                    Text("图片")
                }

                // MARK: 排版
                Section {
                    Picker("排版", selection: $layout) {
                        ForEach(PhotoImportLayout.allCases) { l in
                            Text(l.displayName).tag(l)
                        }
                    }
                    .pickerStyle(.segmented)
                    .disabled(isImporting)

                    Text(layout.descriptionText)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                } header: {
                    Text("排版方式")
                }

                // MARK: 封面
                Section {
                    Toggle("用第一张图作为封面", isOn: $useFirstAsCover)
                        .disabled(isImporting)
                } footer: {
                    Text("关闭的话，会按标题自动配一个纯色封面，之后也能在书架长按更换。")
                }

                // MARK: 名称
                Section("画册名称") {
                    TextField("画册名称", text: $bookTitle)
                        .disabled(isImporting)
                }

                // MARK: 进度 / 完成
                if isImporting {
                    Section("进度") {
                        VStack(alignment: .leading, spacing: 10) {
                            ProgressView(value: progress)
                            Text("正在导入 \(finishedCount) / \(items.count) 张")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        .padding(.vertical, 4)
                    }
                } else if finished {
                    Section {
                        Label("导入完成", systemImage: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                        Text("已创建画册「\(createdBookTitle)」，共 \(finishedCount) 页")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                } else {
                    Section {
                        Button {
                            startImport()
                        } label: {
                            Label("创建画册并导入", systemImage: "square.and.arrow.down")
                        }
                        .disabled(items.isEmpty)
                    } footer: {
                        Text("会把选中的图片全部复制进画册，原图不会被修改。")
                    }
                }
            }
            .navigationTitle("批量导入图片")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    if finished {
                        Button("完成") { dismiss() }
                    } else {
                        Button("取消") { dismiss() }
                            .disabled(isImporting)
                    }
                }
            }
            .interactiveDismissDisabled(isImporting)
            .onChange(of: items) { newItems in
                if bookTitle.isEmpty, !newItems.isEmpty {
                    bookTitle = "画册 \(library.books.count + 1)"
                }
            }
            .alert("导入失败",
                   isPresented: Binding(
                        get: { errorText != nil },
                        set: { if !$0 { errorText = nil } }
                   )) {
                Button("好", role: .cancel) { errorText = nil }
            } message: {
                Text(errorText ?? "")
            }
        }
    }

    // MARK: - 执行导入

    private func startImport() {
        guard !items.isEmpty else { return }

        isImporting = true
        progress = 0
        finishedCount = 0

        let sourceItems = items
        let occupies = layout.occupiesSpread
        let title = bookTitle.trimmingCharacters(in: .whitespacesAndNewlines)

        Task {
            var newPages: [Page] = []
            var firstFileName: String? = nil

            for (index, item) in sourceItems.enumerated() {
                let saved: String? = await loadAndSave(item)
                if let saved {
                    if firstFileName == nil { firstFileName = saved }
                    newPages.append(Page.image(fileName: saved,
                                               occupiesSpread: occupies))
                }
                finishedCount = index + 1
                progress = Double(index + 1) / Double(sourceItems.count)
            }

            finish(pages: newPages,
                   firstFileName: firstFileName,
                   title: title,
                   useCover: useFirstAsCover)
        }
    }

    private func loadAndSave(_ item: PhotosPickerItem) async -> String? {
        guard let data = try? await item.loadTransferable(type: Data.self) else {
            return nil
        }
        let ext = ImageFileType.fileExtension(for: data)
        return try? FileStorage.saveImageData(data, preferredExtension: ext)
    }

    private func finish(pages: [Page],
                        firstFileName: String?,
                        title: String,
                        useCover: Bool) {
        isImporting = false

        guard !pages.isEmpty else {
            errorText = "没有导入任何图片"
            return
        }

        let finalTitle = title.isEmpty
            ? "画册 \(library.books.count + 1)"
            : title

        let created = library.createBook(title: finalTitle)

        var updated = created
        updated.pages = pages
        if useCover, let cover = firstFileName {
            updated.customCoverImage = cover
        }
        library.update(updated)

        createdBookTitle = finalTitle
        finishedCount = pages.count
        finished = true
    }
}
