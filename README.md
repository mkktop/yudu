# 雨读 Yudu

SwiftUI 原生漫画阅读器，支持本地 ZIP / CBZ / PDF、散图文件夹、WebDAV / NAS 和天翼云盘。

Orbital 改版以深空背景、冷青交互与轨道几何统一书架、书库、作品详情、阅读器、统计和设置。已有书库与阅读记录继续使用。

![Orbital 设计参考，使用示例数据](docs/orbital-overview.png)

- [完整设计与功能说明](docs/design.md)
- [离线设计预览](docs/orbital-preview.html)：下载后用浏览器打开，可切换深浅模式与示例筛选。
- 原生运行截图：查看 GitHub Actions 的 `simulator-screenshots` artifact。上图为设计参考，非运行截图。

用 Xcode 打开 `yudu.xcodeproj`，选择 iPhone / iPad 模拟器运行。发行目标为 iOS 18。真机运行需要配置自己的签名团队。

[构建与回归检查步骤](docs/design.md#实现与验证)包含 SwiftData 逻辑检查和离线模拟器阅读流程。应用运行不依赖第三方库。
