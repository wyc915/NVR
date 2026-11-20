# NVR app（Flutter）

監控系統的手機 App。同一份程式碼可以編成 Android、iOS 和網頁版。
整體介紹、架構和部署方式請看專案根目錄的 [README](../README.md)。

```bash
flutter pub get
../scripts/build-web.ps1   # 網頁版（iPhone Safari），由 server 在 / 提供；帶版本號，開著的 App 會自動更新
flutter build apk --release --split-per-abi          # Android
flutter analyze
```

| 目錄 | 內容 |
|---|---|
| `lib/core/` | 伺服器設定（secure storage）、REST client 與簽章網址、資料模型、格式化、Passkey 與分享（網頁版，搭配 `web/passkey.js`） |
| `lib/state/` | Riverpod 狀態：伺服器狀態 + WebSocket 事件、錄影/截圖分頁列表、UI 狀態（靜音、全螢幕） |
| `lib/features/live/` | 即時畫面：WebRTC (WHEP) 連線、自動重連、靜音、全螢幕、雙指放大、錄影（可定時）/截圖/畫質控制 |
| `lib/features/recordings/` | 錄影列表（星號、日期跳轉、多選刪除）與播放 |
| `lib/features/snapshots/` | 截圖格狀列表與檢視（可縮放） |
| `lib/features/setup/` | 登入：Face ID / 配對碼（網頁版）、伺服器位址與 token（Android） |
| `lib/features/settings/` | 設定：裝置管理、配對碼、登入紀錄、系統狀態 |
| `lib/widgets/` | 共用元件（分頁捲動、存到照片） |
