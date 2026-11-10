import Foundation

public struct ProfileLibrary: Codable, Sendable {
    public var version = 1
    public var selectedID: UUID
    public var profiles: [SpeakerProfile]
    public init(profiles: [SpeakerProfile], selectedID: UUID) {
        self.profiles = profiles
        self.selectedID = selectedID
    }
    public func validated() throws -> ProfileLibrary {
        guard version == 1, !profiles.isEmpty, Set(profiles.map(\.id)).count == profiles.count, profiles.contains(where: { $0.id == selectedID }) else {
            throw MonoSplitError("配置库结构或版本无效")
        }
        for profile in profiles { _ = try profile.validated() }
        return self
    }
}

public final class ProfileStore: Sendable {
    public let directory: URL
    public var fileURL: URL { directory.appendingPathComponent("profiles.json") }
    public var backupURL: URL { directory.appendingPathComponent("profiles.previous.json") }
    public init(directory: URL) { self.directory = directory }
    private func decode(_ url: URL) throws -> ProfileLibrary {
        try JSONDecoder().decode(ProfileLibrary.self, from: Data(contentsOf: url)).validated()
    }
    public func load() throws -> (library: ProfileLibrary?, recovered: Bool) {
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            if FileManager.default.fileExists(atPath: backupURL.path) { return (try decode(backupURL), true) }
            return (nil, false)
        }
        do { return (try decode(fileURL), false) }
        catch {
            guard FileManager.default.fileExists(atPath: backupURL.path) else { throw error }
            return (try decode(backupURL), true)
        }
    }
    public func save(_ library: ProfileLibrary) throws {
        _ = try library.validated()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let encoded = try encoder.encode(library)
        // A damaged primary must never overwrite a valid recovery copy.
        if (try? decode(fileURL)) != nil {
            try Data(contentsOf: fileURL).write(to: backupURL, options: .atomic)
        }
        try encoded.write(to: fileURL, options: .atomic)
    }
    public static func importProfile(_ data: Data) throws -> SpeakerProfile {
        guard data.count <= 64 * 1024 * 1024 else { throw MonoSplitError("配置文件超过 64 MB") }
        var profile = try JSONDecoder().decode(SpeakerProfile.self, from: data).validated()
        profile.id = UUID()
        return profile
    }
    public static func exportProfile(_ profile: SpeakerProfile) throws -> Data {
        _ = try profile.validated()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(profile)
    }
}

public struct OutputDevice: Identifiable, Equatable, Sendable {
    public var id: UInt32
    public var uid: String
    public var name: String
    public var channelCount: Int
    public var sampleRate: Double
    public var bluetooth: Bool
    public init(id: UInt32, uid: String, name: String, channelCount: Int, sampleRate: Double, bluetooth: Bool) {
        self.id = id
        self.uid = uid
        self.name = name
        self.channelCount = channelCount
        self.sampleRate = sampleRate
        self.bluetooth = bluetooth
    }
}

public enum Routing {
    public static func outputMap(profile: SpeakerProfile, orderedDevices: [OutputDevice]) throws -> [Int32] {
        var map = [Int32](repeating: -1, count: orderedDevices.reduce(0) { $0 + $1.channelCount })
        var base = 0
        for device in orderedDevices {
            for (index, role) in ChannelRole.allCases.enumerated() {
                guard let channel = profile.channels.first(where: { $0.role == role && $0.enabled && $0.deviceUID == device.uid }) else { continue }
                for output in channel.outputChannels {
                    guard output >= 1, output <= device.channelCount else { throw MonoSplitError("\(channel.role.title) 的输出通道 \(output) 在 \(device.name) 上不存在") }
                    guard map[base + output - 1] == -1 else { throw MonoSplitError("输出通道重复") }
                    map[base + output - 1] = Int32(index)
                }
            }
            base += device.channelCount
        }
        guard map.count <= 192 else { throw MonoSplitError("聚合设备输出超过 192 通道") }
        return map
    }
}
