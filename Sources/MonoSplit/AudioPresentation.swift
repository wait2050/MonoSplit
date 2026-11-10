import Observation
import MonoSplitCore

/// Meters change every poll. Only the small views that display them observe this object.
@MainActor @Observable
final class AudioLevels {
    var meter = DSPMeter()
}

/// Route and device changes invalidate the editor; rendered-frame counters do not.
struct AudioStatus: Equatable, Sendable {
    var devices: [OutputDevice]
    var running: Bool
    var requested: Bool
    var sampleRate: Double
    var status: String
    var missing: [String]
    var routeDescription: [String]
    var diagnostics: [String]

    init(_ snapshot: AudioSnapshot = AudioSnapshot()) {
        devices = snapshot.devices
        running = snapshot.running
        requested = snapshot.requested
        sampleRate = snapshot.sampleRate
        status = snapshot.status
        missing = snapshot.missing
        routeDescription = snapshot.routeDescription
        diagnostics = snapshot.diagnostics
    }
}
