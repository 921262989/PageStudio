import SwiftUI
import PencilKit

// MARK: - 图层元数据

struct LayerMeta: Identifiable, Codable, Hashable {
    var id: UUID = UUID()
    var name: String = "图层"
    var isVisible: Bool = true
    var opacity: Double = 1.0

    var clampedOpacity: CGFloat {
        CGFloat(min(max(opacity, 0.0), 1.0))
    }
}

// MARK: - 图层存储

final class LayerStore: ObservableObject {

    /// 元数据变更时自增。笔迹内容变化不触发。
    @Published private(set) var version: Int = 0

    private var registry: [String: [LayerMeta]] = [:]
    private var drawings: [String: [UUID: PKDrawing]] = [:]
    private var pendingSaves: [String: DispatchWorkItem] = [:]

    private func key(_ bookId: UUID, _ spreadIndex: Int) -> String {
        "\(bookId.uuidString)_\(spreadIndex)"
    }

    // MARK: - 读取

    func layers(bookId: UUID, spreadIndex: Int) -> [LayerMeta] {
        let k = key(bookId, spreadIndex)
        if let cached = registry[k] { return cached }

        let loaded = loadMeta(bookId: bookId, spreadIndex: spreadIndex)
        registry[k] = loaded
        return loaded
    }

    func drawing(bookId: UUID, spreadIndex: Int, layerID: UUID) -> PKDrawing {
        let k = key(bookId, spreadIndex)
        if let cached = drawings[k]?[layerID] { return cached }

        let url = layerFileURL(bookId: bookId, spreadIndex: spreadIndex, layerID: layerID)
        let drawing: PKDrawing
        if let data = try? Data(contentsOf: url),
           let loaded = try? PKDrawing(data: data) {
            drawing = loaded
        } else {
            drawing = PKDrawing()
        }

        var dict = drawings[k] ?? [:]
        dict[layerID] = drawing
        drawings[k] = dict
        return drawing
    }

    func isEmpty(bookId: UUID, spreadIndex: Int) -> Bool {
        for meta in layers(bookId: bookId, spreadIndex: spreadIndex) {
            let d = drawing(bookId: bookId, spreadIndex: spreadIndex, layerID: meta.id)
            if !d.strokes.isEmpty { return false }
        }
        return true
    }

    // MARK: - 写入

    func setDrawing(_ drawing: PKDrawing,
                    bookId: UUID,
                    spreadIndex: Int,
                    layerID: UUID) {
        let k = key(bookId, spreadIndex)
        var dict = drawings[k] ?? [:]
        dict[layerID] = drawing
        drawings[k] = dict

        saveKeySafetyNet(bookId: bookId, spreadIndex: spreadIndex)

        let saveKey = "\(k)_\(layerID.uuidString)"
        pendingSaves[saveKey]?.cancel()

        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            let url = self.layerFileURL(bookId: bookId,
                                        spreadIndex: spreadIndex,
                                        layerID: layerID)
            try? drawing.dataRepresentation().write(to: url, options: .atomic)
            self.pendingSaves[saveKey] = nil
        }
        pendingSaves[saveKey] = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4, execute: work)
    }

    /// 确保持久化 meta，防止首次绘制后重启导致 UUID 变化、笔迹成为孤儿
    private func saveKeySafetyNet(bookId: UUID, spreadIndex: Int) {
        let k = key(bookId, spreadIndex)
        guard let list = registry[k] else { return }
        writeMeta(list, bookId: bookId, spreadIndex: spreadIndex)
    }

    func clearLayer(bookId: UUID, spreadIndex: Int, layerID: UUID) {
        setDrawing(PKDrawing(), bookId: bookId,
                   spreadIndex: spreadIndex, layerID: layerID)

        let url = layerFileURL(bookId: bookId, spreadIndex: spreadIndex, layerID: layerID)
        try? FileManager.default.removeItem(at: url)
    }

    // MARK: - 图层增删改

    @discardableResult
    func addLayer(bookId: UUID, spreadIndex: Int, name: String? = nil) -> LayerMeta {
        var list = layers(bookId: bookId, spreadIndex: spreadIndex)
        var meta = LayerMeta()
        meta.name = name ?? "图层 \(list.count + 1)"
        list.append(meta)

        commit(list, bookId: bookId, spreadIndex: spreadIndex)

        let k = key(bookId, spreadIndex)
        var dict = drawings[k] ?? [:]
        dict[meta.id] = PKDrawing()
        drawings[k] = dict

        return meta
    }

    func deleteLayer(_ layerID: UUID, bookId: UUID, spreadIndex: Int) {
        var list = layers(bookId: bookId, spreadIndex: spreadIndex)
        guard list.count > 1 else { return }
        list.removeAll { $0.id == layerID }
        commit(list, bookId: bookId, spreadIndex: spreadIndex)

        let k = key(bookId, spreadIndex)
        drawings[k]?.removeValue(forKey: layerID)

        let url = layerFileURL(bookId: bookId, spreadIndex: spreadIndex, layerID: layerID)
        try? FileManager.default.removeItem(at: url)
    }

    func rename(_ layerID: UUID, to name: String, bookId: UUID, spreadIndex: Int) {
        var list = layers(bookId: bookId, spreadIndex: spreadIndex)
        guard let i = list.firstIndex(where: { $0.id == layerID }) else { return }
        list[i].name = name
        commit(list, bookId: bookId, spreadIndex: spreadIndex)
    }

    func toggleVisibility(_ layerID: UUID, bookId: UUID, spreadIndex: Int) {
        var list = layers(bookId: bookId, spreadIndex: spreadIndex)
        guard let i = list.firstIndex(where: { $0.id == layerID }) else { return }
        list[i].isVisible.toggle()
        commit(list, bookId: bookId, spreadIndex: spreadIndex)
    }

    func setVisibility(_ visible: Bool, layerID: UUID, bookId: UUID, spreadIndex: Int) {
        var list = layers(bookId: bookId, spreadIndex: spreadIndex)
        guard let i = list.firstIndex(where: { $0.id == layerID }) else { return }
        guard list[i].isVisible != visible else { return }
        list[i].isVisible = visible
        commit(list, bookId: bookId, spreadIndex: spreadIndex)
    }

    func setOpacity(_ value: Double, layerID: UUID, bookId: UUID, spreadIndex: Int) {
        var list = layers(bookId: bookId, spreadIndex: spreadIndex)
        guard let i = list.firstIndex(where: { $0.id == layerID }) else { return }
        let clamped = min(max(value, 0), 1)
        list[i].opacity = clamped
        commit(list, bookId: bookId, spreadIndex: spreadIndex)
    }

    func moveLayer(_ layerID: UUID, up: Bool, bookId: UUID, spreadIndex: Int) {
        var list = layers(bookId: bookId, spreadIndex: spreadIndex)
        guard let i = list.firstIndex(where: { $0.id == layerID }) else { return }
        let j = up ? i + 1 : i - 1
        guard list.indices.contains(j) else { return }
        list.swapAt(i, j)
        commit(list, bookId: bookId, spreadIndex: spreadIndex)
    }

    // MARK: - 内部

    private func commit(_ list: [LayerMeta], bookId: UUID, spreadIndex: Int) {
        let k = key(bookId, spreadIndex)
        registry[k] = list
        writeMeta(list, bookId: bookId, spreadIndex: spreadIndex)
        version &+= 1
    }

    private var drawingsRoot: URL {
        FileStorage.ensure(FileStorage.documents
            .appendingPathComponent("Drawings", isDirectory: true))
    }

    private func spreadDirectory(bookId: UUID, spreadIndex: Int) -> URL {
        FileStorage.ensure(drawingsRoot
            .appendingPathComponent(bookId.uuidString, isDirectory: true)
            .appendingPathComponent("\(spreadIndex)", isDirectory: true))
    }

    private func metaURL(bookId: UUID, spreadIndex: Int) -> URL {
        spreadDirectory(bookId: bookId, spreadIndex: spreadIndex)
            .appendingPathComponent("meta.json")
    }

    private func layerFileURL(bookId: UUID,
                              spreadIndex: Int,
                              layerID: UUID) -> URL {
        spreadDirectory(bookId: bookId, spreadIndex: spreadIndex)
            .appendingPathComponent("\(layerID.uuidString).drawing")
    }

    private func writeMeta(_ list: [LayerMeta], bookId: UUID, spreadIndex: Int) {
        let url = metaURL(bookId: bookId, spreadIndex: spreadIndex)
        guard let data = try? JSONEncoder().encode(list) else { return }
        try? data.write(to: url, options: .atomic)
    }

    /// 读取图层元数据，并兼容旧版单层笔迹。
    /// ⚠️ 没有数据时也会**立刻写一份 meta.json**，否则 UUID 每次重启都会变，
    ///    之前画在这个 UUID 下的笔迹就成了找不到的孤儿文件。
    private func loadMeta(bookId: UUID, spreadIndex: Int) -> [LayerMeta] {
        let url = metaURL(bookId: bookId, spreadIndex: spreadIndex)

        if let data = try? Data(contentsOf: url),
           let decoded = try? JSONDecoder().decode([LayerMeta].self, from: data),
           !decoded.isEmpty {
            return decoded
        }

        var meta = LayerMeta()
        meta.name = "图层 1"

        // 旧数据：只有一个 <spreadIndex>.drawing
        let legacyURL = FileStorage.drawingURL(bookId: bookId,
                                               spreadIndex: spreadIndex)
        if FileManager.default.fileExists(atPath: legacyURL.path),
           let data = try? Data(contentsOf: legacyURL),
           let legacy = try? PKDrawing(data: data),
           !legacy.strokes.isEmpty {
            let dest = layerFileURL(bookId: bookId,
                                    spreadIndex: spreadIndex,
                                    layerID: meta.id)
            try? data.write(to: dest, options: .atomic)
        }

        // 无论哪种情况都落盘
        writeMeta([meta], bookId: bookId, spreadIndex: spreadIndex)
        return [meta]
    }
}
