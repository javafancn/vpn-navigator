<p align="center">
  <img src="Resources/Branding/AppIcon.png" width="128" height="128" alt="VPN Navigator logo">
</p>
<h1 align="center">VPN Navigator</h1>

<p align="center">原生 macOS OpenVPN 客户端，让连接、分流与排障更直观。</p>
<p align="center">
  <a href="https://github.com/javafancn/vpn-navigator/releases/tag/v1.0.0"><img src="https://img.shields.io/badge/version-1.0.0-2563eb" alt="版本 1.0.0"></a>
  <img src="https://img.shields.io/badge/macOS-13%2B-111827" alt="macOS 13 及以上">
  <img src="https://img.shields.io/badge/Apple_Silicon_%26_Intel-supported-16a34a" alt="支持 Apple Silicon 与 Intel">
  <a href="https://github.com/javafancn/vpn-navigator/actions/workflows/swift.yml"><img src="https://github.com/javafancn/vpn-navigator/actions/workflows/swift.yml/badge.svg" alt="Swift 核心测试"></a>
</p>
<p align="center">
  <a href="README.md">English</a> · <strong>简体中文</strong><br>
  <a href="https://github.com/javafancn/vpn-navigator/releases/latest">下载安装</a> ·
  <a href="docs/README.md">文档中心</a> ·
  <a href="docs/RELEASE_NOTES_1_0_0.md">版本说明</a> ·
  <a href="https://github.com/javafancn/vpn-navigator/issues">反馈问题</a>
</p>

在原生 macOS 界面中管理 OpenVPN 配置、切换分流策略并检查连接状态。关闭主窗口后，可继续通过状态栏查看隧道速度和快速切换配置。界面支持简体中文和 English。

## 下载与连接

从 [GitHub Releases](https://github.com/javafancn/vpn-navigator/releases/latest) 下载 **1.0.0**，按 Mac 芯片选择文件：

| Mac 芯片 | 下载文件 |
| --- | --- |
| Apple Silicon（M 系列） | `VPN-Navigator-1.0.0-Apple-Silicon-arm64.zip` |
| Intel | `VPN-Navigator-1.0.0-Intel-x86_64.zip` |

每份压缩包包含 OpenVPN 引擎、安装包、卸载包、SHA-256 校验值、构建来源及安装说明。当前提供**本地测试通道：ad-hoc 签名，未经 Apple 公证**，通过管理员批准固定安装代码身份。用户无需安装 Homebrew。完整步骤见[本地安装、更新与卸载](docs/LOCAL_TEST_INSTALLATION.md)。

1. 更新已安装的可连接版本前，先在旧版「设置与维护 → 升级与卸载准备」完成准备，再退出旧应用。
2. 解压并核对随包提供的 SHA-256 校验值，运行对应芯片的安装包。
3. 从「应用程序」打开 VPN Navigator，完成内置安装检查。
4. 导入自己的 `.ovpn`，选择路由模式并连接，按提示输入凭据。

关闭窗口会继续在状态栏运行；选择「打开主窗口」恢复界面。「退出应用 / ⌘Q」会先断开并核验网络恢复，再停止后台工作。

## 功能概览

| 工作区 | 主要能力 |
| --- | --- |
| 连接概览 | 隧道实时速度、60 秒流量曲线、累计流量、已核验路由状态与恢复入口。 |
| 配置库 | Finder 打开与拖放导入、搜索、分组、收藏、备注、安全更新、版本历史和加密备份。 |
| 路由分流 | 原始配置、全局 VPN、中国直连三种模式；IPv4/IPv6 自定义规则和路由解释。 |
| 网络诊断 | DNS、TCP、有限跳数 traceroute、ping、公网 IPv4/IPv6 出口检查和脱敏诊断导出。 |
| 设置与维护 | 可选智能连接、状态通知、登录启动、界面语言及升级/卸载准备。 |

- **认证支持：**账号凭据可选保存在 Keychain；支持私钥口令、静态 OTP 和初次认证的 CRV1 动态挑战。
- **快捷操作：**⇧⌘P 快速搜索配置，⌘1–5 切换工作区；支持键盘导航、VoiceOver 标签和系统「增强对比度」。
- **DNS 与恢复：**中国直连使用分流 DNS，全局模式使用 VPN DNS；通过所有权记录核验 DNS 和路由恢复。
- **连接历史：**本机保存会话时间线与已观察的连接质量，可配置保留时间并清空。

## 三种路由模式

| 模式 | 行为 |
| --- | --- |
| 原始配置 | 遵循经过校验的 OpenVPN 配置。 |
| 全局 VPN | 受管默认流量通过 VPN。 |
| 中国直连 | 按隧道实际承载的地址族，将地区 IPv4/IPv6 目的地直连，其余默认流量通过 VPN；名单内国内域名使用直连 DNS。 |

自定义直连/VPN 规则支持两种地址族。约束及恢复行为见[双栈支持](docs/DUAL_STACK.md)、[路由工具](docs/ROUTING_TOOLS.md)和 [DNS 分流](docs/SPLIT_DNS_AND_DISCONNECT.md)。

## 从源码构建

需要 **macOS 13+**、**Swift 5.9+**，以及兼容的 macOS SDK 和 XCTest 工具链。

```sh
swift test
zsh scripts/build-app.sh
```

未设置 `OPENVPN_BIN` 时生成 UI 预览版。需要实际连接时，参照[本地测试安装](docs/LOCAL_TEST_INSTALLATION.md)或[源码引擎及签名构建](docs/INSTALL_AND_RELEASE.md)。[安装包工作流](https://github.com/javafancn/vpn-navigator/actions/workflows/package-installers.yml)构建双架构产物；Developer ID 签名与公证使用[独立流程](docs/SIGNED_RELEASE_WORKFLOW.md)。

## 文档导航

| 使用场景 | 文档 |
| --- | --- |
| 安装、升级与卸载 | [本地安装指南](docs/LOCAL_TEST_INSTALLATION.md) |
| 整理与迁移配置 | [配置库](docs/PROFILE_LIBRARY.md) · [加密备份](docs/ENCRYPTED_BACKUP.md) · [健康与更新](docs/PROFILE_HEALTH_AND_UPDATES.md) |
| 分流与自动连接 | [路由工具](docs/ROUTING_TOOLS.md) · [智能连接](docs/SMART_CONNECTION.md) |
| 排查连接问题 | [启动诊断](docs/OPENVPN_STARTUP.md) · [网页延迟](docs/WEB_LATENCY_AND_OVERNIGHT.md) · [公网出口](docs/PUBLIC_EGRESS.md) |
| 开发与发布验收 | [架构](docs/ARCHITECTURE.md) · [验收清单](docs/QA.md) · [1.0.0 说明](docs/RELEASE_NOTES_1_0_0.md) |

实现细节、历史修复与验证记录收录在[完整文档索引](docs/README.md)。

## 安全与兼容范围

连接前必须具备 `remote-cert-tls server` 或精确的 `verify-x509-name` 服务端身份约束；旧配置仍可导入和编辑。任意脚本/插件、TAP、硬件 PKCS11、SAML/浏览器认证及会话内 CRV1 重认证不在当前支持范围。

**PF 断线保护为实验性功能，默认关闭。**它要求兼容的系统 PF 布局，保护变更会重置现有网络连接。完整物理网络防泄漏验收尚未完成；1.0.0 版本号不代表已通过 Apple 公证或全部真实网络验收。当前限制及待验收项目见[版本说明](docs/RELEASE_NOTES_1_0_0.md)与[验收清单](docs/QA.md)。

恢复仅处理能确认属于本应用的 DNS、路由和 PF 资源。配置可能含私钥，请勿将真实配置、密码或签名证书提交到 Git 或问题反馈中。

## 致谢与许可证

地区规则来自 [misakaio/chnroutes2](https://github.com/misakaio/chnroutes2)，保留 CC BY-SA 2.0 标识及快照来源，见[规则说明](Resources/Rules/README.md)。引擎构建随包收集 OpenVPN/OpenSSL 原始许可证及对应源码归档。参见 [LICENSES](LICENSES) 和各构建内的依赖声明。
