import AppKit
import Foundation
import MonoSplitCore

@main struct GPUIBridgeChecks {
    @MainActor static func main() async throws {
        func check(_ condition: Bool) { precondition(condition) }
        _ = NSApplication.shared
        monosplitHostInit()
        func command(_ value: [String: Any]) throws {
            let data = try JSONSerialization.data(withJSONObject: value)
            String(decoding: data, as: UTF8.self).withCString { monosplitHostCommand($0) }
        }
        func snapshot() throws -> [String: Any] {
            guard let pointer = monosplitHostSnapshot() else { fatalError("Missing host") }
            defer { monosplitHostFree(pointer) }
            return try JSONSerialization.jsonObject(with: Data(String(cString: pointer).utf8)) as! [String: Any]
        }
        func profile() throws -> SpeakerProfile {
            let state = try snapshot()["profile"]!
            return try JSONDecoder().decode(SpeakerProfile.self, from: JSONSerialization.data(withJSONObject: state))
        }
        func set(_ field: String, _ value: Any, role: String = "woofer") throws {
            try command(["action": "set", "scope": "channel", "role": role, "field": field, "value": value])
        }
        check(try snapshot()["requested"] as? Bool == false)
        try set("deviceUID", "test-device")
        try set("delayMS", 439.13)
        try set("gainDB", -7.5)
        try set("highPass.enabled", true)
        let original = try profile().channels[0]
        try command(["action": "buildGraphic"])
        let beforeDrag = try profile()
        try command(["action": "beginGesture"])
        for gain in [-2.0, -3.1, -4.5] { try command(["action": "graphicGain", "index": 3, "value": gain]) }
        try command(["action": "endGesture"])
        check(try profile().channels[0].bands[3].gainDB == -4.5)
        try command(["action": "undo"])
        check(try profile() == beforeDrag)
        try command(["action": "redo"])
        try command(["action": "savePreset", "name": "集成测试 EQ"])
        var presets = try snapshot()["eqPresets"] as! [[String: Any]]
        check(presets.count == 1 && presets[0]["name"] as? String == "集成测试 EQ")
        let id = presets[0]["id"] as! String
        let savedSettings = EQSettings(channel: try profile().channels[0])
        try command(["action": "applyPreset", "id": id, "role": "fullRange"])
        check(savedSettings.matches(EQSettings(channel: try profile().channels[1])))
        let current = try profile().channels[0]
        check(current.deviceUID == original.deviceUID && current.delayMS == original.delayMS && current.gainDB == original.gainDB && current.highPass == original.highPass)
        try command(["action": "graphicGain", "index": 1, "value": 2.3])
        let states = try snapshot()["presetStates"] as! [String: [String: Any]]
        check(states["woofer"]?["modified"] as? Bool == true)
        try command(["action": "updatePreset", "id": id])
        try command(["action": "renamePreset", "id": id, "name": "更名后 EQ"])
        try command(["action": "duplicatePreset", "id": id])
        presets = try snapshot()["eqPresets"] as! [[String: Any]]
        check(presets.count == 2 && presets[0]["name"] as? String == "更名后 EQ")
        let valid = try profile()
        try command(["action": "graphicGain", "index": 2, "value": "invalid"])
        check(try profile() == valid)
        check(!(try snapshot()["message"] as! String).isEmpty)
        try command(["action": "dismissMessage"])
        try command(["action": "capture"])
        try command(["action": "compare"])
        try command(["action": "graphicGain", "index": 2, "value": 5])
        check(try profile() == valid)
        try set("muted", true)
        check(try profile().channels[0].muted)
        try command(["action": "endComparison"])
        try command(["action": "deletePreset", "id": id])
        check(try (snapshot()["eqPresets"] as! [Any]).count == 1)
        try command(["action": "quit"])
        for _ in 0..<100 {
            if try snapshot()["shutdownComplete"] as? Bool == true { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        check(try snapshot()["shutdownComplete"] as? Bool == true)
        print("PASS: FFI JSON, graphic gesture undo/redo, preset save/apply/update/rename/duplicate/delete, dirty state, isolation, invalid input, comparison, graceful shutdown")
    }
}
