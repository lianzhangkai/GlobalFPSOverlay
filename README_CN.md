# GlobalFPSOverlay 0.1.1

适用于越狱 iOS/iPadOS 13.x 的轻量全局 FPS 浮窗测试版。

## 它显示什么

右上角显示：

```text
FPS 119.8 | MAX 120
```

- `FPS`：当前前台 UIKit 进程里 `CADisplayLink` 的实际回调频率，0.5 秒采样并做轻度平滑。
- `MAX`：`UIScreen.maximumFramesPerSecond`，例如 iPad Pro 2018 应显示 120。

## 很重要的限制

这不是 GPU/RenderServer 的“最终 present 帧率”。它测的是当前 App 主进程的 DisplayLink / 主 RunLoop 显示节奏。

因此：

- 如果显示 `FPS ~60 | MAX 120`，基本可以判断当前 App/当前运行状态没有跑满 120Hz。
- 如果显示 `FPS ~120 | MAX 120`，只能说明 App 主进程的显示回调能到 120Hz；某个具体内容（例如 B 站弹幕、视频画面）仍然可能只按 60fps 或 30fps 更新。
- 这个 Probe 自己创建了一个非常轻量的 CADisplayLink，所以它会对显示系统产生极小扰动。它适合判断 30/60/120 档位，不适合作为精密 GPU profiler。

## 注入范围

`GlobalFPSOverlay.plist` 使用 `com.apple.UIKit` 过滤，因此会进入 UIKit App 和 SpringBoard；代码内部会跳过 `.appex`、WebContent/Networking/GPU 等辅助进程。

## iPad Pro 2018 建议测试

先确认：

`设置 → 辅助功能 → 动态效果 → 限制帧速率` 为关闭。

然后观察：

1. SpringBoard 快速翻页。
2. 设置 App 快速滚动。
3. B 站首页滚动。
4. B 站视频播放页 + 弹幕。
5. Safari 滚动网页。
6. APlayer。

如果系统界面接近 120，而 B 站稳定在 60，就很有价值；如果 B 站显示 120 但弹幕仍有明显拖影，则下一步应单独研究弹幕动画更新频率，而不是屏幕刷新率。

## 编译

本工程已经包含 GitHub Actions，继续使用之前 iOS 13.7 + clang 10 old-arm64e 环境即可。

本地 Theos：

```bash
make clean package FINALPACKAGE=1 messages=yes
```

生成：

```text
packages/com.chatgpt.globalfpsoverlay_0.1.1_iphoneos-arm.deb
```

## 安装

```bash
dpkg -i com.chatgpt.globalfpsoverlay_0.1.1_iphoneos-arm.deb
```

然后 Respring。卸载包即可完全关闭浮窗。


## 0.1.1 修复

- 不再在 SpringBoard 创建高层级 FPS 窗口，避免进入 App 后同时出现 SpringBoard 与 App 两个 FPS 框。
- 仍然在普通 UIKit App 内显示其本进程 CADisplayLink FPS。
- 因此主屏幕桌面暂时不显示 FPS；这是为了保证前台 App 只有一个且测量对象准确。
