# 隔离服务器认证与中断验收

此记录补充 M3 的认证闭环和 M5 的异常场景。通过本地安装通道的正式 XPC API，连接源码构建的真实 OpenVPN 2.7.8 服务器。用例仅允许运行在一次性的 GitHub macOS runner，所有密钥、账号、口令、验证码和 CRV1 状态均为临时生成。

## 自动化范围

| 场景 | 客户端与服务端独立核验 |
| --- | --- |
| 账号密码 | 正确密码成功、错误密码失败；管理协议正确传递空格、引号及反斜杠 |
| 加密私钥 | 正确密码解锁并建立 TLS；错误密码失败；取消后不再启动旧连接 |
| 静态 MFA | flags 0–3 的 SCRV1 / concat 两种编码实际由服务器校验；错误验证码失败、取消不认证 |
| 初始动态 CRV1 | 单轮、连续两轮、无 R 的显式确认；响应携带正确的 opaque state；错误响应失败 |
| 认证上限 | 第四次 CRV1 挑战被拒绝，沿用单次尝试的总超时 |
| 响应生命周期 | 每个已提交 ID 只可使用一次，取消后的旧 ID 被拒绝；等待后仍为断开 |
| 诊断隐私 | 每次检查 SessionReport 与诊断事件不含口令、OTP、解锁密码及 opaque state |
| 服务端掉线 | 已连接时停止测试服务端，客户端显示失败、清理恢复记录，服务端重启后可重新连接 |

服务端认证钩子仅存在于测试进程，通过 via-file 接收临时凭据，单独记录枚举结果。生产助手仍拒绝用户配置的脚本与插件，没有增加任意命令或弱化代码身份校验。私钥密码通过临时 0600 文件交给 OpenSSL，不置于命令行或环境。

工作流为 `.github/workflows/local-install.yml` 的 macOS 14 / 15 / 26 ARM64 与 macOS 15 Intel 四组安装验收。检查结果和具体提交以 PR #17 的 Actions 为准，尚未完成的检查不得记为通过。

## 仍需外部验收

本用例不调用实际 Keychain 和 SwiftUI 输入框，也不连接企业 RADIUS/LDAP、真实 OTP 提供方或外部 VPN。它不替代真实账户/加密密钥/MFA 配置兼容性、物理 IPv4/IPv6 出口抓包、企业 DNS、三种路由模式、Wi-Fi 切换、睡眠、重启、macOS 13 真机和长时资源占用记录。后续应按 QA.md 收集这些结果，再决定是否发布 Beta。

动态挑战仅覆盖连接建立前的 CRV1；连接后的重新认证、SAML/浏览器登录、TAP、PKCS11 和 IPv6 地域分流仍按既定范围延期。

参考：[OpenVPN 2.7 手册](https://openvpn.net/community-docs/community-articles/openvpn-2-7-manual.html)、[2.7.8 management-notes](https://github.com/OpenVPN/openvpn/blob/v2.7.8/doc/management-notes.txt)。
