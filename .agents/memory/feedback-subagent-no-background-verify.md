---
name: subagent-no-background-verify
description: "派工 subagent 的 prompt 必須禁止用 run_in_background 跑最終驗證 — agent 回合結束即死,會卡在「standby 等測試」沒 push/沒開 PR"
metadata: 
  node_type: memory
  type: feedback
  originSessionId: 8a159d4a-e753-4a18-8c87-09e73e40b4ee
---

派工 subagent 做「實作 → 測試 → push → PR」流程時,**最終驗證(make test-unit 等)必須前景阻塞執行**,不可背景跑再「等通知」。

**Why:** subagent 把測試丟背景 + 架 monitor 後回合就結束,harness 視為 completed — 它永遠等不到通知,工作停在未 push 狀態(0.1.0 run 中 #31 連續兩個 agent 都這樣死)。

**How to apply:** agent prompt 加一句「驗證一律前景跑完(可拉長 timeout),禁止 run_in_background + standby」;若全量測試太慢,改跑targeted 子集 + 讓 PR CI 當完整 gate。相關:[[feedback-use-monitor-for-ci]](主迴圈用 Monitor 是對的 — 只有「會死的 subagent」不行)。
