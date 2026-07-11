# 將 TasksTxt UX/UI 設計接入 Figma

**建立時間：** 2026-07-12 00:35
**最後更新：** 2026-07-12 00:53
**狀態：** 已完成

## 目標
把 TasksTxt macOS App 目前的 UI（主清單、Archive、Scratchpad、Focus HUD）匯入 Figma，建立 Scott 可直接編輯的設計檔。

## Plan Steps
- [x] Step 1 — 讀取 App/ SwiftUI 原始碼與 Theme，掌握完整設計 token
- [x] Step 2 — 截取 App 各視圖畫面作為視覺參考（沿用啟動時截圖 + 逐 frame Figma 端截圖比對）
- [x] Step 3 — 載入 Figma MCP 工具並確認帳號授權（whoami：Scott team Full seat）
- [x] Step 4 — 讀取 figma-use / figma-create-new-file skill 指引
- [x] Step 5 — 建立 Figma 檔案並生成各視圖設計（8 frames + 12 色 variables 雙模式 + 3 文字樣式）
- [x] Step 6 — 驗證生成結果（API 讀回 + 截圖比對），交付可編輯連結

## 決策紀錄
- 00:35 — "finma" 解讀為 Figma（環境有官方 Figma MCP，無其他相近工具）
- 00:41 — 檔案建於 Scott team（Full seat）；另一 team 為 View seat 不可編輯
- 00:44 — 等寬字體採 JetBrains Mono（Figma 無 SF Mono；terminal 質感最接近）
- 00:47 — 發現 bound paint 的 opacity 會被 Figma server 正規化回 1（不可持久）；改建 8 個含 alpha 的衍生 variables（selBg/focusBg/captureBg/tint*）重綁全部半透明疊色，Dark/Light 雙模式截圖驗證通過
- 00:58 — advisor 建議的 Light-mode 實測抓到兩個真 bug：上述 opacity 正規化 + createAutoLayout 預設白底殘留（capture bar 三個子列），已全頁掃描清除

## 阻塞 / 待決議
無

## 結束摘要
Figma 檔案「TasksTxt UI」：https://www.figma.com/design/i3IXr85Nar9o4zByeNAI7S
- Theme variable collection：12 色 token × Dark/Light 雙模式，hex 與 Theme.swift 完全一致
- 文字樣式 mono / monoSmall / monoBig（JetBrains Mono）
- 8 個 frames：List View（含 capture bar、focus bar、tag bar、status bar）、Quadrant、Scratchpad、Focus Overlay、⌘K Palette、Global Capture、Focus HUD、Settings
- 全部原生 auto-layout 圖層（TEXT 139 個、IMAGE fill 0 個），可直接拖拉修改
- 後續建議：設計方向確定後可元件化（variant sets）、再做 Figma → SwiftUI 回寫
