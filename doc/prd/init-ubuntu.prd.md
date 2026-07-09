---
name: init-ubuntu
version: 2.0.0
status: approved
owner: ycpss91255
created: 2026-05-13
updated: 2026-07-10
---

# init_ubuntu 產品規格

> 這是一份**回溯式的活規格(living spec)**:描述 `init_ubuntu` 目前「意圖 /
> as-built」的行為,作為單一真相源。已收斂的設計理由以 ADR 形式存在
> `doc/adr/`,本文只以編號引用、不重述;模組契約的深度細節在
> `doc/module-spec.md`,本文指向它、不複製。路線圖與未來工作放在
> 「Out of Scope」與「Further Notes」,不進主體。

`init_ubuntu` 把既有的 `setup_ubuntu.sh` / `module/setup_*.sh` 腳本,重新組織
為一套**模組化、可測試、有 CLI + TUI 雙前端、支援 install / upgrade / remove /
purge / sync 完整生命週期**的 Ubuntu 環境初始化工具。

---

## Problem Statement

我是單一維護者,手上有多台 Ubuntu 機器 —— x86_64 工作站與筆電、Raspberry
Pi 4/5、Jetson Orin、WSL —— 每一台的用途各異但開發環境希望一致。每次重灌、
換機、或臨時調整需求,我都得手動一件一件重裝工具、複製設定、對齊版本。這個
過程既耗時又容易漂移:同樣的工具在不同機器上裝的版本不同、設定檔的內容各自
演化、某些步驟只存在我的記憶裡沒有被記錄下來。結果是每次「回到可工作狀態」
都要花掉數小時,而且無法保證兩台機器真的一致。

我熟悉終端機、能讀 CLI / TUI 介面,也已完成 Ubuntu 基本安裝 —— 我要的不是
另一套通用組態管理器,而是一個能把「我這套個人開發環境」在任意 Ubuntu 主機
上以最小成本重現、且能跨機同步與逐步調整的工具。平台差異(有沒有 NVIDIA
GPU、是不是無頭 server、是不是 SBC 或 WSL)應該被工具自動理解,而不是每次
由我手動判斷該裝哪些東西。我偏好有 `sudo` 但不總是有;工具在受限環境下也應
該可用。

## Solution

`init_ubuntu` 提供單一工具 `setup_ubuntu`,把上述痛點收斂為一套 apt 風格的
完整生命週期管理:在一台全新機器上 `git clone` 後直接執行,就能把個人化開發
環境裝起來、之後隨時增修、並推到別台機器。

- **模組化**:每個工具是一個獨立 module,宣告 metadata 並實作固定契約;
  新增工具不需改動 engine 程式碼(見 `doc/module-spec.md`、ADR-0002)。
- **冪等(idempotent)**:任何生命週期動作重複執行都安全,重灌 / 補裝 /
  升級不會把系統帶進不一致狀態。
- **Docker 內測試**:所有測試只在容器內跑(ADR-0004),主機環境絕不被
  module 的安裝動作觸碰,讓工具本身能在 CI 上跨 Ubuntu 版本持續驗證。
- **環境感知**:工具偵測 form factor 與硬體(GPU / WSL / 容器 / VM / SBC),
  自動調整推薦清單 —— 我不必研究「這台該裝哪些」。
- **CLI + 雙層 TUI 雙前端**:CLI 是核心;TUI 是 CLI 的前端(G4),優先使用
  fzf 的 Rich 層(兩欄式導航器),缺 fzf 時保底走 whiptail 的 Fallback 層
  (ADR-0024)。兩前端共用同一條安裝路徑,行為一致。
- **完整生命週期 + 跨機同步**:install / upgrade / remove / purge / verify /
  doctor,加上 sync / export / import,讓裝完之後仍能持續用同一套工具管理,
  並把「裝了哪些 module」跨機推拉。

## User Stories

1. 作為新機使用者,我想要在乾淨 Ubuntu 上執行一次 TUI 就把整套開發工具裝完,
   以便快速進入工作狀態。
2. 作為新機使用者,我想要用 `git clone` 後直接執行的三行 Quick Start 取得並
   啟動工具,以便不必先找 installer 或一行式 bootstrap。
3. 作為環境變動的使用者,我想要 `setup_ubuntu install lazydocker` 只增加單一
   工具,以便不必重跑整套流程。
4. 作為安裝依賴敏感的使用者,我想要 install 時自動解析並帶入相依 module
   (拓樸排序、循環偵測),以便不必自己記住安裝順序。
5. 作為進階使用者,我想要 `setup_ubuntu install --no-deps neovim` 跳過依賴,
   以便手動掌控依賴版本。
6. 作為謹慎的使用者,我想要對任何破壞性操作加 `--dry-run` 先看它會做什麼,
   以便在不寫入檔案系統的前提下預覽整條 dep chain 的計畫。
7. 作為退場使用者,我想要 `setup_ubuntu remove docker` 移除工具但保留設定,
   以便日後可快速復原。
8. 作為退場使用者,我想要 `setup_ubuntu purge docker` 完整移除工具與設定,
   以便釋放空間或解決衝突。
9. 作為清理使用者,我想要 remove / purge 時用 `--with-orphans` 一併清掉不再
   被其他 module 依賴的孤兒 dep,以便環境保持乾淨。
10. 作為維運使用者,我想要 `setup_ubuntu verify docker` 做裝後驗收,以便確認
    工具真的裝對了。
11. 作為維運使用者,我想要 `setup_ubuntu doctor` 印出環境偵測結果並跑所有已裝
    module 的健檢,以便一眼看出哪裡壞了。
12. 作為維護者,我想要 `setup_ubuntu upgrade` 不帶名時升級所有已裝 module
    (依相依拓樸序、失敗不阻其他),以便一次把環境拉到最新。
13. 作為維護者,我想要 upgrade 前先看到升級計畫(哪些有新版、版本差異),
    以便決定是否繼續。
14. 作為 NVIDIA 使用者,我想要在 TUI 看到「偵測到 RTX 4090,推薦安裝
    nvidia-driver」,以便不必自己研究該裝哪個版本。
15. 作為 WSL / 容器使用者,我想要工具自動跳過 host-only 的 module(如
    nvidia-driver、qmk-firmware),以便不會誤裝裝不起來的東西。
16. 作為多平台使用者(RPi / Jetson),我想要工具偵測 form factor 並只推薦該
    平台合理的 module,以便一套工具走多個平台。
17. 作為多平台使用者,我想要用 `--profile=server|desktop|jetson` 或 config
    覆寫自動偵測到的平台,以便在偵測不準或我另有打算時強制切換。
18. 作為無 sudo 使用者,我想要工具自動偵測並 fallback 到 user-home 安裝,
    以便在受限環境下也能用。
19. 作為 Quick Setup 使用者,我想要多步驟引導(確認平台 -> 推薦 module ->
    CLI 套件組 -> AI agent CLI -> Review & Install),以便不必一次面對爆量勾選。
20. 作為 TUI 使用者(Rich 層),我想要兩欄式導航器 —— 左欄目前層級、右欄
    即時預覽游標所在項目的細節,以便瀏覽 module 時一眼看到重點。
21. 作為 TUI 使用者,我想要在缺 fzf 時仍能用 whiptail 的保底層完成一樣的
    操作,以便工具在任何 Ubuntu 預設環境都可用。
22. 作為 TUI 使用者,我想要勾選累積器模型(子選單只勾不執行,主選單 Run 是
    唯一批次執行點),以便先把選擇湊齊再一次執行,取消時無副作用。
23. 作為使用者,我想要 `setup_ubuntu list` 列出 module 並用 `--installed` /
    `--upgradable` / `--available` / `--json` 過濾,以便查詢環境現況。
24. 作為使用者,我想要 `setup_ubuntu search <kw>` 與 `show <m>` 搜尋與檢視
    module metadata,以便找到並了解某個工具。
25. 作為設定使用者,我想要 `setup_ubuntu config get|set|unset|show` 讀寫我的
    偏好(語言、安裝目標、平台覆寫),以便不必手動編輯生成的設定檔。
26. 作為多機使用者,我想要 `setup_ubuntu sync user@host` 把本機 module 集合
    推到另一台(預設 dry-run,`--apply` 才套用),以便跨機快速同步。
27. 作為多機使用者,我想要 `sync --pull` 從對端把狀態拉回本機(同樣預設
    dry-run),以便反向同步。
28. 作為謹慎的同步使用者,我想要 sync 對端沒裝工具時得到明確的 bootstrap
    教學而不是被自動 rsync,以便不產生斷裂的孤兒安裝。
29. 作為備份使用者,我想要 `setup_ubuntu export <file>` 匯出可跨機的狀態子集,
    再在另一台 `import <file>` 還原,以便離線搬運我的環境定義。
30. 作為安全意識使用者,我想要用獨立子工具 `setup_secrets` 互動式產生 SSH /
    GPG key 並安全儲存 token,以便敏感資料不在批次安裝流程中誤洩、也不入
    shell history。
31. 作為 optional 使用者,我想要用 `install --tag=<group>` 一次裝整組工具
    (如 cli-essentials),以便不必逐一點名。
32. 作為 AI 工作流使用者,我想要在 optional 的 agent 群組多選(或不選)Claude
    Code / Codex / Gemini,以便按需求挑選 AI CLI。
33. 作為 module 作者,我想要只寫一個符合契約的 module 檔就能被 engine 自動
    發現並納入 `list`,以便擴充工具不必改 engine 程式碼。
34. 作為 module 作者,我想要用 archetype macro 一行綁定完整生命週期、再以
    super-call 覆寫個別階段,以便省去重抄樣板。
35. 作為私有擴充使用者,我想要把自己的 module 放進 user-local module 區,撞名
    時我的版本勝,以便不改動 repo 就能加入私有工具。
36. 作為安裝後的使用者,我想要裝完仍能用 CLI 或 TUI 繼續管理環境(增 / 升 /
    移 / 驗 / 診 / 同步),以便工具是長期夥伴而非一次性腳本。
37. 作為關心工具本身更新的使用者,我想要 `setup_ubuntu self-upgrade` 用
    `git pull` 更新工具自身,以便工具與我的環境一起保持最新。
38. 作為輸出敏感的使用者,我想要色彩自動偵測(非 tty / 後台 / `NO_COLOR`
    自動關閉)並可用 `--color` / `--quiet` / `--verbose` / `--lang` 覆寫,
    以便輸出在管線與腳本中乾淨、在終端機中好讀。
39. 作為需要診斷的使用者(或 agent),我想要每次操作都留下結構化 JSONL 事件
    紀錄,以便事後用 `jq` 切片查詢問題。
40. 作為 CI 使用者,我想要在 Docker 內用 `just -f justfile.ci` 跑完所有測試,
    以便在 GitHub Actions 上跨 Ubuntu 版本持續驗證,主機不被觸碰。

## Implementation Decisions

以下是介面層級的持久契約 —— 描述行為與語意,而非檔案佈局或程式碼。已收斂
的理由以 ADR 編號引用;module 契約的完整規範見 `doc/module-spec.md`。

### Engine 與模組發現

Engine 是編排層:CLI 進入點加上 Dispatcher / Runner / Registry / Resolver
(詞彙見 `CONTEXT.md`)。Registry 是 **in-memory** —— 每次執行動態掃描
`module/` 目錄與 user-local module 區重建,無持久化 index,因此沒有「index
過期」的問題,也沒有對應 `apt update` 的子命令。除了 repo 內建的 module,
Engine 額外掃描使用者私有的 user-local module 區;同名撞名時 user-local 勝
(並印警告)。

啟動時做 self-deps preflight:檢查工具自身依賴(如 jq / curl / git),缺且
有 sudo 時詢問一次是否 apt 安裝(`-y` 時自動裝),缺且無 sudo 時 fail fast
並印明確安裝指引。這解開「狀態 / 設定 / 偵測需要 jq,但 jq 本身也是要裝的
工具」的雞生蛋問題。

### 模組分類與環境感知推薦

Module 分四個 category,每個 module 只屬於一個:

- **base**:任何用此 repo 安裝的機器都視為開發平台,base 是所有平台共用的
  最小開發基線(如版本控制、下載工具、編譯工具鏈這類單一 apt 套件)。base
  由早期的 bundle 拆為 per-tool module(ADR-0026,supersedes ADR-0011 的
  bundle 機制),各自可獨立安裝 / 移除,並可合法作為其他 module 的相依。
- **recommended**:環境感知、預設勾選但可取消。是否推薦由 module 的
  `is_recommended()` 依當前 form factor 與硬體回應(例:偵測到 NVIDIA GPU
  且非 VM/container/WSL/jetson 才推薦顯卡驅動;日用工具永遠推薦)。
- **optional**:預設不勾選、使用者主動選擇。以 `TAGS[0]` 再分次群組
  (如 cli-essentials / agent / editor / filemgr / 硬體特定),TUI 逐群詢問、
  CLI 可用 `--tag=<group>` 整群安裝。
- **experimental**:保留給未來不穩定 module 的入口,目前可為空;TUI 主選單
  只顯示非空 category,空的分類自動不出現。

**環境感知推薦邏輯**分兩段:先以 `SUPPORTED_PLATFORMS` 硬過濾(當前 form
factor 不在 allowlist 就直接排除,不再詢問 module 意見);再對通過的 module
看使用者設定的三態 enabled 覆寫(強制納入 / 強制排除 / 交給 module 決定);
最後對「未設 enabled」者呼叫 `is_recommended()`。`--force` 可跨過這些軟過濾
強裝(ADR-0012)。使用者也可用 `--profile` 或 config 覆寫偵測到的平台。

具體有哪些 module、各屬哪一類,是**活資料** —— 以 `setup_ubuntu list` 查詢、
以 `module/` 目錄為準,本規格刻意不逐一列舉,以免與程式碼漂移。

### CLI 介面語意

CLI 動詞刻意對標 apt,讓使用者的心智模型可轉移(對照見 `CONTEXT.md`):
`install` / `remove` / `purge` / `upgrade` / `verify` / `doctor` /
`search` / `show` / `list` / `detect` / `config` / `sync` / `import` /
`export` / `help` / `version`。`install` 自動帶入相依;`remove` 保留設定、
`purge` 連設定一併移除;`upgrade` 呼叫各 module 的 `upgrade()` 升到最新;
`list --installed` 取代已 deprecated 的 `status`;沒有對應 `apt update` 的
子命令(registry in-memory,無 index 可刷新)。

**Exit code 是一份契約**,不是隨意的錯誤碼:0 成功 / Query 為 yes;1 一般
錯誤 / Query 為 no;2 引數錯誤或 metadata 不合法;3 環境不支援;4 無 sudo
且 module 不支援 user-home;5 依賴循環 / 解析失敗 / 觸發 CONFLICTS_WITH;
6 部分 module 失敗(其他成功);7 遠端 / 網路操作失敗。生命週期函式依三類
使用這套碼:Query 類(detect / is_installed / is_recommended / is_outdated)
只回 0/1;Action 類(install / upgrade / remove / purge)用完整語意碼;
Diag 類(verify / doctor)0 通過、非 0 不通過。完整對照表見 Reference Appendix。

**全域 flag** 一致套用於所有子命令:`--lang`(語言白名單 en / zh-TW /
zh-CN / ja,未翻譯 fallback en)、`--quiet` / `--verbose`(調 log 等級)、
`--color=auto|always|never`(預設 auto,自動偵測 tty / `NO_COLOR` / 後台)、
`--state-dir`、`--install-target=auto|sudo|user-home`、`--profile`。

**upgrade 語意**:不帶名時掃已裝 module、依相依拓樸排序(leaf 先升),批次
查詢 is_outdated(GitHub release 走隨需抓 + 短 TTL 的 latest cache 避免 rate
limit;apt module 一次掃 upgradable),非 `-y` 時先顯示升級計畫再詢問。執行
為序列(dpkg lock 與 sudo 互斥,不並行);失敗採 continue(per-module 失敗
不阻其他),失敗 module 的版本紀錄保留舊值。失敗回滾依 archetype 而定:
user-home 換回舊版目錄、config-drop 換回備份、apt 不自動回滾(apt 無乾淨
rollback,只 warn 提示手動 pin 版本)。upgrade 與 install 共用同一條
install -> verify pipeline(ADR-0015),verify 失敗即 upgrade 失敗並觸發回滾。

**安裝輸出 UX**:JSONL 事件是單一真相源,人讀輸出是事件的 render 結果
(ADR-0006)。進行中預設只印 per-module 進度標頭與主要命令行,子命令輸出
捕捉進 JSONL 不即時 stream(`--verbose` 才 stream);「事後要做」的訊息
(post-install / reboot)不在裝完當下印,而是統一發結構化 `action_required`
事件,由 engine 在 session 結尾衍生成人讀的「Action required」聚合區 ——
確保 stdout 與 log 永不分歧。

### 模組契約(介面層;深度細節見 doc/module-spec.md)

每個 module 必須實作 **10 個 mandatory 生命週期函式**(ADR-0002):detect /
is_recommended / is_installed / install / upgrade / remove / purge / verify /
is_outdated / doctor,全部冪等。另有兩個由 helper 提供的 phase(info /
status),作者不需自寫。CLI 的 `show` 對應 standalone 的 info,`list
--installed` 對應 status。

- **Archetype 與 super-call**:四種 archetype(A=apt-only、B=GitHub-release
  tarball、C=config-drop、D=custom hand-written)。A/B/C 有 macro 一行綁定
  完整生命週期,作者只填資料欄位 + 寫 detect / is_recommended;要客製個別
  階段就用 super-call pattern(macro 後重宣告函式,先呼叫 archetype 預設再
  加自訂步驟,bash 後宣告者勝)。D 全部手寫,但仍可重用通用 guard。
- **雙模式(standalone / engine)**:每個 module 都能被使用者直接單檔執行
  (standalone,自 source 依賴、不解析 DEPENDS_ON、不寫 state.json),也能被
  engine 在隔離 sub-shell 內 source 執行(engine 解析相依、寫 state.json)。
  兩模式共用同一份 install / remove / purge 函式,差別只在「誰呼叫」。
- **i18n 關聯陣列**:module-level 的 DESCRIPTION / POST_INSTALL_MESSAGE /
  WARN_MESSAGE 以 `declare -A` 關聯陣列宣告,helper 查表(找不到目標語言
  fallback en);擴充新語系只需新增一行。
- **Sidecar 記帳**:Sidecar 記錄「某 module 裝的是哪個版本」,是 is_outdated
  比對的單一真相源。它由 phase-invocation 層寫入(ADR-0027 refines
  ADR-0001 的「寫在哪」),engine 與 standalone 兩個 invoker 共用同一個
  after-phase wrapper,依 module 的 provided-version hook 記版本;remove /
  purge 時刪除。不變式:`is_installed()==false` 等價於 Sidecar 不存在。
  state.json 只有 engine 寫,standalone 不寫。

其餘契約細則 —— metadata 欄位型別 / 合法值、helper API、dry-run 規則、失敗
回傳與自動清理、每 module 測試契約 —— 完整定義在 `doc/module-spec.md`,本
規格不複製。

### State 與 Config(邏輯模型)

State 與 Config 嚴格分離(見 `CONTEXT.md`):

- **State** 是機器寫入的執行期事實(XDG_STATE_HOME 下),不由使用者手改。
  每個已裝 module 的紀錄拆 `synced`(可跨機:manual flag、depends_on
  snapshot、version_provided、installed_at、installed_by)與 `local`
  (本機:解析後的安裝目標、user-home 根目錄、freeze 的套件集等),只有
  `synced` 會跨機邊界(ADR-0018)。install 失敗不寫 state(維持二態原則);
  install 成功但 verify 失敗會自動跑 purge 收尾且不寫 state(ADR-0015)。
  Schema 有版本,升版走 forward-only migration(ADR-0008),讀到比工具新的
  state 拒絕改檔。並發寫入以檔鎖互斥,讀到損毀 JSON 時備份後 fail fast、
  不靜默重建。
- **manual flag** 標記某 module 是使用者顯式點名(true)還是被拉進來的 dep
  (false),sticky-to-true;孤兒移除以 forward-dep snapshot 判定(ADR-0010)。
- **Sidecar** 是 per-module 的版本紀錄檔,語意見上節與 ADR-0001 / ADR-0027。
- **Log** 是結構化 JSONL,schema 對齊 OTel + W3C Trace Context(ADR-0006),
  主要消費者是 agent 做診斷;session 結尾自動做保留清理(近 30 天且至多
  100 檔)。
- **Config** 是使用者偏好(XDG_CONFIG_HOME 下),但**是工具生成檔、不可手動
  編輯**:透過 `config set/unset` 修改,工具 round-trip 保留註解與排序,檔頭
  固定印警告。`config load` 子命令已砍(ADR-0014);套用 module 附帶的設定
  改走 config-drop archetype 的正常 install pipeline。config.ini 是本機生成
  檔,不跨機同步。

### 多平台支援

Module 以 `SUPPORTED_PLATFORMS` 宣告可裝的 form factor(desktop / server /
rpi-4 / rpi-5 / jetson-orin / wsl / container / vm;空陣列 = 不限)。Engine
的 Environment 層 probe 主機(讀 /etc、/proc,跑 lspci /
systemd-detect-virt)後 classify 出單一 form_factor,推薦過濾時先以此硬過濾
(見上「環境感知推薦邏輯」)。使用者可用 `--profile` 或 config 的平台覆寫
強制切換。form factor 也注入 module sub-shell 供 `is_recommended()` /
`install()` 做平台分支。

### 跨機同步(sync)

sync 的目標是跨機快速同步「裝了哪些 module」,**絕不傳 secrets**。預設
dry-run,`--apply` 才套用;衝突解析規則(union、remote-wins)見 ADR-0013。
流程是:SSH 連線(strict host key checking、只接受 key 認證、流程內不收
password)-> 對端工具檢查(對端無 `setup_ubuntu` 時退 code 7 並印三行
bootstrap 教學,不自動 rsync、不遠端動 sudo,以免產生無 `.git` 的孤兒安裝
而讓 self-upgrade 斷裂)-> export 本機狀態過濾成 payload -> 傳送 -> 對端
import(內部走 install pipeline)。`import` 與 `sync --pull` 走同一條衝突
pipeline,差別只在資料源是本機檔案而非 SSH。state schema 同版即可 sync
(ADR-0008 把關),工具版本不同僅 warn。payload 不做簽章(SSH 通道已認證
已加密)。

### 敏感工具子工具(setup_secrets)

secrets 處理獨立於主安裝流程,由另一個工具 `setup_secrets` 負責:SSH key
生成 / 載入 / 拷貝到遠端、GPG key 生成 / 匯入、API token 安全儲存、互動輸入
密碼(不入 shell history)。它**不走 module pipeline**,但與主 engine 共用
logger / i18n / color;TUI 主選單提供「Manage Secrets」入口跳轉。儲存後端
依序偏好 pass -> gnome-keyring -> 加密檔(絕不寫明文;選擇邏輯見 ADR-0016)。
把 secrets 抽離主流程是刻意的:避免在批次安裝時誤洩敏感資料。

### 安裝後自我管理

裝完之後,使用者永遠可以繼續用同一套工具管理環境(list / install / upgrade /
purge / verify / doctor / sync,或進 TUI)。工具自己是 entry point,不採用
symlink 式的 dotfile 佈署路徑;三個前端腳本保持可執行,可加進 PATH
(install 完成時提示),state.json 持續被讀寫。工具自身的升級路徑是
`self-upgrade`:主路徑 `git fetch` + 顯示 changelog 摘要 + `git pull
--ff-only`,偵測到無 `.git`(tarball 安裝)時改走 GitHub release 下載;升級
受 state schema migration 保護,不影響既有 state。

## Testing Decisions

### 什麼算好測試

測「外部可觀察行為」,不測實作細節。斷言透過產品對外介面(引擎進入點、
module 的 lifecycle 契約、狀態檔)下,而非私有 helper 或中間變數。實作重構若
不改變對外行為,測試不該壞。所有測試只在 Docker 內跑(ADR-0004);主機環境
絕不被 module 的 Action Phase 觸碰。

### 測試金字塔(形狀與各層職責)

本套件是健康的底重金字塔 —— 寬而近乎完整的 unit 底座、薄的 integration
中層、小的 expect-driven E2E 頂層。對 bash 工具而言底重是正確的:多數邏輯是
純的、在 unit 層透過 module 契約驗證,故中層與頂層只需證明「跨模組接線」,
不重測每個 module。避免 ice-cream-cone 與 hourglass 反型。各層只證它獨有
能證的事:

1. **Unit(底座,最寬)** —— 每個 `lib/*.sh` 有 spec;每個 module 透過其 10
   個 lifecycle 函式(ADR-0002)這個「每模組測試面」驗證(metadata /
   lifecycle dry-run / 無副作用 / idempotency / standalone CLI);`script/*`;
   以及 `.claude/hook/*` 的 block-path + allow-path。契約即介面,可 source
   module 呼叫契約函式,但不伸手進私有內部。github-release 取檔以
   `INIT_UBUNTU_TEST_GH_*` seam stub 成離線確定性。
2. **Integration(中層,薄)** —— 只證 unit 無法證的「跨模組 wiring」:引擎
   進入點的真實非 root 安裝路徑(dispatcher 到 runner 到 source module 到
   archetype macro 到 lifecycle,拒絕 EUID 0)、dep 解析、state
   export/import、sync 雙容器真實 ssh(`SYNC_E2E=1`)、TUI real-install。
   不重測個別 module。
3. **E2E(頂層,小,expect-driven)** —— 端使用者面:語言、real-install
   smoke、fzf-smoke、whiptail-parity;TUI 以 `setup_ubuntu_tui.sh --backend
   fzf|whiptail` 槓桿分別驗 Rich / Fallback 兩層。

底重比例(rc3 時約 4076 : 21 : 5 個 `@test`)是刻意且正確的。

### 合規實作必須通過的 gate 契約

(原驗收條件收斂為 gate 契約,已達成的里程碑式項目不再列)

- **Unit 綠**:`just -f justfile.ci test-unit`。
- **Integration 綠(3 影像)**:`just -f justfile.ci test-integration` 於
  22.04 / 24.04 / 26.04 皆綠。
- **覆蓋率(合併規則,AC-17)**:兩層 gate。
  1. **PR 合併規則 —— diff/patch coverage**:PR 新增或改動的行必須 >= 90%
     被覆蓋(diff-cover 類工具,以 PR 對 main 的 diff 計算),作為 required
     status check 直接擋 merge。這解決窄矩陣 PR 總覆蓋率結構性偏低、無法作為
     PR gate 的問題。
  2. **main 總覆蓋率棘輪(ratchet)**:合併 kcov shard 後的整體 line
     coverage 是棘輪地板,隨套件成長往上抬、永不退化(歷史:66 基線於
     2026-06-07,#124 拉到 80.16% 於 2026-06-17,目標朝 90% 上抬);在
     full-matrix / push-to-main 強制,實際 `COVERAGE_MIN` 設為略低於當前
     誠實 merged 數字。兩層 gate 僅 unit 層計入。
- **module 契約 conformance(#305 meta-test)**:每 module 具備 10 個
  lifecycle 函式,僅 allowlist 例外。
- **sync E2E**:雙容器真實 ssh 流程綠。
- **lint**:`just -f justfile.ci lint`(shellcheck -x、fish 語法、hadolint)。

### Prior art(各層可仿照)

- **Unit**:`test/unit/module/*_spec.bats`(module 契約)、`test/unit/hook/*`、
  `test/unit/script/*`。
- **Integration**:`test/helper/engine_lifecycle.bash`(非 root 真實
  install)、`test/integration/sync_ssh_spec.bats`。
- **E2E**:`test/helper/tui_harness.bash`、`tui_real_install.bash` 及 expect
  smoke。

## Out of Scope

### 非目標(明確不做)

- 不發佈 Docker image / container artifact(Docker 僅用於 CI 測試)。
- 不取代 `ansible` / `nix-darwin` / `chezmoi` —— 不是泛用組態管理工具,只針
  對 Ubuntu host。
- 不支援 non-Ubuntu Linux 發行版。
- 不做 GUI(只有 CLI + TUI)。
- 不在 install pipeline 內處理 secrets —— 改由獨立子工具 `setup_secrets`
  負責。
- 不做雲端同步(state 只存本機;跨機同步走 SSH push/pull)。
- 不取代 `apt` —— 系統套件仍委派 `apt-get`,本工具只是 orchestration 層。
- 不對外發行 —— 主用途是個人多機部署;若要分享給他人,僅提供獨立簡易腳本,
  不承諾相容性或支援。
- **不切換語言 / 執行環境** —— 維持 bash + Docker 範疇;語言遷移的觸發條件
  記在 ADR-0003,未達成前不改。

### 未來工作(路線圖,非當前真相)

版本階梯目前規劃至 0.4.0;**1.0 暫不規劃**(非永久取消 —— 若未來要做,先回
本規格變更並 bump 文件版本)。以下屬未來、非 as-built:

- **0.2.0(清理與遷移)**:state schema migration 機制啟用、`tool/` 各檔去向
  逐一決定、`small-tools/` 標 deprecated、`.adoc` -> `.md` 全轉、`doctor
  --json`。
- **0.3.0(便利動詞)**:`reinstall`、`autoremove`、`doctor --fix`、
  `self-upgrade`、shell completion(fish + bash 動態補全)。
- **0.4.0(終局)**:移除 `small-tools/`、nvidia-driver 失敗自動回滾
  (ADR-0020)、i18n 四語系全覆蓋。

### Backlog(願望清單,不排版本)

不承諾、不排程;若要實作須先回本規格變更並 bump 文件版本:並行安裝(非 apt
module worker pool)、`rollback`(任意版本回滾)、`setup_secrets sync`
(secrets 跨機加密搬運)、支援 Debian 衍生、Wayland-aware 推薦、蘋果硬體
偵測、Web UI。

**已砍(不做,亦不入 Backlog)**:並行安裝已從 Goals 與 module spec 移除
(`dpkg` lock 與 sudo 互斥讓 apt module 無法並行,非 apt module 並行收益不足
以抵 scheduler 複雜度);Module repository(`module add <git-url>`,與「不對外
發行」矛盾,私有擴充由 user-local module 區涵蓋);Sync payload 簽章(SSH
通道已認證已加密);ghostty 等一次性 / 探索性項目。

### 已 park 的 TUI backlog

TUI 尚未完成的體驗項目(round-1 / round-2 回饋清單中 FIXED-NOT-TESTED 與
PARTIAL / NOT-FIXED 的項目)park 在 `doc/review/tui-feedback-traceability.md`,
待 shell 層完成後再回頭處理(見 Further Notes)。

## Further Notes

- **交付里程碑**:0.1.0 的實作里程碑(M0 ~ M15)與 0.2.0 ~ 0.4.0 的範圍不在
  本文件維護執行狀態 —— 進度由 GitHub issues / milestones 追蹤,本規格只
  定義範圍。
- **diff-coverage required check 是規格指定的後續實作**:Testing Decisions
  的 PR 合併規則(diff/patch coverage >= 90%)需要把一個 diff-cover CI step
  接進 ci-passed aggregator,並在 classic branch protection 註冊為 required
  check —— 這在本規格撰寫當下**尚未接線**,是待實作的 follow-up。
- **已收斂決策 = ADR**:本規格早期以長篇 Open Questions / 決定事項敘事承載
  設計理由;那些理由現在以 ADR 形式活在 `doc/adr/`(索引即目錄),本文只以
  編號引用。要了解「為什麼這樣決定」請查對應 ADR,不要回頭找敘事。
- **參考文件指標**:
  - 模組契約的深度細節(metadata 欄位、helper API、生命週期規範、每 module
    測試契約) —— `doc/module-spec.md`。
  - 領域詞彙(Module / Archetype / Lifecycle / Phase / Engine / Frontend /
    Tier / State / Config / Sidecar / manual flag 等) —— `CONTEXT.md`。
  - 架構決策索引 —— `doc/adr/`。
- **取得工具(bootstrap)**:乾淨機器上的第一步是 `git clone` + 直接執行,
  不另做 installer 或一行式 bootstrap:先確保有 git,`git clone` 本 repo,
  進目錄執行 `setup_ubuntu_tui.sh`(或 `setup_ubuntu.sh install
  --recommended`)。README 以此三行作為 Quick Start。這與 self-upgrade
  (`git pull` / release)、user-local module 區同一世界觀。
- 舊版 Appendix A(與既有檔案的一對一對應表)已移除:它以檔案路徑為主、
  已隨實作演進而陳舊,不再是有效真相源;實際佈局以 repo 現況與
  `doc/module-spec.md` 為準。

---

## Reference Appendix(may drift)

> **這一段是具體 artifact 的便利參考,可能與程式碼漂移。** 持久的決策在上面
> 各節;這裡的表格 / wireframe / schema 只為方便查閱而保留,若與程式碼不符,
> 以程式碼與 `setup_ubuntu list` / `detect --json` 的實際輸出為準。模組契約
> 的深度細節請看 `doc/module-spec.md`,不在此複製。

### A. CLI subcommand 表

| Subcommand | Args | 主要 Flags | 行為 | 對標 apt |
|---|---|---|---|---|
| `install` | `<module>...` | `-y`、`--dry-run`、`--no-deps`、`--base`、`--recommended`、`--category=<n>`、`--tag=<t>`、`--install-target=auto\|sudo\|user-home`、`--force` | 安裝指定 module(自動帶 dep);非 `-y` 時先列 plan 問 `Proceed? [Y/n]` | `apt install` |
| `remove` | `<module>...` | `-y`、`--dry-run`、`--with-orphans` | 移除 module(保留 config) | `apt remove` |
| `purge` | `<module>...` | `-y`、`--dry-run`、`--with-orphans` | 完整移除 module + config | `apt purge` |
| `upgrade` | `[<module>...]` | `-y`、`--dry-run` | 呼叫各 module `upgrade()`;不帶名 = 升級所有已裝 | `apt upgrade` |
| `verify` | `[<module>...]` | `--dry-run` | 跑 `verify()` 做裝後驗收 | — |
| `search` | `<keyword>` | — | 在 NAME / DESCRIPTION / TAGS 內搜尋 | `apt search` |
| `show` | `<module>` | — | 印出 module 完整 metadata | `apt show` |
| `list` | — | `--category=<n>`、`--installed`、`--upgradable`、`--available`、`--tag=<t>`、`--json` | 列出 module | `apt list` |
| `status` | `[<module>]` | `--json` | deprecated,forward 到 `list --installed` | — |
| `detect` | — | `--json` | 環境偵測結果 | — |
| `doctor` | `[<module>...]` | `--validate-modules`、`--fix`(0.3.0) | env detect + 已裝 module `doctor()`;`--validate-modules` 跑 metadata lint | — |
| `config get\|set\|unset\|show` | `<key> [<value>]` | `--json`(show) | 讀寫生成的 config.ini | — |
| `sync` | `<user@host>` | `--modules=<list>`、`--include-user-local-modules`、`--pull`、`--apply` | SSH 跨機同步;預設 dry-run(ADR-0013) | — |
| `import` | `<file>` | `--apply` | 從 export 的 state 還原;走同 `sync --pull` 的 conflict pipeline | — |
| `export` | `<file>` | `--modules=<list>` | 匯出 state.json `synced` 段子集(ADR-0018) | — |
| `help` | `[<subcommand>]` | — | 顯示說明 | `apt --help` |
| `version` | — | — | 顯示版本 | `apt --version` |

> 無對應 `apt update` 的子命令:module 來源是本地檔案,registry 每次執行
> in-memory 重建,無 index 可過期;GitHub release 版本情報走隨需抓 + TTL 1h
> 的 latest cache;工具自身更新走 `self-upgrade`(0.3.0)。

### B. Exit code

| Code | 意義 |
|---|---|
| 0 | 成功 / Query 答案 = yes |
| 1 | 一般錯誤 / Query 答案 = no |
| 2 | 引數錯誤(unknown subcommand / module 名拼錯 / metadata 不合法) |
| 3 | 環境不支援(non-Ubuntu / 不支援的 Ubuntu 版本) |
| 4 | sudo 不可用且 module 不支援 user-home |
| 5 | 依賴循環 / 依賴解析失敗 / CONFLICTS_WITH 觸發 |
| 6 | 部分 module 失敗(其他成功) |
| 7 | 遠端 / 網路操作失敗(sync / SSH、GitHub release download、apt repo 不通) |

生命週期函式分三類使用 exit code:Query 類(detect / is_installed /
is_recommended / is_outdated)0 = yes、1 = no;Action 類(install / upgrade /
remove / purge)0 = 成功、1 = 一般失敗、3 = env 不支援、4 = sudo 缺、
5 = dep 缺(standalone)、7 = 網路;Diag 類(verify / doctor)0 = 通過、
1 = 不通過、7 = 網路失敗。

### C. 全域 flags

| Flag | 說明 |
|---|---|
| `--lang=en\|zh-TW\|zh-CN\|ja` | 強制語言(未翻譯字串 fallback en) |
| `--quiet` | 只輸出 warn / error |
| `--verbose` / `-v` | 輸出 debug 等級 |
| `--color=auto\|always\|never` | 預設 auto,自動偵測 tty / `NO_COLOR` / `TERM=dumb` / 後台執行 |
| `--state-dir=<path>` | 改寫 state 目錄 |
| `--install-target=auto\|sudo\|user-home` | 強制安裝目標(預設 auto) |
| `--profile=server\|desktop\|jetson\|...` | 強制平台 form factor(覆寫自動偵測) |

### D. upgrade 計畫輸出範例

```
Will upgrade 4 of 12 installed modules (topo order):
  fzf       v0.50.0 -> v0.51.0
  lazygit   v0.40.1 -> v0.41.0
  ripgrep   apt-managed -> upgradable
  neovim    v0.10.2 -> v0.10.5
8 already at latest: fish, eza, zoxide, ...
Proceed? [y/N]
```

結束 summary:

```
Upgraded:  fzf, lazygit, ripgrep
Failed:    neovim (verify failed at v0.10.5, rolled back to v0.10.2)
           -> trace_id=abc-def, see jsonl log
Skipped:   fish, eza, ...
Exit code: 6 (partial)
```

### E. TUI wireframe

> TUI = CLI 的前端(G4):資料來源是 `setup_ubuntu list --json` / `detect
> --json`(ADR-0019 schema),動作 fork `setup_ubuntu <subcommand>` 子程序;
> TUI 自身不 source engine lib、不寫 state。Rich 層(fzf)以兩欄式導航器
> 呈現(左欄目前層級、右欄即時預覽),Fallback 層(whiptail)以對話框呈現,
> 兩層共用同一資料層與同一條安裝路徑(ADR-0024 / ADR-0025)。

主選單:

```
+- init_ubuntu v0.1.0 --------------------------------------+
|                                                           |
|  System: Ubuntu 24.04 / NVIDIA RTX 4090 / GNOME / X11     |
|                                                           |
|   1.  Quick Setup           Install all recommended       |
|   2.  Base Tools            View / toggle base modules    |
|   3.  Recommended  (5/6) v  Environment-aware suggestions |
|   4.  Optional              Browse optional modules       |
|   5.  Manage Installed -->  Update / Remove / Purge       |
|   6.  Manage Secrets   -->  setup_secrets (SSH/GPG)       |
|   7.  System Info           Environment detection details |
|                                                           |
|   <  Run  >    <  Exit  >                                 |
+-----------------------------------------------------------+
```

執行模型:主選單分類項只顯示非空 CATEGORY;Base / Recommended / Optional
子選單為純勾選(`< OK >` 存回記憶體、`< Back >` 放棄本頁),所有勾選只存在
記憶體、不落地;`< Run >` 是唯一批次執行點(進 Review & Install -> Proceed
才 fork CLI pipeline);`< Exit >` 直接退出、無副作用。例外:Quick Setup 與
Manage Installed 自帶執行,最終皆 fork 同一條 CLI pipeline。

Optional 子選單(按 TAGS 分組):

```
+- Optional Modules ----------------------------------------+
|                                                           |
|  cli-essentials:                                          |
|    [ ] eza           (ls alternative)                     |
|    [ ] zoxide        (cd alternative)                     |
|    [ ] batcat        (cat alternative)                    |
|    [ ] ripgrep       (grep alternative)                   |
|                                                           |
|  agent:                                                   |
|    [ ] claude-code                                        |
|    [ ] codex                                              |
|    [ ] gemini                                             |
|                                                           |
|  editor:                                                  |
|    [ ] vscode                                             |
|                                                           |
|  <  OK  >   <  Back  >                                    |
+-----------------------------------------------------------+
```

Quick Setup 多 step 流程:

```
Step 1/4: Confirm platform
  Detected: Ubuntu 24.04 / desktop / NVIDIA RTX 4090
  [Yes, continue]  [Override platform]

Step 2/4: Recommended modules  (5 / 8 will be installed)
  [x] nvidia-driver        (NVIDIA detected)
  [x] docker
  [x] fish
  [x] neovim               (will pull deps: fzf, lazygit, ...)
  [x] font                 (desktop only)
  [x] tmux                 (daily driver)
  [x] ssh-config           (daily driver)
  [x] git-config           (daily driver)
  [ Continue ]

Step 3/4: CLI Essentials suite?  (9 tools)
  lazygit / lazydocker / fzf / eza / zoxide / batcat / fdfind / ripgrep / fnm
  [ Yes, install all ]  [ Pick individually ]  [ Skip ]

Step 4/4: AI agent CLI?  (multi-select)
  [x] claude-code     (recommended)
  [ ] codex
  [ ] gemini
  [ Continue ]

Review & Install  -->  顯示完整安裝清單,Proceed / Back / Cancel
```

Manage Installed:

```
+- Manage Installed ----------------------------------------+
|                                                           |
|   Module          Version       Installed at             |
|   --------------- ------------- -----------------         |
|  > docker         27.4.0        2026-05-13 14:22         |
|  > neovim         0.10.2        2026-05-13 14:25         |
|  > fish           4.5.0         2026-05-13 14:31         |
|                                                           |
|   <  Update  > <  Remove  > <  Purge  > <  Back  >       |
+-----------------------------------------------------------+
```

破壞性操作確認對話框:

```
+- Confirm Purge -------------------------------------------+
|                                                           |
|  About to PURGE 'docker':                                 |
|    - apt-get purge docker-ce docker-ce-cli containerd.io  |
|    - rm -rf /etc/docker  ~/.docker                        |
|    - Remove from state.json                               |
|                                                           |
|  This will lose all containers / images / volumes.        |
|                                                           |
|  <  Proceed  >    <  Cancel  >                            |
+-----------------------------------------------------------+
```

Tier 偵測(ADR-0024:fzf Rich 層優先、whiptail Fallback 層保底):指定
`--backend fzf|whiptail` 時跳過偵測與安裝詢問(invalid 值退 exit 2 + usage);
否則有 fzf 就走 Rich 層,無 fzf 且互動時以純文字 prompt 詢問是否安裝 fzf
(TUI 自己不裝東西,而是 fork `setup_ubuntu install fzf`,G4),使用者拒絕或
非互動時落到 whiptail Fallback 層,兩者皆缺才 fatal(提示 `sudo apt install
whiptail` 或改用 CLI)。無 sudo 環境跑 TUI 退 code 4 提示改用 CLI(fzf 走
user-home 安裝,whiptail fallback 不需 sudo)。

### F. Module metadata 形狀(放檔頭)

```bash
NAME="docker"
VERSION_PROVIDED="apt-managed"
CATEGORY="recommended"                   # base | recommended | optional | experimental
TAGS=("container" "devops")              # TAGS[0] 決定 TUI 分組
HOMEPAGE="https://docs.docker.com/engine/"

declare -A DESCRIPTION=(
    [en]="Docker Engine + Compose plugin"
    [zh-TW]="Docker 容器引擎 + Compose 外掛"
)
declare -A POST_INSTALL_MESSAGE=(
    [en]="Run 'newgrp docker' or re-login to use docker without sudo."
    [zh-TW]="執行 'newgrp docker' 或重新登入以免 sudo 使用 docker。"
)
declare -A WARN_MESSAGE=()               # RISK_LEVEL=high 時 install 前顯示

SUPPORTED_UBUNTU=("22.04" "24.04" "26.04")
SUPPORTED_PLATFORMS=("desktop" "server" "wsl")
DEPENDS_ON=("curl")
CONFLICTS_WITH=()
SUPPORTS_USER_HOME=false
RISK_LEVEL="low"                         # low | medium | high
REBOOT_REQUIRED=false
INSTALL_TARGET_DEFAULT="sudo"            # sudo | user-home | auto
TEST_VERIFY_CMD="docker --version"
```

10 個 mandatory lifecycle 函式(ADR-0002)+ 2 個 helper phase:

```bash
detect()          # 0 = 此 module 可在當前環境執行
is_recommended()  # 0 = 在當前環境建議勾選(看 INIT_UBUNTU_FORM_FACTOR)
is_installed()    # 0 = 已安裝
install()         # 安裝(idempotent;看 INIT_UBUNTU_INSTALL_TARGET)
upgrade()         # 升級到 latest(idempotent;archetype 預設可用)
remove()          # 移除(保留 config,idempotent)
purge()           # 完整移除(含 config,idempotent)
verify()          # 0 = 裝後驗收;verify 失敗等同 install 失敗(ADR-0015)
is_outdated()     # 0 = 有新版可裝(GitHub 用 Sidecar 比對;APT 用 apt list --upgradable)
doctor()          # 0 = 運行時健檢(ADR-0009;有 daemon/group/runtime 的 module 須覆寫)
# helper-provided(作者不寫):info / status
```

Archetype A/B/C 的 `module_use_*_archetype` macro 一次綁定全部 10 個
lifecycle,只有 archetype D(custom)需作者自寫;覆寫用 super-call pattern。
完整 metadata 欄位型別 / 合法值、helper API、template 佈局、每 module 測試
契約見 `doc/module-spec.md`。

### G. state.json schema

每個 installed module 拆 `synced`(可跨機)+ `local`(本機 only)兩段
(ADR-0018)。Sync / import / export 只攜 `synced`,receiver 自己重建 `local`。

```json
{
  "version": "0.1.0",
  "installed": {
    "docker": {
      "synced": {
        "manual": true,
        "depends_on": ["curl"],
        "version_provided": "apt-managed",
        "installed_at": "2026-05-13T14:22:33+08:00",
        "installed_by": "init_ubuntu@v0.1.0"
      },
      "local": {
        "install_target_resolved": "sudo"
      }
    },
    "neovim": {
      "synced": {
        "manual": true,
        "depends_on": ["fzf", "lazygit", "ripgrep", "fdfind", "fnm"],
        "version_provided": "v0.10.2",
        "installed_at": "2026-05-13T14:25:01+08:00",
        "installed_by": "init_ubuntu@v0.1.0"
      },
      "local": {
        "install_target_resolved": "user-home",
        "user_home_root": "/home/<user>/.local/lib/init_ubuntu/neovim"
      }
    }
  }
}
```

Sidecar(`${XDG_STATE_HOME}/init_ubuntu/versions/<name>`):單行版本字串,
是 is_outdated 比對的真相源;install / upgrade 成功寫,remove / purge 刪;
不變式 `is_installed()==false` 等價 Sidecar 不存在(ADR-0001 / ADR-0027)。

### H. Config 檔(生成檔,勿手改)

```ini
# ===========================================================================
# THIS FILE IS AUTO-GENERATED BY setup_ubuntu. DO NOT EDIT BY HAND.
# Edit via:  setup_ubuntu config set <key> <value>
#            setup_ubuntu config unset <key>
# Manual edits will be preserved on a best-effort basis but may be overwritten
# by future schema migrations without notice.
# ===========================================================================

[ui]
lang = zh-TW
color = auto

[install]
default_yes = false
include_orphans_on_remove = false
install_target = auto                  # auto | sudo | user-home

[platform]
override =                             # 留空為自動;否則填 server / desktop / jetson 等

[modules.qmk-firmware]
enabled = false                        # 三態:true 強制納入 / false 強制排除 / 未設交給 is_recommended()

[modules.docker]
enabled = true

[secrets]
backend = auto                         # auto | pass | gnome-keyring | encrypted-file
```
