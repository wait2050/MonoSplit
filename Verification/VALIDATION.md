# Validation / 验证记录

Release: 0.5.0 · Date: 2026-11-10

| Check | Result |
| --- | --- |
| MonoSplit Swift core and application tests | 39 passed |
| FineTune integration, routing, device EQ, master volume and initial-state tests | 30 passed across 5 suites |
| Full FineTune test suite for the public release | 829 passed across 150 suites |
| GPUI Rust release tests | 2 passed |
| GPUI native bridge regression | Passed |
| PCM transport with AddressSanitizer and UndefinedBehaviorSanitizer | Passed |
| Transport implementation/header parity between the two apps | Identical |
| Silent real Core Audio bridge check | Passed at 48 kHz |
| Real application → FineTune → MonoSplit → physical output | Observed at 44.1 kHz with nonzero input and continuous frame transfer |

PCM checks cover stereo, multiple sources, startup preroll, underrun recovery,
track reuse, actual cross-process transfer, crashed sender cleanup, sample-rate
rejection and receiver shutdown. The real Core Audio check keeps master mute on
while confirming incoming samples and output callback progress.

The speaker profile was unchanged during the integration check. No personal
speaker profile, device UID, listening-session data or machine-specific debug
backup is included in this repository.

These checks do not establish long-session Bluetooth stability, acoustic
alignment on every device or measured end-to-end latency. The bridge's roughly
40 ms preroll is only one component of latency.

Reproduce portable checks with `swift test`, `scripts/check-pcm-bridge.sh`,
`scripts/check-gpui-bridge.sh` and the Cargo test command in the README.
`Integration/HostIntegrationChecks.swift` is an optional silent hardware check
and needs an available built-in speaker device plus an isolated
`MONOSPLIT_BRIDGE_DIR`.
