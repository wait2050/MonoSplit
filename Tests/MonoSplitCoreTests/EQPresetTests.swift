import XCTest
@testable import MonoSplitCore

final class EQPresetTests: XCTestCase {
    func testApplyingPresetPreservesRoutingCrossoverAndOutputControls() throws {
        var channel = ChannelSettings(role: .fullRange)
        channel.deviceUID = "external"; channel.outputChannels = [2]
        channel.lowPass.enabled = true; channel.lowPass.frequency = 180
        channel.gainDB = -7; channel.delayMS = 439.13; channel.inverted = true; channel.muted = true
        var settings = EQSettings.graphicFlat
        settings.bands[3].gainDB = -4.5; settings.bands[4].enabled = false; settings.preampDB = -3
        let applied = try settings.applying(to: channel)
        XCTAssertTrue(EQSettings(channel: applied).matches(settings))
        XCTAssertNotEqual(applied.bands[0].id, settings.bands[0].id)
        var restored = applied
        restored.bands = channel.bands; restored.preampDB = channel.preampDB; restored.eqEnabled = channel.eqEnabled
        XCTAssertEqual(restored, channel)
        XCTAssertTrue(settings.isGraphic)
        settings.bands[0].frequency = 33
        XCTAssertFalse(settings.isGraphic)
    }
    func testPresetPortableRoundTripAndValidation() throws {
        let preset = EQPreset(name: "日常聆听", settings: .graphicFlat)
        let imported = try EQPresetStore.importPreset(EQPresetStore.exportPreset(preset))
        XCTAssertNotEqual(imported.id, preset.id)
        XCTAssertEqual(imported.name, preset.name)
        XCTAssertTrue(imported.settings.matches(preset.settings))
        var invalid = preset
        invalid.settings.bands[0].gainDB = .infinity
        XCTAssertThrowsError(try invalid.validated())
        invalid = preset; invalid.name = " \n "
        XCTAssertThrowsError(try invalid.validated())
        invalid = preset; invalid.version = 99
        XCTAssertThrowsError(try invalid.validated())
        invalid = preset; invalid.settings.bands = (0..<21).map { _ in EQBand() }
        XCTAssertThrowsError(try invalid.validated())
        invalid = preset; invalid.settings.preampDB = -61
        XCTAssertThrowsError(try invalid.validated())
    }
    func testLibraryRecoveryRetainsLastValidBackup() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = EQPresetStore(directory: directory)
        XCTAssertTrue(try store.load().library.presets.isEmpty)
        var first = EQPresetLibrary(); first.presets = [EQPreset(name: "原版", settings: .graphicFlat)]
        try store.save(first)
        var second = first; second.presets[0].name = "修改版"
        try store.save(second)
        try Data("broken".utf8).write(to: store.fileURL)
        let recovered = try store.load()
        XCTAssertTrue(recovered.recovered)
        XCTAssertEqual(recovered.library.presets[0].name, "原版")
        let backup = try Data(contentsOf: store.backupURL)
        try store.save(recovered.library)
        XCTAssertEqual(try Data(contentsOf: store.backupURL), backup)
        XCTAssertFalse(try store.load().recovered)
    }
    func testMatchingIgnoresOnlyBandIdentifiers() {
        let first = EQSettings.graphicFlat
        var second = EQSettings.graphicFlat
        XCTAssertTrue(first.matches(second))
        second.bands[0].enabled = false
        XCTAssertFalse(first.matches(second))
        second = first; second.enabled = false
        XCTAssertFalse(first.matches(second))
        second = first; second.bands[0].q += 0.01
        XCTAssertFalse(first.matches(second))
    }
}
