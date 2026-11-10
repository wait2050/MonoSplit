# MonoSplit 0.5.0 — 独立调音，接入 FineTune / Independent tuning, connected to FineTune

## 中文

首个公开版本：独立的 macOS 单声道分频与调音应用，可作为 FineTune Sync 中的一台输出设备。

- 三路分频、每路最多 20 段参数 EQ、极性、音量、静音和 0–2000 ms 延迟。
- 图示和参数 EQ、REW 滤波器及测量导入、音箱配置、EQ 预设、撤销和快照对比。
- FineTune 管理应用路由与日常音量，MonoSplit 保留独立窗口及实际输出。
- 自有代码采用 0BSD，允许商用、修改和再发布；第三方依赖保留各自许可。

下载 ZIP 后打开 `MonoSplitFineTune.app`。需 Apple Silicon Mac 与 macOS 15.4+。
联动还需 [FineTune Sync cn-v1.9.0-r5 或更新版本](https://github.com/wait2050/FineTune-Sync/releases/latest)。
MonoSplit 菜单栏中启用“FineTune 输入（作为独立设备）”并启动后，在 FineTune 选择 MonoSplit。

输入按 `(L + R) / 2` 混合为单声道。桥接约有 40 ms 预缓冲，并非总延迟测量。
MonoSplit 当前界面主要为简体中文，仓库提供中英文说明。应用本地签名，未经过 Apple 公证。

## English

First public release of an independent macOS mono crossover and speaker-tuning app, with an optional logical output inside FineTune Sync.

- Three branches with crossovers, up to 20 parametric EQ filters each, polarity, level, mute and 0–2000 ms delay.
- Graphic and parametric EQ, REW filter/measurement import, profiles, presets, undo and tuning comparisons.
- FineTune handles routing and everyday volume while MonoSplit keeps its own window and physical outputs.
- Original code is 0BSD; commercial use, modification and redistribution are allowed. Dependencies retain their licenses.

Unzip and open `MonoSplitFineTune.app`. Requires Apple Silicon and macOS 15.4+.
Integration also needs [FineTune Sync cn-v1.9.0-r5 or later](https://github.com/wait2050/FineTune-Sync/releases/latest).
Enable “FineTune 输入（作为独立设备）”, start processing in MonoSplit, then select MonoSplit in FineTune.

Stereo is mixed as `(L + R) / 2`. The bridge uses about 40 ms of preroll, not a measured end-to-end latency.
MonoSplit's UI is primarily Simplified Chinese, with English documentation. The app is locally signed and not Apple-notarized.

Source for this release is available through the tag's GitHub source archives. Bundled dependency notices are under the app's `Contents/Resources/`.
