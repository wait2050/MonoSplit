import Foundation
import MonoSplitCore
import MonoSplitDSP

@main struct HostIntegrationChecks {
    static func main() async throws {
        let host = CoreAudioHost(fineTuneInput: true)
        let available = await host.inspect()
        guard let device = available.devices.first(where: { $0.uid == "BuiltInSpeakerDevice" }) else {
            throw MonoSplitError("验证需要内置扬声器")
        }
        var profile = SpeakerProfile(name: "Silent bridge verification")
        profile.masterMuted = true // Exercise the hardware callback with silent output.
        for index in profile.channels.indices {
            profile.channels[index].enabled = index < 2
            profile.channels[index].deviceUID = device.uid
        }
        let started = try await host.start(profile)
        guard started.running else { throw MonoSplitError("FineTune 输入模式未启动") }
        let directory = URL(fileURLWithPath: ProcessInfo.processInfo.environment["MONOSPLIT_BRIDGE_DIR"]!)
        let metadataURL = directory.appendingPathComponent("endpoint.json")
        let metadata = try JSONSerialization.jsonObject(with: Data(contentsOf: metadataURL)) as! [String: Any]
        guard let writer = mspcm_open_writer(metadata["path"] as! String, started.sampleRate) else { throw MonoSplitError("无法打开发送端") }
        do {
            var samples = [Float](repeating: 0.1, count: 2048 * 2)
            for _ in 0..<15 {
                samples.withUnsafeMutableBytes { bytes in
                    var audio = AudioBufferList(mNumberBuffers: 1, mBuffers: AudioBuffer(mNumberChannels: 2, mDataByteSize: UInt32(bytes.count), mData: bytes.baseAddress))
                    _ = mspcm_write(writer, &audio, 0, 1)
                }
                try await Task.sleep(for: .milliseconds(30))
            }
            let result = await host.poll(refreshDevices: true)
            guard result.meter.renderedFrames > 0, result.meter.inputPeak > 0.09 else {
                throw MonoSplitError("实际 Core Audio 回调未收到桥接音频：\(result.status), \(result.diagnostics), frames=\(result.meter.renderedFrames), input=\(result.meter.inputPeak)")
            }
            print("Hardware bridge passed: rate=\(result.sampleRate), frames=\(result.meter.renderedFrames), inputPeak=\(result.meter.inputPeak), masterMuted=true")
            mspcm_close(writer)
            await host.stop()
            guard !FileManager.default.fileExists(atPath: metadataURL.path) else { throw MonoSplitError("停止后设备声明未清除") }
            print("Endpoint teardown passed")
        } catch {
            mspcm_close(writer)
            await host.stop()
            throw error
        }
    }
}
