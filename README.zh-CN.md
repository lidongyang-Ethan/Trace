# Trace

[English](README.md) | **简体中文**

一个基于 Alamofire `EventMonitor` 的 iOS 网络诊断面板。当前为 **0.1.1 开发预览版**，通过 Swift Package Manager 分发。Swift Package Index 收录需等待其审核。

## 现在可以做什么

- 请求列表、域名 / 路径搜索、失败 / 慢请求筛选、暂停、清空。
- 请求与响应头、受限 JSON 正文、HTTP 校验错误、网络错误。
- `DecodingError` 的字段路径与预期类型；不记录可能泄露正文的原始错误描述。
- 按字段脱敏、内存记录数量限制、单条正文与全局正文预算。
- 报告预览与系统分享；默认仅内存保存。
- 本地模拟响应示例：成功、401、JSON 解码失败、超时；请求真实经过 Alamofire，不访问服务器。

## 环境

- 当前验证工具链：Xcode 27、Swift 6.4。
- 项目使用 Swift 6 语言模式；依赖 Alamofire **5.12.2**（该版本要求 Swift 6.4）。
- iOS 16+；包另声明 macOS 13+ 供本机测试和复用，macOS UI 尚未做交互验收。
- 模拟器运行不需要付费开发者账号。

## 先运行示例

1. 用 Xcode 打开 `Examples/TraceExample/TraceExample.xcodeproj`。
2. 等待 Swift Package Manager 解析 Alamofire 依赖（首次需要网络）。
3. 选择 **TraceExample** scheme、**Debug** 配置及一个 iPhone 模拟器，然后运行。
4. 首次打开自动发出一组本地模拟请求；点“再发一组”可重新生成。
5. 打开 `/v1/feed`，查看 `items[2].title` 的解析失败。
6. 打开登录请求，确认请求密码及响应 accessToken 已隐藏。

请打开示例 `.xcodeproj` 来运行 App；直接打开仓库根目录只会显示 Swift 包的库 scheme。

Release 示例不创建诊断对象和界面。真机运行需要在 Signing & Capabilities 里选择自己的 Team，并修改 Bundle Identifier（如有冲突）。

## 语言

界面、诊断说明与分享报告支持中文和英文，随系统的首选支持语言选择；其他语言回退到英文。中文目前使用简体文案。切换系统语言后重新启动 App 即可生效，无需在面板里手动选择。

开发时可在 Xcode 的 Edit Scheme → Run → Options → App Language 中选择中文或英文进行验证；验收后改回 System Language。

## 在自己的项目里集成

在 Xcode 中选择 **File → Add Package Dependencies…**，输入：

```text
https://github.com/lidongyang-Ethan/Trace.git
```

选择 **0.1.1** 或 0.1 系列的后续版本，添加 `TraceAlamofire` 与 `TraceUI` 产品。宿主项目也需要直接依赖 Alamofire。

使用 `Package.swift` 时添加：

```swift
.package(url: "https://github.com/lidongyang-Ethan/Trace.git", .upToNextMinor(from: "0.1.1"))
```

本地开发仍可通过 Xcode 的 **Add Local…** 添加本仓库根目录。

```swift
import Alamofire
#if DEBUG
import TraceAlamofire
import TraceUI
#endif

// 在合适的长期持有对象中创建；不要每发一个请求就新建 Session。
#if DEBUG
let diagnostics = NetworkDiagnostics()
let session = Session(eventMonitors: [diagnostics.monitor])
#else
let session = Session()
#endif
```

在宿主的调试入口展示：

```swift
#if DEBUG
NetworkDiagnosticsView(store: diagnostics.store)
#endif
```

面板拥有自己的 NavigationStack，适合放在 sheet 中。必须使用配置了 monitor 的 Session；不会自动监听 `AF.request`、其他 Session 或其他网络库。

## 目录

```text
Sources/TraceCore        记录模型、脱敏、有界存储、报告
Sources/TraceAlamofire   Alamofire 事件适配、错误分类
Sources/TraceUI          SwiftUI 列表、详情、设置与分享
Tests/                  核心测试与 URLProtocol 集成测试
Examples/TraceExample   可运行的 iOS 示例工程
Documentation/          设计、学习与验证记录
```

## 测试

```sh
swift test
```

测试通过自定义 URLProtocol 提供确定性响应，不依赖外部接口。覆盖敏感信息脱敏、正文省略、暂停 / 清空、容量、并发、HTTP 与解码错误、取消、超时、重试，以及中英文资源与语言回退。

每次提交 PR、推送到 main 或推送数字开头的版本标签时，GitHub Actions 都会运行包测试，并选取具体的 iPhone 模拟器构建 Debug 示例。发布 Release 前，请确认标签指向的提交已通过 **Trace CI**。

## 当前边界

- 仅支持普通 Alamofire DataRequest；上传、下载、流式请求暂不记录。
- HTTP 错误指 Alamofire 配置的校验失败。未调用 `.validate()` 的 4xx 响应不一定是客户端处理失败。
- 多个响应解析器共用一条记录：记录任意已观察到的失败。重试开始后清除上次结果，最后一次尝试决定新结果；暂不保留逐次尝试明细。
- 当前总耗时包含排队、重试与观察到的解析处理时间；尚未展示 DNS / TLS / TTFB 指标。
- 只保存可解析、可按字段脱敏的 JSON。非 JSON、损坏 JSON、超限正文均省略，不截取原始内容冒充安全结果。
- 默认隐藏认证 / Cookie 头和 password、token、accessToken、refreshToken、email、apiKey、secret、signature 字段（不区分大小写）。可通过配置增加字段；自由文本和 URL 路径中的个人信息无法自动保证脱敏。
- 详情和报告预览每 250ms 刷新；清空、设置变更或容量淘汰后，不再回退显示旧记录。已交给系统分享界面的报告无法撤回。
- 设置改变会清空已有记录。外部调用方已取得的值类型快照不能被追溯撤回。
- 正文预算不等于整个进程内存上限。Alamofire 仍会持有其请求数据；当前没有事件队列背压机制，未做极端并发性能验收。
- 列表每 250ms 拉取一次快照，避免每个回调都刷新 UI；后续可根据性能测量改为合并通知。
- 工程尚无正式 App 图标和商店材料；这是开发工具包与示例，不是已提交商店的产品。

## 下一步

先读 `Documentation/第一课.md`。先跑通并理解一条请求，再逐步优化；不要同时扩充所有能力。
