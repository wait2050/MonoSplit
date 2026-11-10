# Use MonoSplit inside FineTune

[简体中文](FineTune接入说明.md) · [MonoSplit](https://github.com/wait2050/MonoSplit)

MonoSplit represents a complete speaker-processing chain inside FineTune. FineTune handles application routing, volume and mute; MonoSplit handles stereo-to-mono mixing, three-way crossovers, EQ, polarity, delay and physical output. Both apps run independently and keep separate settings.

## Connect

1. Install bridge-enabled FineTune Sync and MonoSplit releases. Quit other FineTune editions.
2. Assign physical devices and output channels in MonoSplit and choose an appropriate initial level.
3. Enable “FineTune 输入（作为独立设备）” in MonoSplit’s menu bar menu, then start processing.
4. MonoSplit appears in FineTune’s device list within about half a second. Select it as FineTune’s default output or as the output for a specific app.
5. Switch apps with existing explicit physical or multi-device routes individually. Selecting a default in FineTune does not rewrite those routes.

The device row provides volume, mute, device EQ and a button to open MonoSplit’s window. Existing branch settings, EQ presets and speaker profiles stay in MonoSplit. FineTune and MonoSplit gains multiply.

## Outputs and timing

The logical device exists inside FineTune; macOS continues to list the original audio devices. Ignored or uncaptured apps and system alerts retain their original paths. Select the single MonoSplit route for speakers already managed within MonoSplit.

The input is mixed as `(L + R) / 2`. The bridge has approximately 40 ms of preroll buffering, plus callback blocks, output-device latency and MonoSplit branch delays. FineTune can send an app to MonoSplit and other independent devices simultaneously, but their alignment needs to be checked again.

Stopping or quitting MonoSplit removes the device from FineTune and triggers its existing disconnect fallback. Changing MonoSplit’s physical output or sample rate creates a new bridge session.

## Return to independent operation

Stop MonoSplit, quit FineTune, disable “FineTune 输入”, then start processing. MonoSplit resumes capturing system audio. Processing always starts stopped after launching the app.

## Implementation and licensing

The apps exchange Float32 stereo through shared memory in the current user’s application-support directory. Each FineTune renderer has an independent ring buffer, with up to 64 tracks. MonoSplit mixes them into its existing DSP. Bridge callbacks perform no file/network I/O, allocation or locking.

Sessions live in `~/Library/Application Support/MonoSplitBridge/`. Both ends use the same physical output clock and sample rate. MonoSplit disables its system-audio tap while connected; FineTune excludes MonoSplit’s output process from capture.

FineTune Sync as a whole remains GPL-3.0. Independent PCM transport files originate from 0BSD-licensed MonoSplit; see [third-party notices](../THIRD_PARTY_NOTICES.md). MonoSplit and dependency terms are explained in [its repository](https://github.com/wait2050/MonoSplit/blob/main/README.en.md#license).
