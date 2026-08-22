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
.build/M · Imago.app
```

## 朋友版发布

正式发布包继续使用 `Modus App Signing - com.modus.imago` 本地证书签名，接收者需先安装并信任 DMG 中附带的 `Modus Friends Root CA`。

生成 Release 构建、DMG、ZIP 和 SHA-256 校验文件：

```bash
zsh scripts/build-release.sh 0.1.0 1
```

产物位于 `dist/v0.1.0/`。在 GitHub 创建正式 Release，标签必须使用与 App 版本对应的 `v0.1.0`，并上传 DMG、ZIP 和 `SHA256SUMS.txt`。

从 `0.1.1` 起应用使用 Sparkle 2 自动更新。通用面板可以启用“每天自动检查更新”；发现新版本后会在应用内显示版本说明、下载进度，并自动替换应用后重新启动。

发布前先更新 `updates/release-notes.md`，然后执行构建脚本。脚本会使用登录钥匙串中账号 `com.modus.imago` 的 Sparkle EdDSA 私钥签名 ZIP，并生成及同步 `updates/appcast.xml`。私钥只保存在本机钥匙串，禁止导出或提交到仓库。

构建完成后，先提交并推送更新后的 `updates/appcast.xml`，再创建对应 Tag 和正式 Release，上传 DMG、ZIP、`appcast.xml` 与 `SHA256SUMS.txt`。`0.1.0` 用户需要手动安装一次 `0.1.1`；此后的版本可以直接在应用内更新。

## 诊断日志

运行日志会自动轮换保存在：

```text
~/Library/Application Support/M-Imago/Logs/
```

“通用 → 问题反馈”目前提供日志附带、报告导出和打印机模拟发送交互，不会执行真实网络上传。
