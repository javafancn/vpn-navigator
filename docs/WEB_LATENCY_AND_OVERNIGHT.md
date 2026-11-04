# 网页首次访问与跨夜对照

受管 DNS 现在缓存 A、AAAA、SVCB（64）及 HTTPS（65）的正向完整响应。
HTTPS/SVCB 的 TargetName、ALPN、地址提示、ECH 及未知参数按原报文保留，
不根据地址族改写记录。缓存仍按最短 RR TTL 失效、最多 300 秒，遵循原有
512 项/2 MB 上限、UDP/TCP 和请求标志隔离。零 TTL、错误、截断及带签名的
响应保持不缓存。未知海外域名仍只走 VPN DNS。

## 按需采样

从项目目录运行（macOS 自带 Python 3、curl）：

```sh
umask 077
python3 scripts/sample-web-latency.py --label evening > /private/tmp/vpnnav-evening.json
python3 scripts/sample-web-latency.py --label next-day --compare /private/tmp/vpnnav-evening.json > /private/tmp/vpnnav-next-day.json
```

第一条在晚间运行，第二条在次日**尚未重新连接 VPN**时运行。各采九轮，固定访问
YouTube、Google、GitHub、Cloudflare，每轮四个站点并发。每个请求独立 curl 进程，
使用 HEAD、系统 DNS/路由、正常证书校验；单次最多 12 秒，不跟随跳转。
工具禁用 curl 配置及 HTTP/SOCKS 代理，使三组结果使用相同测量路径。
进度写 stderr，JSON 写 stdout。可用 `--samples 1` 做快速连通性检查。

如要比较重连后的差异，在保存次日数据后自行通过 App 重连，再运行：

```sh
python3 scripts/sample-web-latency.py --label after-reconnect --compare /private/tmp/vpnnav-next-day.json > /private/tmp/vpnnav-after-reconnect.json
```

工具不会重连、刷新缓存、修改 DNS/路由，也不读取配置、账号或浏览器 Cookie。
JSON 包含公开测试主机/IP、时间、连接历史中的会话标识、模式及各次耗时，
并汇总成功次数、失败次数、中位数与最近秩 p90。比较字段是当前中位数减基线，
正数表示更慢；失败请求单独计数，不作为零耗时纳入统计。

会话信息来自本地连接历史，包含采样前后快照；只在历史最近 90 秒有更新、仍在
观察中且会话/模式一致时标记 `session_stable`。跨文件比较另报告
`same_observed_session_and_mode`。这只是观察证据，不是实时助手证明；App 关闭、
历史暂停或状态过期时仍可测量网络，但不能据此断言同一会话。

不清缓存意味着首轮可能已经命中缓存；不能将首轮一律称为冷启动。
HEAD 不测浏览器页面渲染、多域名资源、浏览器 DoH/HTTP3 或视频吞吐。
采样时尽量保持相同物理网络、VPN 节点和负载，并记录是否经历睡眠。
只有几组结果不能证明普遍性能提升，也不能消除线路本身的往返延迟。

## 回归与长期验收

```sh
swift build --product VPNNavigatorHelper
.build/debug/VPNNavigatorHelper --self-test-network-latency
GITHUB_ACTIONS=true python3 scripts/test-split-dns.py .build/debug/VPNNavigatorHelper
python3 -m unittest discover -s scripts/tests -p test_web_latency_sampler.py -v
```

回环测试验证三类正向记录在 UDP/TCP 下的命中、TTL 衰减/过期、事务 ID 和原始
服务参数保留，以及模式切换清空缓存；同一个代理还经历无请求空闲、两个上游均
静默超时、随后恢复响应，确认无需重启代理即可继续查询。默认空闲 2.2 秒便于 CI，
不会把短测称为跨夜验收。隔离机器可将同一测试扩展到六小时空闲：

```sh
GITHUB_ACTIONS=true VPNNAV_DNS_IDLE_SECONDS=21600 python3 scripts/test-split-dns.py .build/debug/VPNNavigatorHelper
```

实际睡眠唤醒须在实机单独验收：先采 evening，保持 VPN，按日常习惯睡眠并唤醒，
待物理网络恢复后、重连之前采 next-day；另做持续开机仅锁屏的一组。检查同会话
标记、失败率和各阶段分布，若持续超时，再保存数据进行上游生命周期排查。
回环静默恢复测试不模拟 macOS 睡眠/NAT/物理网络切换。现阶段不根据未复现的
跨夜假设改变生产上游连接恢复逻辑。

本轮本地验证（2026-11-04）：Debug/Release Helper 构建、扩展后的缓存自检及完整
回环 DNS 回归通过；40 项 Python 脚本测试、双语目录及 diff 空白检查通过。
新采样工具的一轮公网检查完成四个站点请求并生成有效 JSON；这只是工具连通性
验证，不是新版安装后的提速对照。未替换本机安装版，未执行六小时空闲或真实
睡眠唤醒验收，也未运行完整 XCTest/UI 验收。
