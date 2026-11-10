import Foundation

/// Portable EQ settings. Routing, crossover, output gain and delay are deliberately outside this value.
public struct EQSettings: Codable, Equatable, Sendable {
    public var enabled: Bool
    public var preampDB: Double
    public var bands: [EQBand]
    public static let graphicFrequencies: [Double] = [32, 64, 125, 250, 500, 1000, 2000, 4000, 8000, 16000]
    public static var graphicFlat: Self {
        Self(enabled: true, preampDB: 0, bands: graphicFrequencies.map { EQBand(frequency: $0, q: sqrt(2)) })
    }
    public init(channel: ChannelSettings) {
        enabled = channel.eqEnabled; preampDB = channel.preampDB; bands = channel.bands
    }
    public init(enabled: Bool = true, preampDB: Double = 0, bands: [EQBand] = []) {
        self.enabled = enabled; self.preampDB = preampDB; self.bands = bands
    }
    public var isGraphic: Bool {
        bands.count == 10 && zip(bands, Self.graphicFrequencies).allSatisfy { $0.kind == .peak && abs($0.frequency - $1) < 0.001 }
    }
    public func validated() throws -> Self {
        var profile = SpeakerProfile()
        profile.channels[0].eqEnabled = enabled; profile.channels[0].preampDB = preampDB; profile.channels[0].bands = bands
        _ = try profile.validated()
        return self
    }
    public func matches(_ other: Self) -> Bool {
        enabled == other.enabled && preampDB == other.preampDB && bands.count == other.bands.count && zip(bands, other.bands).allSatisfy {
            $0.enabled == $1.enabled && $0.kind == $1.kind && $0.frequency == $1.frequency && $0.gainDB == $1.gainDB && $0.q == $1.q
        }
    }
    public func applying(to channel: ChannelSettings) throws -> ChannelSettings {
        _ = try validated()
        var result = channel
        result.eqEnabled = enabled; result.preampDB = preampDB
        result.bands = bands.map { var band = $0; band.id = UUID(); return band }
        return result
    }
}

public struct EQPreset: Codable, Equatable, Identifiable, Sendable {
    public var version = 1
    public var id = UUID()
    public var name: String
    public var createdAt = Date()
    public var updatedAt = Date()
    public var settings: EQSettings
    public init(name: String, settings: EQSettings) { self.name = name; self.settings = settings }
    public func validated() throws -> Self {
        guard version == 1 else { throw MonoSplitError("EQ 预设版本 \(version) 不受支持") }
        guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, name.count <= 120 else { throw MonoSplitError("预设名称应为 1–120 个字符") }
        _ = try settings.validated()
        return self
    }
}

public struct EQPresetLibrary: Codable, Sendable {
    public var version = 1
    public var presets: [EQPreset] = []
    public init() {}
    public func validated() throws -> Self {
        guard version == 1, presets.count <= 1000, Set(presets.map(\.id)).count == presets.count else { throw MonoSplitError("EQ 预设库结构或版本无效") }
        for preset in presets { _ = try preset.validated() }
        return self
    }
}

public final class EQPresetStore: Sendable {
    public let directory: URL
    public var fileURL: URL { directory.appendingPathComponent("eq-presets.json") }
    public var backupURL: URL { directory.appendingPathComponent("eq-presets.previous.json") }
    public init(directory: URL) { self.directory = directory }
    private static var decoder: JSONDecoder { let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601; return decoder }
    private static var encoder: JSONEncoder {
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601; encoder.outputFormatting = [.prettyPrinted, .sortedKeys]; return encoder
    }
    private func decode(_ url: URL) throws -> EQPresetLibrary {
        try Self.decoder.decode(EQPresetLibrary.self, from: Data(contentsOf: url)).validated()
    }
    public func load() throws -> (library: EQPresetLibrary, recovered: Bool) {
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            if FileManager.default.fileExists(atPath: backupURL.path) { return (try decode(backupURL), true) }
            return (EQPresetLibrary(), false)
        }
        do { return (try decode(fileURL), false) }
        catch { guard FileManager.default.fileExists(atPath: backupURL.path) else { throw error }; return (try decode(backupURL), true) }
    }
    public func save(_ library: EQPresetLibrary) throws {
        _ = try library.validated()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let data = try Self.encoder.encode(library)
        if (try? decode(fileURL)) != nil { try Data(contentsOf: fileURL).write(to: backupURL, options: .atomic) }
        try data.write(to: fileURL, options: .atomic)
    }
    public static func importPreset(_ data: Data) throws -> EQPreset {
        guard data.count <= 1024 * 1024 else { throw MonoSplitError("EQ 预设文件超过 1 MB") }
        var preset = try decoder.decode(EQPreset.self, from: data).validated()
        preset.id = UUID(); preset.createdAt = Date(); preset.updatedAt = Date()
        return preset
    }
    public static func exportPreset(_ preset: EQPreset) throws -> Data { try encoder.encode(preset.validated()) }
}
