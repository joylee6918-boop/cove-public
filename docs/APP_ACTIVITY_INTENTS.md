# 原生 App 活动记录（可选配置）

系统Shortcuts的打开/关闭App自动化 → Cove「记录 App 活动」App Intent → 本机持久队列 → 配置好的接收端。
这不是系统Screen Time、当前前台应用检测或已有历史导入。自动化须用户亲自建立；录制默认关闭。

## 配置

1. 自行构建签名安装；家 → App使用 → 自动记录与双端同步，配置一个或两个接收端。
2. 每个接收端填写自己的HTTPS基址和**独立写入专用密钥**，不要复用owner聊天/读取密钥。
   凭据仅在本机Keychain保存，不写进源码、快捷指令、事件或日志。
3. 配置Shortcuts打开/关闭触发器，明确选择App与动作；先用一个App验证，再增加其他触发器。
   支持微信、抖音、淘宝、ChatGPT、Cove、CCC、Safari、小红书；不会猜触发器对应的应用。
4. 若更改签名Bundle命名空间，同步修改 `CoveActivityRecorder` 的session/task ID与Info.plist的BGTask标识。

Cove接收端：`POST <base>/v1/app-events/queued`，使用 `COVE_SHORTCUTS_TOKEN`。
可选第二接收端：`POST <base>/integrations/app-events/queued`，需要自行提供兼容CCC协议的服务。
**该外部后端不包含在本仓库，也不提供公共接收地址或凭据。** 不启用它不会阻止Cove独立记录。

## 行为与边界

- Intent不拉起界面，不等待HTTP；先原子保存原UUID、App、动作、执行时刻。暂停时不记录；本地存储失败如实报错。
- 两端单独ACK/重试/错误状态。一端失败不阻塞另一端；开启接收端不补发启用前事件，改址不误投已有待传。
- HTTP200还要收到 `ok=true`、原ID、布尔duplicate才确认。未知结果重试原ID，400/409保留拒绝记录，401/403/404暂停该接收端。
- 文件锁、受保护原子文件、0700/0600、排除备份。重启首次解锁前不保证写入；队列上限10000，满或损坏不静默丢记录。
- 默认关闭；暂停保留待传。明确放弃待传不删除服务器历史。预览不记录/上传真实活动。
- 后台URLSession与BGProcessingTask按系统调度，30/120/600/1800/3600秒有界退避；不承诺锁屏、强退或离线时实时送达。
- 无额外模型调用、通知或聊天记录。缺失/未结束事件不推断使用时长。

## 后端协议

独立Bearer写入凭据，最多2KiB，严格四字段：

```json
{"id":"00000000-0000-4000-8000-000000000001","app":"Safari","action":"open","timestamp":"2026-11-04T12:00:00Z"}
```

示例是合成协议演示，不要作为真实活动上传。queued入口接收配置之后、过去最多7天/未来最多60秒的事件。
幂等检查先于时效检查，原ID丢ACK可恢复；同ID不同内容409。旧 `/v1/app-events` 保持10分钟限制。
仅queued路径归一化 `WeChat→微信`、`rednote→小红书`，不改旧记录身份。

合成回归：`server/test_queued_app_events.py` 和 `tests/swift/AppActivityQueueChecks.swift`。
真实自动化触发、锁屏/离线恢复、第二接收端和设备签名能力需操作者单独验收。
