# Cove

原生 SwiftUI iPhone / iPad 助手客户端，搭配**你自己部署**的 Python 后端与 Codex app-server。五个页面：家 · 心跳 · 对话 · 健康 · 设置。

**公开源码快照更新：2026-10-29，客户端功能基线 Build 79。** 这是独立脱敏的源码版本，不包含维护者的私人服务器、人格/记忆文件、账号、签名身份或运行数据；不等同于 App Store / TestFlight 发行版。

> **不是开箱即用的公共聊天服务，也不是多人 SaaS。**
> 一个后端实例只服务一个信任主体。部分页面是 **Developer-only** 的集成入口，需要额外服务、账号、硬件或代码适配；看见按钮不代表可以直接使用。详见 [功能分级与开发者集成](docs/DEVELOPER_FEATURES.md)。

## 这次更新

- **聊天记录**：搜索全部可见对话、按月/按日期浏览、每日准确条数（不截成 `99+`）、本月消息总数；关键词过滤、分页、结果与正文高亮、定位原消息、清除筛选和返回当前聊天。
- **聊天体验**：本机缓存、增量恢复、连续发送、耐久附件 outbox、长历史有界渲染、Markdown / 代码 / 文件预览、引用、收藏式点赞、独立表情库、通知与已读状态。搜索和键盘变化不应强行把阅读位置拉回底部。
- **媒体与界面**：语音录制、语音气泡/波形/拖动播放，原生 inline widget，浅深色与系统界面适配。模型能否理解音频取决于已配置的分析能力，不能把转写当成原生听音。
- **生活页面**：健身记录与个人账本；个人账本与助手的虚拟钱包是两套独立数据。健康/生活数据的持续授权需要用户在手机端明确开启。
- **可选后端能力**：手机系统动作、Apple WeatherKit、App 打开/关闭事件、上下文续接、公开 `little thoughts` 附言。还有供开发者接入的 Pulse / Ombre / Collar / BLE / 旅行 / 实验终端适配器。

完整变更及验证边界见 [CHANGELOG](CHANGELOG.md)。

## 功能分级速览

| 分级 | 功能 | 能否直接用 |
|---|---|---|
| 核心自托管 | 聊天、历史搜索/计数、Markdown、附件、表情、增量恢复、原生 widget、上下文状态 | 配置自己的 Cove 后端和可用 Codex 账号后使用 |
| 手机本地 | 健身与个人账本编辑、语音录制/播放、主题、示例预览 | 需自行构建安装及相应 iOS 权限；不会自带私人记录 |
| 可选配置 | APNs、HealthKit、日历/提醒/AlarmKit、快捷指令事件、WeatherKit、付费 TTS | 需自己的 Apple 能力/凭据或供应商配置；未配置不可用 |
| **Developer-only** | Pulse 主动唤醒、Ombre 记忆/叙事池、Collar Watch、特定 BLE 硬件、旅行与图片服务、实时语音、实验 tmux/Shell | **需要开发、独立服务或硬件验收，不是完整的一键发行功能** |

Developer-only 是支持范围标记，不是一个秘密解锁开关，也不代替鉴权和用户授权。

## 获取与构建

```sh
git clone https://github.com/joylee6918-boop/cove-public.git
cd cove-public
```

### iOS

- 当前快照目标 **iOS 27.0+、Xcode 27**。它不再是最初快照的 iOS 18 / Xcode 26.5 兼容承诺；低版本需要自行回移相关 API。
- 打开 `ios/Cove.xcodeproj`，选择 `Cove` scheme。依赖版本在 `ios/project.yml` 和 `Package.resolved` 中固定。
- 无服务器时可在设置中开启明确标注的**示例预览**；示例不上传到真实服务。
- 真机安装前，把 `ios/project.yml` 中 `com.example.cove` 和测试 Bundle ID 改为自己的唯一标识，填写自己的 Development Team，然后执行：

```sh
xcodegen generate --spec ios/project.yml
```

- 公共工程**没有维护者的 Team ID、profile、APNs key 或配对配置**。需要你自己的签名；HealthKit / Push / AlarmKit 等能力还取决于 Apple 账号和系统授权。
- 模拟器无签名编译示例（不等于真机或真实服务验收）：

```sh
xcodebuild -project ios/Cove.xcodeproj -scheme Cove \
  -destination 'generic/platform=iOS Simulator' CODE_SIGNING_ALLOWED=NO build
```

### 后端

1. 使用 **Python 3.12+**、支持相应 app-server 协议的 Codex CLI，以及独立低权限系统用户和工作目录。
2. 在该用户的独立 `CODEX_HOME` 中完成你自己的登录。不要复用其他助手正在使用的 session、身份目录或包含不相关 MCP 的配置。
3. 复制 `server/.env.example` 为 `server/.env`，生成自己的随机 `COVE_TOKEN`，填写真实工作目录；按需设置账号实际支持的模型。示例 token 不是生产密钥。
4. 启动：

```sh
cd server
chmod 600 .env
set -a
. ./.env
set +a
python3 cove.py
```

5. 为默认 `127.0.0.1:8796` 配置自己的 HTTPS 反向代理。在 App 设置填写 **Cove 服务地址**及同一 `COVE_TOKEN`；不是模型 API 地址。

[后端配置与升级](server/README.md) · [接口与数据约定](docs/CONTRACT.md) · [Developer-only 依赖表](docs/DEVELOPER_FEATURES.md)

## 安全和数据边界

- **单用户实例，无多租户隔离。** 同一个 owner token 可访问该实例的聊天、附件、共享生活数据、钱包及终端控制；不要分享 token，也不要公开裸端口。
- 默认保持 `read-only` sandbox 和 `on-request` 审批。`never` / `danger-full-access` 是更宽的操作者选择，不是此仓库建议的部署方式。模型工具最终受运行它的系统账户权限约束。
- HealthKit 读取、向后端共享、持续授权、主动硬件测量是不同的动作。持续生活数据权限可能包含账本代记；不是银行支付权限。关闭授权不会自动删除历史对话、备份或已经上传的副本。
- `little thoughts` 是同一次响应中**明确供用户阅读的附言**，不是隐藏思维链；原始 reasoning 不作为聊天内容发布。
- 密钥、登录文件、聊天/健康/财务库、截图、录音、个人声线、人格文件、部署交接、签名导出均不在公开发布范围。`.gitignore` 不会补救已经提交的秘密；泄露时先吊销/轮换，再处理历史。
- 这是维护者整理的脱敏快照，**不是独立安全审计认证**。生产使用前自行审查、配置访问控制与备份；更新前备份自己的数据并检查协议差异。

## 测试

```sh
cd server
python3 -m unittest discover -v
```

默认测试使用临时库、合成记录和 fake app-server，不应调用真实模型、APNs、付费 TTS 或读取个人数据。依赖加密库的 WeatherKit 测试需要安装 `server/requirements-apns.txt`；原生 CLI 的实验测试默认因未配置专用测试二进制而跳过。

iOS 测试在 `ios/CoveTests` 和 `ios/CoveUITests`。音频 fixture 是重新生成的 5 秒电子音加静音段，**不是任何人的录音**。真实 HealthKit、蓝牙、通知、模型和外部服务的可用性必须在你自己的环境验证。

## 许可

本仓库仍**没有项目级开源许可证**；源码公开不自动授予任意再分发或商用授权。本次更新不改变这个事实。第三方代码/依赖保留其原始许可，见 [第三方声明](docs/THIRD_PARTY_NOTICES.md)。
