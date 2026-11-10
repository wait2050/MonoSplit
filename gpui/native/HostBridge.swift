import AppKit
import Foundation
import MonoSplitCore
import UniformTypeIdentifiers

/// Control-thread ABI for the GPUI frontend. The audio callback never crosses this boundary.
@MainActor
final class HostBridge: NSObject, NSMenuDelegate {
    let model: AppModel
    let presetStore: EQPresetStore
    var presetLibrary = EQPresetLibrary()
    var selectedPresets: [ChannelRole: UUID] = [:]
    var presetProfileID: UUID?
    var statusItem: NSStatusItem?
    var quitting = false
    var shutdownComplete = false
    private(set) var fileDialogPending = false
    private var cachedProfile: SpeakerProfile?
    private var cachedDisplay: SpeakerProfile?
    private var cachedRate = 0.0
    private var profileObject: [String: Any] = [:]
    private var displayObject: [String: Any] = [:]
    private var tuningObserver: NSObjectProtocol?

    override init() {
        let environment = ProcessInfo.processInfo.environment
        let testing = environment["MONOSPLIT_TEST_MODE"] == "1"
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let directory = environment["MONOSPLIT_PROFILE_DIR"].map { URL(fileURLWithPath: $0) } ?? base.appendingPathComponent("MonoSplitGPUI")
        if !testing && !FileManager.default.fileExists(atPath: directory.appendingPathComponent("profiles.json").path) {
            if let library = try? ProfileStore(directory: base.appendingPathComponent("MonoSplit")).load().library {
                try? ProfileStore(directory: directory).save(library)
            }
        }
        model = AppModel(directory: directory, monitorDevices: !testing)
        presetStore = EQPresetStore(directory: directory)
        super.init()
        do {
            let loaded = try presetStore.load(); presetLibrary = loaded.library
            if loaded.recovered { model.message = "EQ 预设库已从上一份有效备份恢复" }
        } catch { model.fail(error) }
        if !testing {
            tuningObserver = DistributedNotificationCenter.default().addObserver(
                forName: Notification.Name("com.monosplit.showTuning"), object: nil, queue: .main
            ) { [weak self] _ in Task { @MainActor in self?.showWindow() } }
            NSApp.setActivationPolicy(.accessory)
            let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
            item.button?.image = NSImage(systemSymbolName: "waveform.path", accessibilityDescription: "MonoSplit")
            item.button?.toolTip = "MonoSplit · GPUI"
            let menu = NSMenu()
            menu.delegate = self
            item.menu = menu
            statusItem = item
            menuWillOpen(menu)
        }
    }

    func menuWillOpen(_ menu: NSMenu) {
        menu.removeAllItems()
        menu.addItem(NSMenuItem(title: model.snapshot.status, action: nil, keyEquivalent: ""))
        add(menu, "打开调音窗口", #selector(showWindow), "o")
        add(menu, model.snapshot.requested ? "停止处理" : "启动处理", #selector(toggleRunning), "")
        let input = add(menu, "FineTune 输入（作为独立设备）", #selector(toggleFineTuneInput), "")
        input.state = model.fineTuneInput ? .on : .off
        input.isEnabled = !model.busy
        let mute = add(menu, "总静音", #selector(toggleMute), "")
        mute.state = model.profile.masterMuted ? .on : .off
        menu.addItem(.separator())
        for profile in model.profiles {
            let item = add(menu, profile.name, #selector(selectProfile(_:)), "")
            item.representedObject = profile.id.uuidString
            item.state = profile.id == model.profile.id ? .on : .off
        }
        menu.addItem(.separator())
        add(menu, "退出 MonoSplit", #selector(requestQuit), "q")
    }
    @discardableResult private func add(_ menu: NSMenu, _ title: String, _ action: Selector, _ key: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.target = self
        menu.addItem(item)
        return item
    }
    @objc func showWindow() {
        if let window = NSApp.windows.first(where: { $0.title.contains("MonoSplit") }) {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
        }
    }
    @objc func toggleRunning() {
        if !model.snapshot.requested && NSWorkspace.shared.runningApplications.contains(where: { $0.bundleIdentifier == "com.monosplit.app" }) {
            model.fail(MonoSplitError("请先退出旧版 MonoSplit，再启动 GPUI 版处理。"))
            return
        }
        model.toggleRunning()
    }
    @objc func toggleMute() { model.profile.masterMuted.toggle() }
    @objc func toggleFineTuneInput() { model.setFineTuneInput(!model.fineTuneInput) }
    @objc func selectProfile(_ item: NSMenuItem) {
        if let id = item.representedObject as? String, let uuid = UUID(uuidString: id) { model.selectProfile(uuid) }
    }
    @objc func requestQuit() {
        guard !quitting else { return }
        quitting = true
        Task {
            await model.shutdown()
            shutdownComplete = true
        }
    }

    func snapshot() throws -> String {
        let rate = model.snapshot.sampleRate
        let displayed = model.displayProfile
        if presetProfileID != model.profile.id { selectedPresets.removeAll(); presetProfileID = model.profile.id }
        var presetStates: [String: Any] = [:]
        for channel in model.profile.channels {
            let settings = EQSettings(channel: channel)
            let selected = presetLibrary.presets.first { $0.id == selectedPresets[channel.role] }
                ?? presetLibrary.presets.first { $0.settings.matches(settings) }
            if let selected {
                selectedPresets[channel.role] = selected.id
                presetStates[channel.role.rawValue] = ["id": selected.id.uuidString, "name": selected.name, "modified": !selected.settings.matches(settings)]
            }
        }
        if cachedProfile != model.profile || cachedRate != rate {
            profileObject = try compact(model.profile, rate: rate)
            cachedProfile = model.profile
        }
        if cachedDisplay != displayed || cachedRate != rate {
            displayObject = try compact(displayed, rate: rate)
            cachedDisplay = displayed
        }
        cachedRate = rate
        let status = model.snapshot
        let meter = model.levels.meter
        var result: [String: Any] = [
            "profile": profileObject, "display": displayObject,
            "eqPresets": try object(presetLibrary.presets), "presetStates": presetStates,
            "profiles": model.profiles.map { ["id": $0.id.uuidString, "name": $0.name] },
            "devices": status.devices.map { ["uid": $0.uid, "name": $0.name, "channels": $0.channelCount, "sampleRate": $0.sampleRate, "bluetooth": $0.bluetooth] as [String: Any] },
            "status": status.status, "running": status.running, "requested": status.requested,
            "sampleRate": rate, "busy": model.busy || fileDialogPending, "pending": model.hasPendingChanges,
            "fileDialogPending": fileDialogPending,
            "issues": model.issues, "message": model.message ?? "",
            "canUndo": model.history.canUndo, "canRedo": model.history.canRedo,
            "comparisons": model.comparisons.keys.map(\.rawValue), "comparing": model.comparingRole?.rawValue ?? "",
            "peaks": meter.peaks, "inputPeak": meter.inputPeak, "reduction": meter.limiterReductionDB,
            "frames": meter.renderedFrames, "faults": meter.nonFiniteSamples,
            "routes": status.routeDescription, "missing": status.missing, "diagnostics": status.diagnostics,
            "quitting": quitting, "shutdownComplete": shutdownComplete,
            "dark": NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        ]
        if let preview = model.importPreview {
            result["preview"] = ["source": preview.source, "role": preview.role.rawValue, "preampDB": preview.result.preampDB,
                                 "bands": try object(preview.result.bands), "issues": preview.result.issues.map(\.description), "canApply": preview.result.canApply]
        }
        return String(decoding: try JSONSerialization.data(withJSONObject: result, options: [.sortedKeys]), as: UTF8.self)
    }
    private func object<T: Encodable>(_ value: T) throws -> Any { try JSONSerialization.jsonObject(with: JSONEncoder().encode(value)) }
    private func compact(_ profile: SpeakerProfile, rate: Double) throws -> [String: Any] {
        var result = try object(profile) as! [String: Any]
        var channels = result["channels"] as! [[String: Any]]
        for index in channels.indices {
            let channel = profile.channels[index]
            channels[index]["coefficients"] = FilterMath.coefficients(channel: channel, sampleRate: rate).map(\.values)
            channels[index]["graphic"] = EQSettings(channel: channel).isGraphic || channel.bands.isEmpty
            var bands = channels[index]["bands"] as! [[String: Any]]
            for bandIndex in bands.indices {
                let band = channel.bands[bandIndex]
                bands[bandIndex]["coefficient"] = FilterMath.coefficient(kind: band.kind, frequency: band.frequency, gainDB: band.gainDB, q: band.q, sampleRate: rate).values
            }
            channels[index]["bands"] = bands
            channels[index]["measurements"] = channel.measurements.map { reference -> [String: Any] in
                var points: [[Double]] = []
                var bucket = -1
                let maximum = min(20000, rate * 0.499)
                for point in reference.points where point.frequency >= 20 && point.frequency <= maximum {
                    let next = Int(log(point.frequency / 20) / log(maximum / 20) * 700)
                    if next == bucket { continue }
                    bucket = next
                    points.append([point.frequency, point.spl, point.phase ?? 0, point.phase == nil ? 0 : 1])
                }
                return ["id": reference.id.uuidString, "name": reference.name, "source": reference.source,
                        "visible": reference.visible, "offsetDB": reference.offsetDB, "pointCount": reference.points.count, "plotPoints": points]
            }
        }
        result["channels"] = channels
        return result
    }

    /// A GPUI callback holds a mutable App borrow until the C ABI returns. AppKit's
    /// modal loop dispatches GPUI keyboard, input-source and redraw callbacks again.
    /// Present native panels on the next main-queue turn, after that borrow is released.
    func submit(_ command: [String: Any]) throws {
        let panelActions: Set<String> = ["importProfile", "exportProfile", "importEQ", "importMeasurement", "importPreset", "exportPreset"]
        guard panelActions.contains(command["action"] as? String ?? "") else {
            try self.command(command)
            return
        }
        guard !fileDialogPending, !quitting else { return }
        fileDialogPending = true
        DispatchQueue.main.async { [self] in
            defer { fileDialogPending = false }
            do { try self.command(command) }
            catch { model.fail(error) }
        }
    }

    func command(_ command: [String: Any]) throws {
        guard !quitting else { return }
        let action = command["action"] as? String ?? ""
        let role = ChannelRole(rawValue: command["role"] as? String ?? "woofer") ?? .woofer
        let channelIndex = model.profile.channels.firstIndex { $0.role == role }!
        let id = UUID(uuidString: command["id"] as? String ?? "")
        let editing = ["editBand", "graphicGain", "buildGraphic", "applyPreset", "savePreset", "updatePreset", "addBand", "removeBand", "duplicateBand", "clearEQ", "flatEQ", "copyEQ", "pair", "importEQ", "applyEQ", "importMeasurement", "removeMeasurement"]
        if model.comparingRole == role && editing.contains(action) { throw MonoSplitError("请先返回当前调音，再编辑参数") }
        switch action {
        case "set":
            var next = model.profile
            let field = command["field"] as? String ?? ""
            let number = (command["value"] as? NSNumber)?.doubleValue ?? .nan
            let flag = (command["value"] as? NSNumber)?.boolValue ?? false
            let text = command["value"] as? String ?? ""
            let scope = command["scope"] as? String ?? "channel"
            if model.comparingRole == role && scope != "master" && !(scope == "channel" && ["muted", "solo", "showCurve"].contains(field)) { throw MonoSplitError("请先返回当前调音，再编辑参数") }
            switch scope {
            case "master":
                switch field {
                case "gain": next.masterGainDB = number
                case "preamp": next.preampDB = number
                case "muted": next.masterMuted = flag
                default: throw MonoSplitError("未知总控制参数")
                }
            case "band":
                guard let index = next.channels[channelIndex].bands.firstIndex(where: { $0.id == id }) else { return }
                switch field {
                case "frequency": next.channels[channelIndex].bands[index].frequency = number
                case "gainDB": next.channels[channelIndex].bands[index].gainDB = number
                case "q": next.channels[channelIndex].bands[index].q = number
                case "enabled": next.channels[channelIndex].bands[index].enabled = flag
                case "kind": if let kind = FilterKind(rawValue: text) { next.channels[channelIndex].bands[index].kind = kind }
                default: throw MonoSplitError("未知 EQ 参数")
                }
            case "measurement":
                guard let index = next.channels[channelIndex].measurements.firstIndex(where: { $0.id == id }) else { return }
                if field == "offsetDB" { next.channels[channelIndex].measurements[index].offsetDB = number }
                if field == "visible" { next.channels[channelIndex].measurements[index].visible = flag }
            default:
                switch field {
                case "gainDB": next.channels[channelIndex].gainDB = number
                case "preampDB": next.channels[channelIndex].preampDB = number
                case "delayMS": next.channels[channelIndex].delayMS = number
                case "muted": next.channels[channelIndex].muted = flag
                case "solo": next.channels[channelIndex].solo = flag
                case "enabled": next.channels[channelIndex].enabled = flag
                case "inverted": next.channels[channelIndex].inverted = flag
                case "eqEnabled": next.channels[channelIndex].eqEnabled = flag
                case "showCurve": next.channels[channelIndex].showCurve = flag
                case "highPass.enabled": next.channels[channelIndex].highPass.enabled = flag
                case "lowPass.enabled": next.channels[channelIndex].lowPass.enabled = flag
                case "highPass.frequency": next.channels[channelIndex].highPass.frequency = number
                case "lowPass.frequency": next.channels[channelIndex].lowPass.frequency = number
                case "highPass.shape": if let shape = CrossoverShape(rawValue: text) { next.channels[channelIndex].highPass.shape = shape }
                case "lowPass.shape": if let shape = CrossoverShape(rawValue: text) { next.channels[channelIndex].lowPass.shape = shape }
                case "deviceUID":
                    next.channels[channelIndex].deviceUID = text
                    if let device = model.snapshot.devices.first(where: { $0.uid == text }) {
                        next.channels[channelIndex].outputChannels = next.channels[channelIndex].outputChannels.filter { $0 <= device.channelCount }
                        if next.channels[channelIndex].outputChannels.isEmpty { next.channels[channelIndex].outputChannels = [min(role == .fullRange ? 2 : 1, device.channelCount)] }
                    }
                case "outputChannels": next.channels[channelIndex].outputChannels = command["value"] as? [Int] ?? []
                default: throw MonoSplitError("未知声道参数")
                }
            }
            _ = try next.validated()
            model.profile = next
        case "editBand":
            guard let index = model.profile.channels[channelIndex].bands.firstIndex(where: { $0.id == id }) else { return }
            var next = model.profile
            next.channels[channelIndex].bands[index].frequency = (command["frequency"] as? NSNumber)?.doubleValue ?? .nan
            next.channels[channelIndex].bands[index].gainDB = (command["gainDB"] as? NSNumber)?.doubleValue ?? .nan
            model.profile = try next.validated()
        case "buildGraphic", "graphicGain":
            var next = model.profile
            if action == "buildGraphic" || next.channels[channelIndex].bands.isEmpty {
                next.channels[channelIndex].bands = EQSettings.graphicFlat.bands
            }
            if action == "graphicGain" {
                guard let index = command["index"] as? Int, next.channels[channelIndex].bands.indices.contains(index), next.channels[channelIndex].bands[index].kind.hasGain else { throw MonoSplitError("无效的均衡器频段") }
                next.channels[channelIndex].bands[index].gainDB = (command["value"] as? NSNumber)?.doubleValue ?? .nan
            }
            if action == "buildGraphic" { next.channels[channelIndex].eqEnabled = true }
            model.profile = try next.validated()
        case "applyPreset":
            var next = model.profile
            if let id, let preset = presetLibrary.presets.first(where: { $0.id == id }) {
                next.channels[channelIndex] = try preset.settings.applying(to: next.channels[channelIndex])
                selectedPresets[role] = id
            } else if command["id"] as? String == "flat" {
                next.channels[channelIndex] = try EQSettings.graphicFlat.applying(to: next.channels[channelIndex])
                selectedPresets[role] = nil
            } else { throw MonoSplitError("预设不存在") }
            model.profile = try next.validated()
        case "savePreset", "updatePreset", "renamePreset", "duplicatePreset", "deletePreset":
            var next = presetLibrary
            let name = (command["name"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            var savedID: UUID?
            if action == "savePreset" {
                let preset = try EQPreset(name: name, settings: EQSettings(channel: model.profile.channels[channelIndex])).validated()
                next.presets.append(preset); savedID = preset.id
            } else {
                guard let index = next.presets.firstIndex(where: { $0.id == id }) else { throw MonoSplitError("预设不存在") }
                switch action {
                case "updatePreset": next.presets[index].settings = EQSettings(channel: model.profile.channels[channelIndex]); next.presets[index].updatedAt = Date(); savedID = next.presets[index].id
                case "renamePreset": next.presets[index].name = name; next.presets[index].updatedAt = Date()
                case "duplicatePreset":
                    var preset = next.presets[index]; preset.id = UUID(); preset.name = String(preset.name.prefix(110)) + " 副本"; preset.createdAt = Date(); preset.updatedAt = Date(); next.presets.append(preset)
                default: next.presets.remove(at: index)
                }
            }
            try presetStore.save(next); presetLibrary = next
            if let savedID { selectedPresets[role] = savedID }
            model.message = action == "deletePreset" ? "已删除预设，当前 EQ 参数仍保留" : "EQ 预设已保存"
        case "importPreset":
            let panel = NSOpenPanel(); panel.allowedContentTypes = [.json]; panel.allowsMultipleSelection = true; panel.message = "导入 MonoSplit EQ 预设 JSON"
            if panel.runModal() == .OK {
                var next = presetLibrary
                for url in panel.urls { next.presets.append(try EQPresetStore.importPreset(Data(contentsOf: url))) }
                try presetStore.save(next); presetLibrary = next; model.message = "EQ 预设已导入，可选择应用到任意声道"
            }
        case "exportPreset":
            guard let preset = presetLibrary.presets.first(where: { $0.id == id }) else { throw MonoSplitError("预设不存在") }
            let panel = NSSavePanel(); panel.allowedContentTypes = [.json]; panel.nameFieldStringValue = preset.name.replacingOccurrences(of: "/", with: "-") + ".eq.json"
            if panel.runModal() == .OK, let url = panel.url { try EQPresetStore.exportPreset(preset).write(to: url, options: .atomic) }
        case "run": toggleRunning()
        case "undo": model.undo()
        case "redo": model.redo()
        case "beginGesture": model.editGesture(true)
        case "endGesture": model.editGesture(false)
        case "endComparison": model.endComparison()
        case "capture": model.captureComparison(role: role)
        case "compare": model.toggleComparison(role: role)
        case "clearSolos": model.clearSolos()
        case "addBand":
            guard model.profile.channels[channelIndex].bands.count < 20 else { throw MonoSplitError("每路最多 20 段 EQ") }
            model.profile.channels[channelIndex].bands.append(EQBand())
        case "removeBand": model.profile.channels[channelIndex].bands.removeAll { $0.id == id }
        case "duplicateBand":
            guard model.profile.channels[channelIndex].bands.count < 20, var band = model.profile.channels[channelIndex].bands.first(where: { $0.id == id }) else { return }
            band.id = UUID(); model.profile.channels[channelIndex].bands.append(band)
        case "clearEQ":
            var next = model.profile; next.channels[channelIndex].bands = []; next.channels[channelIndex].preampDB = 0; model.profile = next
        case "flatEQ":
            var next = model.profile
            for index in next.channels[channelIndex].bands.indices where next.channels[channelIndex].bands[index].kind.hasGain { next.channels[channelIndex].bands[index].gainDB = 0 }
            model.profile = next
        case "copyEQ": if let source = ChannelRole(rawValue: command["source"] as? String ?? "") { model.copyEQ(from: source, to: role) }
        case "pair":
            model.applyPairedCrossover(frequency: (command["frequency"] as? NSNumber)?.doubleValue ?? .nan,
                                      shape: CrossoverShape(rawValue: command["shape"] as? String ?? "") ?? .linkwitzRiley24,
                                      lowPassRole: role)
        case "selectProfile": if let id { model.selectProfile(id) }
        case "newProfile": model.addProfile(copy: false)
        case "duplicateProfile": model.addProfile(copy: true)
        case "renameProfile": model.renameText = command["name"] as? String ?? ""; model.renameProfile()
        case "deleteProfile": model.deleteProfile()
        case "importProfile": model.importProfile()
        case "exportProfile": model.exportProfile()
        case "importEQ": model.importEQ(role: role)
        case "applyEQ": model.applyEQPreview()
        case "cancelEQ": model.importPreview = nil
        case "importMeasurement": model.importMeasurement(role: role)
        case "removeMeasurement": model.profile.channels[channelIndex].measurements.removeAll { $0.id == id }
        case "dismissMessage": model.message = nil; model.errorPresented = false
        case "appearance":
            let mode = command["value"] as? String ?? "system"
            NSApp.appearance = mode == "dark" ? NSAppearance(named: .darkAqua) : mode == "light" ? NSAppearance(named: .aqua) : nil
        case "show": showWindow()
        case "hide": NSApp.keyWindow?.orderOut(nil)
        case "quit": requestQuit()
        default: throw MonoSplitError("未知操作")
        }
    }
}

@MainActor private var bridge: HostBridge?
@_cdecl("monosplit_host_init") @MainActor
public func monosplitHostInit() { if bridge == nil { bridge = HostBridge() } }
@_cdecl("monosplit_host_snapshot") @MainActor
public func monosplitHostSnapshot() -> UnsafeMutablePointer<CChar>? {
    guard let bridge else { return nil }
    do { return strdup(try bridge.snapshot()) }
    catch { return strdup("{\"message\":\"状态读取失败\"}") }
}
@_cdecl("monosplit_host_command") @MainActor
public func monosplitHostCommand(_ pointer: UnsafePointer<CChar>?) {
    guard let pointer, let bridge else { return }
    do {
        let object = try JSONSerialization.jsonObject(with: Data(String(cString: pointer).utf8))
        guard let command = object as? [String: Any] else { throw MonoSplitError("操作格式无效") }
        try bridge.submit(command)
    } catch { bridge.model.fail(error) }
}
@_cdecl("monosplit_host_free")
public func monosplitHostFree(_ pointer: UnsafeMutablePointer<CChar>?) { free(pointer) }
