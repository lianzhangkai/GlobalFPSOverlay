# GlobalFPSOverlay 0.2.1 CompactStatusBar

基于 0.2.0 的日用版，只改显示层，不改 FPS / Wi-Fi 统计逻辑。

## 变化

- 显示文字压缩为：`118/120  ↓12.4M ↑1.1M`
- 背景 alpha 从 0.42 降到 0.18，更透明，减少遮挡弹幕
- 背景宽度完全跟随当前文字长度，不再设置 205pt 的最小宽度
- 左右 padding 约 5pt，圆角 5pt
- 位置仍然锚定屏幕宽度 80% 附近
- 仍然排除 SpringBoard，避免重复 Overlay
- Wi-Fi 仍统计 `en0` 全机流量，单位为 Bytes/s

## 编译

```bash
make clean package FINALPACKAGE=1 messages=yes
```

目标环境：iPadOS 13.7 / arm64 + arm64e / Odyssey + libhooker。
