import SwiftUI
import PDFKit
import UniformTypeIdentifiers
import UIKit

// MARK: - PDF 渲染

enum PDFImporter {

    /// ⚠️ PDFKit 的 PDFDocument / PDFPage **不是线程安全的**。
    /// 以前用 DispatchQueue.global 并发渲染，PDFKit 经常直接返回 nil，
    /// 表现就是「PDF 导不进去」。这里统一排队，一次只渲染一页。
    private static let renderQueue = DispatchQueue(
        label: "com.pagestudio.pdf.render",
        qos: .userInitiated
    )

    /// PDF 总页数
    static func pageCount(url: URL) -> Int {
        guard let doc = PDFDocument(url: url) else { return 0 }
        return doc.pageCount
    }

    /// 把第 index 页渲染成位图
    /// - Parameter maxPixel: **长边像素数**（真正控制到像素，不再乘屏幕倍率）
    static func renderPage(url: URL, index: Int, maxPixel: CGFloat) -> UIImage? {
        var result: UIImage?
        renderQueue.sync {
            result = autoreleasepool { renderPageLocked(url: url,
                                                        index: index,
                                                        maxPixel: maxPixel) }
        }
        return result
    }

    private static func renderPageLocked(url: URL,
                                         index: Int,
                                         maxPixel: CGFloat) -> UIImage? {
        guard let doc = PDFDocument(url: url),
              let page = doc.page(at: index) else { return nil }

        let bounds = page.bounds(for: .mediaBox)
        let w = max(bounds.width, 1)
        let h = max(bounds.height, 1)

        // 自己算像素，绝不交给 thumbnail 去乘屏幕倍率
        let scale = min(maxPixel / max(w, h), 8)
        let pixelW = max((w * scale).rounded(), 1)
        let pixelH = max((h * scale).rounded(), 1)

        // 目标像素上限保护：超过 4000 万像素就直接放弃这一页，别把内存撑爆
        guard pixelW * pixelH <= 40_000_000 else { return nil }

        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1          // 像素 = 我们自己给的尺寸，不再乘倍率
        format.opaque = true

        let renderer = UIGraphicsImageRenderer(size: CGSize(width: pixelW,
                                                            height: pixelH),
                                               format: format)

        return renderer.image { ctx in
            let cg = ctx.cgContext

            // 白底
            cg.setFillColor(UIColor.white.cgColor)
            cg.fill(CGRect(x: 0, y: 0, width: pixelW, height: pixelH))

            // PDF 原点在左下角，UIKit 在左上角，翻转坐标系
            cg.saveGState()
            cg.translateBy(x: 0, y: pixelH)
            cg.scaleBy(x: scale, y: -scale)
            // draw(with:to:) 会自己处理页面旋转和裁剪
            page.draw(with: .mediaBox, to: cg)
            cg.restoreGState()
        }
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

    @MainActor
    private func startImport() {
        guard pageCount > 0 else { return }

        isImporting = true
        progress = 0
        finishedCount = 0

        let total = pageCount
        let url = fileURL
        let title = newBookTitle
        let targetID = targetBookID

        // ⚠️ 必须 @MainActor：这里会写 @State（progress / finishedCount），
        //    不在主线程写 @State 是未定义行为，会出各种诡异问题。
        Task { @MainActor in
            var imported: [Page] = []

            for i in 0..<total {
                let page: Page? = await withCheckedContinuation { cont in
                    DispatchQueue.global(qos: .userInitiated).async {
                        autoreleasepool {
                            guard let image = PDFImporter.renderPage(url: url,
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

                if let page { imported.append(page) }

                finishedCount = i + 1
                progress = Double(i + 1) / Double(total)
            }

            finish(pages: imported, title: title, targetID: targetID)
        }
    }

    @MainActor
    private func finish(pages: [Page], title: String, targetID: UUID?) {
        isImporting = false

        guard !pages.isEmpty else {
            errorText = "PDF 中没有可导入的页面（渲染失败）"
            return
        }

        if let targetID, let existing = library.book(id: targetID) {
            var updated = existing
            updated.pages.append(contentsOf: pages)
            library.update(updated)
        } else {
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
