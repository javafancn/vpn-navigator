# 原生配置文件入口（0.3.6 / Build 9）

安装包声明 `.ovpn` 文档读取能力（Viewer / Alternate）。可在 Finder 使用“打开方式 → VPN Navigator”，或将文件拖到 Dock 图标/应用主窗口。已有默认应用由系统选择；本应用不主动修改默认关联。文件打开使用 AppKit `application(_:open:)`，冷启动时先暂存请求，等主窗口和配置加载完成。

外部文件入口先显示毛玻璃确认页，只列文件名及被忽略项的数量。此时不读取配置、证书或凭据，不连接 VPN。确认后才调用已有批量导入，可逐项查看成功/失败并取消剩余项。取消确认会丢弃本次待导入列表，原文件不修改。

认证、连接建立/停止、设置页、首次检查、文件选择、维护或已有导入结果窗口期间，请求在内存中等待。已有结果关闭后显示下一次确认；新请求不会替换上一批的结果。确认页中继续打开的文件会追加，同一标准化路径去重，不跟随符号链接判断别名。实际文件与材料验证仍由 ProfileStore 执行。

只接收本机 `file:` URL 的 `.ovpn`，拒绝远端主机、网页 URL、查询/片段/凭据、目录标记和异常过长路径。每次请求最多考察 100 项，待处理有效文件总数最多 100；超限明确计数，需用户另批重试。文件名显示去除控制字符，不显示父目录。尚未确认的请求不写磁盘，退出应用后不会恢复。

拖拽只加载 `public.file-url` 表示，保留原文件位置以便原有相邻证书解析。加载在 drop 回调内立即开始，最多 100 个 provider；按拖拽顺序汇总，3 秒内未响应或出错的项记录为无法取得位置，晚到回调不重复提交。一次加载结束前拒绝第二次拖拽，避免无限累积。拖拽无效项可以关闭确认页后重试。

核心测试覆盖不读取文件的准入、顺序、URL 类型、去重、上限、脱敏文件名、计数与清空。发布 UI 自检调用真实生命周期委托和 AppModel，验证冷启动、首次检查/认证/忙碌延迟、取消无写入、确认后的混合结果、下一请求及真实 NSItemProvider 的乱序/超时。原生工作流注册构建后的应用并查询 Launch Services，再用 `open -a` 冷启动交付真实文档事件、截图确认页。具体通过情况以 PR Actions 为准。

真实 Finder/Dock 手势、用户改变默认关联、iCloud/第三方文件提供方的下载与授权、挂载磁盘权限仍需真机检查。本轮不宣称文件提供方或沙盒分发全场景通过。

Apple 参考：[AppKit 文档事件](https://developer.apple.com/documentation/appkit/nsapplicationdelegate/application(_:open:))、[文档声明](https://developer.apple.com/library/archive/documentation/General/Reference/InfoPlistKeyReference/Articles/CoreFoundationKeys.html)、[SwiftUI drop 时开始加载](https://developer.apple.com/documentation/swiftui/view/ondrop(of:istargeted:perform:)-f15m)。
