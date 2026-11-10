import AppKit
import CoreAudio
import MonoSplitCore
import MonoSplitDSP

private enum HAL {
    static let system = AudioObjectID(kAudioObjectSystemObject)
    static func check(_ status: OSStatus, _ operation: String) throws {
        guard status == noErr else { throw MonoSplitError("\(operation)失败（Core Audio \(status)）。请检查系统音频录制权限和输出设备。") }
    }
    static func value<T>(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector, scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal, initial: T) throws -> T {
        var result = initial
        var address = AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
        var size = UInt32(MemoryLayout<T>.size)
        try check(withUnsafeMutablePointer(to: &result) { AudioObjectGetPropertyData(object, &address, 0, nil, &size, $0) }, "读取音频属性")
        return result
    }
    static func ids(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector, scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) throws -> [AudioObjectID] {
        var address = AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        try check(AudioObjectGetPropertyDataSize(object, &address, 0, nil, &size), "读取音频列表")
        var result = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        if size > 0 { try check(AudioObjectGetPropertyData(object, &address, 0, nil, &size, &result), "读取音频列表") }
        return result
    }
    static func string(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector) throws -> String {
        let result: CFString = try value(object, selector, initial: "" as CFString)
        return result as String
    }
    static func layout(_ object: AudioObjectID, scope: AudioObjectPropertyScope) throws -> [Int] {
        var address = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyStreamConfiguration, mScope: scope, mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        try check(AudioObjectGetPropertyDataSize(object, &address, 0, nil, &size), "读取声道布局")
        guard size >= MemoryLayout<AudioBufferList>.size else { return [] }
        let storage = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { storage.deallocate() }
        try check(AudioObjectGetPropertyData(object, &address, 0, nil, &size, storage), "读取声道布局")
        return UnsafeMutableAudioBufferListPointer(storage.assumingMemoryBound(to: AudioBufferList.self)).map { Int($0.mNumberChannels) }
    }
    static func devices() -> [OutputDevice] {
        let ids = (try? ids(system, kAudioHardwarePropertyDevices)) ?? []
        return ids.compactMap { id in
            guard let uid = try? string(id, kAudioDevicePropertyDeviceUID),
                  !uid.hasPrefix("com.monosplit.aggregate."),
                  let name = try? string(id, kAudioObjectPropertyName),
                  let layout = try? layout(id, scope: kAudioObjectPropertyScopeOutput),
                  layout.reduce(0, +) > 0 else { return nil }
            let transport = (try? value(id, kAudioDevicePropertyTransportType, initial: UInt32(0))) ?? 0
            // Physical devices have predictable channel mappings and avoid nested aggregates.
            guard transport != kAudioDeviceTransportTypeAggregate, transport != kAudioDeviceTransportTypeVirtual else { return nil }
            let rate = (try? value(id, kAudioDevicePropertyNominalSampleRate, initial: Double(0))) ?? 0
            let alive = (try? value(id, kAudioDevicePropertyDeviceIsAlive, initial: UInt32(0))) ?? 0
            guard alive != 0, rate > 0 else { return nil }
            return OutputDevice(id: id, uid: uid, name: name, channelCount: layout.reduce(0, +), sampleRate: rate, bluetooth: transport == kAudioDeviceTransportTypeBluetooth || transport == kAudioDeviceTransportTypeBluetoothLE)
        }
    }
    static func ownProcess() throws -> AudioObjectID {
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyTranslatePIDToProcessObject, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var pid = getpid(), result = AudioObjectID(0), size = UInt32(MemoryLayout<AudioObjectID>.size)
        try check(AudioObjectGetPropertyData(system, &address, UInt32(MemoryLayout<pid_t>.size), &pid, &size, &result), "识别自身音频进程")
        return result
    }
    static func excludeHardwareInputs(_ device: AudioObjectID, proc: AudioDeviceIOProcID, tapInput: Bool = true) throws {
        let streams = try ids(device, kAudioDevicePropertyStreams, scope: kAudioObjectPropertyScopeInput)
        guard !streams.isEmpty else {
            if tapInput { throw MonoSplitError("聚合设备没有 Tap 输入流") }
            return
        }
        let offset = MemoryLayout<AudioHardwareIOProcStreamUsage>.offset(of: \.mStreamIsOn)!
        let bytes = offset + streams.count * MemoryLayout<UInt32>.size
        let storage = UnsafeMutableRawPointer.allocate(byteCount: max(bytes, MemoryLayout<AudioHardwareIOProcStreamUsage>.size), alignment: MemoryLayout<AudioHardwareIOProcStreamUsage>.alignment)
        defer { storage.deallocate() }
        storage.initializeMemory(as: UInt8.self, repeating: 0, count: bytes)
        let usage = storage.assumingMemoryBound(to: AudioHardwareIOProcStreamUsage.self)
        usage.pointee.mIOProc = unsafeBitCast(proc, to: UnsafeMutableRawPointer.self)
        usage.pointee.mNumberStreams = UInt32(streams.count)
        let flags = storage.advanced(by: offset).assumingMemoryBound(to: UInt32.self)
        // HAL appends Tap streams after physical-device input streams.
        if tapInput { flags[streams.count - 1] = 1 }
        var address = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyIOProcStreamUsage, mScope: kAudioObjectPropertyScopeInput, mElement: kAudioObjectPropertyElementMain)
        try check(AudioObjectSetPropertyData(device, &address, 0, nil, UInt32(bytes), storage), "关闭硬件麦克风输入")
    }
}

struct AudioSnapshot: Sendable {
    var devices: [OutputDevice] = []
    var running = false
    var requested = false
    var sampleRate: Double = 48000
    var status = "已停止"
    var missing: [String] = []
    var meter = DSPMeter()
    var routeDescription: [String] = []
    var diagnostics: [String] = []
}

/// A session exclusively owns all HAL resources and releases DSP storage after its IOProc stops.
private final class AudioSession {
    var tap = AudioObjectID(0)
    var aggregate = AudioObjectID(0)
    var proc: AudioDeviceIOProcID?
    var kernel: DSPKernel?
    var configuration = SpeakerProfile()
    var bridge: OpaquePointer?
    var bridgePath: URL?
    var endpoint: [String: Any]?
    static var bridgeDirectory: URL {
        if let path = ProcessInfo.processInfo.environment["MONOSPLIT_BRIDGE_DIR"] { return URL(fileURLWithPath: path, isDirectory: true) }
        return FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("MonoSplitBridge", isDirectory: true)
    }
    func publishEndpoint() {
        guard var endpoint else { return }
        endpoint["updatedAt"] = Date().timeIntervalSince1970
        if let data = try? JSONSerialization.data(withJSONObject: endpoint, options: [.sortedKeys]) {
            try? data.write(to: Self.bridgeDirectory.appendingPathComponent("endpoint.json"), options: .atomic)
        }
        if let bridge { mspcm_reap(bridge) }
    }
    func close() {
        if aggregate != 0, let proc {
            AudioDeviceStop(aggregate, proc)
            AudioDeviceDestroyIOProcID(aggregate, proc)
        }
        proc = nil
        kernel = nil
        if aggregate != 0 { AudioHardwareDestroyAggregateDevice(aggregate); aggregate = 0 }
        if tap != 0 { AudioHardwareDestroyProcessTap(tap); tap = 0 }
        if let bridge { mspcm_close(bridge); self.bridge = nil }
        if let bridgePath {
            let location = Self.bridgeDirectory.appendingPathComponent("endpoint.json")
            if let data = try? Data(contentsOf: location),
               let existing = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               existing["path"] as? String == bridgePath.path {
                try? FileManager.default.removeItem(at: location)
            }
            try? FileManager.default.removeItem(at: bridgePath)
            self.bridgePath = nil
        }
        endpoint = nil
    }
    deinit { close() }
}

/// All HAL lifecycle and configuration operations execute serially on this actor.
actor CoreAudioHost {
    private var fineTuneInput: Bool
    init(fineTuneInput: Bool = false) { self.fineTuneInput = fineTuneInput }
    func setFineTuneInput(_ enabled: Bool) throws -> AudioSnapshot {
        guard fineTuneInput != enabled else { return inspect() }
        fineTuneInput = enabled
        do { if desiredRunning && !suspended { try rebuild() } }
        catch { fineTuneInput = !enabled; throw error }
        return inspect()
    }
    private var processingStatus: String {
        snapshot.missing.isEmpty ? (fineTuneInput ? "正在处理 FineTune 音频" : "正在处理系统音频") : "正在运行，部分支路等待设备"
    }
    private var session: AudioSession?
    private var profile = SpeakerProfile()
    private var desiredRunning = false
    private var suspended = false
    private var signature = ""
    private var snapshot = AudioSnapshot()
    private var lastProgress = Date()
    private var lastFrames: UInt64 = 0

    func inspect() -> AudioSnapshot {
        snapshot.devices = HAL.devices()
        updateIdleRate()
        snapshot.requested = desiredRunning
        return snapshot
    }
    private func updateIdleRate() {
        guard session == nil else { return }
        let preferred = [ChannelRole.woofer, .fullRange, .builtin].compactMap { role in
            profile.channels.first { $0.role == role && $0.enabled }?.deviceUID
        }
        if let device = preferred.compactMap({ uid in snapshot.devices.first { $0.uid == uid } }).first {
            snapshot.sampleRate = device.sampleRate
        }
    }
    private func topology(_ profile: SpeakerProfile) -> String {
        profile.channels.map { "\($0.role.rawValue)|\($0.enabled)|\($0.deviceUID)|\($0.outputChannels)" }.joined(separator: ";")
    }
    private func fingerprint(_ devices: [OutputDevice]) -> String {
        let defaultOutput = fineTuneInput ? 0 : ((try? HAL.value(HAL.system, kAudioHardwarePropertyDefaultOutputDevice, initial: UInt32(0))) ?? 0)
        let selected = Set(profile.channels.filter(\.enabled).map(\.deviceUID))
        return "\(defaultOutput):" + devices.filter { selected.contains($0.uid) }.map { "\($0.id)|\($0.uid)|\($0.channelCount)|\($0.sampleRate)" }.joined(separator: ";")
    }
    func start(_ profile: SpeakerProfile) throws -> AudioSnapshot {
        _ = try profile.validated()
        self.profile = profile
        desiredRunning = true
        do { try rebuild() }
        catch {
            destroyResources()
            desiredRunning = false
            snapshot.status = error.localizedDescription
            throw error
        }
        return inspect()
    }
    func apply(_ profile: SpeakerProfile) throws -> AudioSnapshot {
        let oldProfile = self.profile
        let reroute = topology(oldProfile) != topology(profile)
        _ = try profile.validated(sampleRate: reroute ? nil : session?.kernel?.sampleRate)
        self.profile = profile
        guard desiredRunning, !suspended else {
            updateIdleRate()
            snapshot.requested = desiredRunning
            return snapshot
        }
        do {
            if reroute || session == nil { try rebuild() }
            else if let session {
                var renderProfile = profile
                let connected = Set(snapshot.devices.map(\.uid))
                for index in renderProfile.channels.indices where !connected.contains(renderProfile.channels[index].deviceUID) {
                    renderProfile.channels[index].enabled = false
                }
                try session.kernel?.apply(renderProfile)
                session.configuration = renderProfile
                snapshot.status = processingStatus
            }
            snapshot.requested = desiredRunning
            return snapshot
        } catch {
            self.profile = oldProfile
            snapshot.status = "参数应用失败，\(error.localizedDescription)"
            throw error
        }
    }
    func stop() {
        desiredRunning = false
        if let session {
            var quiet = session.configuration
            quiet.masterMuted = true
            try? session.kernel?.apply(quiet)
            Thread.sleep(forTimeInterval: 0.08)
        }
        destroyResources()
        snapshot.status = "已停止"
        snapshot.requested = false
    }
    func suspend() {
        suspended = true
        destroyResources()
        snapshot.status = desiredRunning ? "休眠暂停" : "已停止"
    }
    func resume() {
        suspended = false
        guard desiredRunning else { return }
        do { try rebuild() } catch { snapshot.status = error.localizedDescription }
    }
    func poll(refreshDevices: Bool) -> AudioSnapshot {
        if refreshDevices {
            session?.publishEndpoint()
            let devices = HAL.devices()
            snapshot.devices = devices
            updateIdleRate()
            let currentSignature = fingerprint(devices)
            if desiredRunning && !suspended && currentSignature != signature {
                do { try rebuild() } catch {
                    // A disconnected clock cannot keep the previous session alive.
                    destroyResources()
                    snapshot.status = error.localizedDescription
                    signature = currentSignature
                }
            }
        }
        if let kernel = session?.kernel {
            snapshot.meter = kernel.meter()
            kernel.collect()
            if snapshot.meter.renderedFrames != lastFrames {
                lastProgress = Date()
                lastFrames = snapshot.meter.renderedFrames
                snapshot.status = processingStatus
            } else if refreshDevices && desiredRunning && !suspended && Date().timeIntervalSince(lastProgress) > 5 {
                // Bluetooth/HAL can stop delivering buffers while every source is
                // idle. Frame inactivity alone is not a device failure: rebuilding
                // and then tearing down here silently bypassed DSP before playback
                // resumed. Actual device/rate changes are handled by fingerprint().
                snapshot.status = "已启动，等待系统音频"
            }
        }
        snapshot.requested = desiredRunning
        return snapshot
    }
    private func rebuild() throws {
        let devices = HAL.devices()
        snapshot.devices = devices
        signature = fingerprint(devices)
        let enabled = profile.channels.filter(\.enabled)
        var seen = Set<String>()
        var orderedDevices: [OutputDevice] = enabled.compactMap { channel in
            guard seen.insert(channel.deviceUID).inserted else { return nil }
            return devices.first { $0.uid == channel.deviceUID }
        }
        // External L/R should share the physical device clock whenever it is available.
        let externalUID = [ChannelRole.woofer, .fullRange].compactMap { role in
            profile.channels.first { $0.role == role && $0.enabled }?.deviceUID
        }.first { uid in orderedDevices.contains { $0.uid == uid } }
        if let externalUID, let index = orderedDevices.firstIndex(where: { $0.uid == externalUID }) {
            let primary = orderedDevices.remove(at: index)
            orderedDevices.insert(primary, at: 0)
        }
        snapshot.missing = enabled.filter { channel in !devices.contains { $0.uid == channel.deviceUID } }.map { $0.role.title }
        guard let main = orderedDevices.first else {
            destroyResources()
            snapshot.status = "等待输出设备，请为支路选择设备"
            return
        }
        let staged = AudioSession()
        do {
            var format = AudioStreamBasicDescription()
            let tapUUID = UUID()
            if !fineTuneInput {
                let initialOwn = try HAL.ownProcess()
                let description = CATapDescription(stereoGlobalTapButExcludeProcesses: initialOwn == 0 ? [] : [initialOwn])
                description.name = "MonoSplit System Audio"
                description.uuid = tapUUID
                description.isPrivate = true
                description.muteBehavior = .mutedWhenTapped
                try HAL.check(AudioHardwareCreateProcessTap(description, &staged.tap), "创建系统音频 Tap")
                let own = try HAL.ownProcess()
                guard own != 0 else { throw MonoSplitError("无法排除自身音频，已停止以避免反馈") }
                if own != initialOwn {
                    description.processes = [own]
                    var address = AudioObjectPropertyAddress(mSelector: kAudioTapPropertyDescription, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
                    var updated = Unmanaged.passUnretained(description).toOpaque()
                    try HAL.check(AudioObjectSetPropertyData(staged.tap, &address, 0, nil, UInt32(MemoryLayout<UnsafeMutableRawPointer>.size), &updated), "排除自身音频")
                }
                format = try HAL.value(staged.tap, kAudioTapPropertyFormat, initial: AudioStreamBasicDescription())
                guard format.mFormatID == kAudioFormatLinearPCM, format.mFormatFlags & kAudioFormatFlagIsFloat != 0, format.mBitsPerChannel == 32, format.mChannelsPerFrame == 2 else {
                    throw MonoSplitError("系统 Tap 未提供双声道 Float32 格式")
                }
            }
            var composition: [String: Any] = [
                kAudioAggregateDeviceNameKey: "MonoSplit Private Output",
                kAudioAggregateDeviceUIDKey: "com.monosplit.aggregate.\(UUID().uuidString)",
                kAudioAggregateDeviceIsPrivateKey: true,
                kAudioAggregateDeviceIsStackedKey: true,
                kAudioAggregateDeviceMainSubDeviceKey: main.uid,
                kAudioAggregateDeviceClockDeviceKey: main.uid,
                kAudioAggregateDeviceTapAutoStartKey: true,
                kAudioAggregateDeviceSubDeviceListKey: orderedDevices.enumerated().map { index, device in
                    [kAudioSubDeviceUIDKey: device.uid, kAudioSubDeviceDriftCompensationKey: index != 0] as [String: Any]
                },
            ]
            if !fineTuneInput {
                composition[kAudioAggregateDeviceTapListKey] = [[
                    kAudioSubTapUIDKey: tapUUID.uuidString,
                    kAudioSubTapDriftCompensationKey: true,
                    kAudioSubTapDriftCompensationQualityKey: kAudioAggregateDriftCompensationHighQuality
                ]]
            }
            try HAL.check(AudioHardwareCreateAggregateDevice(composition as CFDictionary, &staged.aggregate), "创建多设备输出")
            var inputLayout: [Int] = [], outputLayout: [Int] = []
            for _ in 0..<100 {
                inputLayout = (try? HAL.layout(staged.aggregate, scope: kAudioObjectPropertyScopeInput)) ?? []
                outputLayout = (try? HAL.layout(staged.aggregate, scope: kAudioObjectPropertyScopeOutput)) ?? []
                if (fineTuneInput || inputLayout.reduce(0, +) >= 2) && outputLayout.reduce(0, +) == orderedDevices.reduce(0, { $0 + $1.channelCount }) { break }
                usleep(20_000)
            }
            let rate = try HAL.value(staged.aggregate, kAudioDevicePropertyNominalSampleRate, initial: Double(0))
            _ = try profile.validated(sampleRate: rate)
            let fullList: CFArray = try HAL.value(staged.aggregate, kAudioAggregateDevicePropertyFullSubDeviceList, initial: [] as CFArray)
            guard let actualUIDs = fullList as? [String] else { throw MonoSplitError("无法读取聚合设备成员顺序") }
            guard actualUIDs.count == orderedDevices.count, Set(actualUIDs) == Set(orderedDevices.map(\.uid)) else { throw MonoSplitError("聚合设备的输出成员与请求不一致") }
            let actualDevices = actualUIDs.compactMap { uid in orderedDevices.first { $0.uid == uid } }
            let map = try Routing.outputMap(profile: profile, orderedDevices: actualDevices)
            guard map.count == outputLayout.reduce(0, +), fineTuneInput || inputLayout.reduce(0, +) >= 2 else { throw MonoSplitError("聚合设备通道布局尚未就绪") }
            for stream in try HAL.ids(staged.aggregate, kAudioDevicePropertyStreams, scope: kAudioObjectPropertyScopeOutput) {
                let virtualFormat = try HAL.value(stream, kAudioStreamPropertyVirtualFormat, initial: AudioStreamBasicDescription())
                guard virtualFormat.mFormatID == kAudioFormatLinearPCM, virtualFormat.mFormatFlags & kAudioFormatFlagIsFloat != 0, virtualFormat.mBitsPerChannel == 32 else { throw MonoSplitError("输出设备未提供 Float32 音频流") }
            }
            let processor = try DSPKernel(sampleRate: rate)
            if fineTuneInput {
                let directory = AudioSession.bridgeDirectory
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
                let path = directory.appendingPathComponent("session-\(UUID().uuidString).pcm")
                guard let bridge = mspcm_create(path.path, rate) else { throw MonoSplitError("无法创建 FineTune 音频桥接") }
                staged.bridge = bridge
                staged.bridgePath = path
                staged.endpoint = ["version": 1, "path": path.path, "clockUID": main.uid,
                                   "sampleRate": rate, "pid": Int(getpid())]
                ms_bridge_input(processor.pointer, bridge)
            }
            var renderProfile = profile
            for index in renderProfile.channels.indices {
                if !orderedDevices.contains(where: { $0.uid == renderProfile.channels[index].deviceUID }) { renderProfile.channels[index].enabled = false }
            }
            var quiet = renderProfile
            quiet.masterMuted = true
            try processor.apply(quiet)
            map.withUnsafeBufferPointer { ms_route(processor.pointer, Int32(inputLayout.reduce(0, +) - 2), $0.baseAddress, Int32(map.count)) }
            staged.kernel = processor
            try HAL.check(AudioDeviceCreateIOProcID(staged.aggregate, { _, _, input, _, output, _, context in
                guard let context else { return noErr }
                ms_render_audio(OpaquePointer(context), input, output)
                return noErr
            }, UnsafeMutableRawPointer(processor.pointer), &staged.proc), "创建音频渲染回调")
            guard let proc = staged.proc else { throw MonoSplitError("音频回调创建失败") }
            try HAL.excludeHardwareInputs(staged.aggregate, proc: proc, tapInput: !fineTuneInput)
            try HAL.check(AudioDeviceStart(staged.aggregate, proc), "启动系统音频处理")
            // Some HAL versions expose SubTap IDs before those objects support
            // property reads. Diagnostics must not make an otherwise valid route fail.
            let subTaps = (try? HAL.ids(staged.aggregate, kAudioAggregateDevicePropertySubTapList)) ?? []
            let tapDrift = subTaps.map { subTap in
                (try? HAL.value(subTap, kAudioSubTapPropertyDriftCompensation, initial: UInt32(0))).map(String.init) ?? "unavailable"
            }
            staged.configuration = renderProfile
            if let previous = session {
                // Fill the new delay histories while the old route remains audible.
                let fillTime = renderProfile.channels.filter(\.enabled).map(\.delayMS).max() ?? 0
                Thread.sleep(forTimeInterval: fillTime / 1000 + 0.04)
                var fadeOut = previous.configuration
                fadeOut.masterMuted = true
                try previous.kernel?.apply(fadeOut)
                Thread.sleep(forTimeInterval: 0.08)
                previous.close()
            }
            try processor.apply(renderProfile)
            session = staged
            lastProgress = Date()
            lastFrames = 0
            snapshot.running = true
            snapshot.sampleRate = rate
            snapshot.status = processingStatus
            staged.publishEndpoint()
            snapshot.diagnostics = ["tapRate=\(format.mSampleRate)", "tapChannels=\(format.mChannelsPerFrame)", "tapDriftConfigured=true", "tapDriftReadback=\(tapDrift)", "inputLayout=\(inputLayout)", "outputLayout=\(outputLayout)", "outputMap=\(map)", "clock=\(main.uid)", "aggregateRate=\(rate)"]
            snapshot.routeDescription = actualDevices.map { "\($0.name) · \($0.channelCount) 通道 · \(Int($0.sampleRate)) Hz" }
            // Use post-creation rates so HAL's nominal-rate negotiation does not trigger a rebuild loop.
            signature = fingerprint(HAL.devices())
        } catch {
            staged.close()
            throw error
        }
    }
    private func destroyResources() {
        session?.close()
        session = nil
        snapshot.running = false
        snapshot.meter = DSPMeter()
        snapshot.routeDescription = []
    }
}
