# 隔离 TLS / utun 联调

此用例补充本地安装及管理套接字测试，使用内置源码引擎作为临时 OpenVPN 服务器，通过已安装 root 助手启动真实客户端。仅允许运行在一次性的 GitHub macOS runner 中；不属于应用安装内容。

## 覆盖范围

- 临时 CA、serverAuth / clientAuth 证书及客户端私钥，使用源码构建的 OpenSSL CLI 生成。
- 服务器仅监听 127.0.0.1 的临时 TCP 端口，使用独立的 198.18.254.0/24 测试子网；不推送默认路由或 DNS。
- 当前批准在测试期间临时切换为 CI 客户端的固定代码身份。客户端 XPC 同时验证真实助手的 CDHash；测试后恢复原始批准。没有修改生产助手的身份检查。
- 通过生产 connect API 以 Original 模式完成两次真实证书 TLS / utun 连接及断开，随后使用错误 CA 验证拒绝与清理。
- 断开后核验所有固定会话/路由/DNS/PF/PID 记录均不存在，且默认网关与接口未改变。服务端子进程、密钥及临时配置均在 finally 清理。
- 证书、私钥、配置和原始引擎日志不进入 artifact；发生失败时只输出合成服务器的日志尾部。

PR #16 已增加控制器崩溃、明确恢复及重新连接。PR #17 继续增加账号/加密私钥/静态与动态挑战、取消及服务端中断，详见 [认证验收范围](LOCAL_AUTH_ACCEPTANCE.md)。认证脚本只在测试服务器启用，不安装到应用。

此用例证明隔离主机上的原生引擎集成、证书握手、utun 和会话恢复行为。它不证明数据包已经过物理 VPN 出口，也不替代真实企业账号/MFA、实际 DNS、物理 IPv4/IPv6 抓包、网络切换、睡眠或物理路由事务中断验收。

执行结果以新增工作流检查为准。生产 Beta 的外部验收门槛仍见 LOCAL_IMPLEMENTATION_STATUS_2026_10_18.md 和 QA.md。

参考：[OpenVPN 官方手册](https://openvpn.net/community-docs/community-articles/openvpn-2-6-manual.html)。

0.8.8 / Build 28 增加真实应用 TCP／UDP × 原始／全局／规则连接、4096 条实际路由、在线往返切换、加密数据回显和明确退出。具体隔离方式、真实系统变更和验收边界见 [受管连接验收](MANAGED_CONNECTION_ACCEPTANCE.md)。
