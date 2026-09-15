# GlobalFPSOverlay 0.2.0 — FPS + Wi‑Fi 网速状态栏版

适配当前测试环境：

- iPad Pro 2018 / A12X（arm64e）
- iPadOS 13.7
- Odyssey / libhooker / MobileSubstrate 兼容注入
- iOS 13.7 SDK + clang10 old-arm64e 工具链

## 0.2.0 改动

1. 在 FPS 后新增实时 Wi‑Fi 吞吐显示：

   `FPS 118/120   WiFi ↓12.4M ↑1.1M`

   - `↓`：当前 Wi‑Fi 接收速率（下载）
   - `↑`：当前 Wi‑Fi 发送速率（上传）
   - `M/K/B`：MiB/s、KiB/s、B/s 的紧凑显示
   - 每约 0.5 秒采样一次，并做轻微平滑

2. 显示条移动到最顶部的状态栏区域。

3. 横向位置以屏幕宽度的 **80%（4/5 分界点）** 为中心锚点；横竖屏都会重新定位。

4. 不拦截触摸；不强制 60/120Hz；FPS 仍然只是当前前台 UIKit App 主进程的 CADisplayLink 回调频率。

5. 继续排除 SpringBoard，避免再次出现两个重复框。

## 关于 Wi‑Fi 网速

本版读取 iOS 的 Wi‑Fi 接口 `en0` 的累计收发字节，并计算两次采样之间的速率。

因此显示的是 **整台设备当前 Wi‑Fi 接口的总吞吐**，不是“当前 App 自己”的网络速度。若有后台下载、系统同步等，它们也会计入。

若当前没有可用的 `en0` Wi‑Fi 接口，会显示：

`WiFi ↓-- ↑--`

## 编译

继续使用仓库自带 GitHub Actions，或：

```bash
make clean package FINALPACKAGE=1 messages=yes
```

输出应为：

`com.chatgpt.globalfpsoverlay_0.2.0_iphoneos-arm.deb`

## 安装

```bash
dpkg -i /var/mobile/Media/Downloads/com.chatgpt.globalfpsoverlay_0.2.0_iphoneos-arm.deb
```

然后 Respring，并彻底重开正在测试的 App。

## 备注

状态栏隐藏的全屏 App 中，iOS 可能返回高度为 0 的 status bar frame。本版仍把监视器固定在物理屏幕最上沿 20pt 区域，避免自动下移到普通 App 内容区域。
