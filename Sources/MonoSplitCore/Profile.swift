import Foundation

public enum ChannelRole: String, Codable, CaseIterable, Identifiable, Sendable {
    // Keep the original storage identifiers so existing speaker profiles remain compatible.
    case woofer, fullRange, builtin
    public var id: String { rawValue }
    public var title: String {
        switch self {
        case .woofer: "左声道"
        case .fullRange: "右声道"
        case .builtin: "内置扬声器"
        }
    }
}

public enum CrossoverShape: String, Codable, CaseIterable, Identifiable, Sendable {
    case butterworth12, butterworth24, butterworth48, linkwitzRiley24, linkwitzRiley48
    public var id: String { rawValue }
    public var title: String {
        switch self {
        case .butterworth12: "Butterworth · 12 dB/oct"
        case .butterworth24: "Butterworth · 24 dB/oct"
        case .butterworth48: "Butterworth · 48 dB/oct"
        case .linkwitzRiley24: "Linkwitz–Riley · 24 dB/oct"
        case .linkwitzRiley48: "Linkwitz–Riley · 48 dB/oct"
        }
    }
    public var qualityFactors: [Double] {
        switch self {
        case .butterworth12: [1 / sqrt(2)]
        case .butterworth24: [0.541196100146197, 1.306562964876377]
        case .butterworth48: [0.509795579104159, 0.601344886935045, 0.899976223136416, 2.562915447741506]
        case .linkwitzRiley24: [1 / sqrt(2), 1 / sqrt(2)]
        case .linkwitzRiley48: [0.541196100146197, 1.306562964876377, 0.541196100146197, 1.306562964876377]
        }
    }
}

public struct Crossover: Codable, Equatable, Sendable {
    public var enabled = false
    public var frequency: Double = 200
    public var shape: CrossoverShape = .linkwitzRiley24
    public init() {}
}

public enum FilterKind: String, Codable, CaseIterable, Identifiable, Sendable {
    case peak, lowShelf, highShelf, highPass, lowPass
    public var id: String { rawValue }
    public var title: String {
        switch self {
        case .peak: "峰值"
        case .lowShelf: "低架"
        case .highShelf: "高架"
        case .highPass: "高通 · 二阶"
        case .lowPass: "低通 · 二阶"
        }
    }
    public var hasGain: Bool { self != .highPass && self != .lowPass }
}

public struct EQBand: Codable, Equatable, Identifiable, Sendable {
    public var id = UUID()
    public var enabled = true
    public var kind: FilterKind = .peak
    public var frequency: Double = 1000
    public var gainDB: Double = 0
    public var q: Double = 1
    public init(kind: FilterKind = .peak, frequency: Double = 1000, gainDB: Double = 0, q: Double = 1, enabled: Bool = true) {
        self.kind = kind
        self.frequency = frequency
        self.gainDB = gainDB
        self.q = q
        self.enabled = enabled
    }
}

public struct MeasurementPoint: Codable, Equatable, Sendable {
    public var frequency: Double
    public var spl: Double
    public var phase: Double?
    public init(frequency: Double, spl: Double, phase: Double? = nil) {
        self.frequency = frequency
        self.spl = spl
        self.phase = phase
    }
}

public struct MeasurementReference: Codable, Equatable, Identifiable, Sendable {
    public var id = UUID()
    public var name: String
    public var source: String
    public var offsetDB: Double = 0
    public var visible = true
    public var points: [MeasurementPoint]
    public init(name: String, source: String, points: [MeasurementPoint]) {
        self.name = name
        self.source = source
        self.points = points
    }
}

public struct ChannelSettings: Codable, Equatable, Identifiable, Sendable {
    public var role: ChannelRole
    public var id: ChannelRole { role }
    public var deviceUID: String = ""
    /// One-based channel numbers on the physical device, duplicated for the built-in branch.
    public var outputChannels: [Int]
    public var enabled = true
    public var muted = false
    public var solo = false
    public var highPass = Crossover()
    public var lowPass = Crossover()
    public var eqEnabled = true
    public var bands: [EQBand] = []
    public var gainDB: Double = 0
    public var preampDB: Double = 0
    public var inverted = false
    public var delayMS: Double = 0
    public var showCurve = true
    public var measurements: [MeasurementReference] = []
    public init(role: ChannelRole) {
        self.role = role
        outputChannels = role == .fullRange ? [2] : role == .builtin ? [1, 2] : [1]
        showCurve = role != .builtin
    }
}

public struct SpeakerProfile: Codable, Equatable, Identifiable, Sendable {
    public static let currentVersion = 1
    public var version = currentVersion
    public var id = UUID()
    public var name: String
    public var masterGainDB: Double = -12
    public var preampDB: Double = 0
    public var masterMuted = false
    public var channels = ChannelRole.allCases.map(ChannelSettings.init)
    public init(name: String = "新音箱配置") { self.name = name }

    public func validationIssues(sampleRate: Double? = nil) -> [String] {
        var issues: [String] = []
        if version != Self.currentVersion { issues.append("配置版本 \(version) 不受支持") }
        if name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { issues.append("配置名称不能为空") }
        if channels.count != 3 || Set(channels.map(\.role)) != Set(ChannelRole.allCases) {
            issues.append("配置必须各包含一条左声道、右声道和内置支路")
        }
        if !masterGainDB.isFinite || !(-60...12).contains(masterGainDB) { issues.append("总音量应在 −60 至 +12 dB") }
        if !preampDB.isFinite || !(-60...0).contains(preampDB) { issues.append("总前级衰减应在 −60 至 0 dB") }
        if let sampleRate, !sampleRate.isFinite || !(8000...192000).contains(sampleRate) {
            issues.append("采样率应在 8 至 192 kHz")
        }
        var destinations = Set<String>()
        for channel in channels {
            let prefix = channel.role.title
            if channel.outputChannels.isEmpty || channel.outputChannels.count > 64 || Set(channel.outputChannels).count != channel.outputChannels.count || channel.outputChannels.contains(where: { !(1...64).contains($0) }) {
                issues.append("\(prefix) 的输出通道应为不重复的 1–64")
            }
            if channel.enabled && !channel.deviceUID.isEmpty {
                for output in channel.outputChannels {
                    if !destinations.insert("\(channel.deviceUID)#\(output)").inserted { issues.append("\(prefix) 与其他支路占用同一输出通道") }
                }
            }
            if channel.bands.count > 20 { issues.append("\(prefix) 超过 20 段 EQ") }
            if Set(channel.bands.map(\.id)).count != channel.bands.count { issues.append("\(prefix) 包含重复的 EQ 标识") }
            for (value, range, label) in [(channel.gainDB, -60.0...12.0, "音量"), (channel.preampDB, -60.0...12.0, "前级"), (channel.delayMS, 0.0...2000.0, "延迟")] {
                if !value.isFinite || !range.contains(value) { issues.append("\(prefix) 的\(label)超出范围") }
            }
            for (filter, label) in [(channel.highPass, "高通"), (channel.lowPass, "低通")] {
                if !filter.frequency.isFinite || !(1...96000).contains(filter.frequency) { issues.append("\(prefix) 的\(label)频率无效") }
                if channel.enabled && filter.enabled, let sampleRate, filter.frequency >= sampleRate / 2 { issues.append("\(prefix) 的\(label)频率超过奈奎斯特频率 \(Int(sampleRate / 2)) Hz") }
            }
            for (index, band) in channel.bands.enumerated() {
                if !band.frequency.isFinite || !(1...96000).contains(band.frequency) || !band.gainDB.isFinite || !(-30...30).contains(band.gainDB) || !band.q.isFinite || !(0.05...100).contains(band.q) {
                    issues.append("\(prefix) EQ \(index + 1) 的频率、增益或 Q 无效")
                }
                if channel.enabled && channel.eqEnabled && band.enabled, let sampleRate, band.frequency >= sampleRate / 2 { issues.append("\(prefix) EQ \(index + 1) 超过奈奎斯特频率 \(Int(sampleRate / 2)) Hz") }
            }
            if Set(channel.measurements.map(\.id)).count != channel.measurements.count { issues.append("\(prefix) 包含重复的测量标识") }
            for reference in channel.measurements {
                if !reference.offsetDB.isFinite || reference.points.count < 2 || reference.points.count > 500_000 || !zip(reference.points, reference.points.dropFirst()).allSatisfy({ $0.frequency < $1.frequency }) || reference.points.contains(where: { !$0.frequency.isFinite || $0.frequency <= 0 || !$0.spl.isFinite || ($0.phase.map { !$0.isFinite } ?? false) }) {
                    issues.append("\(prefix) 的测量参考数据无效")
                }
            }
        }
        return issues
    }

    public func validated(sampleRate: Double? = nil) throws -> SpeakerProfile {
        let issues = validationIssues(sampleRate: sampleRate)
        guard issues.isEmpty else { throw MonoSplitError(issues.joined(separator: "\n")) }
        return self
    }
}

public struct MonoSplitError: LocalizedError, Sendable {
    public var message: String
    public var errorDescription: String? { message }
    public init(_ message: String) { self.message = message }
}
