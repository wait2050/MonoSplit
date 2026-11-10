import XCTest
import Observation
import Synchronization
import MonoSplitCore
@testable import MonoSplit

@MainActor final class AppModelTests: XCTestCase {
    private func makeModel() -> (AppModel, URL) {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("MonoSplitTests-\(UUID())")
        return (AppModel(directory: directory, monitorDevices: false), directory)
    }

    func testNestedListeningEditsParticipateInUndo() async throws {
        let (model, directory) = makeModel()
        defer { try? FileManager.default.removeItem(at: directory) }
        model.profile.channels[0].solo = true
        model.undo()
        XCTAssertFalse(model.profile.channels[0].solo)
        model.redo()
        XCTAssertTrue(model.profile.channels[0].solo)
        model.clearSolos()
        XCTAssertFalse(model.profile.channels[0].solo)
        model.undo()
        XCTAssertTrue(model.profile.channels[0].solo)
        await model.shutdown()
    }

    func testClearEQAndUndoRestoreAllBands() async throws {
        let (model, directory) = makeModel()
        defer { try? FileManager.default.removeItem(at: directory) }
        model.profile.channels[1].bands = [EQBand(gainDB: -3.5), EQBand(gainDB: 4)]
        let before = model.profile
        var cleared = model.profile.channels[1]
        cleared.bands = []
        cleared.preampDB = 0
        model.profile.channels[1] = cleared
        XCTAssertTrue(model.profile.channels[1].bands.isEmpty)
        model.undo()
        XCTAssertEqual(model.profile, before)
        model.profile.channels[0].solo = true
        model.undo()
        XCTAssertEqual(model.profile, before)
        await model.shutdown()
    }

    func testComparisonIsTransientAndKeepsLiveMuteRoutingAndMaster() async throws {
        let (model, directory) = makeModel()
        defer { try? FileManager.default.removeItem(at: directory) }
        model.profile.channels[0].gainDB = -5
        model.captureComparison(role: .woofer)
        model.profile.channels[0].gainDB = -8
        model.toggleComparison(role: .woofer)
        XCTAssertEqual(model.displayProfile.channels[0].gainDB, -5)
        XCTAssertEqual(model.profile.channels[0].gainDB, -8)
        model.profile.masterMuted = true
        model.profile.masterGainDB = -20
        model.profile.channels[0].muted = true
        model.profile.channels[0].deviceUID = "live-device"
        XCTAssertTrue(model.displayProfile.masterMuted)
        XCTAssertTrue(model.displayProfile.channels[0].muted)
        XCTAssertEqual(model.displayProfile.masterGainDB, -20)
        XCTAssertEqual(model.displayProfile.channels[0].deviceUID, "live-device")
        await model.shutdown()
        let stored = try ProfileStore(directory: directory).load().library!.profiles[0]
        XCTAssertEqual(stored.channels[0].gainDB, -8)
        XCTAssertEqual(stored.masterGainDB, -20)
    }

    func testProfileSwitchResetsSessionToolsAndSameSelectionKeepsEdits() async throws {
        let (model, directory) = makeModel()
        defer { try? FileManager.default.removeItem(at: directory) }
        let originalID = model.profile.id
        model.profile.channels[0].delayMS = 10
        model.selectProfile(originalID)
        XCTAssertEqual(model.profile.channels[0].delayMS, 10)
        model.captureComparison(role: .woofer)
        model.toggleComparison(role: .woofer)
        model.addProfile(copy: true)
        XCTAssertNil(model.comparingRole)
        XCTAssertTrue(model.comparisons.isEmpty)
        XCTAssertFalse(model.history.canUndo)
        model.selectProfile(originalID)
        XCTAssertEqual(model.profile.channels[0].delayMS, 10)
        await model.shutdown()
    }

    func testMeterRefreshDoesNotInvalidateEditorStatus() async throws {
        let (model, directory) = makeModel()
        defer { try? FileManager.default.removeItem(at: directory) }
        let editorInvalidated = Mutex(false)
        let meterInvalidated = Mutex(false)
        withObservationTracking {
            _ = model.snapshot
        } onChange: { editorInvalidated.withLock { $0 = true } }
        withObservationTracking {
            _ = model.levels.meter
        } onChange: { meterInvalidated.withLock { $0 = true } }
        var packet = AudioSnapshot()
        for tick in 1...100 {
            packet.meter.renderedFrames = UInt64(tick * 4800)
            packet.meter.peaks = [Float(tick) / 100, 0.1, 0]
            model.receiveSnapshot(packet)
        }
        XCTAssertFalse(editorInvalidated.withLock { $0 })
        XCTAssertTrue(meterInvalidated.withLock { $0 })
        XCTAssertEqual(model.levels.meter.renderedFrames, 480000)
        packet.sampleRate = 44100
        model.receiveSnapshot(packet)
        XCTAssertTrue(editorInvalidated.withLock { $0 })
        XCTAssertEqual(model.snapshot.sampleRate, 44100)
        await model.shutdown()
    }
}
