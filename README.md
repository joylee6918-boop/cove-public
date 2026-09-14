# Cove

原生 SwiftUI iPhone 聊天客户端，搭配自托管 Python 后端与 Codex app-server。包含聊天、Markdown、附件、可导入的表情包、订阅用量展示，以及需要明确授权的 HealthKit 汇总同步。

这是独立整理的公开源码快照，不包含维护者的私人服务器、账号、配对密钥、聊天/健康记录或原仓库历史。界面预览和测试数据均为示例。

**不是下载后就能使用的公共聊天服务，也不是多人 SaaS。每位使用者应部署自己的独立后端。**

## 获取与运行

```sh
git clone https://github.com/joylee6918-boop/cove-public.git
cd cove-public
```

### iOS

- iOS 18 或更新版本；当前工程使用 Xcode 26.5 验证构建。
- 打开 `ios/Cove.xcodeproj`，选择 `Cove` scheme。首次构建需要下载锁定版本的 Swift Package 依赖。
- 模拟器可使用设置里的示例预览，不必配置真实账号或服务器。
- 真机安装前，将 `ios/project.yml` 中的 `com.example.cove` 及测试 Bundle ID 改为自己的唯一标识，填自己的 Development Team，再运行 `xcodegen generate --spec ios/project.yml`。
- HealthKit、Push Notifications 需要相应签名与能力配置；不要使用维护者的签名身份。APNs 推送还需要自己的服务端密钥，授权通知不代表已接通推送。

### 后端

1. 准备 Python 3.9+、已安装并完成主机端登录的 Codex CLI，以及独立的助手工作目录。模型权限与额度取决于你自己的账号，仓库不提供模型账号。
2. 复制 `server/.env.example` 为 `server/.env`，生成独立随机 `COVE_TOKEN`，设置工作目录和数据目录。示例值不是可用的生产配置。
3. 在本机或自己的服务器启动：

```sh
cd server
chmod 600 .env
set -a
. ./.env
set +a
python3 cove.py
```

4. 为默认的 `127.0.0.1:8796` 配置自己的 HTTPS 反向代理，再在 App 设置中填写你的 HTTPS 地址与 `COVE_TOKEN`。不要把普通模型 API 地址当作 Cove 后端地址。

后端部署细节见 [server/README.md](server/README.md)，接口见 [docs/CONTRACT.md](docs/CONTRACT.md)。主机端 Codex 版本需支持此项目使用的 app-server 接口；第三方账号/模型兼容性并非保证。

## 安全边界

- 一个后端实例对应一个信任主体；同一配对密钥能访问该实例的会话、附件、共享健康信息及终端控制。**没有多用户权限隔离，不要把自己的密钥发给别人。**
- 保留默认 `read-only` sandbox 与 `on-request` 审批，使用专用低权限系统用户；聊天指令可能触发主机上的模型工具操作。
- `.gitignore` 排除了私有连接文件、环境文件、数据库、签名密钥与构建产物，但不能清除已经提交的秘密；泄露时先吊销/轮换，再处理历史。
- 健康功能默认需要主动授权；不用于诊断。关闭/删除 Cove 共享数据不等于删除 Apple Health、历史模型上下文或备份。
- 此快照未经过独立安全审计；生产使用前应自行审查、限制访问并配置备份。

## 测试

```sh
cd server
python3 -m unittest discover -v
```

iOS 单元测试位于 `ios/CoveTests`，界面测试位于 `ios/CoveUITests`。模拟器示例不能证明真实模型、HealthKit 后台同步或 APNs 已工作。

## 许可

本仓库尚未指定项目级开源许可证，不应把源码公开理解为自动授予任意再分发或商用授权。第三方依赖保留各自许可证，见 [第三方声明](docs/THIRD_PARTY_NOTICES.md)。
