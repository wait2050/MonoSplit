import XCTest
@testable import MonoSplitCore

final class TuningToolsTests: XCTestCase {
    func testSnapshotPreservesRoutingAndListeningControls() {
        var saved = ChannelSettings(role: .woofer)
        saved.lowPass.enabled = true
        saved.lowPass.frequency = 160
        saved.bands = [EQBand(frequency: 80, gainDB: -4, q: 2)]
        saved.gainDB = -7
        saved.delayMS = 439.13
        saved.inverted = true
        let snapshot = ChannelTuning(saved)
        var live = ChannelSettings(role: .fullRange)
        live.deviceUID = "current-device"
        live.outputChannels = [4]
        live.muted = true
        live.solo = true
        live.enabled = false
        live.showCurve = false
        live.measurements = [MeasurementReference(name: "Current", source: "REW", points: [.init(frequency: 20, spl: 70), .init(frequency: 200, spl: 80)])]
        let audition = snapshot.applying(to: live)
        XCTAssertEqual(ChannelTuning(audition), snapshot)
        XCTAssertEqual(audition.role, live.role)
        XCTAssertEqual(audition.deviceUID, live.deviceUID)
        XCTAssertEqual(audition.outputChannels, live.outputChannels)
        XCTAssertEqual(audition.muted, live.muted)
        XCTAssertEqual(audition.solo, live.solo)
        XCTAssertEqual(audition.enabled, live.enabled)
        XCTAssertEqual(audition.showCurve, live.showCurve)
        XCTAssertEqual(audition.measurements, live.measurements)
        XCTAssertEqual(live.delayMS, 0)
    }

    func testHistoryCoalescesNumericBurstAndKeepsDifferentControlsSeparate() {
        var history = ProfileEditHistory()
        let initial = SpeakerProfile()
        var one = initial
        one.channels[0].gainDB = -1
        history.record(before: initial, after: one, time: 1)
        var two = one
        two.channels[0].gainDB = -2
        history.record(before: one, after: two, time: 1.1)
        var three = two
        three.channels[0].delayMS = 2
        history.record(before: two, after: three, time: 1.2)
        XCTAssertEqual(history.undo(current: three), two)
        XCTAssertEqual(history.undo(current: two), initial)
        XCTAssertFalse(history.canUndo)
        XCTAssertEqual(history.redo(current: initial), two)
        XCTAssertEqual(history.redo(current: two), three)
        XCTAssertFalse(history.canRedo)
    }

    func testHistorySeparatesDiscreteChangesAndDropsRedoAfterNewEdit() {
        var history = ProfileEditHistory()
        let initial = SpeakerProfile()
        var muted = initial
        muted.masterMuted = true
        history.record(before: initial, after: muted, time: 1)
        var solo = muted
        solo.channels[1].solo = true
        history.record(before: muted, after: solo, time: 1.01)
        XCTAssertEqual(history.undo(current: solo), muted)
        var changed = muted
        changed.masterGainDB = -18
        history.record(before: muted, after: changed, time: 1.02)
        XCTAssertFalse(history.canRedo)
        XCTAssertEqual(history.undo(current: changed), muted)
        XCTAssertEqual(history.undo(current: muted), initial)
    }

    func testHistoryIsBoundedAndIsolatedByProfile() {
        var history = ProfileEditHistory(limit: 2)
        var current = SpeakerProfile()
        for index in 1...3 {
            var next = current
            next.channels[0].delayMS = Double(index)
            history.record(before: current, after: next, time: Double(index))
            current = next
        }
        current = history.undo(current: current)!
        XCTAssertEqual(current.channels[0].delayMS, 2)
        current = history.undo(current: current)!
        XCTAssertEqual(current.channels[0].delayMS, 1)
        XCTAssertNil(history.undo(current: current))
        history.record(before: current, after: SpeakerProfile(), time: 4)
        XCTAssertFalse(history.canUndo)
        XCTAssertFalse(history.canRedo)
    }

    func testGraphFrequencyAndGainBurstIsOneUndoAction() {
        var history = ProfileEditHistory()
        var initial = SpeakerProfile()
        initial.channels[0].bands = [EQBand()]
        var current = initial
        for index in 1...20 {
            var next = current
            next.channels[0].bands[0].frequency += 10
            next.channels[0].bands[0].gainDB -= 0.1
            history.record(before: current, after: next, time: Double(index) * 0.02)
            current = next
        }
        XCTAssertEqual(history.undo(current: current), initial)
        XCTAssertFalse(history.canUndo)
    }

    func testExplicitGestureRemainsOneActionAcrossPausesAndAxisChanges() {
        var history = ProfileEditHistory()
        var initial = SpeakerProfile()
        initial.channels[0].bands = [EQBand()]
        history.beginGroup()
        var one = initial
        one.channels[0].bands[0].frequency = 2000
        history.record(before: initial, after: one, time: 1)
        var two = one
        two.channels[0].bands[0].gainDB = -4
        history.record(before: one, after: two, time: 4)
        history.endGroup()
        XCTAssertEqual(history.undo(current: two), initial)
        XCTAssertEqual(history.redo(current: initial), two)
        var next = two
        next.channels[0].bands[0].q = 2
        history.record(before: two, after: next, time: 5)
        XCTAssertEqual(history.undo(current: next), two)
    }

    func testPairedCrossoverIsAtomicAndPreservesOtherTuning() throws {
        var initial = SpeakerProfile()
        initial.channels[0].highPass.frequency = 32
        initial.channels[1].lowPass.frequency = 16000
        initial.channels[1].delayMS = 4.5
        initial.channels[2].bands = [EQBand(gainDB: 3)]
        let next = try initial.pairedCrossover(frequency: 175, shape: .linkwitzRiley48, sampleRate: 44100)
        var expected = initial
        expected.channels[0].lowPass.enabled = true
        expected.channels[0].lowPass.frequency = 175
        expected.channels[0].lowPass.shape = .linkwitzRiley48
        expected.channels[1].highPass = expected.channels[0].lowPass
        XCTAssertEqual(next, expected)
        var history = ProfileEditHistory()
        history.record(before: initial, after: next, time: 1)
        XCTAssertEqual(history.undo(current: next), initial)
        XCTAssertThrowsError(try initial.pairedCrossover(frequency: .nan, shape: .linkwitzRiley24, sampleRate: 48000))
        XCTAssertThrowsError(try initial.pairedCrossover(frequency: 25000, shape: .linkwitzRiley24, sampleRate: 48000))
        XCTAssertThrowsError(try initial.pairedCrossover(frequency: 4000, shape: .linkwitzRiley24, sampleRate: 8000))
    }

    func testEQCopyKeepsDestinationRoutingAndSourceBandStates() {
        var initial = SpeakerProfile()
        initial.channels[0].bands = [EQBand(frequency: 80, gainDB: -2, enabled: false), EQBand(kind: .highShelf, frequency: 5000, gainDB: 3)]
        initial.channels[0].eqEnabled = false
        initial.channels[0].preampDB = -3
        initial.channels[1].deviceUID = "target"
        initial.channels[1].delayMS = 9
        initial.channels[1].highPass.enabled = true
        let next = initial.copyingEQ(from: .woofer, to: .fullRange)
        XCTAssertEqual(next.channels[0], initial.channels[0])
        XCTAssertEqual(next.channels[1].deviceUID, "target")
        XCTAssertEqual(next.channels[1].outputChannels, [2])
        XCTAssertEqual(next.channels[1].delayMS, 9)
        XCTAssertEqual(next.channels[1].highPass, initial.channels[1].highPass)
        XCTAssertEqual(next.channels[1].eqEnabled, false)
        XCTAssertEqual(next.channels[1].preampDB, -3)
        XCTAssertEqual(next.channels[1].bands.map(\.enabled), [false, true])
        XCTAssertTrue(Set(next.channels[0].bands.map(\.id)).isDisjoint(with: next.channels[1].bands.map(\.id)))
        XCTAssertTrue(next.validationIssues().isEmpty)
        XCTAssertEqual(initial.copyingEQ(from: .woofer, to: .woofer), initial)
    }

    func testPairedCrossoverCanReverseSidesWithoutLeavingBothFiltersEnabled() throws {
        var profile = SpeakerProfile()
        profile.channels[0].gainDB = -5
        profile.channels[1].delayMS = 3.25
        profile.channels[1].bands = [EQBand(frequency: 80, gainDB: -3)]
        profile.channels[2].highPass.enabled = true
        let original = profile
        profile = try profile.pairedCrossover(frequency: 150, shape: .linkwitzRiley24, sampleRate: 48000)
        profile = try profile.pairedCrossover(frequency: 180, shape: .linkwitzRiley48, sampleRate: 48000, lowPassRole: .fullRange)
        XCTAssertTrue(profile.channels[0].highPass.enabled)
        XCTAssertFalse(profile.channels[0].lowPass.enabled)
        XCTAssertTrue(profile.channels[1].lowPass.enabled)
        XCTAssertFalse(profile.channels[1].highPass.enabled)
        XCTAssertEqual(profile.channels[0].highPass.frequency, 180)
        XCTAssertEqual(profile.channels[0].highPass, profile.channels[1].lowPass)
        XCTAssertEqual(profile.channels[0].gainDB, original.channels[0].gainDB)
        XCTAssertEqual(profile.channels[1].delayMS, original.channels[1].delayMS)
        XCTAssertEqual(profile.channels[1].bands, original.channels[1].bands)
        XCTAssertEqual(profile.channels[2], original.channels[2])
        let back = try profile.pairedCrossover(frequency: 200, shape: .linkwitzRiley24, sampleRate: 48000)
        XCTAssertTrue(back.channels[0].lowPass.enabled)
        XCTAssertFalse(back.channels[0].highPass.enabled)
        XCTAssertTrue(back.channels[1].highPass.enabled)
        XCTAssertFalse(back.channels[1].lowPass.enabled)
        XCTAssertThrowsError(try profile.pairedCrossover(frequency: 180, shape: .linkwitzRiley24, sampleRate: 48000, lowPassRole: .builtin))
    }
}
