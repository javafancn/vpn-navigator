# 网络响应与 DNS 修复（2026-11-03，工作区）

后续审查发现的 DNS 归属校验、助手空闲生命周期、首次 IPv6 规则和自动连接竞态，已在 [审查回归修复](REVIEW_REGRESSION_FIXES_2026_11_03.md) 中收紧并补充验证；以下记录的是本轮最初的改动。

针对 IPv4 隧道下的 IPv6 回退、国内解析器选择、DNS 重复查询和端口兼容、断线保护锁定首节点的修复。保留工作区此前的原生路由查询、异步巡检、UDP 上游复用与批量路由日志改动。本机已安装程序未被替换。

## 行为变化

- 受管 DNS 按实际协商的隧道地址族处理 A/AAAA。缺失地址族立即返回 NOERROR/NODATA，不伪造 NXDOMAIN、不宣称 DNSSEC 验证通过，也不向上游发送这类查询。服务器提供双栈时保留 A/AAAA。企业 supplemental DNS 仍由原有匹配规则处理。
- PF 的 IPv6 兜底从静默丢弃改为 `block return`，保留之前所有允许项及最后拒绝规则。使用应用自身 DNS/DoH、缓存地址或字面 IPv6 地址的客户端也可收到失败响应；没有扩大物理出口权限。实际内核回退时间仍需实机验证。
- 在 OpenVPN hook 改写 DNS 前，记录当前物理网络的手工 DNS，缺省记录 DHCP/State DNS。国内名单命中的查询优先使用这些解析器，再补充 AliDNS/DNSPod 候选；排除 VPN DNS、服务器端点、回环、不支持地址族和无效地址。路由器 LAN DNS 保持原有 on-link 路径，不添加经默认网关的错误主机路由。
- DNS 增加会话内正向 A/AAAA 缓存：最多 512 项、约 2 MB 线报文与键、单包 16 KiB，按上游最短 TTL 失效且最多保存 300 秒。命中时减少每条 RR 的 TTL，恢复调用者 ID，保持 OPT 字段。零 TTL、错误、截断、含 DNSSEC 签名或消息认证记录的响应不缓存。UDP/TCP、请求标志、EDNS 和问题大小写独立。
- 同一请求的并发查询合并，最多 32 个调用者共享一项任务；最多 128 项任务同时请求上游、256 项任务含排队、1024 个等待响应。超过有界容量仍返回 SERVFAIL，避免无限内存或套接字增长。
- 优先同时占用 `127.0.0.1:53` 的 UDP/TCP；任一端口冲突均撤销本次占用并退回随机高位端口，通过原生 `ServerPort` 发布，不替换已有 DNS 服务。标准端口不设置 `ServerPort`。模式切换复用监听器，清空缓存并终止旧策略的在途查询，避免端口变化和跨策略缓存。
- 断线保护保留原始配置的全部 `remote`（最多 64），遵循 `remote-random`，预先解析候选地址并去重。重试轮换节点及地址，每次仅向 PF 放行当前选中的端点。先确认旧进程退出及 DNS/路由清理，再更新保护并启动下一会话。已建立连接的自动重连仍受原开关及三次预算约束；首次连接的多节点尝试共享原有总超时，不通过重试延长截止时间。无显式 `connect-timeout` 时，为多候选设置不超过十秒的服务器响应等待，给后续节点留出机会。
- 对 TCP 传输开启 `TCP_NODELAY`。保持服务器所需的 TCP/UDP、证书校验和配置中的 MTU/MSS，不猜测服务器协议或强行替换参数。

## 验证

- Debug、Release 助手构建通过。`--self-test-network-latency` 覆盖 TTL 衰减、过期、LRU/字节上限、报文身份与 TCP/UDP/标志隔离、零 TTL/错误/截断/签名排除、NODATA、LAN DNS、多个 remote/地址、超时及 TCP 参数。
- 真实 loopback UDP/TCP 代理回归：1,000 个独立首尝试查询、160 个突发查询、32 个相同并发查询合并为一次上游请求、缓存衰减与过期、IPv4-only/IPv6-only、完整策略组隔离、模式切换缓存清除和端口保持、UDP 或 TCP 单独占用时的回退。
- DNS journal 使用真实私有文件及内存 SystemConfiguration 边界，覆盖 DHCP 捕获、服务器 hook 后保留物理 DNS、53/高位端口发布和恢复、外部变更冲突、缓存刷新失败。
- 路由回归通过：双栈模式往返、PF 顺序、日志批次/恢复/取消/压缩、进程退出和 128 FD 限制下 3,072 次真实只读路由命令；路由增删使用注入的 OS 模型。
- Python 脚本回归 35 项通过；双语目录同步检查和 diff 空白检查通过。新增行为自检加入四个 macOS CI runner；系统安装测试同时识别标准端口和高位端口，并核验新的国内解析器路径。

本机仅有 Command Line Tools：完整 App 构建缺少 `SwiftUIMacros` 插件，XCTest 缺少 `XCTest` 模块。这些不是已通过的检查。未执行真实安装后的 PF 拒绝、节点切换、浏览器/公网下载或长期会话验收，不能将 loopback 结果当作用户宽带提速比例。

## 保留的边界

未知域名仍只经 VPN 解析，避免为扩大名单覆盖而把海外查询发往物理 DNS。浏览器自带 DoH 也不会自动服从系统的国内域名选择。已有其它 DNS 服务占用 53 时，忽略 `ServerPort` 的客户端兼容性仍取决于该服务。TCP 的丢包吞吐、服务端拥塞及实际路径 MTU 需要同服务器、同线路对照测量；换成 UDP 要求服务器支持。

协议依据：[DNS 报文与 TTL](https://www.rfc-editor.org/rfc/rfc1035.html)、[TTL 边界](https://www.rfc-editor.org/rfc/rfc2181.html)、[OpenVPN 服务器响应等待与 TCP_NODELAY](https://openvpn.net/community-docs/community-articles/openvpn-2-7-manual/)。PF 的 `return` 语义也已对照本机 `/usr/share/man/man5/pf.conf.5`。
