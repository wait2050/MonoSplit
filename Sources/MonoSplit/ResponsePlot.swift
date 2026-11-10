import SwiftUI
import MonoSplitCore

private struct PlotCurve {
    var role: ChannelRole
    var theoretical: [CGPoint]
    var measurements: [[CGPoint]]
    var enabled: Bool
}

private struct BandHandle {
    var id: UUID
    var number: Int
    var frequency: Double
    var responseDB: Double
}

private struct ResponseGeometry {
    var size: CGSize
    var maximumFrequency: Double
    var phase: Bool
    var bounds: CGRect { CGRect(x: 38, y: 9, width: max(10, size.width - 82), height: max(10, size.height - 33)) }
    var low: Double { phase ? -180 : -60 }
    var high: Double { phase ? 180 : 24 }
    func x(_ frequency: Double) -> Double { bounds.minX + log(frequency / 20) / log(maximumFrequency / 20) * bounds.width }
    func y(_ value: Double) -> Double { bounds.maxY - (value - low) / (high - low) * bounds.height }
    func frequency(at x: Double) -> Double {
        20 * pow(maximumFrequency / 20, min(max((x - bounds.minX) / bounds.width, 0), 1))
    }
    func value(at y: Double) -> Double { low + min(max((bounds.maxY - y) / bounds.height, 0), 1) * (high - low) }
}

struct ResponsePlot: View, Equatable {
    var profile: SpeakerProfile
    var sampleRate: Double
    var phaseMode: Bool
    var includeMaster: Bool
    var selectedRole: ChannelRole
    var selectedBandID: UUID?
    var plotHeight: CGFloat = 156
    var allowEditing = true
    var onSelectBand: (UUID) -> Void
    var onEditBand: (UUID, Double, Double) -> Void
    var onEditGesture: (Bool) -> Void
    @State private var curves: [PlotCurve] = []
    @State private var splFloor: Double = 20
    @State private var splCeiling: Double = 110
    @State private var draggingBand: UUID?
    @State private var hoverLocation: CGPoint?

    nonisolated static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.profile == rhs.profile && lhs.sampleRate == rhs.sampleRate && lhs.phaseMode == rhs.phaseMode && lhs.includeMaster == rhs.includeMaster && lhs.selectedRole == rhs.selectedRole && lhs.selectedBandID == rhs.selectedBandID && lhs.plotHeight == rhs.plotHeight && lhs.allowEditing == rhs.allowEditing
    }
    private var upperFrequency: Double { min(20000, sampleRate * 0.499) }
    private var masterDB: Double { includeMaster ? profile.masterGainDB + profile.preampDB : 0 }
    private var handles: [BandHandle] {
        guard !phaseMode, let channel = profile.channels.first(where: { $0.role == selectedRole }), channel.showCurve, channel.eqEnabled else { return [] }
        return channel.bands.enumerated().compactMap { index, band in
            guard band.enabled, (20...upperFrequency).contains(band.frequency) else { return nil }
            let response = FilterMath.response(channel: channel, frequency: band.frequency, sampleRate: sampleRate, masterDB: masterDB)
            let db = 20 * log10(max(response.magnitude, 1e-12))
            guard db.isFinite, (-60...24).contains(db) else { return nil }
            return BandHandle(id: band.id, number: index + 1, frequency: band.frequency, responseDB: db)
        }
    }

    var body: some View {
        let maximumFrequency = upperFrequency
        let floorValue = splFloor
        let ceilingValue = splCeiling
        let isPhase = phaseMode
        let activeRole = selectedRole
        let activeBand = selectedBandID
        let nodes = handles.filter { $0.id != activeBand } + handles.filter { $0.id == activeBand }
        return VStack(spacing: 6) {
            GeometryReader { reader in
                let geometry = ResponseGeometry(size: reader.size, maximumFrequency: maximumFrequency, phase: isPhase)
                Canvas { context, size in
                    let frequencyTicks = [20.0, 50, 100, 200, 500, 1000, 2000, 5000, 10000, 20000].filter { $0 <= maximumFrequency }
                    let valueTicks = isPhase ? [-180.0, -90, 0, 90, 180] : [-60.0, -36, -12, 0, 12, 24]
                    for frequency in frequencyTicks {
                        var line = Path()
                        line.move(to: CGPoint(x: geometry.x(frequency), y: geometry.bounds.minY))
                        line.addLine(to: CGPoint(x: geometry.x(frequency), y: geometry.bounds.maxY))
                        context.stroke(line, with: .color(.secondary.opacity(0.13)), lineWidth: 0.7)
                        let label = frequency >= 1000 ? "\(Int(frequency / 1000))k" : "\(Int(frequency))"
                        context.draw(Text(label).font(.system(size: 10, design: .monospaced)).foregroundStyle(.secondary), at: CGPoint(x: geometry.x(frequency), y: geometry.bounds.maxY + 14))
                    }
                    for value in valueTicks {
                        var line = Path()
                        line.move(to: CGPoint(x: geometry.bounds.minX, y: geometry.y(value)))
                        line.addLine(to: CGPoint(x: geometry.bounds.maxX, y: geometry.y(value)))
                        context.stroke(line, with: .color(.secondary.opacity(value == 0 ? 0.35 : 0.13)), lineWidth: value == 0 ? 1 : 0.7)
                        context.draw(Text("\(Int(value))").font(.system(size: 10, design: .monospaced)).foregroundStyle(.secondary), at: CGPoint(x: 16, y: geometry.y(value)))
                    }
                    if !isPhase && curves.contains(where: { !$0.measurements.isEmpty }) {
                        for fraction in [0.0, 0.5, 1] {
                            let value = floorValue + (ceilingValue - floorValue) * fraction
                            context.draw(Text("\(Int(value))").font(.system(size: 10, design: .monospaced)).foregroundStyle(.secondary), at: CGPoint(x: geometry.bounds.maxX + 24, y: geometry.bounds.maxY - geometry.bounds.height * fraction))
                        }
                    }
                    context.clip(to: Path(geometry.bounds.insetBy(dx: -7, dy: -7)))
                    for curve in curves {
                        func path(_ points: [CGPoint], measurement: Bool) -> Path {
                            var result = Path()
                            var previous: CGPoint?
                            for point in points where point.x >= 20 && point.x <= maximumFrequency && point.y.isFinite {
                                let yy = measurement && !isPhase ? geometry.bounds.maxY - (point.y - floorValue) / max(1, ceilingValue - floorValue) * geometry.bounds.height : geometry.y(point.y)
                                let plotted = CGPoint(x: geometry.x(point.x), y: yy)
                                if previous == nil || (isPhase && abs(point.y - previous!.y) > 180) { result.move(to: plotted) }
                                else { result.addLine(to: plotted) }
                                previous = point
                            }
                            return result
                        }
                        let opacity = curve.enabled ? (curve.role == activeRole ? 1.0 : 0.65) : 0.3
                        context.stroke(path(curve.theoretical, measurement: false), with: .color(curve.role.tint.opacity(opacity)), lineWidth: curve.role == activeRole ? 2.4 : 1.5)
                        for reference in curve.measurements {
                            context.stroke(path(reference, measurement: true), with: .color(curve.role.tint.opacity(0.45)), style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
                        }
                    }
                    if let location = hoverLocation, geometry.bounds.contains(location) {
                        var ruler = Path()
                        ruler.move(to: CGPoint(x: location.x, y: geometry.bounds.minY))
                        ruler.addLine(to: CGPoint(x: location.x, y: geometry.bounds.maxY))
                        context.stroke(ruler, with: .color(.secondary.opacity(0.45)), style: StrokeStyle(lineWidth: 1, dash: [2, 3]))
                    }
                    for node in nodes {
                        let center = CGPoint(x: geometry.x(node.frequency), y: geometry.y(node.responseDB))
                        let selected = node.id == activeBand
                        let circle = Path(ellipseIn: CGRect(x: center.x - 8, y: center.y - 8, width: 16, height: 16))
                        context.fill(circle, with: .color(selected ? activeRole.tint : Color(nsColor: .textBackgroundColor)))
                        context.stroke(circle, with: .color(activeRole.tint), lineWidth: 1.5)
                        context.draw(Text("\(node.number)").font(.system(size: 9, weight: .bold, design: .monospaced)).foregroundStyle(selected ? Color(nsColor: .textBackgroundColor) : activeRole.tint), at: center)
                    }
                }
                .contentShape(Rectangle())
                .onContinuousHover { phase in
                    switch phase {
                    case .active(let location): hoverLocation = location
                    case .ended: hoverLocation = nil
                    }
                }
                .gesture(DragGesture(minimumDistance: 0).onChanged { value in
                    guard !isPhase, allowEditing else { return }
                    if draggingBand == nil {
                        draggingBand = nodes.min { a, b in
                            let distanceA = distance(a, from: value.startLocation, geometry: geometry)
                            let distanceB = distance(b, from: value.startLocation, geometry: geometry)
                            if abs(distanceA - distanceB) < 0.01 { return a.id == activeBand && b.id != activeBand }
                            return distanceA < distanceB
                        }.flatMap { distance($0, from: value.startLocation, geometry: geometry) <= 15 ? $0.id : nil }
                        if let draggingBand { onEditGesture(true); onSelectBand(draggingBand) }
                    }
                    if let draggingBand { edit(draggingBand, at: value.location, geometry: geometry) }
                }.onEnded { _ in finishDrag() })
                .overlay(alignment: .topTrailing) {
                    if let location = hoverLocation, geometry.bounds.contains(location) {
                        Text(readout(at: location, geometry: geometry))
                            .font(.system(size: 10, design: .monospaced)).padding(.horizontal, 7).padding(.vertical, 4)
                            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 5))
                            .padding(.top, 3).padding(.trailing, 47).allowsHitTesting(false)
                    }
                }
            }
            .frame(height: plotHeight)
            .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 7))
            .accessibilityLabel(phaseMode ? "三路相位响应图" : "三路频率响应图，可拖动所选声道的 EQ 控制点")
            HStack(spacing: 8) {
                Text(!allowEditing ? "正在对比已保存的调音快照 · 关闭“对比快照”返回编辑" : phaseMode ? "滤波、极性与有效延迟 · 虚线为 REW 测量" : "拖动编号点调频率与增益 · 虚线为 REW 测量")
                    .font(.system(size: 10)).foregroundStyle(.secondary)
                Spacer()
                if !phaseMode && profile.channels.contains(where: { !$0.measurements.isEmpty }) {
                    NumericControl(title: "SPL", value: $splFloor, range: -150...min(150, splCeiling - 1), decimals: 0, step: 1).frame(width: 85)
                    Text("—").foregroundStyle(.secondary)
                    NumericControl(title: "", value: $splCeiling, range: max(-149, splFloor + 1)...200, unit: "dB", decimals: 0, step: 1).frame(width: 73)
                }
            }.frame(height: 21)
        }
        .onAppear(perform: rebuild)
        .onChange(of: profile) { rebuild() }
        .onChange(of: sampleRate) { rebuild() }
        .onChange(of: phaseMode) { rebuild(); finishDrag() }
        .onChange(of: includeMaster) { rebuild() }
        .onChange(of: selectedRole) { finishDrag() }
        .onChange(of: allowEditing) { finishDrag() }
        .onDisappear { finishDrag() }
    }

    private func finishDrag() {
        if draggingBand != nil { onEditGesture(false) }
        draggingBand = nil
    }

    private func distance(_ node: BandHandle, from point: CGPoint, geometry: ResponseGeometry) -> Double {
        hypot(geometry.x(node.frequency) - point.x, geometry.y(node.responseDB) - point.y)
    }
    private func readout(at point: CGPoint, geometry: ResponseGeometry) -> String {
        let frequency = geometry.frequency(at: point.x)
        guard let channel = profile.channels.first(where: { $0.role == selectedRole }) else { return "" }
        let response = FilterMath.response(channel: channel, frequency: frequency, sampleRate: sampleRate, masterDB: masterDB)
        let value = phaseMode ? response.phase * 180 / .pi : 20 * log10(max(response.magnitude, 1e-12))
        return String(format: "%.1f Hz  %+.1f %@", frequency, value, phaseMode ? "°" : "dB")
    }
    private func edit(_ id: UUID, at point: CGPoint, geometry: ResponseGeometry) {
        guard var channel = profile.channels.first(where: { $0.role == selectedRole }),
              let index = channel.bands.firstIndex(where: { $0.id == id }) else { return }
        let frequency = (geometry.frequency(at: point.x) * 10).rounded() / 10
        let kind = channel.bands[index].kind
        channel.bands[index].gainDB = 0
        let response = FilterMath.response(channel: channel, frequency: frequency, sampleRate: sampleRate, masterDB: masterDB)
        let baseline = 20 * log10(max(response.magnitude, 1e-12))
        let factor = kind == .peak ? 1.0 : 0.5
        let gain = kind.hasGain ? min(max((geometry.value(at: point.y) - baseline) / factor, -30), 30) : 0
        onEditBand(id, frequency, (gain * 10).rounded() / 10)
    }
    private func rebuild() {
        guard sampleRate.isFinite, sampleRate > 40 else { curves = []; return }
        let anySolo = profile.channels.contains { $0.enabled && $0.solo }
        curves = profile.channels.filter(\.showCurve).map { channel in
            let coefficients = FilterMath.coefficients(channel: channel, sampleRate: sampleRate)
            let gainDB = channel.gainDB + channel.preampDB + masterDB
            let delayFrames = (channel.delayMS * sampleRate / 1000).rounded()
            let points = (0..<1024).map { index -> CGPoint in
                let frequency = 20 * pow(upperFrequency / 20, Double(index) / 1023)
                let response = coefficients.reduce(Complex(real: 1, imaginary: 0)) { $0 * $1.response(frequency: frequency, sampleRate: sampleRate) }
                let magnitude = 20 * log10(max(response.magnitude, 1e-12)) + gainDB
                let angle = response.phase - 2 * Double.pi * frequency * delayFrames / sampleRate + (channel.inverted ? .pi : 0)
                return CGPoint(x: frequency, y: phaseMode ? atan2(sin(angle), cos(angle)) * 180 / .pi : magnitude)
            }
            let measurements = channel.measurements.filter(\.visible).map { reference in
                var points: [CGPoint] = []
                var bucket = -1
                for point in reference.points where point.frequency >= 20 && point.frequency <= upperFrequency {
                    let nextBucket = Int(log(point.frequency / 20) / log(upperFrequency / 20) * 1600)
                    guard nextBucket != bucket else { continue }
                    bucket = nextBucket
                    if phaseMode {
                        if let phase = point.phase { points.append(CGPoint(x: point.frequency, y: atan2(sin(phase * .pi / 180), cos(phase * .pi / 180)) * 180 / .pi)) }
                    } else { points.append(CGPoint(x: point.frequency, y: point.spl + reference.offsetDB)) }
                }
                return points
            }
            return PlotCurve(role: channel.role, theoretical: points, measurements: measurements, enabled: channel.enabled && !channel.muted && (!anySolo || channel.solo) && !profile.masterMuted)
        }
    }
}
