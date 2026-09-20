import SwiftUI

struct SettingsView: View {
    @EnvironmentObject private var settingsStore: AppSettingsStore
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Toggle("仅 Apple Pencil 可绘制", isOn: binding(\.pencilOnlyDrawMode))
                    Text(settingsStore.settings.pencilOnlyDrawMode
                         ? "手指用于翻页与手势，不会产生笔迹。"
                         : "手指与 Apple Pencil 都可绘制。翻页请用左右边缘点击。")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                } header: {
                    Text("笔模式")
                }

                Section {
                    Toggle("自动续页", isOn: binding(\.autoAppendPage))
                    Text("在最后一页落笔后自动追加空白页。")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                } header: {
                    Text("阅读")
                }

                Section {
                    Toggle("点击左右边缘翻页", isOn: binding(\.edgeTapTurn))
                    Toggle("翻页后保持缩放", isOn: binding(\.zoomPersistOnTurn))
                } header: {
                    Text("操作")
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

    private func binding(_ key: WritableKeyPath<AppSettings, Bool>) -> Binding<Bool> {
        Binding(
            get: { settingsStore.settings[keyPath: key] },
            set: { settingsStore.settings[keyPath: key] = $0 }
        )
    }
}
