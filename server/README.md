# NVR server（電腦端控制服務）

Node.js + TypeScript 寫的背景服務，負責：

- 啟動並監控 **MediaMTX**（串流伺服器）和 **FFmpeg**（鏡頭擷取 + NVENC 編碼），掛掉會自動重啟
- 手動錄影（MP4：H.264 + AAC，手機可以直接播放）
- 截圖（JPG + 縮圖）
- REST API + WebSocket 即時事件，給手機 App 使用

```
USB 鏡頭 ─► FFmpeg(capture) ─RTSP─► MediaMTX ─WebRTC─► App 即時畫面
                                       │
                                       ├─RTSP─► FFmpeg(recorder) ─► storage/recordings/*.mp4
                                       └─RTSP─► FFmpeg(snapshot) ─► storage/snapshots/*.jpg
Node 服務：管理上面所有程序 + SQLite 索引 + API (:8080)
```

## 執行

```bash
npm install      # 第一次
npm start        # 啟動（Ctrl+C 會正常結束，錄影中會先存檔）
npm run dev      # 開發模式，改程式自動重啟
npm run typecheck
```

第一次啟動會從 `config.example.json` 產生 `config.json`，並隨機產生 API token。
**token 只存在 `config.json`，請不要分享這個檔案。**

## 設定（config.json）

| 欄位 | 說明 |
|---|---|
| `port` | API 埠，預設 8080 |
| `token` | API 金鑰，App 要帶這個 |
| `camera.video` / `camera.audio` | DirectShow 裝置名稱（`ffmpeg -list_devices true -f dshow -i dummy` 可列出）。`audio` 設成 `null` 就不收音 |
| `camera.encoder` | `nvenc`（GPU）或 `x264`（CPU） |
| `camera.defaultPreset` | 第一次啟動的畫質，之後會記住 App 最後選的 |
| `recording.maxSegmentMinutes` | 單一錄影檔最長幾分鐘，超過自動接下一個檔案 |
| `storageDir` | 錄影、截圖、資料庫存放位置 |

畫質預設在 `src/config.ts` 的 `PRESETS`：

| 預設 | 解析度 | fps | 位元率 |
|---|---|---|---|
| `1080p` | 1920×1080 | 30 | 4 Mbps |
| `720p` | 1280×720 | 15 | 1.2 Mbps |

## 安全性

| 防護 | 說明 |
|---|---|
| 網路白名單 | 只接受本機、`allowedNetworks` 內的網段（預設：Tailscale `100.64.0.0/10`、`fd7a:115c:a1e0::/48` 和私人區網）。其他來源一律 403 |
| API 驗證 | `Authorization: Bearer <token>`，比對使用 timing-safe compare |
| 簽章網址 | 圖片、影片、WebSocket 無法帶 Header，改用 `?exp=&sig=`（HMAC-SHA256，綁定單一路徑、只限 GET、最長 24 小時）。**token 永遠不會出現在網址裡** |
| 暴力破解防護 | 同一 IP 10 分鐘內失敗 10 次，封鎖 15 分鐘（回 429） |
| 即時串流 | MediaMTX 透過 `authMethod: http` 交由本服務 `/internal/mediamtx/auth` 驗證。本機程序可推流和讀取；遠端只能**讀取** `cam`，而且必須帶 token。RTSP 和 MediaMTX API 只綁定 `127.0.0.1` |
| HTTPS / 代理 | iPhone 經 `tailscale serve`（HTTPS）連進來；只信任來自本機的 `X-Forwarded-For`，白名單和封鎖機制看到的是手機真實的 Tailscale IP |
| 同源 | 網頁版由本服務直接提供，不開 CORS |
| 錯誤訊息 | 5xx 錯誤只回 `internal error`，詳細內容只寫進 log |
| 回應標頭 | `X-Content-Type-Options: nosniff`、`Referrer-Policy: no-referrer`、`X-Frame-Options: DENY` |
| 資源限制 | 同一時間只執行一個截圖；WebSocket 訊息上限 1 KB |

**部署建議：** 裝好 Tailscale 後，把 `allowedNetworks` 裡的私人區網（`192.168.*`、`10.*`、`172.16.*`）移除，
讓所有連線都經過加密的 Tailscale。區網內的 HTTP 是明文，同一個 Wi-Fi 的其他裝置可以側錄。

## API

除了 `/health` 之外都要驗證：Header `Authorization: Bearer <token>`；
媒體檔案、縮圖和 WebSocket 也可以用簽章網址（見上方「安全性」，App 端實作在 `app/lib/core/api.dart`）。

| 方法 | 路徑 | 說明 |
|---|---|---|
| GET | `/health` | 存活檢查（不需 token） |
| GET | `/api/status` | 鏡頭是否在線、目前畫質、錄影狀態、硬碟空間、即時串流資訊 |
| POST | `/api/stream/preset` | 切換畫質，body：`{"preset":"1080p"}`。即時畫面會斷約 1–2 秒；錄影中會自動切成新檔 |
| POST | `/api/record/start` | 開始錄影 |
| POST | `/api/record/stop` | 停止錄影（檔案會在幾秒內整理好，完成時推送 `recording.saved`） |
| GET | `/api/recordings?limit=50&before=<ms>` | 錄影列表（新到舊，用 `before` 分頁） |
| GET | `/api/recordings/:id` | 單一錄影資訊 |
| GET | `/api/recordings/:id/file` | MP4 檔（支援 Range，可拖拉進度） |
| GET | `/api/recordings/:id/thumb` | 縮圖 |
| DELETE | `/api/recordings/:id` | 刪除錄影 |
| POST | `/api/snapshot` | 截圖，回傳截圖資訊 |
| GET | `/api/snapshots?limit=&before=` | 截圖列表 |
| GET | `/api/snapshots/:id` / `/file` / `/thumb` | 截圖資訊 / 原圖 / 縮圖 |
| DELETE | `/api/snapshots/:id` | 刪除截圖 |
| GET | `/api/events?limit=&before=` | 事件紀錄（鏡頭上下線、錄影開始/停止） |
| WS | `/api/ws?exp=&sig=` | 即時事件，第一則是 `{"type":"hello","status":{...}}` |
| POST | `/api/live/whep` | 即時畫面 WebRTC 連線（WHEP，body 是 SDP offer，回 201 + SDP answer），由本服務轉給 MediaMTX |
| DELETE | `/api/live/whep/:session` | 結束即時畫面連線 |

**即時畫面**的連線協商（WHEP）經過本服務轉送，影音資料則由 MediaMTX 直接用 UDP/TCP 8189 傳到手機。
在電腦本機上可以直接用瀏覽器開 `http://localhost:8889/cam` 測試，不需要 token。

## 網頁版

`config.json` 的 `webDir`（預設 `../app/build/web`）存在時，本服務會在 `/` 提供 Flutter 網頁版。
iPhone 透過 `tailscale serve` 用 HTTPS 開啟（見專案根目錄 README）。

### WebSocket 事件

```jsonc
{ "type": "camera.online", "ts": 1794623451185 }
{ "type": "camera.offline", "reason": "...", "ts": ... }
{ "type": "preset.changed", "preset": "1080p", "ts": ... }
{ "type": "recording.started", "sessionId": "...", "startedAt": ..., "ts": ... }
{ "type": "recording.stopped", "sessionId": "...", "ts": ... }
{ "type": "recording.saved", "recording": { /* 同列表項目 */ }, "ts": ... }
{ "type": "recording.error", "message": "...", "ts": ... }
{ "type": "snapshot.saved", "snapshot": { /* 同列表項目 */ }, "ts": ... }
```

之後的動態偵測會用同一個事件匯流排（`src/events.ts`）發出 `motion.*` 事件。

## 儲存結構

```
storage/
├─ nvr.db                      SQLite：錄影/截圖索引、事件、設定
├─ pids.json                   子程序 PID（當掉重啟時用來清掉殘留程序）
├─ recordings/2026-11-14/
│   ├─ 2026-11-14_10-35-00.mp4  錄影（faststart MP4）
│   ├─ 2026-11-14_10-35-00.jpg  縮圖
│   └─ *.part.mp4               錄影中（fragmented MP4，斷電也能救回）
└─ snapshots/2026-11-14/
    ├─ 2026-11-14_10-30-58-167.jpg
    └─ 2026-11-14_10-30-58-167.thumb.jpg
```

## 已處理的狀況

- **鏡頭時間戳不準**：這支 USB 鏡頭實際約 20fps，卻用 30fps 的間隔標時間戳，會讓延遲越來越大、聲音不同步。已改用電腦時鐘（`-use_wallclock_as_timestamps`）。
- **錄影中切換畫質**：自動結束目前的檔案，串流恢復後接新檔，同一次錄影共用 `sessionId`。
- **服務當掉或斷電**：錄影中的 `.part.mp4` 是 fragmented MP4，下次啟動會自動修復並加入列表；上次殘留的 ffmpeg/mediamtx 也會被清掉。
- **鏡頭拔掉**：擷取程序會以 1s → 30s 的間隔重試，App 會收到 `camera.offline` / `camera.online`。
