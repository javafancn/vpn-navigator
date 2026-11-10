# 文档中心 / Documentation

[English](../README.md) · [简体中文](../README.zh-CN.md) · [1.0.1 / Build 40](RELEASE_NOTES_1_0_1.md)

README 提供安装入口与功能概览；本目录保留操作指南、实现说明及历史验证记录。历史文档中的版本、验收结论和限制仅适用于其记录的提交，当前状态以对应提交的 CI 和实机记录为准。

## 常用指南 / Start here

| 主题 | 文档 |
| --- | --- |
| 安装与维护 | [本地安装、升级、卸载](LOCAL_TEST_INSTALLATION.md) · [构建与发布](INSTALL_AND_RELEASE.md) |
| 配置管理 | [配置库](PROFILE_LIBRARY.md) · [备份迁移](ENCRYPTED_BACKUP.md) · [健康与更新](PROFILE_HEALTH_AND_UPDATES.md) · [导入导出](PROFILE_TRANSFER.md) |
| 连接与网络 | [双栈](DUAL_STACK.md) · [路由工具](ROUTING_TOOLS.md) · [分流 DNS](SPLIT_DNS_AND_DISCONNECT.md) · [智能连接](SMART_CONNECTION.md) |
| 操作与诊断 | [快捷操作](QUICK_ACCESS.md) · [键盘与辅助功能](KEYBOARD_AND_ACCESSIBILITY.md) · [启动诊断](OPENVPN_STARTUP.md) · [网页延迟](WEB_LATENCY_AND_OVERNIGHT.md) |
| 开发与验收 | [架构](ARCHITECTURE.md) · [本地化](LOCALIZATION.md) · [QA](QA.md) · [签名发布](SIGNED_RELEASE_WORKFLOW.md) |

## 完整索引 / All documents

以下包含历史修复和专项验收记录，保留原文件路径以便追溯。

- [VPN Navigator 0.2 architecture](ARCHITECTURE.md)
- [Authentication and maintenance follow-up — 2026-10-18](AUTH_AND_MAINTENANCE_2026_10_18.md)
- [后台服务偏好与维护恢复（0.3.3 / Build 6）](BACKGROUND_SERVICES.md)
- [会话质量与连接历史](CONNECTION_HISTORY.md)
- [0.8.15 / Build 35：DNS 缓存错误阻断连接与退出](DNS_CACHE_FAILURE_0_8_15.md)
- [IPv6 与双栈支持](DUAL_STACK.md)
- [加密备份与迁移](ENCRYPTED_BACKUP.md)
- [0.8.16 / Build 36：缓存错误处理补充检查](FOLLOWUP_REVIEW_0_8_16.md)
- [0.8.17 / Build 37：功能与性能检查](FUNCTION_AND_PERFORMANCE_0_8_17.md)
- [服务端身份与配置库并发修复](HIGH_PRIORITY_FIXES.md)
- [Build, install and update VPN Navigator](INSTALL_AND_RELEASE.md)
- [VPN Navigator 0.1.0 — UI-only developer test](INSTALL_UI_TEST_BUILD.md)
- [键盘与辅助功能](KEYBOARD_AND_ACCESSIBILITY.md)
- [Hardware route acceptance script](LIVE_ROUTE_ASSERT.md)
- [Running live macOS acceptance checks](LIVE_TESTS.md)
- [界面语言与本地化](LOCALIZATION.md)
- [隔离服务器认证与中断验收](LOCAL_AUTH_ACCEPTANCE.md)
- [助手崩溃、错误反馈及升级验收](LOCAL_CRASH_RECOVERY.md)
- [0.8.14 / Build 34：本机反馈修复](LOCAL_FEEDBACK_0_8_14.md)
- [本地通道实施与验收记录（2026-10-18）](LOCAL_IMPLEMENTATION_STATUS_2026_10_18.md)
- [安装事务与中断修复（0.3.2 / Build 5）](LOCAL_INSTALL_REPAIR.md)
- [本地测试通道：安装、更新与卸载](LOCAL_TEST_INSTALLATION.md)
- [隔离 TLS / utun 联调](LOCAL_TLS_ACCEPTANCE.md)
- [Real application managed-connection acceptance](MANAGED_CONNECTION_ACCEPTANCE.md)
- [Managed DNS and route application (0.8.12 / Build 32)](MANAGED_DNS_AND_ROUTE_PERFORMANCE.md)
- [原生配置文件入口（0.3.6 / Build 9）](NATIVE_PROFILE_OPEN.md)
- [网络响应与 DNS 修复（2026-11-03，工作区）](NETWORK_LATENCY_FIXES_2026_11_03.md)
- [OpenVPN startup and control-channel diagnostics](OPENVPN_STARTUP.md)
- [0.8.13 working-tree performance fixes](PERFORMANCE_FIXES.md)
- [性能优化与收尾验证（2026-11-03）](PERFORMANCE_OPTIMIZATION_2026_11_03.md)
- [Experimental PF runtime guard](PF_LEAK_GUARD.md)
- [Product-readiness implementation — 2026-10-17](PRODUCT_READINESS_2026_10_17.md)
- [配置健康、证书提醒与更新向导](PROFILE_HEALTH_AND_UPDATES.md)
- [配置列表备份与故障恢复](PROFILE_INDEX_RECOVERY.md)
- [配置库筛选、排序与分组复用](PROFILE_LIBRARY.md)
- [配置迁移与批量导入（0.3.5 / Build 8）](PROFILE_TRANSFER.md)
- [公网出口检测](PUBLIC_EGRESS.md)
- [VPN Navigator — macOS release acceptance tests](QA.md)
- [快速打开（0.3.4 / Build 7）](QUICK_ACCESS.md)
- [0.8.18 / Build 38](RELEASE_NOTES_0_8_18.md)
- [VPN Navigator 1.0.0 / Build 39](RELEASE_NOTES_1_0_0.md)
- [VPN Navigator 1.0.1 / Build 40](RELEASE_NOTES_1_0_1.md)
- [规则、下载、备份和连接诊断改进](RELIABILITY_IMPROVEMENTS.md)
- [2026-11-02 检查与后续优先级](REVIEW_2026_11_02.md)
- [截图审查意见逐项核验（2026-11-03）](REVIEW_FINDINGS_VERIFICATION_2026_11_03.md)
- [审查回归修复（2026-11-03，工作区）](REVIEW_REGRESSION_FIXES_2026_11_03.md)
- [规则 / 全局切换（0.3.7 / Build 10）](ROUTING_MODE_SWITCH.md)
- [Retained route-reader backlog during mode changes](ROUTING_SWITCH_READER_FIX.md)
- [> 0.5.0 已将 IPv6 接入实际分流、自定义规则和排障。以下为 0.4.0 的原始功能说明，当前边界以 [双栈支持](DUAL_STACK.md) 为准。](ROUTING_TOOLS.md)
- [Manual signed release workflow](SIGNED_RELEASE_WORKFLOW.md)
- [智能连接与状态通知](SMART_CONNECTION.md)
- [DNS splitting and intentional disconnect (0.8.12 / Build 32)](SPLIT_DNS_AND_DISCONNECT.md)
- [VPN Navigator — Native macOS workspace UI](UI_DESIGN.md)
- [设计优化：更轻的导航与更清楚的信息层级](UI_DESIGN_REFINEMENT_2026_10_16.md)
- [VPN Navigator 原生 UI 还原规范（2026-10-16）](UI_FIDELITY_PLAN_2026_10_16.md)
- [原生玻璃与交互打磨](UI_POLISH_2026_10_16.md)
- [macOS Reference UI Audit (October 2026)](UI_REFERENCE_AUDIT.md)
- [网页首次访问与跨夜对照](WEB_LATENCY_AND_OVERNIGHT.md)
