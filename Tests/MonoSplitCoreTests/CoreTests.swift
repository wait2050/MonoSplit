import XCTest
import Foundation
import AudioToolbox
import MonoSplitDSP
@testable import MonoSplitCore

final class CoreTests: XCTestCase {
    private let rate = 48000.0
    private func flat() -> SpeakerProfile {
        var profile = SpeakerProfile(name: "Test")
        profile.masterGainDB = 0
        return profile
    }
    private func render(_ kernel: DSPKernel, left: [Float], right: [Float]) -> [[Float]] {
        precondition(left.count == right.count)
        var a = [Float](repeating: 0, count: left.count)
        var b = a, c = a
        left.withUnsafeBufferPointer { l in
            right.withUnsafeBufferPointer { r in
                a.withUnsafeMutableBufferPointer { aa in
                    b.withUnsafeMutableBufferPointer { bb in
                        c.withUnsafeMutableBufferPointer { cc in
                            ms_process_planar(kernel.pointer, l.baseAddress, r.baseAddress, aa.baseAddress, bb.baseAddress, cc.baseAddress, Int32(left.count))
                        }
                    }
                }
            }
        }
        return [a, b, c]
    }
    private func warm(_ kernel: DSPKernel, count: Int = 6000) {
        _ = render(kernel, left: Array(repeating: 0, count: count), right: Array(repeating: 0, count: count))
    }
    func testStereoMixdownAndAntiphase() throws {
        let kernel = try DSPKernel(sampleRate: rate)
        try kernel.apply(flat())
        warm(kernel)
        let mono = render(kernel, left: Array(repeating: 0.2, count: 2000), right: Array(repeating: 0, count: 2000))
        for channel in mono { XCTAssertEqual(channel.last!, 0.1, accuracy: 0.00001) }
        let same = render(kernel, left: Array(repeating: 0.2, count: 100), right: Array(repeating: 0.2, count: 100))
        XCTAssertEqual(same[0].last!, 0.2, accuracy: 0.00001)
        let cancelled = render(kernel, left: Array(repeating: 0.2, count: 100), right: Array(repeating: -0.2, count: 100))
        XCTAssertTrue(cancelled.flatMap { $0 }.allSatisfy { abs($0) < 0.00001 })
    }
    func testGainPolarityAndSolo() throws {
        let kernel = try DSPKernel(sampleRate: rate)
        var profile = flat()
        profile.channels[0].gainDB = -6
        profile.channels[1].inverted = true
        profile.channels[2].muted = true
        try kernel.apply(profile)
        warm(kernel)
        let out = render(kernel, left: Array(repeating: 0.1, count: 100), right: Array(repeating: 0.1, count: 100))
        XCTAssertEqual(out[0].last!, Float(0.1 * pow(10, -6.0 / 20)), accuracy: 0.00001)
        XCTAssertEqual(out[1].last!, -0.1, accuracy: 0.00001)
        XCTAssertEqual(out[2].last!, 0)
        profile.channels[0].solo = true
        try kernel.apply(profile)
        warm(kernel)
        let solo = render(kernel, left: [0.1], right: [0.1])
        XCTAssertEqual(solo[1][0], 0, accuracy: 0.000001)
    }
    func testButterworthAndLRCornersAcrossRates() {
        for rate in [44100.0, 48000, 96000, 192000] {
            for shape in CrossoverShape.allCases {
                for kind in [FilterKind.highPass, .lowPass] {
                    let magnitude = shape.qualityFactors.map { FilterMath.coefficient(kind: kind, frequency: 200, q: $0, sampleRate: rate) }.reduce(Complex(real: 1, imaginary: 0)) { $0 * $1.response(frequency: 200, sampleRate: rate) }.magnitude
                    let expected = shape == .linkwitzRiley24 || shape == .linkwitzRiley48 ? -6.020599913 : -3.010299956
                    XCTAssertEqual(20 * log10(magnitude), expected, accuracy: 0.000001)
                }
            }
        }
    }
    func testLR24ComplexSumIsFlat() {
        for frequency in [20.0, 50, 100, 150, 200, 350, 1000, 5000, 18000] {
            var low = ChannelSettings(role: .woofer)
            low.lowPass.enabled = true
            low.lowPass.frequency = 200
            var high = ChannelSettings(role: .fullRange)
            high.highPass = low.lowPass
            let sum = FilterMath.response(channel: low, frequency: frequency, sampleRate: rate) + FilterMath.response(channel: high, frequency: frequency, sampleRate: rate)
            XCTAssertEqual(20 * log10(sum.magnitude), 0, accuracy: 0.000001)
        }
    }
    func testSlopeAndPEQGain() {
        let low = FilterMath.coefficient(kind: .lowPass, frequency: 100, q: 1 / sqrt(2), sampleRate: 192000)
        let attenuation = 20 * log10(low.response(frequency: 1000, sampleRate: 192000).magnitude)
        XCTAssertEqual(attenuation, -40, accuracy: 0.02)
        for q in [0.1, 0.707, 1, 10, 100] {
            let peak = FilterMath.coefficient(kind: .peak, frequency: 1234, gainDB: 7.5, q: q, sampleRate: rate)
            XCTAssertEqual(20 * log10(peak.response(frequency: 1234, sampleRate: rate).magnitude), 7.5, accuracy: 0.000001)
        }
    }
    func testDigitalResponseMatchesPlotWithinPointOneDB() throws {
        for sampleRate in [44100.0, 48000] {
            var profile = flat()
            profile.channels[0].highPass.enabled = true
            profile.channels[0].highPass.frequency = 150
            profile.channels[0].lowPass.enabled = true
            profile.channels[0].lowPass.frequency = 4000
            profile.channels[0].bands = [EQBand(frequency: 500, gainDB: 4, q: 2), EQBand(kind: .highShelf, frequency: 2000, gainDB: -3, q: 0.707)]
            let kernel = try DSPKernel(sampleRate: sampleRate)
            try kernel.apply(profile)
            warm(kernel)
            for frequency in [100.0, 200, 500, 2000, 6000] {
                let count = Int(sampleRate * 2)
                let signal = (0..<count).map { Float(0.01 * sin(2 * .pi * frequency * Double($0) / sampleRate)) }
                let output = render(kernel, left: signal, right: signal)[0]
                let tail = Array(output.suffix(Int(sampleRate)))
                let rms = sqrt(tail.reduce(0.0) { $0 + Double($1 * $1) } / Double(tail.count))
                let measured = 20 * log10(rms / (0.01 / sqrt(2)))
                let expected = 20 * log10(FilterMath.response(channel: profile.channels[0], frequency: frequency, sampleRate: sampleRate).magnitude)
                XCTAssertEqual(measured, expected, accuracy: 0.1, "\(sampleRate) Hz / \(frequency) Hz")
            }
        }
    }
    func testDelayImpulseAcrossBufferBoundaries() throws {
        for sampleRate in [44100.0, 48000] {
            let kernel = try DSPKernel(sampleRate: sampleRate)
            var profile = flat()
            profile.channels[0].delayMS = 439.13
            try kernel.apply(profile)
            warm(kernel)
            let expected = Int((profile.channels[0].delayMS * sampleRate / 1000).rounded())
            var collected: [Float] = []
            for block in 0..<100 {
                var signal = [Float](repeating: 0, count: 257)
                if block == 0 { signal[0] = 0.2 }
                collected += render(kernel, left: signal, right: signal)[0]
            }
            let index = collected.enumerated().max { abs($0.element) < abs($1.element) }!.offset
            XCTAssertEqual(index, expected)
            XCTAssertEqual(collected[index], 0.2, accuracy: 0.00001)
        }
    }
    func testParameterEditPreservesDelayHistoryAndMuteIsPrompt() throws {
        let kernel = try DSPKernel(sampleRate: rate)
        var profile = flat()
        profile.channels[0].delayMS = 439
        try kernel.apply(profile)
        _ = render(kernel, left: Array(repeating: 0.1, count: 30000), right: Array(repeating: 0.1, count: 30000))
        profile.channels[0].gainDB = -6
        try kernel.apply(profile)
        let changed = render(kernel, left: Array(repeating: 0.1, count: 5000), right: Array(repeating: 0.1, count: 5000))[0]
        XCTAssertTrue(changed.allSatisfy { $0 > 0.049 })
        profile.masterMuted = true
        try kernel.apply(profile)
        let muted = render(kernel, left: Array(repeating: 0.1, count: 6000), right: Array(repeating: 0.1, count: 6000))[0]
        XCTAssertLessThan(abs(muted.last!), 0.00001)
    }
    func testLimiterUsesSharedEnvelopeAndHandlesNonFiniteInput() throws {
        let kernel = try DSPKernel(sampleRate: rate)
        var profile = flat()
        profile.channels[1].gainDB = -6
        try kernel.apply(profile)
        warm(kernel)
        let out = render(kernel, left: Array(repeating: 4, count: 2000), right: Array(repeating: 4, count: 2000))
        XCTAssertTrue(out.flatMap { $0 }.allSatisfy { $0.isFinite && abs($0) <= 0.980001 })
        XCTAssertEqual(out[1].last! / out[0].last!, Float(pow(10, -6.0 / 20)), accuracy: 0.00001)
        _ = render(kernel, left: [.nan, .infinity], right: [0, 0])
        XCTAssertEqual(kernel.meter().nonFiniteSamples, 2)
    }
    func testRapidConcurrentPlanReplacement() throws {
        let kernel = try DSPKernel(sampleRate: rate)
        try kernel.apply(flat())
        let group = DispatchGroup()
        group.enter()
        DispatchQueue.global().async {
            let input = [Float](repeating: 0.01, count: 128)
            var a = input, b = input, c = input
            for _ in 0..<3000 {
                input.withUnsafeBufferPointer { buffer in
                    ms_process_planar(kernel.pointer, buffer.baseAddress, buffer.baseAddress, &a, &b, &c, 128)
                }
            }
            group.leave()
        }
        for index in 0..<1500 {
            var profile = flat()
            profile.channels[0].bands = [EQBand(frequency: Double(100 + index % 1000), gainDB: -3)]
            try kernel.apply(profile)
        }
        XCTAssertEqual(group.wait(timeout: .now() + 20), .success)
        XCTAssertEqual(kernel.meter().nonFiniteSamples, 0)
        kernel.collect()
    }
    func testRoutingUsesActualDeviceOrderAndIndependentChannels() throws {
        var profile = flat()
        profile.channels[0].deviceUID = "ys"
        profile.channels[1].deviceUID = "ys"
        profile.channels[2].deviceUID = "mac"
        let ys = OutputDevice(id: 1, uid: "ys", name: "YS", channelCount: 2, sampleRate: 44100, bluetooth: true)
        let mac = OutputDevice(id: 2, uid: "mac", name: "Mac", channelCount: 2, sampleRate: 48000, bluetooth: false)
        XCTAssertEqual(try Routing.outputMap(profile: profile, orderedDevices: [ys, mac]), [0, 1, 2, 2])
        XCTAssertEqual(try Routing.outputMap(profile: profile, orderedDevices: [mac, ys]), [2, 2, 0, 1])
        XCTAssertEqual(try Routing.outputMap(profile: profile, orderedDevices: [mac]), [2, 2])
        profile.channels[1].outputChannels = [3]
        XCTAssertThrowsError(try Routing.outputMap(profile: profile, orderedDevices: [ys, mac]))
    }
    func testProfileValidationAndSampleRateChanges() throws {
        var profile = flat()
        profile.channels[0].bands = [EQBand(frequency: 23000)]
        XCTAssertNoThrow(try profile.validated(sampleRate: 48000))
        XCTAssertThrowsError(try profile.validated(sampleRate: 44100))
        profile.channels[0].bands[0].enabled = false
        XCTAssertNoThrow(try profile.validated(sampleRate: 44100))
        profile.channels[1].delayMS = .nan
        XCTAssertThrowsError(try profile.validated())
        profile.channels[1].delayMS = 0
        profile.channels[0].deviceUID = "ys"
        profile.channels[1].deviceUID = "ys"
        profile.channels[1].outputChannels = [1]
        XCTAssertThrowsError(try profile.validated())
    }
    func testREWImportWithAttachedUnitsWhitespaceAndOff() {
        let text = """
        Filter Settings file
        Room EQ V5.31
        Equaliser: Generic
        Preamp: -4.5 dB
        Filter  1: ON  PK Fc 129.1Hz Gain -3.5dB Q 4.0
        Filter\t2: OFF LSC Fc 100 Hz Gain 2 dB Q 0.71
        Filter 3: ON HSC Fc 8000 Hz Gain -1 dB Q 0.7
        Filter 4: ON HPQ Fc 30 Hz Q 0.707
        Filter 5: ON LP Fc 300 Hz
        Filter 6: ON None
        """
        let parsed = REWImporter.parseEQ(text.replacingOccurrences(of: "\n", with: "\r\n"))
        XCTAssertTrue(parsed.canApply, parsed.issues.map(\.description).joined())
        XCTAssertEqual(parsed.bands.count, 5)
        XCTAssertFalse(parsed.bands[1].enabled)
        XCTAssertEqual(parsed.bands[0].frequency, 129.1)
        XCTAssertEqual(parsed.preampDB, -4.5)
    }
    func testREWImportRejectsUnsupportedInvalidAndOversizedChains() {
        for line in ["Filter 1: ON AP Fc 100 Hz Q 1", "Filter 1: ON PK Fc NaN Hz Gain 1 dB Q 1", "Filter 1: ON PK Fc 100 Hz Gain 1 dB", "Filter 1: ON PK Fc 100 Hz Gain 1 dB Q -1", "Include: other.txt", "Channel: L"] {
            XCTAssertFalse(REWImporter.parseEQ(line).canApply, line)
        }
        let text = (1...21).map { "Filter \($0): ON PK Fc 100 Hz Gain 0 dB Q 1" }.joined(separator: "\n")
        let parsed = REWImporter.parseEQ(text)
        XCTAssertFalse(parsed.canApply)
        XCTAssertTrue(parsed.issues.contains { $0.line == 21 })
    }
    func testMeasurementImportAndInvalidData() throws {
        let reference = try REWImporter.parseMeasurement("* REW V5.31\n* Freq(Hz) SPL(dB) Phase(degrees)\n100 75 -90\n20 60 15\n1000 80 0\n", name: "Test", source: "test.txt")
        XCTAssertEqual(reference.points.map(\.frequency), [20, 100, 1000])
        XCTAssertEqual(reference.points[1].phase, -90)
        XCTAssertThrowsError(try REWImporter.parseMeasurement("20 70\n20 80", name: "", source: ""))
        XCTAssertThrowsError(try REWImporter.parseMeasurement("20 70\n30 NaN", name: "", source: ""))
        XCTAssertThrowsError(try REWImporter.parseMeasurement("20 70\n30 80 NaN", name: "", source: ""))
    }
    func testProfileRoundTripAndRecovery() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = ProfileStore(directory: directory)
        XCTAssertNil(try store.load().library)
        var profile = flat()
        profile.channels[0].bands = [EQBand(frequency: 85, gainDB: -3.5, q: 4.1, enabled: false)]
        let imported = try ProfileStore.importProfile(ProfileStore.exportProfile(profile))
        XCTAssertNotEqual(imported.id, profile.id)
        XCTAssertEqual(imported.channels, profile.channels)
        try store.save(ProfileLibrary(profiles: [profile], selectedID: profile.id))
        profile.name = "New"
        try store.save(ProfileLibrary(profiles: [profile], selectedID: profile.id))
        try Data("broken".utf8).write(to: store.fileURL)
        let recovered = try store.load()
        XCTAssertTrue(recovered.recovered)
        XCTAssertEqual(recovered.library?.profiles[0].name, "Test")
        // Recovery writes must preserve the previous valid backup.
        try store.save(ProfileLibrary(profiles: [profile], selectedID: profile.id))
        XCTAssertEqual(try JSONDecoder().decode(ProfileLibrary.self, from: Data(contentsOf: store.backupURL)).profiles[0].name, "Test")
    }
    func testUnknownVersionRejected() throws {
        var profile = flat()
        profile.version = 99
        XCTAssertThrowsError(try profile.validated())
        XCTAssertThrowsError(try ProfileStore.importProfile(JSONEncoder().encode(profile)))
    }
    func testAPOOptionalNumbersAndCumulativePreamps() {
        let parsed = REWImporter.parseEQ("Preamp: -2dB\nPreamp: -3 dB # cumulative\nFilter: ON LS Fc 100 Hz Gain 3 dB\nFilter 1: ON PK Fc 500 Hz Gain 2 dB Q 1\nFilter 1: OFF HS Fc 2000 Hz Gain -2 dB")
        XCTAssertTrue(parsed.canApply, parsed.issues.map(\.description).joined())
        XCTAssertEqual(parsed.preampDB, -5)
        XCTAssertEqual(parsed.bands.count, 3)
        XCTAssertFalse(REWImporter.parseEQ("Filter 1: ON LS 6dB Fc 100 Hz Gain 3 dB Q 1").canApply)
        XCTAssertFalse(REWImporter.parseEQ("Filter 1: ON LS Fc 100 Hz Gain 3 dB BW Oct 1").canApply)
        XCTAssertFalse(REWImporter.parseEQ("Filter 1: ON LS Fc 100 Hz Gain 3 dB Q broken").canApply)
        XCTAssertFalse(REWImporter.parseEQ("If: 1\nFilter 1: ON PK Fc 100 Hz Gain 3 dB Q 1").canApply)
    }
    func testAudioBufferListsKeepThreeBranchesIsolated() throws {
        let kernel = try DSPKernel(sampleRate: rate)
        var profile = flat()
        profile.channels[0].gainDB = -6
        profile.channels[1].inverted = true
        profile.channels[2].gainDB = -12
        try kernel.apply(profile)
        warm(kernel)
        let map: [Int32] = [0, 1, 2, 2, -1]
        map.withUnsafeBufferPointer { ms_route(kernel.pointer, 1, $0.baseAddress, 5) }
        let frameCount = 256
        let inputRaw = UnsafeMutableRawPointer.allocate(byteCount: MemoryLayout<AudioBufferList>.size + MemoryLayout<AudioBuffer>.size, alignment: MemoryLayout<AudioBufferList>.alignment)
        let outputRaw = UnsafeMutableRawPointer.allocate(byteCount: MemoryLayout<AudioBufferList>.size + 2 * MemoryLayout<AudioBuffer>.size, alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { inputRaw.deallocate(); outputRaw.deallocate() }
        let input = inputRaw.assumingMemoryBound(to: AudioBufferList.self)
        let output = outputRaw.assumingMemoryBound(to: AudioBufferList.self)
        input.pointee.mNumberBuffers = 2
        output.pointee.mNumberBuffers = 3
        let inputs = UnsafeMutableAudioBufferListPointer(input)
        let outputs = UnsafeMutableAudioBufferListPointer(output)
        // A disabled hardware input precedes the tapped stereo stream.
        inputs[0] = AudioBuffer(mNumberChannels: 1, mDataByteSize: UInt32(frameCount * 4), mData: nil)
        let tapped = UnsafeMutablePointer<Float>.allocate(capacity: frameCount * 2)
        tapped.initialize(repeating: 0.2, count: frameCount * 2)
        inputs[1] = AudioBuffer(mNumberChannels: 2, mDataByteSize: UInt32(frameCount * 8), mData: tapped)
        let destination = UnsafeMutablePointer<Float>.allocate(capacity: frameCount * 5)
        destination.initialize(repeating: 99, count: frameCount * 5)
        outputs[0] = AudioBuffer(mNumberChannels: 2, mDataByteSize: UInt32(frameCount * 8), mData: destination)
        outputs[1] = AudioBuffer(mNumberChannels: 2, mDataByteSize: UInt32(frameCount * 8), mData: destination.advanced(by: frameCount * 2))
        outputs[2] = AudioBuffer(mNumberChannels: 1, mDataByteSize: UInt32(frameCount * 4), mData: destination.advanced(by: frameCount * 4))
        defer { tapped.deallocate(); destination.deallocate() }
        ms_render_audio(kernel.pointer, input, output)
        XCTAssertEqual(destination[0], Float(0.2 * pow(10, -6.0 / 20)), accuracy: 0.00001)
        XCTAssertEqual(destination[1], -0.2, accuracy: 0.00001)
        XCTAssertEqual(destination[frameCount * 2], Float(0.2 * pow(10, -12.0 / 20)), accuracy: 0.00001)
        XCTAssertEqual(destination[frameCount * 2], destination[frameCount * 2 + 1])
        XCTAssertEqual(destination[frameCount * 4], 0)
    }

    func testExtremeFiniteInputRemainsFiniteThroughEQAndDelay() throws {
        let kernel = try DSPKernel(sampleRate: rate)
        var profile = flat()
        profile.channels[0].bands = [EQBand(frequency: 1000, gainDB: 30, q: 0.1)]
        profile.channels[0].delayMS = 0.5
        try kernel.apply(profile)
        warm(kernel)
        let signal = (0..<4096).map { Float.greatestFiniteMagnitude * ($0.isMultiple(of: 2) ? 1 : -1) }
        let output = render(kernel, left: signal, right: signal)
        XCTAssertTrue(output.flatMap { $0 }.allSatisfy { $0.isFinite && abs($0) <= 0.980001 })
    }
    func testMeasurementProfileRequiresOrderedPoints() throws {
        var profile = flat()
        profile.channels[0].measurements = [MeasurementReference(name: "invalid", source: "", points: [MeasurementPoint(frequency: 200, spl: 70), MeasurementPoint(frequency: 100, spl: 70)])]
        XCTAssertThrowsError(try profile.validated())
    }

}
