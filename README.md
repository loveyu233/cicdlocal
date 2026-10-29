# 本地 CI（LocalCICD）

一个 macOS 原生小工具：在这台 Mac 上 `git push` 成功后，读取推送提交里的 `.local.cicd.yml`，依次执行

1. **测试**：配置里写的命令；
2. **构建推送**：`docker build` + `docker push`，或你自己的构建命令（例如 `make push`）；
3. **替换**：用事先导入的 k8s 连接执行 `kubectl set image`，并等待 `rollout status`。

单个或多个镜像统一使用列表；构建与同批部署分别支持并发上限。每个批次只等待自身引用的镜像推送并核验 digest，已就绪的批次可任选顺序确认，也可同时部署不同服务，不等待其他构建。重新替换使用冻结摘要。新版不兼容旧配置，历史记录保留可查看。

原生三栏窗口与菜单栏提供运行状态、日志、确认替换和快捷操作。项目、连接与记录保存在你的 Mac 上，源码不预装任何项目或集群配置。

**使用前请阅读 [安全说明](SECURITY.md)**：项目命令以当前用户权限执行，只为可信仓库开启监听。示例中的 `example.invalid` 是不可用的占位地址，需要替换成你自己的镜像仓库。

```yaml
test:
  - go vet ./...
  - go test ./...
build:
  images:
    - name: app
      image: registry.example.invalid/cicddemo/cicddemo_go:${TIME}
      dockerfile: Dockerfile
deploy:
  - name: 测试发布
    branches: [dev, main]
    k8s: 测试环境
    targets:
      - {build: app, namespace: demo, deployment: cicddemo, container: cicddemo}
  - name: 正式发布
    branches: [main]
    k8s: 正式环境
    confirm: true
    targets:
      - {build: app, namespace: demo, deployment: cicddemo, container: cicddemo}
```

## 文档

- [使用说明](docs/使用说明.md)：导入 k8s 连接、配置字段、开启推送监听、确认替换。
- [设计](docs/设计.md)：包划分、数据流、数据库表、凭据处理。
- [验收记录](docs/验收记录.md)：已验证的内容和待验证的内容。
- [agents.md](agents.md)：产品定义与开发规范，改动产品行为前先改这里。

## 构建

需要 macOS 27、Xcode（Swift 6.4）、[XcodeGen](https://github.com/yonaskolb/XcodeGen)、Git 2.54 或更高。

```bash
scripts/build.sh              # 生成工程、构建 App、逐包测试
scripts/build.sh --skip-tests # 只构建
scripts/test-packages.sh      # 只跑包测试
scripts/release.sh --local    # 本机使用的 Release 包，产物在 build/releases/
```

当前验证平台为 Apple Silicon；需要完整 Xcode、Python 3 和本机开发签名。没有开发证书时可显式使用临时签名构建：

```bash
LOCALCICD_UI_SIGNING_IDENTITY=- scripts/build.sh --skip-tests
open build/DerivedData/Build/Products/Debug/LocalCICD.app
```

临时签名可能导致重编译后重新请求系统授权。本地构建不会自动发布或公证；正式分发流程见 `scripts/release.sh --help`。公开版标识为 `io.github.loveyu233.cicdlocal`，使用独立数据目录；不会自动读取其他应用标识下的历史项目或凭据。

## 测试与安全检查

```bash
scripts/test-packages.sh
python3 scripts/test-ui-signing.py
python3 scripts/test-source-guards.py
python3 scripts/check-public-source.py
```

完整流程测试需要一个已获授权、名为 `cicddemo` 的测试 Git 仓库，通过 `LOCALCICD_TEST_SOURCE` 提供其绝对路径。脚本只修改 `.test-repos/` 内的隔离副本，用本地裸仓库接收推送，不向真实集群部署：

```bash
export LOCALCICD_TEST_SOURCE="$HOME/Projects/cicddemo"
python3 scripts/test-pushwatch.py
python3 scripts/test-ui.py
python3 scripts/test-cicddemo.py
```

UI 测试使用假 Docker 和假 kubectl；`test-cicddemo.py` 才会执行真实本地镜像构建与回环仓库推送，需要 Docker、Go 和包含对应 Dockerfile 的 cicddemo 项目。源仓库不会随本仓库提供，未指定时集成脚本会拒绝运行。验证范围见 [验收记录](docs/验收记录.md)。

本地脚本检查隐私文件与路径，Gitleaks 用于扫描凭据。可选的 [GitHub Actions 模板](docs/examples/security-workflow.yml) 固定了工具版本与 SHA-256 校验；具有 GitHub `workflow` 权限后，可将它放入 `.github/workflows/` 启用。当前仓库没有启用该工作流。扫描通过不代表不存在未知漏洞。

## 许可

本项目采用 [MIT 许可证](LICENSE)。依赖各自的许可文本见 [第三方许可](THIRD_PARTY_NOTICES.md)。

## 目录

```
App/          界面：Main（三栏主窗口）、Project（项目概览）、Settings（k8s 连接、通用）、Shared
HookHelper/   Git 钩子调用的小程序，只记录推送意图
Packages/     Models · Platform · LogKit · GitKit · Storage · PushWatch · Runner · ApplicationKit
UITests/      原生界面测试
scripts/      构建、发布和验收脚本
docs/         使用说明、设计、验收记录
```
