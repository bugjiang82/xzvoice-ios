# XZVoice — ESP32-S3 录音助手 iOS 端

通过 BLE 连接 XZ-Voice 开发板（Nordic UART Service），接收 ADPCM 分段录音并转 WAV 播放。

## 结构
- `XZVoice/BLEManager.swift` — CoreBluetooth 中心设备 + 协议重组 + 吞吐统计
- `XZVoice/ADPCM.swift` — IMA ADPCM 解码（与固件 adpcm.py 对应）+ WAV 封装
- `XZVoice/ContentView.swift` — 主界面（连接/统计/控制/段列表/日志）+ 设置页（API Key）
- `XZVoice.xcodeproj` — Xcode 16 同步文件夹工程

## 构建（无 Mac）
```
builder ios build   # 触发 GitHub Actions macOS runner，IPA 输出到 ./dist/
```

## 协议
见固件仓库 `firmware/ble_nus.py`。API Key 一律运行时填写，不入库。
