# VPN Navigator 1.0.1 / Build 40

[English README](../README.md) · [中文说明](../README.zh-CN.md) · [Documentation](README.md)

## 简体中文

修复主窗口打开时，实时流量和快捷键可用状态更新引起顶部应用菜单反复刷新的问题。应用入口现在独立持有连接模型和工作区命令控制器，由各窗口直接订阅所需状态；连接状态、速度显示与快捷键继续正常更新。

- 新增真实 AppKit 菜单回归检查，持续更新模拟流量并切换菜单可用状态，确认菜单根节点、顶层菜单项及子菜单保持同一对象。
- 本地 Release 构建、状态栏与窗口生命周期自检、工作区原生菜单与快捷键自检通过。当前环境不提供进程内辅助功能节点，VoiceOver 仍需实际辅助功能客户端验收。
- 本版本没有针对 GitHub 下载速度修改 DNS、MTU/MSS 或隧道传输策略。

### 下载与升级

分别提供 Apple Silicon 和 Intel 压缩包，包含安装包、卸载包、SHA-256 校验值、构建来源和批准清单。继续使用管理员批准的 **local-test** 通道，采用 ad-hoc 签名，**未经 Apple 公证**（not Apple notarized）。升级前请在旧版完成「升级与卸载准备」，退出旧应用后安装新版本。详见[安装指南](LOCAL_TEST_INSTALLATION.md)。

PF 断线保护仍为实验性功能，默认关闭；物理网络防泄漏、睡眠唤醒及最低支持系统等完整实机验收仍未完成。本版本不扩大已有兼容性和安全性声明，参见 [QA](QA.md)。

## English

Fix repeated application menu refreshes while the main window is open and live traffic or workspace command availability changes. A stable application owner retains the session model and command router, while individual windows observe their state directly. Connection status, throughput display and keyboard shortcuts continue updating.

- Add an actual AppKit regression check that preserves the main menu, top-level items and submenus across synthetic traffic and command availability updates.
- Local Release build, status menu/window lifecycle checks and native workspace menu/keyboard checks passed. In-process accessibility nodes are unavailable in the local environment; VoiceOver still needs acceptance with a real assistive client.
- This release does not change DNS, MTU/MSS or tunnel transport policy for GitHub download performance.

### Downloads and upgrade

Separate Apple Silicon and Intel archives include installers, uninstallers, SHA-256 checksums, build provenance and approval manifests. These packages retain the administrator-approved **local-test** channel, are ad-hoc signed and are **not Apple notarized**. Complete **Upgrade & Uninstall Preparation** in the old app, then quit before installing. See the [installation guide](LOCAL_TEST_INSTALLATION.md).

PF protection remains experimental and off by default. Full physical-network leak, sleep/wake and minimum-system hardware acceptance remains incomplete; compatibility and safety claims are unchanged. See [QA](QA.md).
