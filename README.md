# ClawdSnip 增强版

住在屏幕角落的像素宠物，支持截图、录屏、独立电脑声音录制和自定义全局快捷键。

本项目是 [fwwwwjj/ClawdSnip](https://github.com/fwwwwjj/ClawdSnip) 的增强 fork，保留原作者的宠物动画、截图与 Claude 自动粘贴功能。这是非官方工具，与 Anthropic 无关。

![上游宠物与菜单预览](docs/preview.png)

## 新增功能

- 全屏或框选区域录屏，支持多屏选择。
- 720p、1080p、1440p 和原始分辨率，最高 30 帧/秒；保持比例，不放大小选区，并显示实际输出像素。
- **电脑声音与麦克风分别开关**，可只录电脑内部声音、只录麦克风、同时录制或无声录制。
- 倒计时、录制时长、停止并保存 MP4，必要时合并两路音轨。
- 自定义全局快捷键：框选截图、窗口截图、录屏/停止、退出、显示/隐藏宠物。
- 设置窗口中的原生开机启动开关。
- 隐藏宠物后保留菜单栏入口，快捷键继续可用；再次打开应用也可找回。

发布文件也保存在 [`dist`](dist) 目录；[源码包](https://github.com/jasper20047/ClawdSnip/raw/refs/tags/v0.3.0/dist/ClawdSnip-v0.3.0-source.zip) · [SHA-256 校验文件](https://github.com/jasper20047/ClawdSnip/blob/v0.3.0/dist/SHA256SUMS-v0.3.0.txt)。

## 系统要求

- macOS 15 或更新版本。
- Release 中的预编译应用仅适用于 **Apple 芯片（arm64）**。
- 源码构建需要 Xcode 命令行工具及匹配的 Swift 编译器/macOS SDK；Intel 构建未在本次发布中验证。
- 自动粘贴功能配合 [Claude 桌面版](https://claude.ai/download) 使用；未运行 Claude 时，截图复制到剪贴板。

## 下载安装

1. 打开 [Releases](https://github.com/jasper20047/ClawdSnip/releases)，点击安装包下载链接；也可直接[下载 Apple 芯片版](https://github.com/jasper20047/ClawdSnip/raw/refs/tags/v0.3.0/dist/ClawdSnip-v0.3.0-macos-arm64.zip)。
2. 解压后，把 `ClawdSnip.app` 放到个人的“应用程序”文件夹（`~/Applications`），再打开。
3. 这是采用临时签名、未经 Apple 公证的本机构建。若 macOS 阻止打开，请在确认下载来源后，按系统“隐私与安全性”中的提示处理；无需关闭系统安全保护。

首次使用时按系统提示允许必要权限：

| 权限 | 用途 |
| --- | --- |
| 屏幕与系统录音 | 截图、录屏及电脑内部声音 |
| 麦克风 | 仅勾选“录制麦克风”时需要 |
| 辅助功能 | 截图后自动向 Claude 输入框粘贴 |

### 已开启权限却仍提示无权限

临时签名会随重新编译而变化。macOS 可能保留旧版本的授权记录，出现“开关已开，但新版本仍被拒绝”的情况。**只重启应用可能无法解决。**

1. 先从菜单正常退出 ClawdSnip。
2. 系统设置 → 隐私与安全性 → 录屏与系统录音，移除旧的 ClawdSnip 条目。
3. 点“＋”重新添加**实际安装位置**的 `ClawdSnip.app`，开启权限。
4. 按系统提示退出并重新打开，再试录。

如旧条目无法正常刷新，可以在终端只重置本应用的录屏授权，再按上面的步骤重新添加：

```bash
tccutil reset ScreenCapture local.fwj.ClawdSnip
```

该命令不会替你授予权限；仍需在系统设置中亲自开启。不要重置全部应用的权限。

## 使用

### 截图

单击宠物框选截图；悬停菜单也提供“框选截图”“窗口截图”“自动粘贴”。拖动宠物可换位置。

### 只录电脑内部声音

宠物菜单或菜单栏 → **录屏…**：

1. 选择目标屏幕或框选区域、清晰度。
2. 勾选 **录制电脑声音**，关闭 **录制麦克风**。
3. 点击“开始录制…”，选择一个新的 MP4 保存位置。
4. 倒计时 3 秒后开始；控制条或菜单栏可停止并保存。

保存位置默认建议为“影片/ClawdSnip”。录制时排除本应用的宠物与控制窗口。锁屏、屏幕睡眠或显示器变化时，会停止并尝试保存已有内容。保存失败会提示可恢复的文件路径，保存期间请勿强制退出。

### 快捷键、开机启动与隐藏

宠物菜单或菜单栏 → **设置…**。

- 点击对应快捷键按钮，按组合键即保存；Esc 取消，“清除”移除。需要包含 ⌘、⌥ 或 ⌃ 中至少一个修饰键。应用内重复或系统独占注册冲突会提示。
- 快捷键默认未设置。录屏快捷键在空闲时打开设置，在准备/录制时取消或停止保存，保存中不重复执行。
- “开机自动启动”读取 macOS 登录项的实际状态；若等待批准，点“系统登录项…”前往允许。
- 关闭“显示桌面宠物”或选“隐藏宠物”可隐藏悬浮界面；菜单栏“显示桌面宠物”可恢复。录屏停止控制仍会保留。

## 源码构建

```bash
xcode-select --install
git clone https://github.com/jasper20047/ClawdSnip.git
cd ClawdSnip
./build.sh
open ~/Applications/ClawdSnip.app
```

只构建，不替换运行中的应用：

```bash
./build.sh --output /absolute/path/ClawdSnip.app
```

`build.sh` 会使用可用 SDK；如本机存在编译器/SDK 版本不匹配，请通过 `SDKROOT` 指向匹配的 SDK 后重试。上游的 `setup-signing.sh` 保留供开发者使用，固定签名能否生效取决于本机可用的签名身份，本次 Release 使用临时签名。

## 验证

```bash
./tests/run.sh
./tests/settings.sh
./tests/media.sh
./tests/settings.sh --integration
```

后两项需要 macOS 编码器/窗口服务，受限沙盒中可能无法运行；集成测试使用独立偏好域和临时设置窗口。

本次发布已通过录屏配置/生命周期、快捷键校验/持久化/回滚、真实系统热键注册及焦点恢复、合成双音源混音测试。Apple 芯片 Mac 上已验证关闭麦克风时真实录屏能保存并录入内部测试音。真实麦克风采集、Intel 构建及重启后的自动启动尚未完整实测。

## 源码结构

- `main.swift`：原有宠物、像素菜单、截图与控制器接入。
- `RecordingOptions.swift`、`ScreenRecorder.swift`、`RecordingFile.swift`：录屏配置、生命周期和文件输出。
- `RecordingUI.swift`、`RegionSelector.swift`：录制设置、框选与停止控制。
- `HotKeyRules.swift`、`GlobalHotKeys.swift`、`SettingsUI.swift`、`AppStatusMenu.swift`：快捷键、偏好和菜单栏。

## 来源

原始项目、像素宠物和截图功能来自 [fwwwwjj/ClawdSnip](https://github.com/fwwwwjj/ClawdSnip)。本仓库保留上游提交历史与来源说明，未擅自为上游代码新增许可证。
