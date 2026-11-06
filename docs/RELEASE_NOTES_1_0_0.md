# VPN Navigator 1.0.0 / Build 39

[English README](../README.md) · [中文说明](../README.zh-CN.md) · [Documentation](README.md)

## English

VPN Navigator 1.0.0 brings the existing native macOS OpenVPN workspace into a new versioned release. It supports macOS 13 and later, with separate Apple Silicon and Intel builds.

- Native profile library with groups, favorites, safe updates, encrypted backups and portable exports.
- Original, Global VPN and Mainland China Direct routing, dual-stack support, custom rules and split DNS.
- Menu bar controls, live tunnel traffic, quick profile search, connection history and optional smart connection.
- Local diagnostics, public egress checks, guarded network recovery, English and Simplified Chinese interfaces.
- Redesigned bilingual READMEs using the existing app logo, a focused installation guide and a complete documentation index.
- Application version advanced from 0.8.18 / Build 38 to **1.0.0 / Build 39**. Runtime behavior is unchanged from 0.8.18; its [menu, DNS and transport fixes](RELEASE_NOTES_0_8_18.md) remain included.

### Downloads and upgrade

Choose the `Apple-Silicon-arm64` or `Intel-x86_64` ZIP. Each includes an installer, uninstaller, SHA-256 checksums, build provenance, approval manifest and binary audit. OpenVPN and its matching source/license materials are bundled in the application.

These packages use the administrator-approved **local-test channel**, are ad-hoc signed and are **not Apple notarized**. Developer ID distribution remains a separate signing/notarization workflow. Before upgrading an existing connection-capable installation, complete **Upgrade & Uninstall Preparation** in the old app, then quit it. Follow the included instructions and [installation guide](LOCAL_TEST_INSTALLATION.md).

### Known limits

PF disconnect protection remains experimental and off by default. Physical-network leak acceptance and the complete real-server/signed-machine matrix are still incomplete; version 1.0.0 does not change those limits. Unsupported authentication and profile types remain documented in the README. See [QA](QA.md) and the [signed-release publication gate](SIGNED_RELEASE_WORKFLOW.md#publication-gate).

## 简体中文

1.0.0 将现有原生 macOS OpenVPN 工作区整理为新的版本发布，支持 macOS 13 及以上，分别提供 Apple Silicon 与 Intel 构建。

- 配置库支持分组、收藏、安全更新、加密备份与便携导出。
- 原始配置、全局 VPN、中国直连三种模式，支持双栈、自定义规则和 DNS 分流。
- 状态栏控制、真实隧道流量、快速搜索、连接历史及可选智能连接。
- 本机诊断、公网出口检查、按所有权核验的网络恢复、中英文界面。
- 重新设计中英文 README，使用已有应用 Logo，整理安装入口及完整文档索引。
- 版本从 0.8.18 / Build 38 升级至 **1.0.0 / Build 39**；运行逻辑沿用 0.8.18，包含其[状态栏菜单、DNS 和传输修复](RELEASE_NOTES_0_8_18.md)。

### 下载与升级

按芯片选择 `Apple-Silicon-arm64` 或 `Intel-x86_64` 压缩包，内含安装包、卸载包、SHA-256、构建来源、批准清单及二进制审计。应用内含 OpenVPN 引擎及对应源码、许可证材料。

当前为管理员批准的**本地测试通道**，采用 ad-hoc 签名，**未经 Apple 公证**；Developer ID 分发仍使用独立签名及公证流程。更新前先在旧版完成「升级与卸载准备」，再退出旧应用。请按包内说明及[安装指南](LOCAL_TEST_INSTALLATION.md)操作。

### 已知限制

PF 断线保护仍为实验性功能，默认关闭；完整物理网络防泄漏、真实服务器及签名真机验收仍需补齐。1.0.0 不改变上述边界。不支持的认证与配置类型见 README，验收矩阵见 [QA](QA.md) 与[签名发布门槛](SIGNED_RELEASE_WORKFLOW.md#publication-gate)。
