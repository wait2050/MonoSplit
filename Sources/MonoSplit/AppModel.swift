import AppKit
import Observation
import SwiftUI
import UniformTypeIdentifiers
import MonoSplitCore

@MainActor @Observable
final class AppModel {
    var profile: SpeakerProfile {
        didSet {
            guard ready, oldValue != profile else { return }
            if oldValue.id != profile.id {
                history.reset()
                comparisons.removeAll()
                comparingRole = nil
            } else if !restoringHistory {
                history.record(before: oldValue, after: profile, time: ProcessInfo.processInfo.systemUptime)
            }
            scheduleUpdate()
        }
    }
    private(set) var profiles: [SpeakerProfile] = []
    private(set) var snapshot = AudioStatus()
    let levels = AudioLevels()
    var message: String?
    var busy = false
    private(set) var fineTuneInput: Bool
    var hasPendingChanges = false
    var phaseMode = false
    var includeMaster = false
    var renameText = ""
    var showRename = false
    var importPreview: EQPreview?
    var errorPresented = false
    private(set) var history = ProfileEditHistory()
    private(set) var comparisons: [ChannelRole: ChannelTuning] = [:]
    private(set) var comparingRole: ChannelRole?
    private var restoringHistory = false
    private var needsInitialRouting = false
    private var ready = false
    private let host: CoreAudioHost
    private let store: ProfileStore
    private let writer: ProfileWriter
    private var revision = 0
    private var saveTask: Task<Void, Never>?
    private var updateTask: Task<Void, Never>?
    private var pollTask: Task<Void, Never>?
    private var notifications: [NSObjectProtocol] = []
    private var applicationError: String?

    init(directory: URL? = nil, monitorDevices: Bool = true) {
        let managed = monitorDevices && UserDefaults.standard.bool(forKey: "fineTuneInput")
        fineTuneInput = managed
        host = CoreAudioHost(fineTuneInput: managed)
        let directory = directory ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("MonoSplit", isDirectory: true)
        store = ProfileStore(directory: directory)
        writer = ProfileWriter(store: store)
        profile = SpeakerProfile(name: "我的三路音箱")
        do {
            let loaded = try store.load()
            if let library = loaded.library {
                profiles = library.profiles
                profile = profiles.first { $0.id == library.selectedID }!
                if loaded.recovered { message = "配置库已从上一份有效备份恢复" }
            } else { profiles = [profile]; needsInitialRouting = true }
        } catch { profiles = [profile]; message = "配置库读取失败，已载入空白配置。\(error.localizedDescription)" }
        ready = true
        guard monitorDevices else { return }
        pollTask = Task { [weak self] in
            var tick = 0
            while !Task.isCancelled {
                guard let self else { return }
                self.receiveSnapshot(await self.host.poll(refreshDevices: tick % 10 == 0))
                tick += 1
                try? await Task.sleep(for: .milliseconds(100))
            }
        }
        let center = NSWorkspace.shared.notificationCenter
        notifications.append(center.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in await self?.host.suspend() }
        })
        notifications.append(center.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in await self?.host.resume() }
        })
        Task {
            do { _ = try await host.apply(profile) } catch { message = error.localizedDescription }
            receiveSnapshot(await host.inspect())
            // Only populate a pristine first-run profile. Existing saved choices retain their UIDs.
            if needsInitialRouting {
                needsInitialRouting = false
                if let ys = snapshot.devices.first(where: { $0.name.localizedCaseInsensitiveContains("YS Audio") }) {
                    profile.channels[0].deviceUID = ys.uid
                    profile.channels[1].deviceUID = ys.uid
                }
                if let builtin = snapshot.devices.first(where: { $0.uid == "BuiltInSpeakerDevice" }) {
                    profile.channels[2].deviceUID = builtin.uid
                    profile.channels[2].outputChannels = Array(1...min(2, builtin.channelCount))
                }
                persist()
            }
        }
    }
    var displayProfile: SpeakerProfile {
        guard let role = comparingRole, let tuning = comparisons[role],
              let index = profile.channels.firstIndex(where: { $0.role == role }) else { return profile }
        var audition = profile
        audition.channels[index] = tuning.applying(to: audition.channels[index])
        return audition
    }
    func receiveSnapshot(_ next: AudioSnapshot) {
        let status = AudioStatus(next)
        if status != snapshot { snapshot = status }
        if next.meter != levels.meter { levels.meter = next.meter }
    }
    var issues: [String] { displayProfile.validationIssues(sampleRate: snapshot.sampleRate) }
    func captureComparison(role: ChannelRole) {
        guard let channel = profile.channels.first(where: { $0.role == role }) else { return }
        let wasComparing = comparingRole != nil
        history.endGroup()
        comparingRole = nil
        comparisons[role] = ChannelTuning(channel)
        if wasComparing { scheduleUpdate() }
    }
    func toggleComparison(role: ChannelRole) {
        guard comparisons[role] != nil else { return }
        history.endGroup()
        comparingRole = comparingRole == role ? nil : role
        if !issues.isEmpty { comparingRole = nil; fail(MonoSplitError("快照在当前采样率下不可用，请重新保存快照。")) }
        scheduleUpdate()
    }
    func endComparison() {
        guard comparingRole != nil else { return }
        comparingRole = nil
        scheduleUpdate()
    }
    func undo() {
        guard let previous = history.undo(current: profile) else { return }
        comparingRole = nil
        restoringHistory = true
        profile = previous
        restoringHistory = false
    }
    func editGesture(_ editing: Bool) {
        if editing { history.beginGroup() } else { history.endGroup() }
    }
    func redo() {
        guard let next = history.redo(current: profile) else { return }
        comparingRole = nil
        restoringHistory = true
        profile = next
        restoringHistory = false
    }
    func applyPairedCrossover(frequency: Double, shape: CrossoverShape, lowPassRole: ChannelRole) {
        do {
            let next = try profile.pairedCrossover(frequency: frequency, shape: shape, sampleRate: snapshot.sampleRate, lowPassRole: lowPassRole)
            comparingRole = nil
            profile = next
        } catch { fail(error) }
    }
    func copyEQ(from role: ChannelRole, to destination: ChannelRole) {
        endComparison()
        profile = profile.copyingEQ(from: role, to: destination)
    }
    func clearSolos() {
        var next = profile
        for index in next.channels.indices { next.channels[index].solo = false }
        profile = next
    }
    func fail(_ error: Error) { message = error.localizedDescription; errorPresented = true }
    private func scheduleUpdate() {
        hasPendingChanges = true
        updateTask?.cancel()
        updateTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(35))
            guard !Task.isCancelled, let self else { return }
            do {
                let updated = try await self.host.apply(self.displayProfile)
                guard !Task.isCancelled else { return }
                self.receiveSnapshot(updated)
                self.hasPendingChanges = false
                if let applicationError = self.applicationError, self.message == applicationError { self.message = nil }
                self.applicationError = nil
                self.persist()
            } catch {
                if !Task.isCancelled {
                    self.applicationError = error.localizedDescription
                    self.message = error.localizedDescription
                }
            }
        }
    }
    func persist() {
        guard profile.validationIssues().isEmpty else { return }
        if let index = profiles.firstIndex(where: { $0.id == profile.id }) { profiles[index] = profile }
        revision += 1
        let currentRevision = revision
        let library = ProfileLibrary(profiles: profiles, selectedID: profile.id)
        saveTask?.cancel()
        saveTask = Task { [weak self, writer] in
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled else { return }
            do { try await writer.save(library, revision: currentRevision) }
            catch { self?.message = "保存失败。\(error.localizedDescription)" }
        }
    }
    func toggleRunning() {
        guard !busy else { return }
        busy = true
        Task {
            defer { busy = false }
            if snapshot.requested || snapshot.running {
                await host.stop()
                receiveSnapshot(await host.inspect())
                return
            }
            let fineTune = NSWorkspace.shared.runningApplications.first { app in
                (app.bundleIdentifier?.lowercased().contains("finetune") == true) || app.localizedName?.lowercased().contains("finetune") == true
            }
            if fineTune != nil && !fineTuneInput { fail(MonoSplitError("请切换为“FineTune 输入”，或先退出 FineTune 后使用独立系统音频处理。")); return }
            do {
                updateTask?.cancel()
                receiveSnapshot(try await host.start(displayProfile))
                hasPendingChanges = false
                message = nil
                persist()
            } catch { fail(error) }
        }
    }
    func setFineTuneInput(_ enabled: Bool) {
        guard !busy, fineTuneInput != enabled else { return }
        if !enabled && snapshot.requested && NSWorkspace.shared.runningApplications.contains(where: {
            $0.bundleIdentifier?.lowercased().contains("finetune") == true
        }) {
            fail(MonoSplitError("请先停止处理或退出 FineTune，再切回系统音频输入。"))
            return
        }
        busy = true
        Task {
            defer { busy = false }
            do {
                receiveSnapshot(try await host.setFineTuneInput(enabled))
                fineTuneInput = enabled
                UserDefaults.standard.set(enabled, forKey: "fineTuneInput")
            } catch { fail(error) }
        }
    }
    func selectProfile(_ id: UUID) {
        guard id != profile.id, let next = profiles.first(where: { $0.id == id }) else { return }
        persist()
        profile = next
    }
    func addProfile(copy: Bool) {
        persist()
        var next = copy ? profile : SpeakerProfile()
        next.id = UUID()
        next.name = copy ? profile.name + " 副本" : "新音箱配置"
        profiles.append(next)
        profile = next
        persist()
    }
    func renameProfile() {
        let value = renameText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return }
        profile.name = value
        persist()
    }
    func deleteProfile() {
        guard profiles.count > 1 else { return }
        profiles.removeAll { $0.id == profile.id }
        profile = profiles[0]
        persist()
    }
    func exportProfile() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.json]
        panel.title = "导出音箱配置"
        panel.prompt = "导出"
        panel.nameFieldStringValue = profile.name + ".json"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do { try ProfileStore.exportProfile(profile).write(to: url, options: .atomic) } catch { fail(error) }
    }
    func importProfile() {
        guard let url = chooseFile(types: [.json], title: "导入音箱配置") else { return }
        do {
            let imported = try ProfileStore.importProfile(readFile(url, maximum: 64 * 1024 * 1024))
            persist()
            profiles.append(imported)
            profile = imported
            persist()
        } catch { fail(error) }
    }
    func importEQ(role: ChannelRole) {
        guard let url = chooseFile(types: [.plainText, .text], title: "导入\(role.title)的 EQ 参数", message: "选择 REW 导出的 Generic / Equalizer APO 滤波器设置文本。") else { return }
        do {
            let text = try decodeText(readFile(url, maximum: 4 * 1024 * 1024))
            importPreview = EQPreview(profileID: profile.id, role: role, source: url.lastPathComponent, result: REWImporter.parseEQ(text))
        } catch { fail(error) }
    }
    func applyEQPreview() {
        guard let preview = importPreview, preview.profileID == profile.id, preview.result.canApply,
              let index = profile.channels.firstIndex(where: { $0.role == preview.role }) else { return }
        // Whole-profile assignment causes a single configuration transaction.
        var next = profile
        next.channels[index].bands = preview.result.bands
        next.channels[index].preampDB = preview.result.preampDB
        next.channels[index].eqEnabled = true
        profile = next
        importPreview = nil
    }
    func importMeasurement(role: ChannelRole) {
        guard let url = chooseFile(types: [.plainText, .commaSeparatedText, .text], title: "导入\(role.title)的测量曲线", message: "选择包含频率、SPL 和可选相位的文本文件。") else { return }
        do {
            let reference = try REWImporter.parseMeasurement(decodeText(readFile(url, maximum: 64 * 1024 * 1024)), name: url.deletingPathExtension().lastPathComponent, source: url.lastPathComponent)
            guard let index = profile.channels.firstIndex(where: { $0.role == role }) else { return }
            profile.channels[index].measurements.append(reference)
        } catch { fail(error) }
    }
    private func chooseFile(types: [UTType], title: String, message: String? = nil) -> URL? {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = types
        panel.title = title
        panel.prompt = "导入"
        panel.message = message ?? ""
        panel.allowsMultipleSelection = false
        return panel.runModal() == .OK ? panel.url : nil
    }
    private func readFile(_ url: URL, maximum: Int) throws -> Data {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        guard ((attributes[.size] as? NSNumber)?.intValue ?? 0) <= maximum else { throw MonoSplitError("文件过大") }
        return try Data(contentsOf: url)
    }
    private func decodeText(_ data: Data) throws -> String {
        if let text = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .utf16) { return text }
        throw MonoSplitError("文本编码不受支持，请导出 UTF-8 文本")
    }
    func shutdown() async {
        ready = false
        pollTask?.cancel()
        updateTask?.cancel()
        persist()
        saveTask?.cancel()
        revision += 1
        do { try await writer.save(ProfileLibrary(profiles: profiles, selectedID: profile.id), revision: revision) }
        catch { message = error.localizedDescription }
        await host.stop()
        for token in notifications { NSWorkspace.shared.notificationCenter.removeObserver(token) }
        notifications.removeAll()
    }
}

struct EQPreview: Identifiable {
    var id = UUID()
    var profileID: UUID
    var role: ChannelRole
    var source: String
    var result: EQImportResult
}

private actor ProfileWriter {
    let store: ProfileStore
    private var savedRevision = 0
    init(store: ProfileStore) { self.store = store }
    func save(_ library: ProfileLibrary, revision: Int) throws {
        guard revision >= savedRevision else { return }
        try store.save(library)
        savedRevision = revision
    }
}
