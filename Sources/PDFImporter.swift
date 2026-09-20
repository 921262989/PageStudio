import SwiftUI
import PDFKit
import UniformTypeIdentifiers
import UIKit

// MARK: - PDF 渲染

enum PDFImporter {

    /// PDF 总页数
    static func pageCount(url: URL) -> Int {
        guard let doc = PDFDocument(url: url) else { return 0 }
        return doc.pageCount
    }

    /// 把第 index 页渲染成位图
    /// - Parameter maxPixel: 长边最大像素数
    static func renderPage(url: URL, index: Int, maxPixel: CGFloat) -> UIImage? {
        guard let doc = PDFDocument(url: url),
              let page = doc.page(at: index) else { return nil }

        let bounds = page.bounds(for: .mediaBox)
        let w = max(bounds.width, 1)
        let h = max(bounds.height, 1)
        let scale = maxPixel / max(w, h)
        let size = CGSize(width: w * scale, height: h * scale)

        // thumbnail 会自动处理页面旋转与裁剪
        return page.thumbnail(of: size, for: .mediaBox)
    }
}

// MARK: - 文件引用（给 sheet(item:) 用）

struct PDFFileRef: Identifiable {
    let id = UUID()
    let url: URL
}

// MARK: - 导入界面

struct PDFImportSheet: View {
    let fileURL: URL

    @EnvironmentObject private var library: LibraryStore
    @Environment(\.dismiss) private var dismiss

    @State private var targetBookID: UUID? = nil
    @State private var newBookTitle = ""
    @State private var pageCount = 0
    @State private var isImporting = false
    @State private var progress: Double = 0
    @State private var finishedCount = 0
    @State private var errorText: String? = nil
    @State private var finished = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    LabeledContent("文件", value: fileURL.lastPathComponent)
                    LabeledContent("总页数", value: "\(pageCount) 页")
                }

                Section("导入到") {
                    Picker("导入到", selection: $targetBookID) {
                        Text("新建画册").tag(UUID?.none)
                        ForEach(library.books) { b in
                            Text(b.title).tag(Optional(b.id))
                        }
                    }
                }

                if targetBookID == nil {
                    Section("新画册名称") {
                        TextField("画册名称", text: $newBookTitle)
                    }
                }

                if isImporting {
                    Section("进度") {
                        VStack(alignment: .leading, spacing: 10) {
                            ProgressView(value: progress)
                            Text("正在渲染 \(finishedCount) / \(pageCount) 页")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        .padding(.vertical, 4)
                    }
                } else if finished {
                    Section {
                        Label("导入完成", systemImage: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                        Text("共导入 \(finishedCount) 页")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                } else {
                    Section {
                        Button {
                            startImport()
                        } label: {
                            Label("开始导入", systemImage: "square.and.arrow.down")
                        }
                        .disabled(pageCount == 0)
                    } footer: {
                        Text("每一页 PDF 会被渲染成一张高清图片，作为画册的一页。导入后可正常批注与绘制。")
                    }
                }
            }
            .navigationTitle("导入 PDF")
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
            .task {
                pageCount = PDFImporter.pageCount(url: fileURL)
                if newBookTitle.isEmpty {
                    newBookTitle = fileURL.deletingPathExtension().lastPathComponent
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
        guard pageCount > 0 else { return }

        isImporting = true
        progress = 0
        finishedCount = 0

        let total = pageCount
        let url = fileURL
        let title = newBookTitle
        let targetID = targetBookID

        Task {
            var imported: [Page] = []

            for i in 0..<total {
                let page: Page? = await withCheckedContinuation { cont in
                    DispatchQueue.global(qos: .userInitiated).async {
                        guard let image = PDFImporter.renderPage(url: url,
                                                                 index: i,
                                                                 maxPixel: 2400),
                              let data = image.jpegData(compressionQuality: 0.92),
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

                if let page { imported.append(page) }

                finishedCount = i + 1
                progress = Double(i + 1) / Double(total)
            }

            finish(pages: imported, title: title, targetID: targetID)
        }
    }

    private func finish(pages: [Page], title: String, targetID: UUID?) {
        isImporting = false

        guard !pages.isEmpty else {
            errorText = "PDF 中没有可导入的页面"
            return
        }

        if let targetID, let existing = library.book(id: targetID) {
            // 追加到已有画册末尾
            var updated = existing
            updated.pages.append(contentsOf: pages)
            library.update(updated)
        } else {
            // 新建画册
            let created = library.createBook(title: title.isEmpty
                                             ? "PDF 画册" : title)
            var updated = created
            updated.pages = pages
            library.update(updated)
        }

        finishedCount = pages.count
        finished = true
    }
}
