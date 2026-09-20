import SwiftUI

struct SettingsView: View {
    @EnvironmentObject private var settingsStore: AppSettingsStore
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                // MARK: 外观
                Section {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 14) {
                            ForEach(ReaderTheme.allCases) { t in
                                themeSwatch(t)
                            }
                        }
                        .padding(.vertical, 6)
                        .padding(.horizontal, 2)
                    }

                    LabeledContent("当前主题") {
                        Text(settingsStore.settings.readerTheme.displayName)
                            .foregroundStyle(.secondary)
                    }
                } header: {
                    Text("外观")
                } footer: {
                    Text("同时改变阅读背景与纸张颜色。深色主题适合夜间阅读。")
                }

                // MARK: 笔模式
                Section {
                    Toggle("仅 Apple Pencil 可绘制",
                           isOn: binding(\.pencilOnlyDrawMode))
                    Text(settingsStore.settings.pencilOnlyDrawMode
                         ? "手指用于翻页与手势，不会产生笔迹。"
                         : "手指与 Apple Pencil 都可绘制。翻页请用左右边缘点击。")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                } header: {
                    Text("笔模式")
                }

                // MARK: 阅读
                Section {
                    Toggle("自动续页", isOn: binding(\.autoAppendPage))
                    Text("在最后一页落笔后自动追加空白页。")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                } header: {
                    Text("阅读")
                }

                // MARK: 操作
                Section {
                    Toggle("点击左右边缘翻页", isOn: binding(\.edgeTapTurn))
                    Toggle("翻页后保持缩放", isOn: binding(\.zoomPersistOnTurn))
                } header: {
                    Text("操作")
                }

                // MARK: 关于
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

    // MARK: - 主题色卡

    @ViewBuilder
    private func themeSwatch(_ t: ReaderTheme) -> some View {
        let selected = settingsStore.settings.readerTheme == t

        Button {
            settingsStore.settings.readerTheme = t
        } label: {
            VStack(spacing: 7) {
                ZStack {
                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .fill(LinearGradient(colors: t.backgroundColors,
                                             startPoint: .top,
                                             endPoint: .bottom))
                        .frame(width: 62, height: 84)

                    // 中间一张小纸，直观展示纸张色
                    RoundedRectangle(cornerRadius: 2, style: .continuous)
                        .fill(t.paperColor)
                        .frame(width: 30, height: 56)
                        .overlay(
                            Rectangle()
                                .fill(t.spineLineColor)
                                .frame(width: 1, height: 56)
                        )
                }
                .overlay(
                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .stroke(selected ? Color.accentColor : Color.black.opacity(0.10),
                                lineWidth: selected ? 2.5 : 1)
                )
                .shadow(color: .black.opacity(0.16), radius: 4, y: 2)

                Text(t.displayName)
                    .font(.caption2)
                    .foregroundStyle(selected ? Color.accentColor : Color.secondary)
            }
        }
        .buttonStyle(.plain)
    }

    // MARK: - Binding 工具

    private func binding<T>(_ key: WritableKeyPath<AppSettings, T>) -> Binding<T> {
        Binding(
            get: { settingsStore.settings[keyPath: key] },
            set: { settingsStore.settings[keyPath: key] = $0 }
        )
    }
}
