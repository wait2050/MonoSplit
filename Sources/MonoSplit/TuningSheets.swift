import SwiftUI
import MonoSplitCore

struct PairedCrossoverSheet: View {
    var sampleRate: Double
    var apply: (Double, CrossoverShape, ChannelRole) -> Void
    @Environment(\.dismiss) private var dismiss
    @FocusState private var frequencyFocused: Bool
    @State private var frequencyText: String
    @State private var shape: CrossoverShape
    @State private var lowPassRole: ChannelRole

    init(profile: SpeakerProfile, sampleRate: Double, apply: @escaping (Double, CrossoverShape, ChannelRole) -> Void) {
        self.sampleRate = sampleRate
        self.apply = apply
        let left = profile.channels.first { $0.role == .woofer }
        let right = profile.channels.first { $0.role == .fullRange }
        let role: ChannelRole = right?.lowPass.enabled == true && left?.highPass.enabled == true && left?.lowPass.enabled != true && right?.highPass.enabled != true ? .fullRange : .woofer
        _lowPassRole = State(initialValue: role)
        let existing = profile.channels.first { $0.role == role }?.lowPass ?? Crossover()
        _frequencyText = State(initialValue: String(format: "%.1f", existing.frequency))
        _shape = State(initialValue: existing.shape == .linkwitzRiley48 ? .linkwitzRiley48 : .linkwitzRiley24)
    }
    private var frequency: Double? {
        guard let value = Double(frequencyText.trimmingCharacters(in: .whitespacesAndNewlines)),
              value.isFinite, (20...20000).contains(value), value < sampleRate / 2 else { return nil }
        return value
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack(spacing: 10) {
                Image(systemName: "link").font(.title2).foregroundStyle(.tint)
                VStack(alignment: .leading, spacing: 4) {
                    Text("左右配对分频").font(.title2.bold())
                    Text("选择左右两路各自通过的频段").foregroundStyle(.secondary)
                }
            }
            HStack(spacing: 12) {
                branch(ChannelRole.woofer.title, detail: lowPassRole == .woofer ? "低通 · 通过低频" : "高通 · 通过高频", role: .woofer, icon: "speaker.wave.2")
                Image(systemName: "arrow.left.and.right").foregroundStyle(.secondary)
                branch(ChannelRole.fullRange.title, detail: lowPassRole == .fullRange ? "低通 · 通过低频" : "高通 · 通过高频", role: .fullRange, icon: "speaker.wave.2")
            }
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text("频段分配").frame(width: 80, alignment: .leading)
                    Picker("频段分配", selection: $lowPassRole) {
                        Text("左声道低通 / 右声道高通").tag(ChannelRole.woofer)
                        Text("左声道高通 / 右声道低通").tag(ChannelRole.fullRange)
                    }.labelsHidden()
                }
                HStack {
                    Text("分频点").frame(width: 80, alignment: .leading)
                    TextField("频率", text: $frequencyText).textFieldStyle(.roundedBorder)
                        .focused($frequencyFocused).multilineTextAlignment(.trailing).frame(width: 120)
                        .accessibilityLabel("配对分频点")
                    Text("Hz").foregroundStyle(.secondary)
                }
                HStack {
                    Text("滤波类型").frame(width: 80, alignment: .leading)
                    Picker("配对滤波类型", selection: $shape) {
                        Text("Linkwitz–Riley · 24 dB/oct").tag(CrossoverShape.linkwitzRiley24)
                        Text("Linkwitz–Riley · 48 dB/oct").tag(CrossoverShape.linkwitzRiley48)
                    }.labelsHidden()
                }
                Text(frequency == nil ? "请输入 20–\(Int(min(20000, sampleRate / 2 - 1))) Hz 范围内的有效分频点。" : "根据音箱参数和测量选择分频点。每个声道均可连接任意类型的音箱。")
                    .font(.caption).foregroundStyle(frequency == nil ? Color.orange : .secondary)
            }
            Text("应用会替换左右两路的高通、低通开关与所用分频参数。EQ、音量、极性和延迟继续使用当前设置。")
                .font(.caption).foregroundStyle(.secondary)
            Divider()
            HStack {
                Text("应用后可用 ⌘Z 整体撤销").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("取消", role: .cancel) { dismiss() }.keyboardShortcut(.cancelAction)
                Button("应用左右分频") {
                    guard let frequency else { return }
                    apply(frequency, shape, lowPassRole)
                    dismiss()
                }.buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction).disabled(frequency == nil)
            }
        }.padding(26).frame(width: 510).onAppear { frequencyFocused = true }
    }
    private func branch(_ title: String, detail: String, role: ChannelRole, icon: String) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            Image(systemName: icon).font(.title2)
            Text(title).font(.headline)
            Text(detail).font(.caption)
        }.foregroundStyle(role.tint).frame(maxWidth: .infinity, alignment: .leading)
            .padding(16).background(role.tint.opacity(0.08), in: RoundedRectangle(cornerRadius: 9))
    }
}

struct QuickStartGuide: View {
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack(spacing: 12) {
                Image(systemName: "waveform.path").font(.system(size: 32)).foregroundStyle(.tint)
                VStack(alignment: .leading, spacing: 4) {
                    Text("接线与调音").font(.title2.bold())
                    Text("系统立体声 → 单声道 → 三路独立处理").foregroundStyle(.secondary)
                }
            }
            HStack(spacing: 10) {
                route(.woofer, destination: "YS Audio · 通道 1")
                route(.fullRange, destination: "YS Audio · 通道 2")
                route(.builtin, destination: "内置扬声器 · 通道 1、2")
            }
            instruction("确认输出", icon: "cable.connector", detail: "在“设备与测量”选择设备并勾选通道。未接好的支路可关闭“启用声道”。")
            instruction("设置分频", icon: "line.diagonal", detail: "左右声道均可连接任意类型的音箱，分别调整高通与低通；也可用“左右配对分频”选择频段分配。分频点根据音箱和测量决定。")
            instruction("逐路调音", icon: "slider.horizontal.3", detail: "用左侧“独听”逐路检查，再调整 EQ、极性与延迟。导入 REW 参数前会显示预览。")
            instruction("保存与比较", icon: "camera", detail: "修改自动保存。先点击相机存快照，再修改参数，用“对比快照”切换所选声道的改前改后。⌘Z 撤销，⇧⌘Z 重做。")
            Divider()
            HStack(alignment: .center) {
                Text("独立模式请先退出 FineTune；联动时先启用“FineTune 输入”。首次启动按提示允许音频录制，建议从较低总音量开始。")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 20)
                Button("开始调音") { dismiss() }.buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
            }
        }.padding(26).frame(width: 630).onExitCommand { dismiss() }
    }
    private func route(_ role: ChannelRole, destination: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(role.symbol).font(.system(size: 24, weight: .bold, design: .monospaced))
            Text(role.title).font(.headline)
            Text(destination).font(.caption)
        }.foregroundStyle(role.tint).frame(maxWidth: .infinity, alignment: .leading)
            .padding(14).background(role.tint.opacity(0.08), in: RoundedRectangle(cornerRadius: 9))
    }
    private func instruction(_ title: String, icon: String, detail: String) -> some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: icon).font(.system(size: 17)).foregroundStyle(.secondary).frame(width: 22)
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.headline)
                Text(detail).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}
