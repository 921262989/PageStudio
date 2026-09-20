import SwiftUI
import PhotosUI

// MARK: - 封面配色

enum CoverStyle: String, Codable, CaseIterable, Identifiable, Hashable {
    case indigo, crimson, forest, ocean, sunset, plum, charcoal, kraft, sky, rose

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .indigo:   return "靛蓝"
        case .crimson:  return "绯红"
        case .forest:   return "墨绿"
        case .ocean:    return "深海"
        case .sunset:   return "落日"
        case .plum:     return "梅紫"
        case .charcoal: return "炭黑"
        case .kraft:    return "牛皮"
        case .sky:      return "天青"
        case .rose:     return "藕荷"
        }
    }

    var base: Color {
        switch self {
        case .indigo:   return Color(red: 0.20, green: 0.24, blue: 0.45)
        case .crimson:  return Color(red: 0.55, green: 0.14, blue: 0.18)
        case .forest:   return Color(red: 0.13, green: 0.32, blue: 0.24)
        case .ocean:    return Color(red: 0.08, green: 0.28, blue: 0.42)
        case .sunset:   return Color(red: 0.72, green: 0.36, blue: 0.18)
        case .plum:     return Color(red: 0.34, green: 0.18, blue: 0.40)
        case .charcoal: return Color(red: 0.17, green: 0.17, blue: 0.19)
        case .kraft:    return Color(red: 0.62, green: 0.51, blue: 0.36)
        case .sky:      return Color(red: 0.20, green: 0.45, blue: 0.62)
        case .rose:     return Color(red: 0.66, green: 0.42, blue: 0.50)
        }
    }
}

// MARK: - 书架上的一本笔记本

struct NotebookCoverView: View {
    let book: Book
    var width: CGFloat

    private var height: CGFloat { width * 1.38 }

    var body: some View {
        ZStack(alignment: .leading) {
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(
                    LinearGradient(colors: [book.coverStyle.base,
                                            book.coverStyle.base.opacity(0.76)],
                                   startPoint: .topLeading,
                                   endPoint: .bottomTrailing)
                )

            if let name = book.customCoverImage {
                StoredImage(name: name, maxPixel: 900) { image in
                    image.resizable().scaledToFill()
                }
                .frame(width: width, height: height)
                .clipped()
                .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
                .opacity(0.94)
            }

            // 书脊
            LinearGradient(colors: [.black.opacity(0.38), .clear],
                           startPoint: .leading, endPoint: .trailing)
                .frame(width: width * 0.15)
                .allowsHitTesting(false)

            if book.customCoverImage == nil {
                VStack(alignment: .leading, spacing: 6) {
                    Text(book.title)
                        .font(.system(size: max(width * 0.100, 12), weight: .semibold))
                        .foregroundStyle(.white)
                        .multilineTextAlignment(.leading)
                        .lineLimit(3)
                    Spacer(minLength: 4)
                    Text("\(book.pages.count) 页")
                        .font(.system(size: max(width * 0.062, 9)))
                        .foregroundStyle(.white.opacity(0.72))
                }
                .padding(.leading, width * 0.19)
                .padding(.trailing, width * 0.10)
                .padding(.vertical, width * 0.13)
                .allowsHitTesting(false)
            }

            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .stroke(Color.white.opacity(0.13), lineWidth: 1)
        }
        .frame(width: width, height: height)
        .shadow(color: .black.opacity(0.30), radius: 8, x: 2, y: 5)
    }
}

// MARK: - 封面选择器

struct CoverPickerView: View {
    @Environment(\.dismiss) private var dismiss

    let initialStyle: CoverStyle
    let hasCustomImage: Bool
    let onStyle: (CoverStyle) -> Void
    let onCustomImage: (String?) -> Void

    @State private var selectedStyle: CoverStyle
    @State private var photoItem: PhotosPickerItem?

    init(initialStyle: CoverStyle,
         hasCustomImage: Bool,
         onStyle: @escaping (CoverStyle) -> Void,
         onCustomImage: @escaping (String?) -> Void) {
        self.initialStyle = initialStyle
        self.hasCustomImage = hasCustomImage
        self.onStyle = onStyle
        self.onCustomImage = onCustomImage
        _selectedStyle = State(initialValue: initialStyle)
    }

    private let columns = [GridItem(.adaptive(minimum: 96, maximum: 130), spacing: 16)]

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    Text("纯色封面")
                        .font(.headline)
                        .padding(.horizontal, 20)

                    LazyVGrid(columns: columns, spacing: 16) {
                        ForEach(CoverStyle.allCases) { style in
                            VStack(spacing: 6) {
                                RoundedRectangle(cornerRadius: 8, style: .continuous)
                                    .fill(LinearGradient(colors: [style.base,
                                                                  style.base.opacity(0.74)],
                                                         startPoint: .topLeading,
                                                         endPoint: .bottomTrailing))
                                    .frame(height: 120)
                                    .overlay(
                                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                                            .stroke(selectedStyle == style && !hasCustomImage
                                                    ? Color.accentColor : Color.clear,
                                                    lineWidth: 3)
                                    )
                                    .shadow(color: .black.opacity(0.18), radius: 4, y: 2)
                                Text(style.displayName)
                                    .font(.caption)
                            }
                            .onTapGesture {
                                selectedStyle = style
                                onStyle(style)
                            }
                        }
                    }
                    .padding(.horizontal, 20)

                    Divider().padding(.vertical, 8)

                    VStack(alignment: .leading, spacing: 12) {
                        Text("自定义封面图片")
                            .font(.headline)

                        PhotosPicker(selection: $photoItem, matching: .images) {
                            Label("从相册选择图片", systemImage: "photo")
                        }
                        .buttonStyle(.borderedProminent)

                        if hasCustomImage {
                            Button(role: .destructive) {
                                onCustomImage(nil)
                                dismiss()
                            } label: {
                                Label("清除自定义封面", systemImage: "trash")
                            }
                        }
                    }
                    .padding(.horizontal, 20)
                }
                .padding(.vertical, 16)
            }
            .navigationTitle("更换封面")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("完成") { dismiss() }
                }
            }
            .onChange(of: photoItem) { item in
                guard let item else { return }
                Task { await applyCustomImage(item) }
            }
        }
    }

    private func applyCustomImage(_ item: PhotosPickerItem) async {
        guard let data = try? await item.loadTransferable(type: Data.self) else { return }
        let ext = ImageFileType.fileExtension(for: data)
        if let name = try? FileStorage.saveImageData(data, preferredExtension: ext) {
            onCustomImage(name)
        }
        photoItem = nil
        dismiss()
    }
}
