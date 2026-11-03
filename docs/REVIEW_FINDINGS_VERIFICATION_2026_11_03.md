# 截图审查意见逐项核验（2026-11-03）

核验对象为当前工作区：基于 `c9a292a`，包括上一轮尚未提交的路由查询积压修复。
下面区分源码事实、数量估算和性能影响；未用静态调用次数冒充实机耗时、能耗或吞吐测量。
本轮核验未变更业务实现。

后续实现与验证见 [性能优化与收尾验证](PERFORMANCE_OPTIMIZATION_2026_11_03.md)；
本文保留修复前的审查结论。

| 截图项目 | 结论 | 优先级判断 |
| --- | --- | --- |
| 1. WAL 同步落盘、数组操作与重放 | 属实；数量与双栈路由规模有关 | 高 |
| 2. 五秒守护检查的外部进程和串行阻塞 | 属实；20+ 子进程有配置条件 | 高 |
| 3. DNS 缓冲区与超时闭包 | 部分属实；强持有两秒的判断不成立 | 缓冲区优化低优先级 |
| 4. 停止时 sleep 轮询 | 属实；现有等待上限为两秒 | 中低，涉及状态响应 |
| 5. XPC 连接、身份查询与空闲助手 | 属实；完整安装校验已经缓存，仍有剩余开销 | 中，先测量 |
| 6. 主线程轮询和视图失效 | 基本属实；全量重绘、所有行重设等表述需纠正 | 中 |
| 7. 规则重复解析与 RuleAgent 唤醒助手 | 属实；具体解析次数取决于路径 | 中 |
| 功能 1. 配置历史未随修复刷新 | 属实 | 中低 |
| 功能 2. 更新检查并发 | Developer ID 通道属实；Local 通道不发此请求 | 中低 |
| 功能 3. 验收覆盖缺口 | 属实，但属于验证缺口，不能等同于没有 CI | 发布前补齐 |

## 1. WAL、平方级数组操作与恢复

- `Sources/VPNNavigatorHelper/RouteExecutor.swift:122`：每次安装写 begun 和
  committed，两次调用 `append`。删除路径在 `:180` 和 `:283`，同样执行两次。
  `append` 在 `:202` 每次创建 `JSONEncoder`，在 `:220` 调用
  `FileHandle.synchronize()`。约 12,500 条路由意味着一次安装或一次卸载约
  25,000 次日志同步调用；一次完整连接再断开约 50,000 次。实际条数与地址族、
  自定义规则及路由裁剪有关，不能把该示例直接当作当前 IPv4 会话的条数。
- 不能把同步调用次数直接解释为相同次数的磁盘物理写入，也不能仅凭次数判断它
  占了总耗时的大部分。同步是现有崩溃恢复协议的一部分，优化时须保留事务和
  所有权语义，不能直接删除同步步骤。
- `RouteExecutor.swift:165`：在线删除先 `installed.contains`，再在 `release`
  执行 `installed.removeAll`；IPv6 在 `:267`、`:283` 同样如此。逐条删除的
  `removeAll` 确有 O(N²) 扫描/移动成本。截图的约 8×10⁷ 比较适用于把
  12,500 项当作一个数组的粗估；IPv4/IPv6 实际分开，按 8,500 和 4,000 项，
  单算这两个数组的完整删除扫描约 4.4×10⁷ 项。不能将粗估视为实测指令数。
- `Sources/VPNNavigatorCore/RouteLedger.swift:59`：重放使用数组
  `contains/removeAll`，大规模旧事件重放确有平方级行为。现有检查点减少了
  重放记录数，但没有消除后续数组操作的复杂度。
- `RouteExecutor.swift:33` 重放后调用 `rollback`，后者在 `:137` 再读、重放
  日志。重复工作属实；这是安全检查，消除重复时需要明确已验证状态的有效范围。
- `Sources/VPNNavigatorHelper/RouteJournalRecovery.swift:50`：仅在“不确定的
  add 已被证明不存在”的恢复路径重写存活路由，每条重建 begun/committed，
  再重放校验，尚未直接用 `RouteLedgerCheckpoint`。这里的局部 `append`
  写入内存 Data，并非每条再次 fsync；主要是额外序列化、日志体积和重放开销。

## 2. 五秒守护检查

- `Sources/VPNNavigatorHelper/ManagedTunnel.swift:734` 每五秒把核验放在
  `ManagedTunnel.queue`；`main.swift:95` 的网络变化通知也进入该队列。
- `ManagedTunnel.swift:710` 的核验同步执行物理默认路由、局域网、DNS、
  PF 和受管路由检查。`:617` 的 `localNetworks` 派生两条 netstat 命令，
  并解析文本；`:649` 的路由核验仍逐项派生 route 命令，没有复用原生查询器。
- `Sources/VPNNavigatorHelper/PacketFilterGuard.swift:48` 的一次完整
  `verify` 在常见有 IPv4 直连表情况下运行六次 pfctl：preflight 三次、
  状态一次、anchor 规则一次、直连表一次。
- “每次 20+ 子进程”不是所有会话的固定值；双栈、DNS 数量、自定义规则、
  PF 开关等都会改变数量，双栈并开启 PF 时可以达到该量级。
- `ManagedTunnel.swift:676` 的 IPv6 sample 选择线性遍历直连前缀；
  `Sources/VPNNavigatorCore/IPv6CIDR.swift:34` 每次 contains 重新解析字符串，
  内部确实调用 inet_pton。最坏扫描数千个前缀，且可能尝试多个候选 sample。
- 状态快照也使用同一串行队列，因此检查耗时会延迟快照响应。能确认阻塞关系，
  但“每五秒明显 CPU 尖峰”和对下载吞吐的实际影响仍需采样测量。

## 3. SplitDNSProxy

- `Sources/VPNNavigatorHelper/SplitDNSProxy.swift:88` 每次可读事件分配一个
  65,535 字节的数组，最多处理 32 个报文；不是每个报文都新建该接收数组。
  可以改用实例缓冲区复用，但当前分配有界，不是已证实的内存泄漏。
- `:308` 每个上游 exchange 新建 NWConnection，属实；一次解析可能启动
  多个 exchange，受 hedging、失败回退和并发预算约束。
- `:316` 的两秒超时闭包未显式取消，但已使用 **`[weak self]`**。
  不能据此推断已完成 DNSExchange 及其数据被该闭包强持有两秒。
  仍存在延迟任务调度成本，可以优化，但截图的保留实例结论不成立。
- 组级 hedging 已保存 `DispatchWorkItem` 并在 `:261`、`:275` 取消；
  不应将它与 exchange 的弱引用超时混为一谈。

## 4. 停止时轮询

`Sources/VPNNavigatorHelper/ManagedTunnel.swift:913` 确认使用 terminate 后
每 50 ms 的 Thread.sleep，最多等待两秒；这期间串行队列不能处理快照。
可改为退出通知和截止时间驱动的停止状态机，但必须保留“子进程确认退出后
才恢复路由”的顺序。不能靠先删路由来缩短表面上的断开时间。

## 5. XPC、Security 与空闲助手

- `Sources/VPNNavigatorApp/VPNNavigatorApp.swift:243` 在状态请求完成后等待
  一秒或三秒再轮询；并非严格固定周期，也不是此循环自身并发发请求。
- `Sources/VPNNavigatorApp/HelperClient.swift:107` 每次 ask 创建新连接，
  完成后 invalidate，属实。客户端 requirement 查询发生在每次 ask；
  `Sources/VPNNavigatorHelper/PeerVerifier.swift:10` 每个新连接还计算调用者要求。
- `Sources/VPNNavigatorCore/LocalInstallation.swift:229` 的 selfMatches、
  `PrivilegedServiceTrust.swift:7` 的 Developer ID 自身身份查询、PeerVerifier
  的 Developer ID 分支仍反复调用 Security API。这些剩余优化机会属实。
- **0.8.17 已缓存 LocalInstallation.load 的完整签名和哈希校验**，每次仍
  检查输入文件元数据以失效缓存。不能将现在的身份查询与此前每秒重新散列
  整套约 17 MB payload 的问题混为一谈。见 FUNCTION_AND_PERFORMANCE_0_8_17.md。
- 固定进程身份信息可考虑缓存，但管理员审批、安装事务变化和 OS 对端身份
  校验仍要生效，不能缓存整个授权结果后绕过这些检查。
- 安装有效且应用保持打开时，断开状态轮询仍会联系助手；没有自动空闲退出
  定时器。应用正常退出会显式调用 stopWhenIdle，所以“永远无法退出”需限定
  为应用持续轮询期间，而不是退出流程失效。驻留也不等于内存泄漏。

## 6. 主线程、发布与视图更新

- `Sources/VPNNavigatorApp/SmartConnectionController.swift:44` 总会启动三秒
  定时器，未按 preferences.enabled 停止。`:86` 的 refreshNetwork 在主线程
  访问动态存储；正常取得物理网卡时是两个全局项、两个接口项，共四次。
- `:107` 未比较新旧值便赋给 @Published network，`:42` 又将通知转发给
  AppModel。相等值赋值也可能产生发布通知。这证明有多余失效/重算机会，
  不能直接声称每次都完成了整个窗口的重绘。
- `Sources/VPNNavigatorApp/VPNNavigatorApp.swift:967` 高频赋值多个发布字段；
  `ConnectionHistoryController.swift:24` 同样转发变更，`:44` 每次消费都赋 state。
- `Sources/VPNNavigatorCore/ConnectionHistoryStore.swift:49` 确实重复计算
  archive/records。常规路径中 open/state、前后 archive、返回 state 共四次
  records 排序，tracker.consume 的 prune 还会排序 finished 一次。因此截图的
  “四次”没有算入 prune。上限是 200 条记录，真实耗时通常比大路由数组问题小，
  不能因排序次数就把两者定为同等严重。
- `StatusBarLabel.swift:46` 和 `ConnectionOverviewCards.swift:9` 的一秒时钟
  未按连接状态停用。前者只刷新本地视图状态，且状态图片已有缓存；后者仅在
  对应视图存活时调度，均不是一秒一次的网络探测。
- `VPNNavigatorApp.swift:17` 的 libraryProfiles 每次执行筛选/排序，
  ProfileLibraryView 多处读取 filtered/visibleSelection，重复计算属实；
  精确“每次 body 六次”受分支和视图求值影响，不是固定运行次数。
- `NativeProfileList.swift:61` 遍历配置行，但使用 makeIfNecessary:false，
  **只给已存在的 NSHostingView 重设 rootView**，不会为所有配置创建视图。
  可减少遍历及不变内容的赋值，但截图“所有行全部重设”过于宽泛。

## 7. 规则缓存与 RuleAgent

- `Sources/VPNNavigatorCore/RuleCacheStore.swift:15` 在读取 JSON 快照时
  构造 RuleSet/IPv6RuleSet 校验，随后 RoutingRuleUpdate.cached 在 `:122`
  再解析一次，属实。
- `Sources/VPNNavigatorApp/VPNNavigatorApp.swift:321` 无条件调用两次
  reloadRuleCache；已有有效 JSON 缓存时，每个地址族可解析四遍。
  首次引导、旧缓存或缺失缓存的路径次数不同。
- `:1122` 在 Full VPN 下也重新读取、解析并序列化规则发送给 Helper；
  Helper 的 ManagedTunnel.start 在 `:164` 只在 China Direct 解析这份规则。
  全局模式的这部分客户端准备和传输是多余的。
- `Sources/VPNNavigatorRuleAgent/RuleAgentEntry.swift:25` 在安装可用时查询
  助手，断开状态仍在 `:36` 调用 updateRules。即使只需要更新缓存也会唤醒
  助手；任务结束没有 stopWhenIdle，Helper 的主 RunLoop 会继续运行。
- 这是生命周期优化问题；清理时仍须经过助手的空闲/恢复状态检查，不能由
  RuleAgent 无条件停止一个可能刚被应用连接的助手。

## 功能 1. 配置历史刷新

`Sources/VPNNavigatorApp/MainView.swift:1023` 将历史放在本地 @State，
`:1084` 的 onAppear 加载；手工编辑保存、主动刷新、回滚也会显式重新加载。
`VPNNavigatorApp.swift:1407` 的健康检查更新只修改配置元数据/大小，没有通知
详情页重载历史；`ProfileLibraryView.swift:229` 使用稳定 profile.id 保持视图身份。
所以同一个配置通过健康检查生成新备份后，当前详情页历史列表可能保持旧值。
属实，但不是所有编辑路径都不刷新，也不是备份未生成或丢失。

## 功能 2. 更新检查

`Sources/VPNNavigatorApp/VPNNavigatorApp.swift:773` 没有 in-flight guard、
请求合并、取消旧任务或结果代次校验；`MainView.swift:873` 每次点击创建 Task。
Developer ID 通道确实可并发查询 GitHub，并由后完成的旧请求覆盖界面状态。
`UpdateChecker.swift:27` 有响应体上限和超时，但没有解决并发结果顺序问题。

Local 通道在 `VPNNavigatorApp.swift:776` 直接进入维护/手动更新流程，不调用
GitHub API。当前用户安装的 Local-Test 包不受这条网络请求并发问题影响。

## 功能 3. 测试和实机验收

- 当前 xcode-select 仍指向 CommandLineTools，本机完整 App/XCTest 验证限制
  与已有文档一致；之前通过的是 Helper 构建、独立回归和隔离测试。
- `.github/workflows/swift.yml:58` 已配置 swift test，其他工作流也有安装和
  受管连接测试，所以不能把“本机不能完整执行”理解为“项目没有完整 CI 配置”。
  本轮没有查询新的远程运行结果，未将已配置等同于已通过。
- 目前源码中的主要矩阵为 macOS 15/26，缺少 macOS 13/14 的实机覆盖。
  最低部署版本设置不能代替实际安装、授权、连接和卸载测试。
- Wi-Fi/有线切换、休眠唤醒、双栈泄漏及进程异常后的恢复在 QA 中仍是需要
  实机验收的事项。源码审查和回环测试不能证明这些场景全部通过。

## 建议顺序与本次结论的边界

优先优化路由所有权集合/日志重放和守护检查的派生进程；随后减少无变化发布、
重复规则解析及不必要 XPC 建连，再改进停止状态机、历史刷新和更新请求合并。
WAL 批处理和异步停止需要故障注入回归，不能用削弱恢复检查换取性能数字。

这些问题主要直接影响连接/断开/切换耗时、状态响应和能耗。它们值得修复，
但并不能直接证明 GitHub 特定下载慢的根因。前一轮修复解决了原生路由查询
队列积压及失败记录缺失，没有解决本次确认的这些性能热点。
