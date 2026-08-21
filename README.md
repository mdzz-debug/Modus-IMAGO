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

## 诊断日志

运行日志会自动轮换保存在：

```text
~/Library/Application Support/M-Imago/Logs/
```

“通用 → 问题反馈”目前提供日志附带、报告导出和打印机模拟发送交互，不会执行真实网络上传。
