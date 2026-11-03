# Fluent Network Sentinel (Windows 11 Fluent UI 網路狀態監控工具)

一個基於 **PowerShell** + **WPF (XAML)** 與 **Windows 11 Fluent Design** 打造的現代化即時網路狀態監控軟體。

---

## ✨ 核心功能亮點

1. **雙軌即時監控**：
   - 🌐 **外網狀態 (WAN)**：持續偵測 `www.google.com` 連線品質。
   - 📡 **區域網路 (LAN)**：持續偵測指定 Local IP（預設自動偵測本機 Default Gateway 路由器位址，如 `192.168.1.1`）。

2. **動態修改 Local IP**：
   - 允許直接在 UI 介面的輸入框修改目標 IP（例如 `192.168.1.1`、`192.168.0.254`、`10.0.0.1` 或 NAS/Server 區網 IP）。
   - 按下 **Enter** 或點擊 **「套用新 IP」** 立即切換偵測目標，並自動重置該目標的統計數據。

3. **完整連線指標儀表板**：
   - **即時延遲 (Latency)**：支援顏色分級標示（<40ms 青藍色、40~120ms 琥珀黃、>120ms 橙色、斷線紅色）。
   - **平均延遲 (Avg)**：即時統計平均往返時間。
   - **最小 / 最大延遲 (Min / Max)**：極端值追蹤。
   - **封包遺失率 (Packet Loss %)**：計算 `Lost / Sent` 與遺失次數。
   - **最後回應時間**：精準標註最近一次收到封包的時間。

4. **Windows 11 Fluent UI 設計**：
   - 深色 Mica 主題配色風格（`#181818` / `#242424`）。
   - 調用 Windows 11 DWM API 實現原生深色標題列與圓角視窗（Window Corner Preference）。
   - Segoe UI Variable 字體與現代化按鈕、輸入框樣式、連線狀態徽章（Status Pill）。

5. **實用輔助工具**：
   - **偵測間隔切換**：支援 1 秒、2 秒、3 秒、5 秒自由調整。
   - **暫停 / 繼續偵測**：可隨時暫停或重啟背景 Ping。
   - **斷線警報音效**：勾選後若連線發生異常斷線即時播放系統提示音。
   - **即時偵測日誌 (Activity Feed)**：自動滾動記錄最近 100 筆連線狀態，可一鍵清除。
   - **極致流暢不卡頓**：採用非同步 Background Task + UI Dispatcher 進行 Ping，連線逾時亦不影響 UI 操作。

---

## 🚀 啟動方式

### 方法 1：一鍵啟動（推薦）
直接在檔案總管中雙擊：
```cmd
Start-NetworkSentinel.bat
```
*(會以無黑視窗背景模式啟動 Fluent UI 介面)*

### 方法 2：使用 PowerShell 命令列啟動
```powershell
powershell -ExecutionPolicy Bypass -File .\NetworkSentinel.ps1
```

---

## 🛠️ 檔案結構說明

- `NetworkSentinel.ps1`：主程式碼（包含 WPF XAML、DWM 深色樣式 API、非同步 Ping 引擎、UI 事件處理）。
- `Start-NetworkSentinel.bat`：快速啟動腳本，自動繞過執行原則並隱藏背景終端機視窗。
- `README.md`：說明文件。
