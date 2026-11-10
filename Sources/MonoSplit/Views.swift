import AppKit
import SwiftUI
import MonoSplitCore

extension ChannelRole {
    var tint: Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            let dark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            switch self {
            case .woofer: return NSColor(srgbRed: dark ? 0.38 : 0.15, green: dark ? 0.65 : 0.43, blue: dark ? 1 : 0.86, alpha: 1)
            case .fullRange: return NSColor(srgbRed: dark ? 1 : 0.76, green: dark ? 0.64 : 0.33, blue: dark ? 0.32 : 0.08, alpha: 1)
            case .builtin: return NSColor(srgbRed: dark ? 0.27 : 0.04, green: dark ? 0.8 : 0.46, blue: dark ? 0.76 : 0.45, alpha: 1)
            }
        })
    }
    var symbol: String {
        switch self { case .woofer: "L"; case .fullRange: "R"; case .builtin: "M" }
    }
}

enum EditorPage: String, CaseIterable, Identifiable {
    case tuning = "分频与 EQ"
    case routing = "设备与测量"
    var id: String { rawValue }
}

struct MenuContent: View {
    @Bindable var model: AppModel
    @Environment(\.openWindow) private var openWindow
    var body: some View {
        Text(model.snapshot.status)
        if let role = model.comparingRole {
            Text("\(role.title) · 快照对比中")
            Button("返回当前调音") { model.endComparison() }
        }
        Button("打开调音窗口") {
            openWindow(id: "tuning")
            NSApp.activate(ignoringOtherApps: true)
        }.keyboardShortcut("o")
        Button(model.snapshot.requested ? "停止处理" : "启动处理") { model.toggleRunning() }
            .disabled(model.busy || (!model.snapshot.requested && !model.issues.isEmpty))
        Toggle("总静音", isOn: $model.profile.masterMuted)
        Toggle("FineTune 输入（作为独立设备）", isOn: Binding(get: { model.fineTuneInput }, set: { model.setFineTuneInput($0) }))
            .disabled(model.busy)
        Divider()
        Menu("音箱配置") {
            ForEach(model.profiles) { profile in
                Button {
                    model.selectProfile(profile.id)
                } label: {
                    if profile.id == model.profile.id { Label(profile.name, systemImage: "checkmark") }
                    else { Text(profile.name) }
                }
            }
        }
        Divider()
        Button("退出 MonoSplit") { NSApp.terminate(nil) }.keyboardShortcut("q")
    }
}

struct MainView: View {
    @Bindable var model: AppModel
    @State private var selectedRole: ChannelRole = .woofer
    @State private var selectedBandID: UUID?
    @State private var editorPage: EditorPage = .tuning
    @State private var showRouting = false
    @State private var showCrossover = false
    @State private var showGuide = false
    @State private var confirmDelete = false

    private var channelIndex: Int { model.profile.channels.firstIndex { $0.role == selectedRole }! }
    private var editorIdentity: String { "\(model.profile.id.uuidString)-\(selectedRole.rawValue)" }
    private var profileBinding: Binding<SpeakerProfile> {
        let id = model.profile.id
        return Binding(get: { model.profile }, set: { if model.profile.id == id { model.profile = $0 } })
    }
    private var comparing: Bool { model.comparingRole == selectedRole }
    private var channel: Binding<ChannelSettings> {
        let id = model.profile.id
        let role = selectedRole
        return Binding(get: { model.displayProfile.channels.first { $0.role == role }! }, set: { next in
            guard model.profile.id == id, model.comparingRole != role,
                  let index = model.profile.channels.firstIndex(where: { $0.role == role }) else { return }
            model.profile.channels[index] = next
        })
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            HStack(spacing: 0) {
                sidebar.frame(width: 190)
                Divider()
                workspace
            }
            if !model.issues.isEmpty || model.message != nil { feedback }
            Divider()
            footer
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .sheet(item: $model.importPreview) { preview in
            EQImportSheet(preview: preview, apply: { model.applyEQPreview() }, cancel: { model.importPreview = nil })
        }
        .sheet(isPresented: $showCrossover) {
            PairedCrossoverSheet(profile: model.profile, sampleRate: model.snapshot.sampleRate) { frequency, shape, lowPassRole in
                model.applyPairedCrossover(frequency: frequency, shape: shape, lowPassRole: lowPassRole)
            }
        }
        .sheet(isPresented: $showGuide) { QuickStartGuide() }
        .alert("删除“\(model.profile.name)”？", isPresented: $confirmDelete) {
            Button("取消", role: .cancel) {}
            Button("删除配置", role: .destructive) { model.deleteProfile() }
        } message: { Text("此配置将从配置库移除。需要保留时，可先导出 JSON。") }
        .alert("重命名配置", isPresented: $model.showRename) {
            TextField("配置名称", text: $model.renameText)
            Button("取消", role: .cancel) {}
            Button("保存") { model.renameProfile() }
        }
        .alert("MonoSplit", isPresented: $model.errorPresented) {
            Button("知道了", role: .cancel) {}
        } message: { Text(model.message ?? "") }
        .onChange(of: model.profile.id) { selectedBandID = nil }
        .onChange(of: model.profile.channels[channelIndex].bands.map(\.id)) {
            if let selectedBandID, !model.profile.channels[channelIndex].bands.contains(where: { $0.id == selectedBandID }) {
                self.selectedBandID = nil
            }
        }
    }

    private var header: some View {
        HStack(spacing: 12) {
            Image(systemName: "waveform.path").font(.system(size: 23, weight: .medium)).foregroundStyle(.tint)
            Text("MonoSplit").font(.system(size: 20, weight: .semibold, design: .rounded))
            Text("单声道 · 三路分频").font(.callout).foregroundStyle(.secondary)
            Spacer()
            HStack(spacing: 0) {
                Button { model.undo() } label: { Image(systemName: "arrow.uturn.backward") }
                    .disabled(!model.history.canUndo).help("撤销参数修改 · ⌘Z").accessibilityLabel("撤销参数修改")
                Button { model.redo() } label: { Image(systemName: "arrow.uturn.forward") }
                    .disabled(!model.history.canRedo).help("重做参数修改 · ⇧⌘Z").accessibilityLabel("重做参数修改")
            }
            Picker("音箱配置", selection: Binding(get: { model.profile.id }, set: { model.selectProfile($0) })) {
                ForEach(model.profiles) { profile in Text(profile.name).tag(profile.id) }
            }.labelsHidden().frame(width: 185)
            Menu("管理配置") {
                Button("新建配置") { model.addProfile(copy: false) }
                Button("复制当前配置") { model.addProfile(copy: true) }
                Button("重命名") { model.renameText = model.profile.name; model.showRename = true }
                Button("删除当前配置…", role: .destructive) { confirmDelete = true }.disabled(model.profiles.count <= 1)
                Divider()
                Button("导入配置 JSON…") { model.importProfile() }
                Button("导出当前配置…") { model.exportProfile() }
            }.fixedSize()
            Button { showGuide = true } label: { Image(systemName: "questionmark.circle") }
                .buttonStyle(.plain).help("接线与调音指南").accessibilityLabel("接线与调音指南")
            Button { model.toggleRunning() } label: {
                Label(model.busy ? "正在切换" : model.snapshot.requested ? "停止处理" : "启动处理", systemImage: model.snapshot.requested ? "stop.fill" : "play.fill")
                    .frame(minWidth: 82)
            }
            .buttonStyle(.borderedProminent)
            .disabled(model.busy || (!model.snapshot.requested && !model.issues.isEmpty))
            .keyboardShortcut(.return, modifiers: .command)
        }.padding(.horizontal, 18).padding(.vertical, 12)
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("输出声道").font(.headline)
                Spacer()
                Text("L + R → MONO").font(.system(size: 9, weight: .medium, design: .monospaced)).foregroundStyle(.secondary)
            }.padding(.bottom, 4)
            ForEach(ChannelRole.allCases) { role in
                if let index = model.profile.channels.firstIndex(where: { $0.role == role }) {
                    ChannelNavigationCard(channel: $model.profile.channels[index], selected: selectedRole == role, deviceName: deviceName(for: role), levels: model.levels, anySolo: model.profile.channels.contains { $0.enabled && $0.solo }, comparing: model.comparingRole == role, displayGain: model.displayProfile.channels[index].gainDB, select: { select(role) })
                }
            }
            Spacer(minLength: 10)
            if model.profile.channels.contains(where: \.solo) {
                Button("取消全部独听") { model.clearSolos() }.font(.caption).frame(maxWidth: .infinity)
            }
            InputLevelIndicator(levels: model.levels)
            Button {
                editorPage = .routing
            } label: { Label("设置所选声道的输出", systemImage: "cable.connector") }
                .buttonStyle(.plain).font(.caption).foregroundStyle(.secondary)
            Text("⌘1 / ⌘2 / ⌘3 切换声道")
                .font(.system(size: 10)).foregroundStyle(.secondary)
        }
        .padding(12)
        .frame(maxHeight: .infinity, alignment: .top)
        .background(Color(nsColor: .underPageBackgroundColor).opacity(0.45))
    }

    private var workspace: some View {
        GeometryReader { geometry in
            workspaceContent(chartHeight: max(128, min(190, geometry.size.height - 480)))
        }
    }
    private func workspaceContent(chartHeight: CGFloat) -> some View {
        VStack(spacing: 10) {
            HStack(spacing: 12) {
                Picker("响应图类型", selection: $model.phaseMode) {
                    Text("频响").tag(false)
                    Text("相位").tag(true)
                }.pickerStyle(.segmented).labelsHidden().frame(width: 150)
                Toggle("计入总增益", isOn: $model.includeMaster).toggleStyle(.checkbox).font(.caption)
                    .help("将总音量与总前级衰减计入理论曲线")
                Spacer()
                Button { model.captureComparison(role: selectedRole) } label: { Image(systemName: "camera") }
                    .disabled(comparing)
                    .help("保存所选声道的分频、EQ、音量、极性与延迟，供改前改后对比。快照仅在本次使用中保留。")
                    .accessibilityLabel("保存调音快照")
                Toggle("对比快照", isOn: Binding(get: { comparing }, set: { _ in model.toggleComparison(role: selectedRole) }))
                    .toggleStyle(.button).tint(.orange).font(.caption)
                    .disabled(model.comparisons[selectedRole] == nil)
                    .help(comparing ? "正在使用快照参数，点击返回当前编辑" : "对比所选声道的快照，其他声道及总音量保持当前设置")
                ForEach($model.profile.channels) { $channel in
                    Toggle(channel.role.symbol, isOn: $channel.showCurve)
                        .tint(channel.role.tint).toggleStyle(.checkbox)
                        .help("显示\(channel.role.title)响应曲线")
                }
            }.frame(height: 26)
            ResponsePlot(profile: model.displayProfile, sampleRate: model.snapshot.sampleRate, phaseMode: model.phaseMode, includeMaster: model.includeMaster, selectedRole: selectedRole, selectedBandID: selectedBandID, plotHeight: chartHeight, allowEditing: !comparing, onSelectBand: { selectedBandID = $0 }, onEditBand: editBand, onEditGesture: { model.editGesture($0) })
                .equatable()
            ChannelControlStrip(channel: channel, sampleRate: model.snapshot.sampleRate, editGesture: { model.editGesture($0) }).disabled(comparing).id(editorIdentity)
            HStack {
                Text(selectedRole.title).font(.headline).foregroundStyle(selectedRole.tint)
                Toggle("启用声道", isOn: channel.enabled).toggleStyle(.switch).controlSize(.mini)
                    .disabled(comparing)
                if comparing { Text("快照 · 只读").font(.caption).foregroundStyle(.orange) }
                Spacer()
                if model.hasPendingChanges { Text("参数待应用").font(.caption).foregroundStyle(.orange) }
                Picker("参数区域", selection: $editorPage) {
                    ForEach(EditorPage.allCases) { page in Text(page.rawValue).tag(page) }
                }.pickerStyle(.segmented).labelsHidden().frame(width: 225)
            }.frame(height: 28)
            if editorPage == .tuning {
                HStack(alignment: .top, spacing: 12) {
                    CrossoverPanel(channel: channel, sampleRate: model.snapshot.sampleRate, pairedSetup: { showCrossover = true }, editGesture: { model.editGesture($0) }).frame(width: 242)
                    EQTable(channel: channel, selectedBandID: $selectedBandID, sampleRate: model.snapshot.sampleRate, importEQ: { model.importEQ(role: selectedRole) }, copySources: model.profile.channels.filter { $0.role != selectedRole }.map(\.role), copyEQ: { model.copyEQ(from: $0, to: selectedRole) })
                }.frame(maxHeight: .infinity, alignment: .top).disabled(comparing).id(editorIdentity)
            } else {
                RoutingAndMeasurements(channel: channel, devices: model.snapshot.devices, importMeasurement: { model.importMeasurement(role: selectedRole) }).disabled(comparing).id(editorIdentity)
            }
        }.padding(14).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    private var feedbackText: String {
        if let channel = model.profile.channels.first(where: { $0.outputChannels.isEmpty }) {
            return "\(channel.role.title)尚未选择输出通道，请在“设备与测量”中至少勾选一项。"
        }
        return model.issues.first ?? model.message ?? ""
    }
    private var feedback: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "exclamationmark.circle.fill").foregroundStyle(.orange)
            Text(feedbackText).font(.callout).lineLimit(2).textSelection(.enabled)
                .help(model.issues.joined(separator: "\n"))
            Spacer()
            if model.issues.isEmpty {
                Button { model.message = nil } label: { Image(systemName: "xmark") }
                    .buttonStyle(.plain).help("关闭提示")
            }
        }.padding(.horizontal, 16).padding(.vertical, 9).background(Color.orange.opacity(0.08))
    }

    private var footer: some View {
        HStack(spacing: 10) {
            Button { showRouting.toggle() } label: {
                HStack(spacing: 6) {
                    Circle().fill(model.snapshot.running ? Color.green : Color.secondary).frame(width: 7, height: 7)
                    Text(model.snapshot.status).lineLimit(1)
                    Image(systemName: "info.circle").foregroundStyle(.secondary)
                }.frame(maxWidth: 225, alignment: .leading)
            }.buttonStyle(.plain).help("查看音频路由状态")
                .popover(isPresented: $showRouting) { RoutingStatus(snapshot: model.snapshot, levels: model.levels) }
            Text("\(model.snapshot.sampleRate / 1000, specifier: "%.1f") kHz").monospacedDigit().foregroundStyle(.secondary)
            LimiterIndicator(levels: model.levels)
            Spacer(minLength: 8)
            NumericControl(title: "前级", value: profileBinding.preampDB, range: -60...0, unit: "dB").frame(width: 122)
            Text("总音量")
            Slider(value: profileBinding.masterGainDB, in: -60...12, onEditingChanged: { model.editGesture($0) }).frame(width: 94).accessibilityLabel("总音量滑块")
            NumericControl(title: "", value: profileBinding.masterGainDB, range: -60...12, unit: "dB", accessibilityName: "总音量").frame(width: 82)
            Toggle("总静音", isOn: $model.profile.masterMuted).toggleStyle(.button)
        }.font(.caption).padding(.horizontal, 14).padding(.vertical, 9).id(model.profile.id)
    }

    private func deviceName(for role: ChannelRole) -> String {
        guard let channel = model.profile.channels.first(where: { $0.role == role }) else { return "选择输出设备" }
        return model.snapshot.devices.first { $0.uid == channel.deviceUID }?.name ?? (channel.deviceUID.isEmpty ? "选择输出设备" : "设备未连接")
    }
    private func select(_ role: ChannelRole) {
        model.editGesture(false)
        model.endComparison()
        selectedRole = role
        selectedBandID = nil
        if let index = model.profile.channels.firstIndex(where: { $0.role == role }), !model.profile.channels[index].showCurve {
            model.profile.channels[index].showCurve = true
        }
    }
    private func editBand(_ id: UUID, _ frequency: Double, _ gain: Double) {
        guard !comparing else { return }
        var profile = model.profile
        guard let index = profile.channels[channelIndex].bands.firstIndex(where: { $0.id == id }) else { return }
        profile.channels[channelIndex].bands[index].frequency = frequency
        if profile.channels[channelIndex].bands[index].kind.hasGain { profile.channels[channelIndex].bands[index].gainDB = gain }
        model.profile = profile
    }
}

struct ChannelNavigationCard: View {
    @Binding var channel: ChannelSettings
    var selected: Bool
    var deviceName: String
    var levels: AudioLevels
    var anySolo: Bool
    var comparing: Bool
    var displayGain: Double
    var select: () -> Void
    private var peak: Float { levels.meter.peaks[ChannelRole.allCases.firstIndex(of: channel.role)!] }
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button(action: select) {
                HStack(spacing: 8) {
                    Text(channel.role.symbol).font(.system(size: 20, weight: .bold, design: .monospaced)).foregroundStyle(channel.role.tint)
                        .frame(width: 31, height: 33).background(channel.role.tint.opacity(0.12), in: RoundedRectangle(cornerRadius: 6))
                    VStack(alignment: .leading, spacing: 3) {
                        Text(channel.role.title).font(.system(size: 13, weight: .semibold)).foregroundStyle(.primary)
                        Text(deviceName).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }.buttonStyle(.plain).accessibilityLabel("选择\(channel.role.title)")
                .keyboardShortcut(KeyEquivalent(Character(String(ChannelRole.allCases.firstIndex(of: channel.role)! + 1))), modifiers: .command)
            HStack {
                Text(channel.enabled ? "\(displayGain, specifier: "%+.1f") dB" : "声道已关闭").font(.system(.caption, design: .monospaced)).foregroundStyle(.secondary)
                Spacer()
                Toggle("静音", isOn: $channel.muted).toggleStyle(.button).accessibilityLabel("\(channel.role.title)静音")
                Toggle("独听", isOn: $channel.solo).toggleStyle(.button).accessibilityLabel("\(channel.role.title)独听")
            }.font(.caption2).controlSize(.mini)
            HStack(spacing: 4) {
                Text(comparing ? "快照对比中" : !channel.enabled ? "输出关闭" : channel.muted ? "已静音" : anySolo && !channel.solo ? "其他声道独听中" : channel.solo ? "独听中" : "通道 " + channel.outputChannels.map(String.init).joined(separator: "、"))
                    .lineLimit(1).foregroundStyle(comparing || channel.muted || (anySolo && !channel.solo) ? Color.orange : .secondary)
                Spacer(minLength: 0)
                Text(peak > 0.000001 ? String(format: "%.1f", 20 * log10(Double(peak))) : "−∞")
                    .monospacedDigit().foregroundStyle(.secondary)
            }.font(.system(size: 10))
            GeometryReader { geometry in
                let fraction = min(1, max(0, (20 * log10(max(Double(peak), 0.000001)) + 60) / 60))
                ZStack(alignment: .leading) {
                    Capsule().fill(.quaternary)
                    Capsule().fill(channel.role.tint).frame(width: geometry.size.width * fraction)
                }
            }.frame(height: 3).accessibilityLabel("\(channel.role.title)输出电平")
        }
        .padding(10)
        .background(selected ? channel.role.tint.opacity(0.08) : Color(nsColor: .controlBackgroundColor).opacity(0.6), in: RoundedRectangle(cornerRadius: 9))
        .overlay { RoundedRectangle(cornerRadius: 9).strokeBorder(selected ? channel.role.tint.opacity(0.7) : Color.secondary.opacity(0.12), lineWidth: 1) }
    }
}

struct RoutingStatus: View {
    var snapshot: AudioStatus
    var levels: AudioLevels
    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            Text("音频路由").font(.headline)
            Text(snapshot.status)
            ForEach(snapshot.routeDescription, id: \.self) { Text($0) }
            if !snapshot.missing.isEmpty { Text("等待设备 · " + snapshot.missing.joined(separator: "、")).foregroundStyle(.orange) }
            Text("输入峰值 \(20 * log10(max(Double(levels.meter.inputPeak), 0.000001)), specifier: "%.1f") dBFS")
            Text("已渲染 \(levels.meter.renderedFrames) 帧")
            Text("非有限输入 \(levels.meter.nonFiniteSamples) 个")
            DisclosureGroup("详细信息") {
                ForEach(snapshot.diagnostics, id: \.self) { Text($0).font(.system(.caption2, design: .monospaced)) }
            }
        }.font(.caption).textSelection(.enabled).padding(18).frame(minWidth: 300, alignment: .leading)
    }
}

private struct InputLevelIndicator: View {
    var levels: AudioLevels
    var body: some View {
        HStack {
            Text("输入峰值").foregroundStyle(.secondary)
            Spacer()
            Text(levels.meter.inputPeak > 0.000001 ? String(format: "%.1f dBFS", 20 * log10(Double(levels.meter.inputPeak))) : "−∞ dBFS")
                .monospacedDigit()
        }.font(.system(size: 10))
    }
}

private struct LimiterIndicator: View {
    var levels: AudioLevels
    var body: some View {
        Text("限幅 \(levels.meter.limiterReductionDB, specifier: "%.1f") dB")
            .monospacedDigit().foregroundStyle(levels.meter.limiterReductionDB > 0.2 ? .orange : .secondary)
    }
}

/// Edits remain local until Return or focus loss. This permits minus signs and fractional Q values.
struct NumericControl: View {
    var title: String
    @Binding var value: Double
    var range: ClosedRange<Double>
    var unit = ""
    var decimals = 1
    var step: Double = 0.1
    var accessibilityName: String? = nil
    @State private var draft = ""
    @State private var invalid = false
    @FocusState private var focused: Bool

    var body: some View {
        HStack(spacing: 5) {
            if !title.isEmpty { Text(title).foregroundStyle(.secondary).lineLimit(1) }
            TextField(title.isEmpty ? unit : title, text: $draft)
                .textFieldStyle(.roundedBorder).multilineTextAlignment(.trailing)
                .font(.system(size: 12, design: .monospaced))
                .frame(minWidth: 44)
                .focused($focused)
                .overlay { if invalid { RoundedRectangle(cornerRadius: 5).strokeBorder(Color.orange, lineWidth: 1) } }
                .accessibilityLabel(accessibilityName ?? (title.isEmpty ? unit : title))
                .accessibilityHint(invalid ? "数值超出允许范围" : "回车应用，上下方向键微调，Shift 加快，Option 精调")
                .help(invalid ? "请输入 \(range.lowerBound) 至 \(range.upperBound) 的有效数值" : "回车应用 · ↑↓ 微调 · Shift ×10 · Option ÷10")
                .onSubmit { commit() }
                .onExitCommand { synchronize(); focused = false }
                .onKeyPress(.upArrow, phases: [.down, .repeat]) { key in adjust(direction: 1, modifiers: key.modifiers); return .handled }
                .onKeyPress(.downArrow, phases: [.down, .repeat]) { key in adjust(direction: -1, modifiers: key.modifiers); return .handled }
            if !unit.isEmpty { Text(unit).foregroundStyle(.secondary).font(.caption) }
        }
        .onAppear(perform: synchronize)
        .onChange(of: value) { synchronize() }
        .onChange(of: focused) { if focused { synchronize() } else { commit() } }
    }
    private func parsed() -> Double? {
        Double(draft.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: "−", with: "-").replacingOccurrences(of: ",", with: ""))
    }
    private func commit() {
        guard let number = parsed(), number.isFinite, range.contains(number) else { invalid = true; return }
        if number != value { value = number }
        draft = formatted(number)
        invalid = false
    }
    private func synchronize() {
        draft = formatted(value)
        invalid = false
    }
    private func formatted(_ number: Double) -> String {
        number.formatted(.number.locale(Locale(identifier: "en_US_POSIX")).grouping(.never).precision(.fractionLength(decimals...max(6, decimals))))
    }
    private func adjust(direction: Double, modifiers: EventModifiers) {
        let multiplier = modifiers.contains(.shift) ? 10.0 : modifiers.contains(.option) ? 0.1 : 1
        let next = min(max((parsed() ?? value) + direction * step * multiplier, range.lowerBound), range.upperBound)
        if next.isFinite { value = next; draft = formatted(next); invalid = false }
    }
}

struct EQImportSheet: View {
    var preview: EQPreview
    var apply: () -> Void
    var cancel: () -> Void
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("导入 EQ · \(preview.role.title)").font(.title2.bold())
            Text(preview.source).foregroundStyle(.secondary)
            Text("支路前级 \(preview.result.preampDB, specifier: "%.2f") dB · \(preview.result.bands.count) 段滤波器").font(.callout)
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(Array(preview.result.bands.enumerated()), id: \.offset) { index, band in
                        HStack {
                            Text("\(index + 1)").frame(width: 25)
                            Text(band.enabled ? "ON" : "OFF").frame(width: 32)
                            Text(band.kind.title).frame(width: 85, alignment: .leading)
                            Spacer()
                            Text("\(band.frequency, specifier: "%.1f") Hz   \(band.gainDB, specifier: "%+.2f") dB   Q \(band.q, specifier: "%.3f")")
                        }.font(.system(.caption, design: .monospaced))
                    }
                    ForEach(preview.result.issues) { issue in Text(issue.description).foregroundStyle(.orange).textSelection(.enabled) }
                }.frame(maxWidth: .infinity, alignment: .leading)
            }.frame(minHeight: 180, maxHeight: 400)
            Text("应用后将替换所选支路的 EQ 列表和支路前级，分频设置保留。")
                .font(.caption).foregroundStyle(.secondary)
            HStack {
                Spacer()
                Button("取消", action: cancel).keyboardShortcut(.cancelAction)
                Button("应用到\(preview.role.title)", action: apply).buttonStyle(.borderedProminent).disabled(!preview.result.canApply).keyboardShortcut(.defaultAction)
            }
        }.padding(24).frame(width: 650)
    }
}
