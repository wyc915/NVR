# NVR app（Flutter）

監控系統的手機 App。同一份程式碼可以編成 Android、iOS 和網頁版。
整體介紹、架構和部署方式請看專案根目錄的 [README](../README.md)。

```bash
flutter pub get
flutter build web --release --no-web-resources-cdn   # 網頁版（iPhone Safari），由 server 在 / 提供
flutter build apk --release --split-per-abi          # Android
flutter analyze
```

| 目錄 | 內容 |
|---|---|
| `lib/core/` | 伺服器設定（secure storage）、REST client 與簽章網址、資料模型、格式化 |
| `lib/state/` | Riverpod 狀態：伺服器狀態 + WebSocket 事件、錄影/截圖分頁列表、UI 狀態（靜音、全螢幕） |
| `lib/features/live/` | 即時畫面：WebRTC (WHEP) 連線、自動重連、靜音、全螢幕、錄影/截圖/畫質控制 |
| `lib/features/recordings/` | 錄影列表與播放 |
| `lib/features/snapshots/` | 截圖格狀列表與檢視（可縮放） |
| `lib/features/setup/` | 伺服器位址與 token 設定 |
