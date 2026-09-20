import SwiftUI
import PhotosUI

// MARK: - 封面配色

enum CoverStyle: String, Codable, CaseIterable, Identifiable, Hashable {
    // 纯色
    case indigo, crimson, forest, ocean, sunset, plum, charcoal, kraft, sky, rose
    // 自选颜色（颜色存在 UserDefaults，key = coverHex-<bookID>）
    case custom
    // 花纹
    case patternDots, patternStripes, patternGrid
    case patternWaves, patternMarble, patternLinen

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .indigo:          return "靛蓝"
        case .crimson:         return "绯红"
        case .forest:          return "墨绿"
        case .ocean:           return "深海"
        case .sunset:          return "落日"
        case .plum:            return "梅紫"
        case .charcoal:        return "炭黑"
        case .kraft:           return "牛皮"
        case .sky:             return "天青"
        case .rose:            return "藕荷"
        case .custom:          return "自选颜色"
        case .patternDots:     return "波点"
        case .patternStripes:  return "斜纹"
        case .patternGrid:     return "方格"
        case .patternWaves:    return "水波"
        case .patternMarble:   return "大理石"
        case .patternLinen:    return "亚麻"
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
        case .custom:          return Color(red: 0.30, green: 0.34, blue: 0.44)
        case .patternDots:     return Color(red: 0.21, green: 0.27, blue: 0.40)
        case .patternStripes:  return Color(red: 0.16, green: 0.33, blue: 0.28)
        case .patternGrid:     return Color(red: 0.36, green: 0.26, blue: 0.20)
        case .patternWaves:    return Color(red: 0.10, green: 0.30, blue: 0.44)
        case .patternMarble:   return Color(red: 0.87, green: 0.86, blue: 0.84)
        case .patternLinen:    return Color(red: 0.78, green: 0.72, blue: 0.62)
        }
    }

    /// 花纹 / 浅色封面上的文字该用黑还是白
    var prefersDarkText: Bool {
        switch self {
        case .patternMarble, .patternLinen, .kraft:
            return true
        default:
            return false
        }
    }
}

// MARK: - 自选颜色的存取（不动 Book 结构）

enum CoverColorStore {
    static func key(for bookID: UUID) -> String { "coverHex-\(bookID.uuidString)" }

    static func hex(for bookID: UUID) -> String? {
        UserDefaults.standard.string(forKey: key(for: bookID))
    }

    static func setHex(_ hex: String?, for bookID: UUID) {
        let k = key(for: bookID)
        if let hex {
            UserDefaults.standard.set(hex, forKey: k)
        } else {
            UserDefaults.standard.removeObject(forKey: k)
        }
    }

    static func color(for bookID: UUID) -> Color? {
        guard let hex = hex(for: bookID) else { return nil }
        return Color(hex: hex)
    }
}

// MARK: - 花纹绘制

private struct BookPattern: View {
    let style: CoverStyle

    var body: some View {
        Canvas { ctx, size in
            switch style {
            case .patternDots:     drawDots(ctx, size)
            case .patternStripes:  drawStripes(ctx, size)
            case .patternGrid:     drawGrid(ctx, size)
            case .patternWaves:    drawWaves(ctx, size)
            case .patternMarble:   drawMarble(ctx, size)
            case .patternLinen:    drawLinen(ctx, size)
            default:               break
            }
        }
    }

    private var ink: Color {
        style.prefersDarkText
            ? Color.black.opacity(0.16)
            : Color.white.opacity(0.16)
    }

    private func drawDots(_ ctx: GraphicsContext, _ size: CGSize) {
        let step: CGFloat = 18
        let r: CGFloat = 2.2
        var row = 0
        var y: CGFloat = 0
        while y < size.height + step {
            var x: CGFloat = (row % 2 == 0) ? 0 : step / 2
            while x < size.width + step {
                let rect = CGRect(x: x - r, y: y - r, width: r * 2, height: r * 2)
                ctx.fill(Path(ellipseIn: rect), with: .color(ink))
                x += step
            }
            y += step
            row += 1
        }
    }

    private func drawStripes(_ ctx: GraphicsContext, _ size: CGSize) {
        let step: CGFloat = 16
        let w: CGFloat = 5
        var x = -size.height
        while x < size.width + size.height {
            var p = Path()
            p.move(to: CGPoint(x: x, y: 0))
            p.addLine(to: CGPoint(x: x + size.height, y: size.height))
            ctx.stroke(p, with: .color(ink), lineWidth: w)
            x += step + w
        }
    }

    private func drawGrid(_ ctx: GraphicsContext, _ size: CGSize) {
        let step: CGFloat = 20
        var x: CGFloat = 0
        while x <= size.width {
            var p = Path()
            p.move(to: CGPoint(x: x, y: 0))
            p.addLine(to: CGPoint(x: x, y: size.height))
            ctx.stroke(p, with: .color(ink), lineWidth: 1.2)
            x += step
        }
        var y: CGFloat = 0
        while y <= size.height {
            var p = Path()
            p.move(to: CGPoint(x: 0, y: y))
            p.addLine(to: CGPoint(x: size.width, y: y))
            ctx.stroke(p, with: .color(ink), lineWidth: 1.2)
            y += step
        }
    }

    private func drawWaves(_ ctx: GraphicsContext, _ size: CGSize) {
        let amplitude: CGFloat = 5
        let wavelength: CGFloat = 44
        let step: CGFloat = 18
        var y: CGFloat = 0
        while y < size.height + step {
            var p = Path()
            p.move(to: CGPoint(x: 0, y: y))
            var x: CGFloat = 0
            while x <= size.width {
                let ny = y + sin((x / wavelength) * .pi * 2) * amplitude
                p.addLine(to: CGPoint(x: x, y: ny))
                x += 4
            }
            ctx.stroke(p, with: .color(ink), lineWidth: 1.6)
            y += step
        }
    }

    private func drawMarble(_ ctx: GraphicsContext, _ size: CGSize) {
        var seed: UInt64 = 20240517
        func rnd() -> CGFloat {
            seed = seed &* 6364136223846793005 &+ 1442695040888963407
            return CGFloat((seed >> 33) % 1000) / 1000.0
        }

        for _ in 0..<14 {
            var p = Path()
            let startX = rnd() * size.width
            p.move(to: CGPoint(x: startX, y: -20))
            var x = startX
            var y: CGFloat = -20
            while y < size.height + 20 {
                x += (rnd() - 0.5) * 26
                y += 16
                p.addLine(to: CGPoint(x: x, y: y))
            }
            ctx.stroke(p, with: .color(ink), lineWidth: rnd() * 2 + 0.6)
        }
    }

    private func drawLinen(_ ctx: GraphicsContext, _ size: CGSize) {
        let step: CGFloat = 6
        let fine = ink.opacity(0.7)

        var x: CGFloat = 0
        while x <= size.width {
            var p = Path()
            p.move(to: CGPoint(x: x, y: 0))
            p.addLine(to: CGPoint(x: x, y: size.height))
            ctx.stroke(p, with: .color(fine), lineWidth: 0.8)
            x += step
        }
        var y: CGFloat = 0
        while y <= size.height {
            var p = Path()
            p.move(to: CGPoint(x: 0, y: y))
            p.addLine(to: CGPoint(x: size.width, y: y))
            ctx.stroke(p, with: .color(fine), lineWidth: 0.8)
            y += step
        }
    }
}

// MARK: - 书架上的一本笔记本

struct NotebookCoverView: View {
    let book: Book
    var width: CGFloat

    private var height: CGFloat { width * 1.38 }

    /// 自选颜色：从 UserDefaults 读（不改 Book 结构）
    private var effectiveBase: Color {
        if book.coverStyle == .custom,
           let c = CoverColorStore.color(for: book.id) {
            return c
        }
        return book.coverStyle.base
    }

    private var textColor: Color {
        if book.coverStyle == .custom {
            return prefersDarkText(for: effectiveBase) ? Color.black.opacity(0.82)
                                                       : .white
        }
        return book.coverStyle.prefersDarkText ? Color.black.opacity(0.82) : .white
    }

    private func prefersDarkText(for color: Color) -> Bool {
        let ui = UIColor(color)
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        guard ui.getRed(&r, green: &g, blue: &b, alpha: &a) else { return false }
        return (0.299 * r + 0.587 * g + 0.114 * b) > 0.6
    }

    var body: some View {
        ZStack(alignment: .leading) {
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(
                    LinearGradient(colors: [effectiveBase,
                                            effectiveBase.opacity(0.76)],
                                   startPoint: .topLeading,
                                   endPoint: .bottomTrailing)
                )

            // 花纹层（纯色封面上没有）
            BookPattern(style: book.coverStyle)
                .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
                .allowsHitTesting(false)

            if let name = book.customCoverImage {
                StoredImage(name: name, maxPixel: 900) { image in
                    image.resizable().scaledToFill()
                }
                .frame(width: width, height: height)
                .clipped()
                .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
                .opacity(0.96)
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
                        .foregroundStyle(textColor)
                        .multilineTextAlignment(.leading)
                        .lineLimit(3)
                    Spacer(minLength: 4)
                    Text("\(book.pages.count) 页")
                        .font(.system(size: max(width * 0.062, 9)))
                        .foregroundStyle(textColor.opacity(0.72))
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

// MARK: - 自定义封面图片的裁剪

struct CoverCropView: View {
    let image: UIImage
    let onDone: (UIImage) -> Void
    let onCancel: () -> Void

    @State private var scale: CGFloat = 1
    @State private var offset: CGSize = .zero
    @State private var baseScale: CGFloat = 1
    @State private var baseOffset: CGSize = .zero

    var body: some View {
        GeometryReader { geo in
            let frame = coverFrame(in: geo.size)

            ZStack {
                Color.black.ignoresSafeArea()

                VStack(spacing: 18) {
                    Spacer(minLength: 0)

                    Image(uiImage: image)
                        .resizable()
                        .scaledToFill()
                        .frame(width: frame.width, height: frame.height)
                        .scaleEffect(scale)
                        .offset(offset)
                        .frame(width: frame.width, height: frame.height)
                        .clipped()
                        .clipShape(RoundedRectangle(cornerRadius: 9,
                                                    style: .continuous))
                        .overlay(
                            RoundedRectangle(cornerRadius: 9, style: .continuous)
                                .stroke(Color.white.opacity(0.55), lineWidth: 1)
                        )

                    Text("拖动调整位置，双指缩放")
                        .font(.caption)
                        .foregroundStyle(.white.opacity(0.7))

                    HStack(spacing: 16) {
                        Button("取消") { onCancel() }
                            .buttonStyle(.bordered)
                            .tint(.white)

                        Button("完成") { render(frame: frame) }
                            .buttonStyle(.borderedProminent)
                    }
                    .padding(.bottom, 28)

                    Spacer(minLength: 0)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .contentShape(Rectangle())
            .gesture(
                SimultaneousGesture(
                    DragGesture()
                        .onChanged { v in
                            offset = CGSize(width: baseOffset.width + v.translation.width,
                                            height: baseOffset.height + v.translation.height)
                        }
                        .onEnded { _ in baseOffset = offset },
                    MagnificationGesture()
                        .onChanged { v in
                            scale = min(max(baseScale * v, 1), 4)
                        }
                        .onEnded { _ in baseScale = scale }
                )
            )
        }
    }

    private func coverFrame(in size: CGSize) -> CGSize {
        let aspect: CGFloat = 0.72
        var w = size.width * 0.62
        var h = w / aspect
        let maxH = size.height * 0.56
        if h > maxH {
            h = maxH
            w = h * aspect
        }
        return CGSize(width: w, height: h)
    }

    private func render(frame: CGSize) {
        let content = ZStack {
            Color.white

            Image(uiImage: image)
                .resizable()
                .scaledToFill()
                .frame(width: frame.width, height: frame.height)
                .scaleEffect(scale)
                .offset(offset)
        }
        .frame(width: frame.width, height: frame.height)
        .clipped()

        let renderer = ImageRenderer(content: content)
        renderer.scale = 2
        renderer.isOpaque = true

        if let ui = renderer.uiImage {
            onDone(ui)
        } else {
            onCancel()
        }
    }
}

// MARK: - 封面选择器

struct CoverPickerView: View {
    @Environment(\.dismiss) private var dismiss

    let bookID: UUID
    let initialStyle: CoverStyle
    let hasCustomImage: Bool
    let onStyle: (CoverStyle) -> Void
    let onCustomImage: (String?) -> Void

    @State private var selectedStyle: CoverStyle
    @State private var photoItem: PhotosPickerItem?

    @State private var customColor: Color
    @State private var cropImage: UIImage?
    @State private var showCropper = false

    @AppStorage("coverPresetHexes") private var presetHexesRaw: String = ""

    init(bookID: UUID,
         initialStyle: CoverStyle,
         hasCustomImage: Bool,
         onStyle: @escaping (CoverStyle) -> Void,
         onCustomImage: @escaping (String?) -> Void) {
        self.bookID = bookID
        self.initialStyle = initialStyle
        self.hasCustomImage = hasCustomImage
        self.onStyle = onStyle
        self.onCustomImage = onCustomImage
        _selectedStyle = State(initialValue: initialStyle)
        _customColor = State(initialValue: CoverColorStore.color(for: bookID)
                             ?? Color(red: 0.30, green: 0.34, blue: 0.44))
    }

    private var presetHexes: [String] {
        presetHexesRaw.split(separator: ",")
            .map(String.init)
            .filter { !$0.isEmpty }
    }

    private func savePresetHexes(_ list: [String]) {
        presetHexesRaw = list.joined(separator: ",")
    }

    private let columns = [GridItem(.adaptive(minimum: 96, maximum: 130), spacing: 16)]

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    Text("封面")
                        .font(.headline)
                        .padding(.horizontal, 20)

                    LazyVGrid(columns: columns, spacing: 16) {
                        ForEach(CoverStyle.allCases) { style in
                            VStack(spacing: 6) {
                                coverThumb(style)
                                Text(style.displayName)
                                    .font(.caption)
                            }
                            .onTapGesture {
                                selectedStyle = style
                                onStyle(style)
                                if style == .custom {
                                    CoverColorStore.setHex(customColor.hexString,
                                                           for: bookID)
                                }
                            }
                        }
                    }
                    .padding(.horizontal, 20)

                    Divider().padding(.vertical, 8)

                    customColorSection

                    Divider().padding(.vertical, 8)

                    VStack(alignment: .leading, spacing: 12) {
                        Text("自定义封面图片")
                            .font(.headline)

                        PhotosPicker(selection: $photoItem, matching: .images) {
                            Label("从相册选择图片", systemImage: "photo")
                        }
                        .buttonStyle(.borderedProminent)

                        Text("选完可以拖动、缩放，调整要显示的范围。")
                            .font(.caption)
                            .foregroundStyle(.secondary)

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
                Task { await loadForCrop(item) }
            }
            .fullScreenCover(isPresented: $showCropper) {
                if let cropImage {
                    CoverCropView(image: cropImage,
                                  onDone: { ui in
                                      showCropper = false
                                      saveCropped(ui)
                                  },
                                  onCancel: {
                                      showCropper = false
                                      cropImage = nil
                                  })
                }
            }
        }
    }

    // MARK: 缩略图

    @ViewBuilder
    private func coverThumb(_ style: CoverStyle) -> some View {
        let isSelected = (selectedStyle == style) && !hasCustomImage
        let base: Color = style == .custom ? customColor : style.base

        ZStack {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(LinearGradient(colors: [base, base.opacity(0.74)],
                                     startPoint: .topLeading,
                                     endPoint: .bottomTrailing))

            BookPattern(style: style)

            if style == .custom {
                Image(systemName: "paintpalette")
                    .font(.system(size: 22))
                    .foregroundStyle(.white.opacity(0.9))
            }
        }
        .frame(height: 120)
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(isSelected ? Color.accentColor : Color.clear, lineWidth: 3)
        )
        .shadow(color: .black.opacity(0.18), radius: 4, y: 2)
    }

    // MARK: 自选颜色

    @ViewBuilder
    private var customColorSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("自选颜色")
                .font(.headline)

            HStack(spacing: 14) {
                ColorPicker("", selection: $customColor, supportsOpacity: false)
                    .labelsHidden()
                    .frame(width: 40, height: 40)
                    .onChange(of: customColor) { newValue in
                        selectedStyle = .custom
                        onStyle(.custom)
                        CoverColorStore.setHex(newValue.hexString, for: bookID)
                    }

                Button {
                    selectedStyle = .custom
                    onStyle(.custom)
                    CoverColorStore.setHex(customColor.hexString, for: bookID)
                } label: {
                    Label("用这个颜色", systemImage: "checkmark.circle")
                }
                .buttonStyle(.bordered)

                Spacer()

                Button {
                    var list = presetHexes
                    let hex = customColor.hexString
                    if !list.contains(hex) {
                        list.append(hex)
                        savePresetHexes(list)
                    }
                } label: {
                    Label("存为预设", systemImage: "plus.circle")
                }
                .buttonStyle(.bordered)
            }
            .padding(.horizontal, 20)

            if !presetHexes.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 12) {
                        ForEach(presetHexes, id: \.self) { hex in
                            Circle()
                                .fill(Color(hex: hex) ?? .gray)
                                .frame(width: 34, height: 34)
                                .overlay(
                                    Circle().stroke(
                                        customColor.hexString == hex
                                            ? Color.accentColor
                                            : Color.white.opacity(0.25),
                                        lineWidth: customColor.hexString == hex ? 3 : 1
                                    )
                                )
                                .onTapGesture {
                                    if let c = Color(hex: hex) {
                                        customColor = c
                                        selectedStyle = .custom
                                        onStyle(.custom)
                                        CoverColorStore.setHex(hex, for: bookID)
                                    }
                                }
                                .onLongPressGesture {
                                    var list = presetHexes
                                    list.removeAll { $0 == hex }
                                    savePresetHexes(list)
                                }
                        }
                    }
                    .padding(.horizontal, 20)
                    .padding(.vertical, 4)
                }
            }
        }
    }

    // MARK: 图片 → 裁剪 → 保存

    private func loadForCrop(_ item: PhotosPickerItem) async {
        defer { photoItem = nil }

        guard let data = try? await item.loadTransferable(type: Data.self),
              let image = UIImage(data: data) else { return }

        await MainActor.run {
            cropImage = image
            showCropper = true
        }
    }

    private func saveCropped(_ ui: UIImage) {
        guard let data = ui.jpegData(compressionQuality: 0.92) else { return }

        if let name = try? FileStorage.saveCoverData(data,
                                                     preferredExtension: "jpg") {
            onCustomImage(name)
        }

        cropImage = nil
        dismiss()
    }
}
