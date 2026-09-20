import SwiftUI

/// 图层面板。列表从上到下 = 从上层到下层（和 Photoshop 一致）。
struct LayerPanelView: View {
    let book: Book
    let spreadIndex: Int

    @ObservedObject var layerStore: LayerStore
    @Binding var activeLayerID: UUID

    @Environment(\.dismiss) private var dismiss

    @State private var renamingID: UUID?
    @State private var renameText = ""

    private var layers: [LayerMeta] {
        layerStore.layers(bookId: book.id, spreadIndex: spreadIndex)
    }

    /// 显示顺序：顶层在前
    private var displayOrder: [LayerMeta] {
        layers.reversed()
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(displayOrder) { meta in
                        row(meta)
                    }
                } header: {
                    Text("从上层到下层")
                } footer: {
                    Text("点一行把它设为当前图层。左滑可重命名或删除。眼睛图标控制显隐。")
                }

                Section {
                    Button {
                        let meta = layerStore.addLayer(bookId: book.id,
                                                       spreadIndex: spreadIndex)
                        activeLayerID = meta.id
                    } label: {
                        Label("新建图层", systemImage: "plus.square.on.square")
                    }
                }
            }
            .navigationTitle("图层 · \(layers.count)")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("完成") { dismiss() }
                }
            }
            .alert("重命名图层",
                   isPresented: Binding(
                        get: { renamingID != nil },
                        set: { if !$0 { renamingID = nil } }
                   )) {
                TextField("图层名称", text: $renameText)
                Button("取消", role: .cancel) { renamingID = nil }
                Button("保存") {
                    if let id = renamingID {
                        let trimmed = renameText
                            .trimmingCharacters(in: .whitespacesAndNewlines)
                        layerStore.rename(id,
                                          to: trimmed.isEmpty ? "图层" : trimmed,
                                          bookId: book.id,
                                          spreadIndex: spreadIndex)
                    }
                    renamingID = nil
                }
            }
        }
    }

    // MARK: - 单行

    @ViewBuilder
    private func row(_ meta: LayerMeta) -> some View {
        let isActive = meta.id == activeLayerID

        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                Button {
                    layerStore.toggleVisibility(meta.id,
                                                bookId: book.id,
                                                spreadIndex: spreadIndex)
                } label: {
                    Image(systemName: meta.isVisible ? "eye" : "eye.slash")
                        .font(.system(size: 16))
                        .foregroundStyle(meta.isVisible ? Color.primary
                                                        : Color.secondary)
                        .frame(width: 28)
                }
                .buttonStyle(.plain)

                Text(meta.name)
                    .font(.subheadline.weight(isActive ? .semibold : .regular))
                    .foregroundStyle(meta.isVisible ? Color.primary : Color.secondary)

                Spacer()

                if isActive {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(Color.accentColor)
                }

                Menu {
                    Button {
                        layerStore.moveLayer(meta.id, up: true,
                                             bookId: book.id,
                                             spreadIndex: spreadIndex)
                    } label: {
                        Label("上移一层", systemImage: "arrow.up")
                    }
                    Button {
                        layerStore.moveLayer(meta.id, up: false,
                                             bookId: book.id,
                                             spreadIndex: spreadIndex)
                    } label: {
                        Label("下移一层", systemImage: "arrow.down")
                    }

                    Divider()

                    Button {
                        renamingID = meta.id
                        renameText = meta.name
                    } label: {
                        Label("重命名", systemImage: "pencil")
                    }

                    Button(role: .destructive) {
                        deleteLayer(meta)
                    } label: {
                        Label("删除图层", systemImage: "trash")
                    }
                    .disabled(layers.count <= 1)
                } label: {
                    Image(systemName: "ellipsis.circle")
                        .foregroundStyle(.secondary)
                }
            }

            HStack(spacing: 10) {
                Image(systemName: "circle.lefthalf.filled")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)

                Slider(value: opacityBinding(meta), in: 0...1)
                    .disabled(!meta.isVisible)

                Text("\(Int(meta.opacity * 100))%")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .frame(width: 40, alignment: .trailing)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture {
            activeLayerID = meta.id
        }
        .listRowBackground(isActive ? Color.accentColor.opacity(0.10) : Color.clear)
        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
            Button(role: .destructive) {
                deleteLayer(meta)
            } label: {
                Label("删除", systemImage: "trash")
            }
            .disabled(layers.count <= 1)

            Button {
                renamingID = meta.id
                renameText = meta.name
            } label: {
                Label("重命名", systemImage: "pencil")
            }
            .tint(.blue)
        }
    }

    private func opacityBinding(_ meta: LayerMeta) -> Binding<Double> {
        Binding(
            get: {
                layerStore.layers(bookId: book.id, spreadIndex: spreadIndex)
                    .first(where: { $0.id == meta.id })?.opacity ?? 1.0
            },
            set: { value in
                layerStore.setOpacity(value,
                                      layerID: meta.id,
                                      bookId: book.id,
                                      spreadIndex: spreadIndex)
            }
        )
    }

    private func deleteLayer(_ meta: LayerMeta) {
        guard layers.count > 1 else { return }

        let remaining = layers.filter { $0.id != meta.id }
        layerStore.deleteLayer(meta.id,
                               bookId: book.id,
                               spreadIndex: spreadIndex)

        if activeLayerID == meta.id, let first = remaining.first {
            activeLayerID = first.id
        }
    }
}
