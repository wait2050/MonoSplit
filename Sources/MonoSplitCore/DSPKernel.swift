import Foundation
import MonoSplitDSP

/// Configuration is single-producer. Audio rendering is single-consumer on the HAL IOProc.
/// Plans and retired storage are allocated/reclaimed only by the control thread.
public final class DSPKernel: @unchecked Sendable {
    public let pointer: OpaquePointer
    public let sampleRate: Double
    public init(sampleRate: Double) throws {
        guard let pointer = ms_create(sampleRate) else { throw MonoSplitError("无法创建 DSP，采样率不受支持") }
        self.pointer = pointer
        self.sampleRate = sampleRate
    }
    deinit { ms_destroy(pointer) }

    public func apply(_ profile: SpeakerProfile) throws {
        _ = try profile.validated(sampleRate: sampleRate)
        let plan = ms_plan_create()!
        let anySolo = profile.channels.contains { $0.enabled && $0.solo }
        for (index, role) in ChannelRole.allCases.enumerated() {
            let channel = profile.channels.first { $0.role == role }!
            let coefficients = channel.enabled ? FilterMath.coefficients(channel: channel, sampleRate: sampleRate).flatMap(\.values) : []
            let audible = channel.enabled && !channel.muted && !profile.masterMuted && (!anySolo || channel.solo)
            let gain = audible ? pow(10, (channel.gainDB + channel.preampDB + profile.masterGainDB + profile.preampDB) / 20) * (channel.inverted ? -1 : 1) : 0
            coefficients.withUnsafeBufferPointer { buffer in
                ms_plan_channel(plan, Int32(index), buffer.baseAddress, Int32(coefficients.count / 5), gain, channel.delayMS)
            }
        }
        ms_publish(pointer, plan)
    }
    public func collect() { ms_collect(pointer) }
    public func meter() -> DSPMeter {
        var peaks = [Float](repeating: 0, count: 3)
        var reduction: Float = 0, inputPeak: Float = 0
        var frames: UInt64 = 0, faults: UInt64 = 0
        ms_meter(pointer, &peaks, &inputPeak, &reduction, &frames, &faults)
        return DSPMeter(peaks: peaks, inputPeak: inputPeak, limiterReductionDB: reduction, renderedFrames: frames, nonFiniteSamples: faults)
    }
}

public struct DSPMeter: Equatable, Sendable {
    public var peaks: [Float] = [0, 0, 0]
    public var inputPeak: Float = 0
    public var limiterReductionDB: Float = 0
    public var renderedFrames: UInt64 = 0
    public var nonFiniteSamples: UInt64 = 0
    public init() {}
    public init(peaks: [Float], inputPeak: Float, limiterReductionDB: Float, renderedFrames: UInt64, nonFiniteSamples: UInt64) {
        self.peaks = peaks
        self.inputPeak = inputPeak
        self.limiterReductionDB = limiterReductionDB
        self.renderedFrames = renderedFrames
        self.nonFiniteSamples = nonFiniteSamples
    }
}
