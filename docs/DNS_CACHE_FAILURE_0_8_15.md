# 0.8.15 / Build 35：DNS 缓存错误阻断连接与退出

用户在 0.8.14 实机连接时报告：

```text
Routing failed; VPN stopped for safety: The system network command failed: /bin/launchctl.
```

## 原因

0.8.14 在 DNS 发布、模式切换和恢复后增加了通过 `launchctl` 向系统 mDNSResponder job 发送 HUP 的操作。该命令在用户机器上失败，错误沿着路由配置调用链向上传播，使已写入并核验的 DNS 被误判为连接失败。

失败后的 DNS 恢复又调用同一缓存刷新操作。即使原 DNS 值已成功恢复，缓存命令仍可抛错，导致恢复日志保留、会话显示恢复未完成，进而阻止安全退出。这是 0.8.14 引入的回归，不能归因于用户的配置或 VPN 服务器。

## 修复

- 移除 DNS 缓存刷新中的 `launchctl` HUP 调用及路由工具的对应允许项。
- 保留 `dscacheutil -flushcache`，但仅尽力执行。异常只在可选缓存刷新边界消化，不影响已核验的 DNS 发布和恢复。
- DNS 值写入、所有权比较、恢复结果核验和日志文件操作仍须成功；外部 DNS 冲突继续保留证据并阻止不安全恢复。
- 不通过绕过退出保护、强制结束进程或删除未知日志来解除问题。

## 验证

- Debug 助手编译通过。
- `python3 scripts/test-dns-cache-failure.py <Swift products>` 通过：用实际 journal/self-test 源码和真实私有临时文件运行，只有 SystemConfiguration API 边界重定向至内存存储，不修改系统 DNS。
- 每次缓存刷新均抛出 `/bin/launchctl` 失败时，受管 DNS 配置、两次转发端口发布和原值恢复仍成功；恢复日志清除。外部值冲突仍被拒绝，重试恢复及重复恢复继续正确。
- 同一回归针对未修复的 0.8.14 journal 会因所报告的 `launchctl` 错误失败。
- 原有使用合成网络服务的真实 SystemConfiguration 自测也包含上述失败场景；独立无特权回归接入 macOS 四平台 CI。

本机尚未替换已安装的 0.8.14，也未完成真实 VPN 连接复测。修复后的完整安装包仍须由完整 Xcode 构建环境生成并验收。

## 旧版当前状态处理

优先使用主页“恢复网络”，等界面确认恢复完成后再退出。0.8.14 的首次失败可能已经恢复了 DNS 值，后续恢复在值未变动时可清除遗留日志。若恢复仍失败，保留错误信息；不要删除恢复日志或强制清空系统路由。必要时保存其它工作后重启 Mac，重启后不要在 0.8.14 上重连，先使用修复包升级。
