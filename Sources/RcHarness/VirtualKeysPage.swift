import SwiftUI

@MainActor
struct VirtualKeysPage: View {
    @ObservedObject var model: RemoteDashboardModel
    @State private var selectedSchemeID: UUID?
    @State private var selectedInput: ControllerInput = .dpadUp
    @State private var selectedTrigger: ButtonTrigger = .single

    init(model: RemoteDashboardModel) {
        self.model = model
        _selectedSchemeID = State(initialValue: model.virtualKeySchemes.first?.id)
    }

    var body: some View {
        HStack(alignment: .top, spacing: SettingsStyle.Spacing.groups) {
            schemeListPanel.frame(width: 220)
            padPanel.frame(width: 272)
            editorPanel.frame(maxWidth: .infinity)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .onChange(of: model.virtualKeySchemes.map(\.id)) { _, _ in ensureSelection() }
    }

    private var schemeListPanel: some View {
        SettingsPanel(contentPadding: EdgeInsets(top: SettingsStyle.panelPadding, leading: SettingsStyle.controlPadding,
                                               bottom: SettingsStyle.Spacing.groups, trailing: SettingsStyle.controlPadding)) {
            HStack(spacing: SettingsStyle.Spacing.inline) {
                Image(systemName: "rectangle.grid.2x2").foregroundStyle(.secondary)
                Text("虚拟方案").font(SettingsStyle.Typography.panelTitle)
                Spacer(minLength: 4)
                Button {
                    let scheme = VirtualKeyScheme(name: uniqueName("新方案",
                        existingNames: model.virtualKeySchemes.map(\.name), fallback: "新方案"))
                    model.virtualKeySchemes.append(scheme)
                    selectedSchemeID = scheme.id
                } label: {
                    Label("新建", systemImage: "plus")
                }
                .buttonStyle(.bordered).controlSize(.small)
            }
            Divider()
            if model.virtualKeySchemes.isEmpty {
                SettingsEmpty(symbol: "rectangle.grid.2x2", title: "还没有虚拟方案",
                              detail: "点击“新建”创建一套虚拟按键。")
            } else {
                ScrollView {
                    LazyVStack(spacing: 4) {
                        ForEach(model.virtualKeySchemes) { scheme in
                            Button {
                                selectedSchemeID = scheme.id
                            } label: {
                                HStack(spacing: SettingsStyle.Spacing.inline) {
                                    Image(systemName: scheme.id == selectedSchemeID ? "checkmark.circle.fill" : "circle")
                                        .foregroundStyle(scheme.id == selectedSchemeID ? Color.accentColor : .secondary)
                                    Text(scheme.displayName).lineLimit(1)
                                    Spacer(minLength: 0)
                                }
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .font(SettingsStyle.Typography.body)
                        }
                    }
                }
                .frame(maxHeight: .infinity)
            }
            HStack {
                Spacer()
                Button("管理键位") { model.page = .mapping }.buttonStyle(.link).font(.caption)
            }
        }
    }

    private var padPanel: some View {
        SettingsPanel("虚拟按键预览", symbol: "gamecontroller") {
            if let scheme = selectedScheme {
                let titles = padTitles(for: scheme)
                VStack(alignment: .leading, spacing: SettingsStyle.Spacing.groups) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("方案名称").font(SettingsStyle.Typography.caption.weight(.medium)).foregroundStyle(.secondary)
                        TextField("方案名称", text: Binding(
                            get: { scheme.name },
                            set: { name in updateSelected { $0.name = name } }
                        )).textFieldStyle(.roundedBorder)
                    }
                    PhrasePadView(title: { titles[$0] ?? "未分配" },
                                  isAssigned: { titles[$0] != nil },
                                  selectedInput: selectedInput) { input in
                        selectedInput = input
                    }
                    .frame(maxWidth: .infinity)
                    Toggle("执行后关闭窗口", isOn: Binding(
                        get: { scheme.closeAfterAction },
                        set: { value in updateSelected { $0.closeAfterAction = value } }
                    ))
                    .toggleStyle(SettingsSwitchStyle()).font(SettingsStyle.Typography.caption)
                    Text("关闭时：再按任意其他按键或 Esc 退出浮层。")
                        .font(SettingsStyle.Typography.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Divider()
                    VStack(alignment: .leading, spacing: SettingsStyle.Spacing.inline) {
                        Text("如何唤出").font(SettingsStyle.Typography.body.weight(.medium))
                        Text("在按键映射中，把“唤出虚拟按键”绑定到任意按键，并选择本方案。")
                            .font(SettingsStyle.Typography.caption).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 0)
                    HStack {
                        Spacer()
                        Button("删除方案", role: .destructive) {
                            model.requestDeletion(.virtualKeyScheme(scheme.id))
                        }.controlSize(.small)
                    }
                }
                .frame(maxHeight: .infinity)
            } else {
                SettingsEmpty(symbol: "rectangle.grid.2x2", title: "选择一套方案",
                              detail: "新建或选择左侧方案后可编辑。")
            }
        }
    }

    @ViewBuilder private var editorPanel: some View {
        if let scheme = selectedScheme {
            SettingsPanel("按键动作", symbol: "pencil") {
                HStack(alignment: .firstTextBaseline, spacing: SettingsStyle.Spacing.inline) {
                    Text("\(selectedInput.label)").font(SettingsStyle.Typography.body.weight(.medium))
                    Text("· 修改后自动保存").font(SettingsStyle.Typography.caption).foregroundStyle(.secondary)
                    Spacer(minLength: 0)
                }
                Picker("触发方式", selection: $selectedTrigger) {
                    ForEach(ButtonTrigger.allCases) { trigger in
                        Text(trigger.title).tag(trigger)
                    }
                }
                .pickerStyle(.segmented)
                Divider()
                ScrollView {
                    ActionMappingEditor(value: Binding(
                        get: { scheme[selectedInput, selectedTrigger] },
                        set: { value in updateSelected { $0[selectedInput, selectedTrigger] = value } }
                    ), model: model, filter: .all)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                Text("浮层里除上下左右和中间外的任意按键都会退出； Esc 也会关闭。")
                    .font(SettingsStyle.Typography.caption).foregroundStyle(.secondary)
            }
            .id(scheme.id)
        } else {
            SettingsPanel("按键动作", symbol: "pencil") {
                Spacer(minLength: 0)
                SettingsEmpty(symbol: "keyboard", title: "选择虚拟按键",
                              detail: "选择一套方案后，在五向盘上选取要编辑的虚拟按键。")
                Spacer(minLength: 0)
            }
        }
    }

    private func padTitles(for scheme: VirtualKeyScheme) -> [ControllerInput: String] {
        Dictionary(uniqueKeysWithValues: VirtualKeyScheme.inputs.compactMap { input in
            scheme.title(for: input) { model.mappingTitle($0) }.map { (input, $0) }
        })
    }

    private var selectedScheme: VirtualKeyScheme? {
        guard let selectedSchemeID,
              let scheme = model.virtualKeySchemes.first(where: { $0.id == selectedSchemeID }) else { return nil }
        return scheme
    }

    private func updateSelected(_ mutate: (inout VirtualKeyScheme) -> Void) {
        guard let selectedSchemeID,
              let index = model.virtualKeySchemes.firstIndex(where: { $0.id == selectedSchemeID }) else { return }
        mutate(&model.virtualKeySchemes[index])
    }

    private func ensureSelection() {
        if let selectedSchemeID, model.virtualKeySchemes.contains(where: { $0.id == selectedSchemeID }) { return }
        selectedSchemeID = model.virtualKeySchemes.first?.id
    }
}
