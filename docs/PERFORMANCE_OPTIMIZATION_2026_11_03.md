# 性能优化与收尾验证（2026-11-03）

基于 `c9a292a` 的未提交工作区，承接
[审查意见逐项核验](REVIEW_FINDINGS_VERIFICATION_2026_11_03.md)和
[路由查询积压修复](ROUTING_SWITCH_READER_FIX.md)。本文记录实现和本地验证范围，
不将合成测试的调用次数或耗时解释为真实 VPN 吞吐提升。

## 路由事务与恢复

- 路由所有权和日志重放使用保留顺序的哈希集合，避免逐条删除时反复扫描、移动整个数组。
- 每批最多 64 项：先同步整批 begun，再执行内核操作，最后同步 receipts。
  256 条路由安装后卸载的事件日志同步由 1024 次降为 16 次；这是同步调用数，
  并非物理磁盘写入次数或实网性能测量。
- 中途失败时，只为本进程确认未发出的操作写 cancelled；已经发出但未确认的
  内核操作仍是不确定事务。意图或回执同步失败后均禁止自动回滚。
- 检查点仅在完整事务之间生成，预留整批事件的容量；恢复复用首次已验证重放，
  缺失 add 的协调直接写检查点。所有权比较、子进程退出顺序和恢复容量限制保留。
- 原生路由查询在发出新请求前清空旧通知，模式切换失败记录阶段及数值 errno。

## 守护检查与停止响应

- 五秒检查的路由查询、LAN 快照和 IPv6 默认路由检测改为原生 socket、sysctl
  和 getifaddrs。代表性路由探针在策略变更时编译，避免每次检查扫描全部 IPv6 前缀。
- 检查在独立串行队列运行，同一时间最多一个；网络变化合并为后续检查。
  结果回到会话队列后核对连接 attempt 和路由 revision，旧结果不能终止新会话。
- DNS 所有权及 PF 期望规则使用不可变快照验证。PF 完整核验仍执行 pfctl；
  不能据此宣称守护检查已经完全没有子进程。
- 停止 OpenVPN 改为退出通知和两秒截止时间，等待期间会话队列可处理状态请求。
  超时保留子进程、路由和恢复记录；再次断开立即返回当前失败状态，确认稍后退出
  才执行清理。不使用延迟数字 PID 强杀。

## DNS、XPC、规则和界面

- UDP 接收缓冲区复用；每个固定上游复用一个连接，以随机且未占用的 ID
  分发并发请求，完成后恢复原始 ID，并隔离近期已用 ID。TCP 保留独立 exchange。
  exchange 的超时定时器在完成或取消时释放，国内/VPN 分组与后备策略保留。
- 客户端复用具有当前身份要求的 XPC 连接，每个请求独立限时且只完成一次。
  审批要求变化会关闭旧连接；固定进程签名身份缓存，安装批准检查与 OS 对端校验保留。
- 已核验的断开状态以 30 秒间隔轮询，开始连接等状态变化立即唤醒轮询。
  空闲快照后关闭客户端连接；助手无客户端且没有会话、恢复或安装事务时才延迟退出。
- 规则缓存复用已解析对象，文件元数据变化后重新验证；全局模式不再准备国家规则。
  RuleAgent 先读取 launchd 运行状态，避免仅更新磁盘缓存时启动空闲助手。
- 自动连接网络信息改为事件驱动并在后台读取；相等状态不重复发布。
  配置排序结果缓存，原生列表仅在内容或展示状态变化时更新；断开时停用秒级显示时钟。
- 连接历史维持有序记录，减少重复排序和无变化发布；健康检查产生新配置版本后
  通知详情刷新历史；更新检查使用进行中标记合并重复触发。

## 验证命令及边界

已运行并通过：

- `python3 -m unittest discover -s scripts/tests -v`：35 项通过。
- Debug Helper 构建；`--self-test-route-ordering`、`--self-test-core-optimizations`
  和只读 `--self-test-native-network`。
- 全部 Release 产品构建（App、Helper、RuleAgent、LocalSetup、PFPreview），使用
  `swift build -c release --scratch-path /private/tmp/vpnnav-optimized-sdk26 --sdk /Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk`。
- `python3 scripts/test-dns-cache-failure.py .build/debug`：真实私有日志文件及
  内存 DNS 边界，无系统 DNS 更改。
- `GITHUB_ACTIONS=true python3 scripts/test-split-dns.py .build/debug/VPNNavigatorHelper`：
  仅回环 UDP/TCP、并发、64 个客户端使用相同事务 ID 的问题/策略隔离、
  伪造响应拒绝、后备、模式隔离和在途请求停止。
- 双语目录及 `git diff --check`。

路由批处理故障注入包括内核写失败、取消、意图同步失败和回执同步失败；
异步退出测试使用真实测试子进程，验证超时后仍保留身份并在确认退出后完成。
新增规则/历史回归和原生网络比对已接入 Swift CI；本地执行不代表远程 CI 已通过。

本机 CommandLineTools 默认 SDK 27 缺 SwiftUI 宏插件；App 使用已安装的
`MacOSX26.5.sdk` 构建。完整 `swift test` 仍因缺少 XCTest 模块失败，
不能标记为已通过。界面实际交互、签名后的 XPC 连接复用/助手退出、真实 VPN
反复模式切换、睡眠唤醒、能耗和吞吐仍须安装后验收。本轮没有替换已安装程序或切换当前 VPN。
