# 在 FineTune 中使用 MonoSplit

[English](FineTune-Integration.md) · [MonoSplit](https://github.com/wait2050/MonoSplit)

MonoSplit 在 FineTune 内代表整套音箱处理链：FineTune 负责应用路由、音量和静音，MonoSplit 负责单声道混合、三路分频、EQ、极性、延迟及实际输出。两个应用独立运行，设置也分别保存。

## 接入

1. 安装支持联动的 FineTune Sync 和 MonoSplit，退出其他 FineTune 版本。
2. 在 MonoSplit 中选择实际输出设备和通道，设置合适的初始音量。
3. 在 MonoSplit 菜单栏菜单启用「FineTune 输入（作为独立设备）」，再启动处理。
4. FineTune 的设备列表将在约半秒内出现 MonoSplit。选择它作为 FineTune 的默认输出，或只给某个应用选择它。
5. 对已经设置了单独物理输出或多设备路由的应用，明确切换其输出到 MonoSplit。FineTune 的默认输出选择不会重写这些应用的既有路由。

设备行提供音量、静音、设备 EQ 和打开 MonoSplit 窗口的按钮。MonoSplit 原有的各支路参数、EQ 预设和音箱配置继续有效；FineTune 与 MonoSplit 的增益会相乘。

## 设备与延迟

这台逻辑设备只出现在 FineTune，macOS 系统输出列表保持原来的设备。被忽略或未捕获的应用及系统提示音仍沿原路径播放。对于已在 MonoSplit 内管理的扬声器，FineTune 选择 MonoSplit 这一条路径即可。

输入按 `(L + R) / 2` 混为单声道。桥接约有 40 ms 预缓冲，还需叠加回调块、输出设备和 MonoSplit 各支路的延迟。FineTune 可以同时把同一个应用送往 MonoSplit 和其他独立设备，但需要重新检查它们的时间对齐。

停止或退出 MonoSplit 后，该设备会从 FineTune 消失，并触发原有的设备断开回退策略。修改 MonoSplit 的物理输出或采样率会建立新的桥接会话。

## 切回独立模式

停止 MonoSplit，退出 FineTune，取消勾选「FineTune 输入」，再启动处理。MonoSplit 会重新捕获系统音频。启动应用时，音频处理仍保持停止状态。

## 实现与许可

双方使用当前用户目录内的共享内存文件传递 Float32 立体声。每个 FineTune 渲染器使用独立环形缓冲，最多 64 条轨道；MonoSplit 统一混合后送入原 DSP。桥接回调不进行文件或网络读写、内存分配和加锁。

桥接会话位于 `~/Library/Application Support/MonoSplitBridge/`。两边保持同一物理输出时钟和采样率；MonoSplit 在接入模式关闭系统音频 Tap，FineTune 排除 MonoSplit 输出进程。

FineTune Sync 整体沿用 GPL-3.0。独立 PCM 传输文件来自 0BSD 的 MonoSplit，详见 [第三方声明](../THIRD_PARTY_NOTICES.md)。MonoSplit 与其依赖的许可范围在[对应仓库](https://github.com/wait2050/MonoSplit#开源许可)说明。
