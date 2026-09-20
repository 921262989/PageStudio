import SwiftUI

struct SettingsView: View {
    @EnvironmentObject private var settingsStore: AppSettingsStore
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Toggle("仅 Apple Pencil 可绘制", isOn: pencilOnlyBinding)
                    Text(settingsStore.settings.pencilOnlyDrawMode
                         ? "手指用于翻页与手势，不会产生笔迹。"
                         : "手指与 Apple Pencil 都可绘制。翻页请用左右边缘点击。")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                } header: {
                    Text("笔模式")
                }

                Section {
                    Toggle("自动续页", isOn: autoAppendBinding)
                    Text("在最后一页落笔后自动追加空白页。")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                } header: {
                    Text("阅读")
                }

                Section {
                    Toggle("点击左右边缘翻页", isOn: edgeTapBinding)
                    Toggle("翻页后保持缩放", isOn: zoomPersistBinding)
                } header: {
                    Text("操作")
                }

                Section {
                    LabeledContent("默认浏览模式") {
                        Picker("", selection: defaultModeBinding) {
                            Text("单页").tag(ViewMode.single)
                            Text("双页").tag(ViewMode.spread)
                        }
                        .pickerStyle(.segmented)
                        .frame(width: 160)
                    }
                } header: {
                    Text("显示")
                }

                Section {
                    LabeledContent("版本", value: "1.0")
                    LabeledContent("数据存储", value: "本机 · 离线")
                } header: {
                    Text("关于")
                }
            }
            .navigationTitle("设置")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("完成") { dismiss() }
                }
            }
        }
    }

    // MARK: - Bindings

    private var pencilOnlyBinding: Binding<Bool> {
        Binding(
            get: { settingsStore.settings.pencilOnlyDrawMode },
            set: { settingsStore.settings.pencilOnlyDrawMode = $0 }
        )
    }

    private var autoAppendBinding: Binding<Bool> {
        Binding(
            get: { settingsStore.settings.autoAppendPage },
            set: { settingsStore.settings.autoAppendPage = $0 }
        )
    }

    private var edgeTapBinding: Binding<Bool> {
        Binding(
            get: { settingsStore.settings.edgeTapTurn },
            set: { settingsStore.settings.edgeTapTurn = $0 }
        )
    }

    private var zoomPersistBinding: Binding<Bool> {
        Binding(
            get: { settingsStore.settings.zoomPersistOnTurn },
            set: { settingsStore.settings.zoomPersistOnTurn = $0 }
        )
    }

    private var defaultModeBinding: Binding<ViewMode> {
        Binding(
            get: { settingsStore.settings.pencilOnlyDrawMode ? .spread : .spread },
            set: { _ in }
        )
    }
}
