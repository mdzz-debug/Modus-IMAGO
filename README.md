# M · Imago

macOS 截图与录屏工具，支持多显示器选区、窗口/区域捕获、截图标注、置顶截图和录屏参数控制。

## 本地依赖

当前工程使用同一工作区中的 FormaUI 源码包：

```text
../FormaUI/components/FormaUI
```

FormaUI 仓库：`git@github.com:mdzz-debug/Modus-FormaUI.git`

## 构建

```bash
swift build
zsh scripts/package-app.sh
```

打包结果位于：

```text
.build/M-Imago.app
```

## 朋友版发布

正式发布包继续使用 `Modus App Signing - com.modus.imago` 本地证书签名，接收者需先安装并信任 DMG 中附带的 `Modus Friends Root CA`。

生成 Release 构建、DMG、ZIP 和 SHA-256 校验文件：

```bash
zsh scripts/build-release.sh 0.1.0 1
```

产物位于 `dist/v0.1.0/`。在 GitHub 创建正式 Release，标签必须使用与 App 版本对应的 `v0.1.0`，并上传 DMG、ZIP 和 `SHA256SUMS.txt`。

每次正式发布还需要同步更新 `updates/latest.json` 中的版本、标题和 Release 地址。应用内“通用 → 应用信息 → 检查更新”默认读取最新的正式 GitHub Release；GitHub API 限流时会自动改读该清单，草稿和预发布版本不会提示。

## 诊断日志

运行日志会自动轮换保存在：

```text
~/Library/Application Support/M-Imago/Logs/
```

“通用 → 问题反馈”目前提供日志附带、报告导出和打印机模拟发送交互，不会执行真实网络上传。
