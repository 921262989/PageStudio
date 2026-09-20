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

                    LabeledContent("当前背景") {
                        Text(settingsStore.settings.readerTheme.displayName)
                            .foregroundStyle(.secondary)
                    }
                } header: {
                    Text("背景颜色")
                } footer: {
                    Text("只改变纸张背后的桌面颜色。纸张始终是白纸。")
                }

                // MARK: 手势
                Section {
                    Toggle("启用手势", isOn: binding(\.gesturesEnabled))

                    if settingsStore.settings.gesturesEnabled {
                        Toggle("双指轻点 — 撤回", isOn: binding(\.twoFingerUndo))
                        Toggle("双指长按 — 连续撤回",
                               isOn: binding(\.twoFingerLongPressUndo))
                        Toggle("三指轻点 — 重做", isOn: binding(\.threeFingerRedo))
                        Toggle("四指轻点 — 清空当前跨页",
                               isOn: binding(\.fourFingerClear))
                        Toggle("单指长按 — 吸色", isOn: binding(\.longPressEyedropper))
                    }
                } header: {
                    Text("手势")
                } footer: {
                    Text(settingsStore.settings.gesturesEnabled
                         ? "手势只在编辑模式（画笔已打开）下生效。吸色在「手指也能画」模式下会自动关闭，避免和绘制冲突。"
                         : "手势已全部关闭。")
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

    // MARK: - 背景色卡

    @ViewBuilder
    private func themeSwatch(_ t: ReaderTheme) -> some View {
        let selected = settingsStore.settings.readerTheme == t

        Button {
            settingsStore.settings.readerTheme = t
        } label: {
            VStack(spacing: 7) {
                ZStack {
                    // 桌面背景
                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .fill(LinearGradient(colors: t.backgroundColors,
                                             startPoint: .top,
                                             endPoint: .bottom))
                        .frame(width: 62, height: 84)

                    // 中间一小张白纸（固定白纸，直观展示对比）
                    RoundedRectangle(cornerRadius: 2, style: .continuous)
                        .fill(PaperStyle.fill)
                        .frame(width: 30, height: 56)
                        .overlay(
                            Rectangle()
                                .fill(PaperStyle.spineLine)
                                .frame(width: 1, height: 56)
                        )
                }
                .overlay(
                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .stroke(selected ? Color.accentColor
                                         : Color.black.opacity(0.10),
                                lineWidth: selected ? 2.5 : 1)
                )
                .shadow(color: .black.opacity(0.16), radius: 4, y: 2)

                Text(t.displayName)
                    .font(.caption2)
                    .foregroundStyle(selected ? Color.accentColor
                                              : Color.secondary)
            }
        }
        .buttonStyle(.plain)
    }

    // MARK: - Binding

    private func binding<T>(_ key: WritableKeyPath<AppSettings, T>) -> Binding<T> {
        Binding(
            get: { settingsStore.settings[keyPath: key] },
            set: { settingsStore.settings[keyPath: key] = $0 }
        )
    }
}
