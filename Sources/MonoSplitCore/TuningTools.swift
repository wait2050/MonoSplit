import Foundation

/// A comparison affects tuning only. Routing, listening controls and measurements remain live.
public struct ChannelTuning: Equatable, Sendable {
    public var highPass: Crossover
    public var lowPass: Crossover
    public var eqEnabled: Bool
    public var bands: [EQBand]
    public var gainDB: Double
    public var preampDB: Double
    public var inverted: Bool
    public var delayMS: Double

    public init(_ channel: ChannelSettings) {
        highPass = channel.highPass
        lowPass = channel.lowPass
        eqEnabled = channel.eqEnabled
        bands = channel.bands
        gainDB = channel.gainDB
        preampDB = channel.preampDB
        inverted = channel.inverted
        delayMS = channel.delayMS
    }

    public func applying(to channel: ChannelSettings) -> ChannelSettings {
        var next = channel
        next.highPass = highPass
        next.lowPass = lowPass
        next.eqEnabled = eqEnabled
        next.bands = bands
        next.gainDB = gainDB
        next.preampDB = preampDB
        next.inverted = inverted
        next.delayMS = delayMS
        return next
    }
}

public extension SpeakerProfile {
    func pairedCrossover(frequency: Double, shape: CrossoverShape, sampleRate: Double, lowPassRole: ChannelRole = .woofer) throws -> SpeakerProfile {
        guard lowPassRole == .woofer || lowPassRole == .fullRange else {
            throw MonoSplitError("左右配对分频须选择左声道或右声道通过低频")
        }
        guard frequency.isFinite, (20...20000).contains(frequency), frequency < sampleRate / 2 else {
            throw MonoSplitError("分频点须在 20–20000 Hz 内，并低于当前采样率的一半")
        }
        guard let left = channels.firstIndex(where: { $0.role == .woofer }),
              let right = channels.firstIndex(where: { $0.role == .fullRange }) else {
            throw MonoSplitError("配置缺少左右声道")
        }
        var next = self
        var crossover = Crossover()
        crossover.enabled = true
        crossover.frequency = frequency
        crossover.shape = shape
        let low = lowPassRole == .woofer ? left : right
        let high = lowPassRole == .woofer ? right : left
        next.channels[low].lowPass = crossover
        next.channels[low].highPass.enabled = false
        next.channels[high].highPass = crossover
        next.channels[high].lowPass.enabled = false
        return try next.validated(sampleRate: sampleRate)
    }

    func copyingEQ(from source: ChannelRole, to destination: ChannelRole) -> SpeakerProfile {
        guard source != destination,
              let sourceChannel = channels.first(where: { $0.role == source }),
              let target = channels.firstIndex(where: { $0.role == destination }) else { return self }
        var next = self
        next.channels[target].bands = sourceChannel.bands.map { band in
            var copy = band
            copy.id = UUID()
            return copy
        }
        next.channels[target].eqEnabled = sourceChannel.eqEnabled
        next.channels[target].preampDB = sourceChannel.preampDB
        return next
    }
}

/// Bounded, session-local history. Repeated changes to the same numeric fields form one action.
public struct ProfileEditHistory: Sendable {
    private struct Entry: Sendable {
        var profile: SpeakerProfile
        var key: String?
        var time: TimeInterval
    }
    private var past: [Entry] = []
    private var future: [SpeakerProfile] = []
    private let limit: Int
    private var canMerge = false
    private var grouping = false
    private var groupHasEntry = false
    public var canUndo: Bool { !past.isEmpty }
    public var canRedo: Bool { !future.isEmpty }

    public init(limit: Int = 80) { self.limit = max(1, limit) }

    public mutating func beginGroup() { grouping = true; groupHasEntry = false; canMerge = false }
    public mutating func endGroup() { grouping = false; groupHasEntry = false; canMerge = false }

    public mutating func record(before: SpeakerProfile, after: SpeakerProfile, time: TimeInterval) {
        guard before != after else { return }
        guard before.id == after.id else { reset(); return }
        if grouping && groupHasEntry { future.removeAll(); return }
        let key = Self.numericEditKey(before: before, after: after)
        if canMerge, let key, let last = past.last, last.key == key,
           time >= last.time, time - last.time < 0.45 {
            past[past.count - 1].time = time
        } else {
            past.append(Entry(profile: before, key: key, time: time))
            if past.count > limit { past.removeFirst(past.count - limit) }
        }
        future.removeAll()
        canMerge = key != nil
        if grouping { groupHasEntry = true }
    }

    public mutating func undo(current: SpeakerProfile) -> SpeakerProfile? {
        guard let entry = past.popLast() else { return nil }
        future.append(current)
        endGroup()
        return entry.profile
    }

    public mutating func redo(current: SpeakerProfile) -> SpeakerProfile? {
        guard let next = future.popLast() else { return nil }
        past.append(Entry(profile: current, key: nil, time: 0))
        endGroup()
        return next
    }

    public mutating func reset() { past.removeAll(); future.removeAll(); endGroup() }

    private static func numericEditKey(before: SpeakerProfile, after: SpeakerProfile) -> String? {
        var structure = after
        var keys: [String] = []
        func normalize(_ old: Double, _ new: inout Double, _ key: String) {
            if old != new { keys.append(key); new = old }
        }
        normalize(before.masterGainDB, &structure.masterGainDB, "master")
        normalize(before.preampDB, &structure.preampDB, "preamp")
        guard before.channels.map(\.role) == after.channels.map(\.role) else { return nil }
        for index in before.channels.indices {
            let old = before.channels[index]
            let prefix = old.role.rawValue
            normalize(old.gainDB, &structure.channels[index].gainDB, prefix + ".gain")
            normalize(old.preampDB, &structure.channels[index].preampDB, prefix + ".preamp")
            normalize(old.delayMS, &structure.channels[index].delayMS, prefix + ".delay")
            normalize(old.highPass.frequency, &structure.channels[index].highPass.frequency, prefix + ".hp")
            normalize(old.lowPass.frequency, &structure.channels[index].lowPass.frequency, prefix + ".lp")
            guard old.bands.map(\.id) == structure.channels[index].bands.map(\.id),
                  old.measurements.map(\.id) == structure.channels[index].measurements.map(\.id) else { return nil }
            for band in old.bands.indices {
                let key = prefix + ".eq.\(band)"
                normalize(old.bands[band].frequency, &structure.channels[index].bands[band].frequency, key + ".frequency")
                normalize(old.bands[band].gainDB, &structure.channels[index].bands[band].gainDB, key + ".gain")
                normalize(old.bands[band].q, &structure.channels[index].bands[band].q, key + ".q")
            }
            for measurement in old.measurements.indices {
                normalize(old.measurements[measurement].offsetDB, &structure.channels[index].measurements[measurement].offsetDB, prefix + ".ref.\(measurement)")
            }
        }
        return structure == before && !keys.isEmpty ? keys.joined(separator: "|") : nil
    }
}
