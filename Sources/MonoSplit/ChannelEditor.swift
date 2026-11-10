import SwiftUI
import MonoSplitCore

struct ChannelControlStrip: View {
    @Binding var channel: ChannelSettings
    var sampleRate: Double
    var editGesture: (Bool) -> Void
    var body: some View {
        HStack(spacing: 14) {
            HStack(spacing: 8) {
                Text("声道音量").foregroundStyle(.secondary)
                Slider(value: $channel.gainDB, in: -60...12, onEditingChanged: editGesture).tint(channel.role.tint)
                    .frame(minWidth: 75, maxWidth: 150).accessibilityLabel("声道音量滑块")
                NumericControl(title: "", value: $channel.gainDB, range: -60...12, unit: "dB", accessibilityName: "声道音量").frame(width: 82)
            }
            Divider().frame(height: 25)
            Toggle(isOn: $channel.inverted) {
                Label("极性反转", systemImage: "plusminus")
            }.toggleStyle(.button).help("将声道极性反转 180°")
            Spacer(minLength: 0)
            NumericControl(title: "延迟", value: $channel.delayMS, range: 0...2000, unit: "ms", decimals: 2, step: 0.01).frame(width: 143)
            Stepper("延迟微调", value: $channel.delayMS, in: 0...2000, step: 0.1).labelsHidden().help("每次调整 0.1 ms，也可在输入框使用方向键精调")
            Text("\(Int((channel.delayMS * sampleRate / 1000).rounded()))\n采样点")
                .font(.system(size: 9, design: .monospaced)).foregroundStyle(.secondary).multilineTextAlignment(.trailing).frame(minWidth: 42)
                .help("实际延迟 \(FilterMath.effectiveDelayMS(channel.delayMS, sampleRate: sampleRate)) ms")
        }
        .font(.caption)
        .padding(.horizontal, 12).padding(.vertical, 9)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
    }
}

struct CrossoverPanel: View {
    @Binding var channel: ChannelSettings
    var sampleRate: Double
    var pairedSetup: () -> Void
    var editGesture: (Bool) -> Void
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("分频", systemImage: "line.diagonal").font(.headline)
            ScrollView {
                VStack(spacing: 10) {
                    CrossoverEditor(title: "高通", crossover: $channel.highPass, sampleRate: sampleRate, tint: channel.role.tint, editGesture: editGesture)
                    Divider()
                    CrossoverEditor(title: "低通", crossover: $channel.lowPass, sampleRate: sampleRate, tint: channel.role.tint, editGesture: editGesture)
                }
            }.scrollBounceBehavior(.basedOnSize)
            if channel.role != .builtin {
                Button(action: pairedSetup) { Label("左右配对分频…", systemImage: "link") }.frame(maxWidth: .infinity)
                    .help("选择左右声道的低通、高通分配")
            }
        }
        .padding(12)
        .frame(maxHeight: .infinity, alignment: .top)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 9))
    }
}

struct CrossoverEditor: View {
    var title: String
    @Binding var crossover: Crossover
    var sampleRate: Double
    var tint: Color
    var editGesture: (Bool) -> Void
    private var maximum: Double { min(20000, sampleRate * 0.499) }
    private var logarithmicFrequency: Binding<Double> {
        Binding(get: { log10(min(max(crossover.frequency, 20), maximum)) }, set: { crossover.frequency = (pow(10, $0) * 10).rounded() / 10 })
    }
    var body: some View {
        VStack(spacing: 5) {
            HStack {
                Toggle(title, isOn: $crossover.enabled).toggleStyle(.checkbox).font(.system(size: 13, weight: .medium))
                    .help(title == "高通" ? "削减低于截止频率的声音" : "削减高于截止频率的声音")
                Spacer()
                NumericControl(title: "", value: $crossover.frequency, range: 1...96000, unit: "Hz", decimals: 1, step: 1, accessibilityName: "\(title)截止频率").frame(width: 104)
            }
            Picker("\(title)滤波类型", selection: $crossover.shape) {
                ForEach(CrossoverShape.allCases) { shape in Text(shape.title).tag(shape) }
            }.labelsHidden().font(.caption)
            Slider(value: logarithmicFrequency, in: log10(20)...log10(maximum), onEditingChanged: editGesture).tint(tint)
                .accessibilityLabel("\(title)截止频率滑块")
            if crossover.frequency >= sampleRate / 2 {
                Label("频率须低于 \(Int(sampleRate / 2)) Hz", systemImage: "exclamationmark.triangle")
                    .font(.caption2).foregroundStyle(.orange).frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }
}

struct EQTable: View {
    @Binding var channel: ChannelSettings
    @Binding var selectedBandID: UUID?
    var sampleRate: Double
    var importEQ: () -> Void
    var copySources: [ChannelRole]
    var copyEQ: (ChannelRole) -> Void
    private let columns = [GridItem(.fixed(23)), GridItem(.fixed(24)), GridItem(.flexible(minimum: 86)), GridItem(.fixed(91)), GridItem(.fixed(75)), GridItem(.fixed(70)), GridItem(.fixed(22))]
    var body: some View {
        VStack(spacing: 9) {
            HStack(spacing: 8) {
                Toggle("参数 EQ", isOn: $channel.eqEnabled).toggleStyle(.checkbox).font(.headline)
                Text("\(channel.bands.count)/20").font(.caption).foregroundStyle(.secondary)
                if !channel.eqEnabled { Text("已旁路").font(.caption2).foregroundStyle(.orange) }
                Spacer()
                Menu {
                    Button("复制所选滤波器", action: duplicateBand).disabled(selectedBandID == nil || channel.bands.count >= 20)
                    Button("所有 EQ 增益归零") {
                        var next = channel
                        for index in next.bands.indices where next.bands[index].kind.hasGain { next.bands[index].gainDB = 0 }
                        channel = next
                    }.disabled(!channel.bands.contains { $0.kind.hasGain && $0.gainDB != 0 })
                    Menu("从其他声道复制 EQ") {
                        ForEach(copySources) { role in Button(role.title) { copyEQ(role) } }
                    }
                    Divider()
                    Button("清空 EQ", role: .destructive) {
                        var next = channel
                        next.bands = []
                        next.preampDB = 0
                        channel = next
                    }.disabled(channel.bands.isEmpty && channel.preampDB == 0)
                } label: { Image(systemName: "ellipsis.circle") }
                    .menuStyle(.borderlessButton).fixedSize().help("EQ 操作，可用 ⌘Z 撤销").accessibilityLabel("EQ 操作")
                Button("导入 REW…", action: importEQ)
                Button(action: addBand) { Image(systemName: "plus") }
                    .disabled(channel.bands.count >= 20).help("添加滤波器").accessibilityLabel("添加滤波器")
            }
            LazyVGrid(columns: columns, spacing: 0) {
                Text("#")
                Text("开")
                Text("类型").frame(maxWidth: .infinity, alignment: .leading)
                Text("频率 · Hz")
                Text("增益 · dB")
                Text("Q")
                Color.clear.frame(height: 1)
            }.font(.system(size: 10, weight: .medium)).foregroundStyle(.secondary).padding(.horizontal, 7)
            Divider()
            if channel.bands.isEmpty {
                ViewThatFits(in: .vertical) {
                    VStack(spacing: 9) {
                        Image(systemName: "slider.horizontal.3").font(.system(size: 26, weight: .light)).foregroundStyle(channel.role.tint)
                        Text("从一个滤波器开始").font(.callout.weight(.medium))
                        Text("添加后可在曲线上拖动控制点，\n或直接在表格中输入 REW 参数。")
                            .font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center)
                        HStack {
                            Button("添加滤波器", action: addBand).buttonStyle(.borderedProminent).tint(channel.role.tint)
                            Button("导入 REW…", action: importEQ)
                        }
                    }.fixedSize(horizontal: false, vertical: true)
                    HStack(spacing: 10) {
                        Text("EQ 平直").foregroundStyle(.secondary)
                        Button("添加滤波器", action: addBand).buttonStyle(.borderedProminent).tint(channel.role.tint)
                        Button("导入 REW…", action: importEQ)
                    }.fixedSize(horizontal: false, vertical: true)
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(spacing: 3) {
                            ForEach($channel.bands) { $band in
                                EQTableRow(band: $band, number: (channel.bands.firstIndex { $0.id == band.id } ?? 0) + 1, selected: selectedBandID == band.id, tint: channel.role.tint, columns: columns, sampleRate: sampleRate, select: { selectedBandID = band.id }, remove: {
                                    let id = band.id
                                    channel.bands.removeAll { $0.id == id }
                                }).id(band.id)
                            }
                        }
                    }
                    .onChange(of: selectedBandID) {
                        if let selectedBandID { proxy.scrollTo(selectedBandID, anchor: .center) }
                    }
                    .onAppear {
                        if let selectedBandID { proxy.scrollTo(selectedBandID, anchor: .center) }
                    }
                }
            }
            Divider()
            HStack {
                NumericControl(title: "EQ 前级", value: $channel.preampDB, range: -60...12, unit: "dB").frame(width: 155)
                Spacer()
                Text("回车应用 · ↑↓ 微调").font(.system(size: 10)).foregroundStyle(.secondary)
            }
        }
        .controlSize(.small)
        .padding(12)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 9))
    }
    private func addBand() {
        guard channel.bands.count < 20 else { return }
        let band = EQBand()
        channel.bands.append(band)
        selectedBandID = band.id
    }
    private func duplicateBand() {
        guard channel.bands.count < 20, let selectedBandID,
              let source = channel.bands.first(where: { $0.id == selectedBandID }) else { return }
        var copy = source
        copy.id = UUID()
        channel.bands.append(copy)
        self.selectedBandID = copy.id
    }
}

private struct EQTableRow: View {
    @Binding var band: EQBand
    var number: Int
    var selected: Bool
    var tint: Color
    var columns: [GridItem]
    var sampleRate: Double
    var select: () -> Void
    var remove: () -> Void
    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            LazyVGrid(columns: columns, spacing: 0) {
                Button(action: select) { Text("\(number)").font(.system(size: 11, weight: .medium, design: .monospaced)).foregroundStyle(selected ? tint : .secondary) }
                    .buttonStyle(.plain).accessibilityLabel("选择 EQ \(number)")
                Toggle("EQ \(number) 启用", isOn: $band.enabled).labelsHidden().toggleStyle(.checkbox)
                Picker("EQ \(number) 类型", selection: $band.kind) {
                    ForEach(FilterKind.allCases) { kind in Text(kind.title).tag(kind) }
                }.labelsHidden().font(.caption)
                NumericControl(title: "", value: $band.frequency, range: 1...96000, decimals: 1, step: 1, accessibilityName: "EQ \(number) 频率")
                NumericControl(title: "", value: $band.gainDB, range: -30...30, decimals: 2, accessibilityName: "EQ \(number) 增益").disabled(!band.kind.hasGain)
                NumericControl(title: "", value: $band.q, range: 0.05...100, decimals: 4, step: 0.01, accessibilityName: "EQ \(number) Q")
                Button(action: remove) { Image(systemName: "minus.circle") }.buttonStyle(.plain).foregroundStyle(.secondary).help("删除 EQ \(number)")
            }
            if band.frequency >= sampleRate / 2 {
                Label("EQ \(number) 频率须低于 \(Int(sampleRate / 2)) Hz", systemImage: "exclamationmark.triangle")
                    .font(.caption2).foregroundStyle(.orange)
            }
        }
        .padding(.horizontal, 7).padding(.vertical, 5)
        .background(selected ? tint.opacity(0.09) : Color.clear, in: RoundedRectangle(cornerRadius: 5))
        .contentShape(Rectangle())
        .simultaneousGesture(TapGesture().onEnded { _ in select() })
    }
}

struct RoutingAndMeasurements: View {
    @Binding var channel: ChannelSettings
    var devices: [OutputDevice]
    var importMeasurement: () -> Void
    private var device: OutputDevice? { devices.first { $0.uid == channel.deviceUID } }
    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 12) {
                Label("输出设备", systemImage: "cable.connector").font(.headline)
                Picker("设备", selection: Binding(get: { channel.deviceUID }, set: { chooseDevice($0) })) {
                    Text("选择输出设备").tag("")
                    if !channel.deviceUID.isEmpty && device == nil { Text("已保存设备 · 未连接").tag(channel.deviceUID) }
                    ForEach(devices) { device in Text(device.name + (device.bluetooth ? " · 蓝牙" : "")).tag(device.uid) }
                }.labelsHidden()
                if let device {
                    Text("\(device.channelCount) 个独立输出 · \(device.sampleRate / 1000, specifier: "%.1f") kHz").font(.caption).foregroundStyle(.secondary)
                    Text("软件可独立控制的路数，以设备提供的输出通道为准。").font(.caption).foregroundStyle(.secondary)
                    Text("播放到以下物理通道").font(.caption).foregroundStyle(.secondary)
                    ScrollView {
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 78))], spacing: 7) {
                            ForEach(1...device.channelCount, id: \.self) { number in
                                Toggle("通道 \(number)", isOn: Binding(get: { channel.outputChannels.contains(number) }, set: { enabled in
                                    var outputs = channel.outputChannels.filter { $0 != number }
                                    if enabled { outputs.append(number) }
                                    channel.outputChannels = outputs.sorted()
                                })).toggleStyle(.button).tint(channel.role.tint)
                            }
                        }
                    }
                } else {
                    Text("选择设备后，可直接勾选物理输出通道。").font(.caption).foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
            }.padding(14).frame(width: 265).frame(maxHeight: .infinity, alignment: .top)
                .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 9))
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Label("REW 测量参考", systemImage: "waveform.path.ecg").font(.headline)
                    Spacer()
                    Button("导入测量…", action: importMeasurement)
                }
                if channel.measurements.isEmpty {
                    VStack(spacing: 8) {
                        Text("将实际测量叠加到响应曲线").font(.callout)
                        Text("导入 REW 导出的频率、SPL 与可选相位文本。").font(.caption).foregroundStyle(.secondary)
                        Button("选择测量文件…", action: importMeasurement)
                    }.frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    ScrollView {
                        VStack(spacing: 12) {
                            ForEach($channel.measurements) { $reference in
                                HStack {
                                    Toggle(reference.name, isOn: $reference.visible).toggleStyle(.checkbox).lineLimit(1).help(reference.source)
                                    Spacer()
                                    NumericControl(title: "偏移", value: $reference.offsetDB, range: -150...150, unit: "dB").frame(width: 125)
                                    Button {
                                        let id = reference.id
                                        channel.measurements.removeAll { $0.id == id }
                                    } label: { Image(systemName: "trash") }.buttonStyle(.plain).help("移除测量参考")
                                }
                            }
                        }
                    }
                }
            }.padding(14).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 9))
        }.font(.caption).frame(maxHeight: .infinity)
    }
    private func chooseDevice(_ uid: String) {
        var next = channel
        next.deviceUID = uid
        if let selected = devices.first(where: { $0.uid == uid }) {
            next.outputChannels = next.outputChannels.filter { $0 <= selected.channelCount }
            if next.outputChannels.isEmpty { next.outputChannels = [min(channel.role == .fullRange ? 2 : 1, selected.channelCount)] }
        }
        channel = next
    }
}
