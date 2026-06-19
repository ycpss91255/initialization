---
name: init-ubuntu
version: 1.2.1
status: approved
owner: ycpss91255
created: 2026-05-13
updated: 2026-06-07
---

# PRD: init_ubuntu — Ubuntu 環境初始化工具

> 將既有的 `setup_ubuntu.sh` / `module/setup_*.sh` 重新組織為一套**模組化、可測試、有 CLI + TUI 雙前端、支援 install / remove / purge / upgrade / sync 等 apt-style 完整生命週期**的 Ubuntu 環境初始化工具。

---

## 1. Vision & Goals

### 1.1 Vision

讓**本人**在一台**全新 Ubuntu 機器**(包含 server、desktop、RPi 4/5、Jetson Orin、WSL 等多平台)上,透過單一工具完成個人化開發環境配置,並能在**重灌、換機、跨機同步、調整需求**時以最小成本還原或調整環境。

### 1.2 Goals

| # | Goal | Measurable Outcome |
|---|---|---|
| G1 | 一鍵安裝預設工具集 | `setup_ubuntu install --recommended` 在 Ubuntu 22.04 / 24.04 / **26.04** 乾淨機上 30 分鐘內裝完 |
| G2 | 環境感知推薦 | 偵測到 NVIDIA GPU / WSL / 容器 / VM / SBC 時自動調整推薦清單 |
| G3 | 完整生命週期 | 每個 module 都有完整 10 個 mandatory lifecycle(`detect` / `is_recommended` / `is_installed` / `install` / `upgrade` / `remove` / `purge` / `verify` / `is_outdated` / `doctor`),全部 idempotent(見 ADR-0002) |
| G4 | **TUI 是 CLI 的前端**(2026-06-06 定稿,對標 base repo):TUI 讀資料走 `setup_ubuntu list/detect --json`,執行動作 fork `setup_ubuntu <subcommand>` 子程序,不直接碰 engine lib | AC-11(CLI/TUI 行為一致)結構性成立 — TUI 沒有自己的安裝路徑 |
| G5 | 高測試覆蓋率 | **80% 為硬門檻**(kcov gate,AC-17),持續提升為 best-effort(不設 100% 硬性目標);全部在 Docker 內驗證 |
| G6 | CI/CD 可整合 | GitHub Actions 上 `ubuntu-22.04` / `ubuntu-24.04` / **`ubuntu-26.04`** 矩陣全綠 |
| G7 | 易擴充 | 新增一個 module 不需要改 engine 程式碼,只要符合 `module-spec.md` 契約 |

> 原 G8(並行安裝)已自 Goals 移除(2026-06-06):與 §5.2「並行安裝不做」矛盾;移入 §5.3 Backlog。

---

## 2. Non-Goals(明確不做)

- 不打算發佈 Docker image / container artifact(Docker 僅用於 CI 測試)
- 不取代 `ansible` / `nix-darwin` / `chezmoi` — 不是泛用配置管理工具,只針對 Ubuntu host
- 不支援 non-Ubuntu Linux 發行版(v1)
- 不做 GUI(只有 CLI + TUI)
- **不在 install pipeline 內處理 secrets** — 改由獨立子工具 `setup_secrets.sh` 負責(見 §14),避免在批次安裝時誤洩敏感資料
- 不做雲端同步(state 只存本機;跨機同步透過 §16 SSH push/pull)
- 不取代 `apt` — 對於系統套件仍委派給 `apt-get`,本工具只是 orchestration 層
- **不對外發行** — 主用途是個人多機部署;若要分享給他人,僅提供獨立簡易腳本(不維護其他人的使用情境)

---

## 3. Target Users

### 3.1 主要 persona

- **個人開發者(本人)**:每次重灌 Ubuntu 都希望快速還原開發環境
- 採用 fish / neovim(ayamir/nvimdots) / docker / lazygit / fzf / eza / zoxide 等工具鏈

### 3.2 使用情境

- **多機部署**:本人擁有多台 Ubuntu 機器(工作站 / 筆電 / WSL / RPi / Jetson),希望環境一致但能依平台微調
- **重灌還原**:重灌後快速回到工作狀態
- **跨機同步**:用 `setup_ubuntu sync user@host` 把本機 module 集合推到另一台

> **不規劃**對外發行;若需與他人分享,僅提供獨立簡易腳本作為示範,不對外承諾相容性或支援。

### 3.3 假設與限制

- **偏好**使用者有 `sudo` 權限,但**不要求**:
  - 工具啟動時偵測 sudo;若無,改用 user-home 安裝模式(裝到 `$HOME/.local/`)
  - 必要工具(如 `apt-essentials`)若無法用 user-home 安裝(無 sudo 不能 `apt install`),會跳過 + 警示使用者
  - 使用者可透過 `--install-target=sudo|user-home|auto` 或 `~/.config/init_ubuntu/config.ini` 覆寫安裝目標
- 使用者熟悉 terminal,能讀 CLI / TUI 介面
- 使用者已完成 Ubuntu 基本安裝(此工具不負責 OS 安裝)
- 安裝目標 binary 路徑可改(預設 `/opt`、`/usr/local/bin` for sudo;`$HOME/.local/{bin,lib,share}` for user-home)

### 3.4 取得工具(bootstrap,2026-06-06 定稿)

乾淨 Ubuntu 機器上的第一步是 **git clone + 直接執行**,不另做 installer / 一行式 bootstrap script:

```bash
sudo apt install -y git          # 乾淨 server/container 才需要;desktop 通常已有
git clone https://github.com/ycpss91255/initialization.git
cd initialization && ./setup_ubuntu_tui.sh   # 或 ./setup_ubuntu.sh install --recommended
```

- README 以此三行作為 Quick Start(取代現況的零說明)
- 與 self-upgrade(0.3.0,git pull / release)、user-local module 區同一世界觀
- **Self-deps preflight**:entrypoint 啟動時檢查工具自身依賴(`jq` / `curl` / `git`):
  - 缺 + 有 sudo → 提示並**詢問一次**是否 `apt install`(`-y` 時自動裝)
  - 缺 + 無 sudo → fail fast,印明確安裝指引(exit 4)
  - 解決「state/config/detect 需要 jq、但 jq 在 apt-essentials 內」的雞生蛋(AC-34)

---

## 4. User Stories

| # | As a... | I want to... | So that... |
|---|---|---|---|
| US-1 | 新機使用者 | 在乾淨 Ubuntu 跑 `setup_ubuntu_tui.sh` 一次裝完所有開發工具 | 快速進入工作狀態 |
| US-2 | 環境變動使用者 | `setup_ubuntu install lazydocker` 增加單一工具 | 不必重跑整套流程 |
| US-3 | 退場使用者 | `setup_ubuntu purge docker` 完整移除 docker 與 config | 釋放空間或解決衝突 |
| US-4 | NVIDIA 使用者 | TUI 看到「推薦安裝 nvidia-driver(偵測到 RTX 4090)」 | 不需自己研究要裝哪個版本 |
| US-5 | WSL / 容器使用者 | 工具自動跳過 nvidia-driver / qmk-firmware 等 host-only module | 不會誤裝壞掉的東西 |
| US-6 | 多機使用者 | `setup_ubuntu sync user@host` 把本機 module 推到另一台 | 跨機快速同步 |
| US-7 | 進階使用者 | 用 `setup_ubuntu install --no-deps neovim` 跳過依賴 | 手動掌控依賴版本 |
| US-8 | 無 sudo 使用者 | 工具自動偵測並 fallback 到 user-home 安裝 | 在受限環境下也能用 |
| US-9 | 多平台使用者(RPi / Jetson) | 工具偵測 form factor 並只推薦該平台合理的 module | 一套工具走多個平台 |
| US-10 | 開發者 | 寫一個新的 `module/myrust.module.sh` 就能加入工具 | 不必改 engine 程式碼 |
| US-11 | CI 使用者 | 在 Docker 內 `just -f justfile.ci test` 跑完所有測試 | 在 GitHub Actions 持續驗證 |
| US-12 | 安全意識使用者 | 用 `setup_secrets ssh-key generate` 互動產 key 並安全儲存 token | 不會忘記安全性的細節 |

---

## 5. Feature List

### 5.1 必備(v0.1 MVP)

**Engine**
- Module engine(loader + registry + dispatcher + dependency resolver);registry 為 **in-memory** — 每次執行動態掃 `module/` + user-local 區重建,無持久化 index(Q40)
- 環境偵測引擎(JSON 輸出,含 form_factor 平台分類)
- 依賴解析(拓樸排序、循環偵測)
- 狀態追蹤(`${XDG_STATE_HOME}/init_ubuntu/state.json`)+ per-module Sidecar(`versions/<name>`)
- 日誌(`${XDG_STATE_HOME}/init_ubuntu/logs/<ts>.jsonl`)
- Module 生命週期:**全 10 個 mandatory** — `detect` / `is_recommended` / `is_installed` / `install` / `upgrade` / `remove` / `purge` / `verify` / `is_outdated` / `doctor`(ADR-0002)
- Sudo 偵測 + non-sudo fallback(user-home install,可由 `--install-target` 覆寫)
- 4 層分類:`base` / `recommended` / `optional` / `experimental`
- User-local module 區:除了 repo `module/`,Engine 額外掃 `${XDG_CONFIG_HOME}/init_ubuntu/module/`(使用者私有模組,同 NAME 撞名時 user-local 勝)
- Self-deps preflight(`jq` / `curl` / `git` 檢查 + 一次性安裝詢問,§3.4 / AC-34)

**CLI subcommands(對標 apt 的常用使用方式)**
- `install` / `remove` / `purge` / `upgrade` / `verify` / `doctor`
- `search <kw>` / `show <m>`
- `list` / `detect`(`list --installed` / `--upgradable` / `--available` / `--json` 都實作;`status` deprecated → `list --installed`)
- `config get|set|unset|show`(讀寫 `${XDG_CONFIG_HOME}/init_ubuntu/config.ini`;`load` 已砍,Q6 / Q38)
- `sync <user@host>`(跨機 SSH push/pull,見 §16)
- `import <file>` / `export <file>`(state 匯出入,**v0.1 就要有**)
- `--version` / `--help`
- `--dry-run` 對所有破壞性操作

**TUI**
- `setup_ubuntu_tui` 多層選單(`gum`(優先)/ `whiptail`(fallback)雙後端,ADR-0023;`dialog` 已移除)
- 主選單含 Manage Installed / Manage Secrets 入口
- 子選單按 `TAGS[0]` 分組(cli-essentials / agent / editor / filemgr / logs / hardware / remote);主選單分類項只顯示**非空** CATEGORY(Q44 — experimental 目前為空故不顯示)
- 安裝完成後仍能用 CLI / TUI 管理(見 §17)

**輸出與 i18n**
- i18n 支援語系白名單:`{en, zh-TW, zh-CN, ja}`
- `lib/i18n.sh` 提供 `i18n_detect_lang`(讀 `$LANG`)+ `i18n_sanitize_lang`(typo 驗證,bilingual warning),對標 `ycpss91255-docker/base`
- Module-level i18n 訊息用 `declare -A`(關聯陣列)宣告 `DESCRIPTION` / `POST_INSTALL_MESSAGE` / `WARN_MESSAGE`;`module_i18n_get <ARR> [lang]` 查表(fallback `en`)
- ANSI 色彩**自動偵測**(後台 / 非 tty / `NO_COLOR=1` 自動關閉)
- `--color=auto|always|never`(預設 `auto`);`--verbose`/`-v` 設 `LOG_LEVEL=DEBUG`;`--quiet` 設 `LOG_LEVEL=WARN`

**測試 / CI**
- Docker 內完整測試框架(bats + bats-mock + fishtape + kcov)
- GitHub Actions CI:`ubuntu-22.04` / `ubuntu-24.04` / **`ubuntu-26.04`** 矩陣

**子工具**
- `setup_secrets.sh`(見 §14):SSH key / GPG / token 互動式安全處理

### 5.2 Roadmap(0.2.0 ~ 0.4.0)

> 版本階梯目前規劃至 **0.4.0**(2026-06-06 定稿);**1.0 暫不規劃**(非永久取消 — 若未來要做,先回本 PRD 變更並 bump 文件版本)。未排版本的願望收在 §5.3 Backlog。

| 版本 | 主題 | 內容 |
|---|---|---|
| **0.2.0** | 清理與遷移 | state schema migration 機制啟用(AC-30 / AC-31)・`tool/` 各檔去向逐一決定(§6.5)・`small-tools/` 標 deprecated(§6.6)・`.adoc` → `.md` 全轉(AC-28)・`doctor --json`(對齊 ADR-0019 agent-friendly schema) |
| **0.3.0** | 便利動詞 | `setup_ubuntu reinstall <m>`(= `remove` + `install`)・`setup_ubuntu autoremove`(清未被 `manual=true` module 依賴的 orphan)・`setup_ubuntu doctor --fix`(自動修復狀態檔失真 + config hand-edit 偵測,§10.3)・`setup_ubuntu self-upgrade`(主路徑 `git pull`,release 亦提供,§17.3)・shell completion(fish + bash:subcommand / module 名 / flag 動態補全,install 時裝進 `~/.config/fish/completions/`) |
| **0.4.0** | 終局 | `small-tools/` 移除(AC-27)・nvidia-driver 失敗自動回滾(AC-21,ADR-0020)・i18n 四語系全覆蓋(AC-29) |

> **並行安裝不做** — 始終 sequential。`dpkg` lock 與 sudo 互斥讓 apt module 無法並行;非 apt module 並行收益不足以抵 scheduler 複雜度。`PARALLEL_GROUP` metadata 也已從 module spec 移除。未來若使用體驗改變,自 §5.3 Backlog 重啟討論。

### 5.3 Backlog(願望清單,不排版本)

> 不承諾、不排程;若要實作,須先回到本 PRD 變更並 bump 文件版本。

- 並行安裝(非 apt module worker pool)
- `setup_ubuntu rollback`(任意版本回滾;upgrade 失敗的 archetype rollback 已涵蓋主要需求,見 §7.6)
- `setup_secrets sync ...`(secrets 跨機加密搬運)
- 支援 Debian 衍生(非 Ubuntu)
- Wayland-aware 推薦
- 蘋果硬體偵測 + 對應 driver 推薦
- Web UI(若有需求)

**已砍(不做,亦不入 Backlog,2026-06-06)**:
- Module repository(`setup_ubuntu module add <git-url>`)— 與「不對外發行」Non-Goal 矛盾;私有擴充由 user-local module 區(§5.1 / Q35)涵蓋
- Sync payload 簽章 — sync 走 SSH(strict host key checking + key-only 認證),通道已認證已加密,GPG 簽章為重複防護

---

## 6. Module Catalog

### 6.1 base(預設啟用,Quick Setup 必裝)

**前提**:任何用此 repo 安裝的機器都是 devel 平臺(workstation / laptop / rpi / jetson / wsl 一視同仁)。所有平台預設裝**同一份 universal devel pkg list**,僅以「相容性 + 功能重複」過濾(ADR-0011)。

| Module 檔名 | 來源 | 說明 | 依賴 |
|---|---|---|---|
| `apt-essentials.module.sh` | (新建) | Universal devel base:`git` / `vim` / `curl` / `wget` / `ca-certificates` / `build-essential` / `htop` / `unzip` / `jq` / `software-properties-common`。Engine 透過 `INCOMPAT_BY_PLATFORM` map 排除不相容的(例:`container` 默認排除 `build-essential`)。實際裝的 list freeze 入 state.json(ADR-0011)| — |
| `shell.module.sh` | `module/setup_shell.sh` | bash 設定 + 基本 alias | apt-essentials |

### 6.2 recommended(環境感知,預設勾選但可取消)

#### 推薦策略(自動 + 互動雙模式)

- **自動偵測**:由 `lib/detect.sh` + `lib/platform.sh` 偵測 form factor(`desktop` / `server` / `rpi-4` / `rpi-5` / `jetson-orin` / `wsl` / `container` / `vm`),`is_recommended()` 依此回應
- **使用者互動覆寫**:
  - CLI:`--profile=server|desktop|jetson` 強制覆寫
  - TUI:System Info 畫面顯示偵測結果並**詢問是否同意**
  - Config:透過 `setup_ubuntu config set platform.override server`(見 §7.2)寫入;**禁止手動編輯 `config.ini`**(它由工具生成,檔頭會印警告)

| Module 檔名 | 來源 | 說明 | 依賴 | `is_recommended` 觸發條件 |
|---|---|---|---|---|
| `nvidia-driver.module.sh` | `module/setup_nvidia_driver.sh` | NVIDIA 顯卡驅動(`RISK_LEVEL=high`,含失敗回復機制,見 §11.3) | apt-essentials | 偵測到 NVIDIA GPU **且** 非 VM/container/WSL/jetson |
| `docker.module.sh` | `module/setup_docker.sh` | Docker Engine + Compose plugin | apt-essentials | 非 container 內 |
| `fish.module.sh` | `module/config/fish/` 為基礎 | Fish shell + 個人 config | apt-essentials | 永遠 |
| `neovim.module.sh` | `module/setup_neovim.sh`(拆分) | Neovim + 推薦勾選 nvimdots(default Enter 即裝) | apt-essentials, git-config, fzf, lazygit, ripgrep, fdfind, fnm | desktop / server / SBC 皆 yes(個人主力編輯器) |
| `font.module.sh` | `module/setup_font.sh` | Nerd Font(Cascadia / FiraCode) | apt-essentials | 有桌面環境 |
| `tmux.module.sh` | `module/config/tmux/` | tmux + 個人 config | apt-essentials | 永遠(日用必裝) |
| `ssh-config.module.sh` | `module/config/ssh_config` | SSH client 設定 | — | 永遠(日用必裝) |
| `git-config.module.sh` | `module/config/git_config` | git 全域設定 | apt-essentials | 永遠(日用必裝) |

> **vscode 從 recommended 降級為 optional**(已不是主力編輯器)— 見 §6.3。
> **tmux / ssh-config / git-config 從 optional 升級為 recommended**(本人日用必裝)。


### 6.3 optional(預設不勾選,使用者主動選擇)

`optional` 按 `TAGS[0]` 分為三個次群組,TUI Quick Setup 會逐群詢問是否安裝;CLI 可用 `setup_ubuntu install --tag=<group>` 一次裝整群。

#### 6.3.1 CLI Essentials(`TAGS=("cli-essentials")`)— 強烈推薦,Quick Setup 預設 yes

日用 CLI 工具(`ls` / `cd` / `cat` / `find` / `git` UI 等的現代替代)。

| Module 檔名 | 來源 | 說明 | 依賴 |
|---|---|---|---|
| `lazygit.module.sh` | `module/submodules/lazygit.sh` | Git TUI | apt-essentials |
| `lazydocker.module.sh` | `module/submodules/lazydocker.sh` | Docker TUI | docker |
| `fzf.module.sh` | `module/submodules/fzf.sh` | Fuzzy finder | apt-essentials |
| `eza.module.sh` | `module/submodules/eza.sh` | `ls` 替代 | — |
| `zoxide.module.sh` | `module/submodules/zoxide.sh` | `cd` 替代 | — |
| `batcat.module.sh` | `module/submodules/batcat.sh` | `cat` 替代(語法高亮) | — |
| `fdfind.module.sh` | `module/submodules/fdfind.sh` | `find` 替代 | — |
| `ripgrep.module.sh` | (新建,apt archetype;Q41) | `grep` 替代(`rg`) | — |
| `fnm.module.sh` | (新建,拆自 setup_neovim.sh) | Fast Node Manager | — |

> 這些 module 也是 `neovim.module.sh` 的 dep — 裝 neovim 時會自動拉,但也可單獨裝。

#### 6.3.2 Agent CLI(`TAGS=("agent")`)— 多選一(或多選 / 不選)

三大 AI CLI agent,Quick Setup 預設 multi-select(0~3 個)。

| Module 檔名 | 來源 | 說明 | 依賴 |
|---|---|---|---|
| `claude-code.module.sh` | (新建) | Anthropic Claude Code CLI(官方 native installer,archetype D;自帶 auto-update,`is_outdated` 委派之) | — |
| `codex.module.sh` | (新建) | OpenAI Codex CLI(github-release archetype,原生 binary) | — |
| `gemini.module.sh` | (新建) | Google Gemini CLI(npm 安裝 — npm-only 發行) | fnm |
| `claude-code-config.module.sh` | `module/config/claude/` | Claude Code 個人 settings(裝完 claude-code 才裝) | claude-code |

#### 6.3.3 其他(各種 `TAGS[0]`)— 環境/硬體特定或備選

| Module 檔名 | 來源 | 說明 | 依賴 | TAGS[0] |
|---|---|---|---|---|
| `vscode.module.sh` | `module/setup_vscode.sh` | VS Code(從 recommended 降級) | apt-essentials | editor |
| `yazi.module.sh` | `module/submodules/yazi.sh` | TUI file manager | — | filemgr |
| `ranger.module.sh` | `module/config/ranger/rifle.conf` | ranger 檔案管理 | — | filemgr |
| `lnav.module.sh` | `module/config/lnav_pkg/` | log navigator | — | logs |
| `qmk-firmware.module.sh` | `module/setup_qmk_firmware.sh` | QMK 韌體開發環境 | apt-essentials, build-essential | hardware |
| `anydesk.module.sh` | `module/anydesk.sh` | AnyDesk 遠端桌面(`SUPPORTED_PLATFORMS=("desktop")`,Q49) | apt-essentials | remote |
| `notion.module.sh` | (新建,Q50 / #35) | Notion 桌面版(github-release archetype 吃 notion-electron `.deb`;取代 small-tools snap 路徑;`SUPPORTED_PLATFORMS=("desktop")`) | apt-essentials | notes |
| `jetson-stats.module.sh` | (新建,Q51 / #37) | jetson-stats(`jtop` 監控 TUI;pip 安裝;`SUPPORTED_PLATFORMS=("jetson-orin")`) | apt-essentials | hardware |

> TUI 在 §6.3.3 內進一步按 `TAGS[0]` 子分組顯示(`editor` / `filemgr` / `logs` / `hardware` / `remote` / `notes`)。
>
> **gnome-terminal-config 已自 catalog 移除**(Q42,2026-06-06):來源檔 `tool/copy_gnome_terminal_config.sh` 隨 §6.5 整批搬遷至 `tool/`,v0.2+ 再個別決定去向 — 修復「同一檔案兩個矛盾去向」。

### 6.4 experimental(預設不裝,有風險或不穩定)

`experimental` 分類保留,作為未來不穩定 module 的入口。**目前無 module 在此類**(`dual-system-time-sync` / `trash-maintenance` 為一次性腳本,不放 TUI / module pipeline 內,見 §6.5)。

### 6.5 tool/* 處理

> **v0.1 整個 `tool/` 不處理**;一次性腳本(如 `trash.sh`)不放在 TUI 內 / 不模組化。

**v0.1 操作**:
- `tool/*` 整個目錄**搬遷到 repo 根目錄**(如 `tool/`),作為臨時存放區
- 不進 module catalog、不出現在 TUI、不走 install pipeline
- 各檔案後續(v0.2+)再個別討論去向

涵蓋的檔案:
- `tool/setup_terminal_font_size.sh`
- `tool/copy_neovim_local_config.sh`
- `tool/copy_gnome_terminal_config.sh`
- `tool/dual_system_time_sync.sh`
- `tool/trash-maintenance.sh`(原規劃 experimental,撤回)
- `tool/ros1/*`
- `tool/remove/*.sh`

### 6.6 small-tools/ 退場路徑

`small-tools/install.sh` 內裝的東西基本與上述 module 重疊,規劃:
- 0.1.0 釋出:`small-tools/` 維持原狀,可獨立執行
- 0.2.0:在 `setup_ubuntu list` 標示「small-tools/ deprecated,請改用 `setup_ubuntu install --base`」
- 0.4.0:`small-tools/` 移除,README 內僅保留歷史說明(AC-27)

---

## 7. CLI Interface Specification

### 7.1 命令骨架

```
setup_ubuntu <subcommand> [args] [flags]
```

### 7.2 Subcommand 表

> 目前以下列為主,**未來可擴充**(如 `module add` / `self-upgrade` 等已列在 §5.2 nice-to-have)。

| Subcommand | Args | Flags | 行為 | 對標 apt |
|---|---|---|---|---|
| `install` | `<module>...` | `-y / --yes`、`--dry-run`、`--no-deps`、`--base`、`--recommended`、`--all-base`、`--category=<n>`、`--install-target=auto\|sudo\|user-home`、`--force` | 安裝指定 module(自動帶 dep)。`--dry-run` 對整條 dep chain 傳播:engine 對每個 dep + 主 module 都 call `install()`,各 module 內透過 `module_dryrun_guard` 只印 cmd 不執行;dry-run 跳過 verify(印 `verify_skipped`);結束印 summary 列出所有 would-install module。AC-12 驗證 dry-run 期間無 fs 寫入。**確認行為(2026-06-06)**:無 `-y` 時 dep 解析完先列 plan(`Will install: neovim + 6 deps (fzf, lazygit, ...)`)問 `Proceed? [Y/n]`(install 預設 Y;upgrade 維持 `[y/N]`,§7.6);`-y` 跳過 | `apt install` |
| `remove` | `<module>...` | `-y / --yes`、`--dry-run`、`--with-orphans` | 移除 module(保留 config) | `apt remove` |
| `purge` | `<module>...` | `-y / --yes`、`--dry-run`、`--with-orphans` | 完整移除 module + config | `apt purge` |
| `upgrade` | `[<module>...]` | `-y`、`--dry-run` | 呼叫各 module `upgrade()` 升級到 latest(不帶名 = 升級所有 `state.json` 已裝)。詳見 §7.6 | `apt upgrade` |
| `verify` | `[<module>...]` | `--dry-run` | 跑 module `verify()` 做裝後驗收(不帶名 = 驗證所有 installed) | — |
| `search` | `<keyword>` | — | 在 NAME / DESCRIPTION / TAGS 內搜尋 | `apt search` |
| `show` | `<module>` | — | 印出 module 完整 metadata | `apt show` |
| `list` | — | `--category=<n>`、`--installed`、`--upgradable`、`--available`、`--tag=<t>`、`--json` | 列出 module(`--installed` 取代 `status`) | `apt list` |
| `status` | `[<module>]` | `--json` | **deprecated**(forward 到 `list --installed`,印 warn 提示) | — |
| `detect` | — | `--json` | 環境偵測結果(也是 `doctor` 開頭印出的一部分) | — |
| `doctor` | `[<module>...]` | `--validate-modules`、`--fix`(0.3.0) | 不帶名 = 印 env detect + 跑所有 installed 的 `doctor()`;帶名 = 跑該 module;`--validate-modules` 跑 metadata lint | — |
| `config set` | `<key>` `<value>` | — | 修改 `~/.config/init_ubuntu/config.ini` 的單一鍵值(取代手動編輯) | — |
| `config get` | `<key>` | — | 讀取單一鍵值 | — |
| `config unset` | `<key>` | — | 移除單一鍵值(回復為預設) | — |
| `config show` | — | `--json` | 印出整個有效 config(覆寫關係 + default) | — |
| `sync` | `<user@host>` | `--modules=<list>`、`--include-user-local-modules`、`--pull`、`--apply` | SSH 跨機同步(見 §16);conflict 規則見 ADR-0013(dry-run default、union、remote-wins) | — |
| `import` | `<file>` | `--apply` | 從 export 過的 state.json 還原。**內部走同一 conflict pipeline** as `sync --pull`(ADR-0013):預設 dry-run,`--apply` 套用,union + remote-wins。差別只在資料源是 local file 不是 SSH | — |
| `export` | `<file>` | `--modules=<list>` | 匯出 state.json `synced` 段 子集(ADR-0018) | — |
| `help` | `[<subcommand>]` | — | 顯示說明 | `apt --help` |
| `version` | — | — | 顯示版本 | `apt --version` |

> **`apt update` 無對應子命令**(Q40,2026-06-06,原 `update` 已砍):module 來源是本地檔案(repo `module/` + user-local),registry 每次執行 in-memory 動態重建,無 index 可過期;GitHub release 版本情報走 gh-latest cache(§7.6,查詢時隨需抓 + TTL 1h),apt 索引 freshness 委派系統(Q31);工具自身更新走 `self-upgrade`(0.3.0,§17.3)。

### 7.3 範例

```bash
# 一鍵裝完所有 recommended(會依環境推薦自動勾選)
setup_ubuntu install --recommended -y

# 對標 apt 的常用流程
setup_ubuntu search fuzzy
setup_ubuntu show eza
setup_ubuntu install eza
setup_ubuntu upgrade neovim

# 只裝單一 module(自動帶 dep)
setup_ubuntu install neovim

# 跳過 dep(進階)
setup_ubuntu install neovim --no-deps

# 看會做什麼(不實際執行)
setup_ubuntu install docker --dry-run

# 移除但保留 config
setup_ubuntu remove neovim -y

# 完整移除
setup_ubuntu purge neovim -y

# 列出可裝 module
setup_ubuntu list --category=optional --tag=agent

# 看環境
setup_ubuntu detect --json | jq

# 健康檢查
setup_ubuntu doctor

# 跨機同步
setup_ubuntu sync user@laptop --modules=base,recommended

# Export / Import
setup_ubuntu export ~/my-state.json
setup_ubuntu import ~/my-state.json

# 套用 module config(config-drop module,走正常 install pipeline,Q6)
setup_ubuntu install git-config
```

### 7.4 Exit code

| Code | 意義 |
|---|---|
| 0 | 成功 / Query 答案=yes |
| 1 | 一般錯誤 / Query 答案=no |
| 2 | 引數錯誤(unknown subcommand / module 名拼錯 / **metadata 不合法**) |
| 3 | 環境不支援(non-Ubuntu / 不支援的 Ubuntu 版本) |
| 4 | sudo 不可用且 module 不支援 user-home |
| 5 | 依賴循環 / 依賴解析失敗 / **CONFLICTS_WITH 觸發** |
| 6 | 部分 module 失敗(其他成功) |
| 7 | **遠端 / 網路操作失敗**(sync/SSH、GitHub release download、apt repo 不通) |

> Lifecycle 函式分三類使用 exit code:
> - **Query 類**(`detect` / `is_installed` / `is_recommended` / `is_outdated`):0=yes,1=no
> - **Action 類**(`install` / `upgrade` / `remove` / `purge`):0=成功,1=一般失敗,3=env 不支援,4=sudo 缺,5=dep 缺(standalone),7=網路
> - **Diag 類**(`verify` / `doctor`):0=通過,1=不通過,7=網路失敗(如 is_outdated 走網路)

### 7.5 Global flags

| Flag | 說明 |
|---|---|
| `--lang=en\|zh-TW\|zh-CN\|ja` | 強制語言(白名單同 i18n,Q23 / Q47;未翻譯字串 fallback `en`) |
| `--quiet` | 不輸出 info(只輸出 warn / error) |
| `--verbose / -v` | 輸出 debug 等級 |
| `--color=auto\|always\|never` | ANSI 色彩控制;**預設 `auto`,自動偵測 tty / `$NO_COLOR` / `$TERM=dumb` / 後台執行**,適合輸出彩色才開 |
| `--state-dir=<path>` | 改寫 state 目錄(預設 `${XDG_STATE_HOME:-$HOME/.local/state}/init_ubuntu`) |
| `--install-target=auto\|sudo\|user-home` | 強制安裝目標(預設 `auto`) |
| `--profile=server\|desktop\|jetson\|...` | 強制平台 form factor(覆寫自動偵測) |

### 7.6 `upgrade` 詳細語意

`setup_ubuntu upgrade` 不帶 module 名 = 升級所有 state.json 已裝。流程:

1. **掃 state.installed** → topo-sort by `synced.depends_on`(leaf 先升,ADR-0018)
2. **Batch `is_outdated` 查詢**:
   - GitHub release modules:走 `${XDG_CACHE_HOME:-$HOME/.cache}/init_ubuntu/gh-latest/<repo>.json` cache,TTL 1 小時(避 rate limit)
   - apt modules:`apt list --upgradable` 一次掃,比對 `frozen_pkgs`
3. **顯示 plan**(除非 `-y`):
   ```
   Will upgrade 4 of 12 installed modules (topo order):
     fzf       v0.50.0 → v0.51.0
     lazygit   v0.40.1 → v0.41.0
     ripgrep   apt-managed → upgradable
     neovim    v0.10.2 → v0.10.5
   8 already at latest: fish, eza, zoxide, ...
   Proceed? [y/N]
   ```
4. `--dry-run` = 只印 plan 不執行;`-y` = 跳 prompt 直接執行
5. **執行**:序列(per dep order),`sudo -v` 先刷 timestamp 避免 prompt 中斷
6. **失敗策略**:continue(per-module 失敗不阻其他)。失敗 module 的 `version_provided` **不更新**(保留舊值)+ log `upgrade_failed` event(ADR-0006 schema)
7. **失敗 rollback**:
   - User-home archetype(ADR-0017):嘗試 swap `current` symlink 回舊版本目錄(舊 dir 在 upgrade 中保留到 verify 通過才刪)
   - Apt archetype:**不自動 rollback**(apt 沒乾淨 rollback 機制),log warn 提示 user `apt install <pkg>=<old-ver>`
   - Config-drop archetype:swap config file 回 backup(`backup_file` 在 upgrade 前已備份)
8. **結束 summary**:
   ```
   Upgraded:  fzf, lazygit, ripgrep
   Failed:    neovim (verify failed at v0.10.5, rolled back to v0.10.2)
              → trace_id=abc-def, see jsonl log
   Skipped:   fish, eza, ...
   Exit code: 6 (partial)
   ```

upgrade 一個 module 與 install 一樣走 install → verify pipeline(ADR-0015)。verify 失敗 = upgrade 失敗,觸發 archetype rollback。

### 7.7 安裝執行輸出 UX(2026-06-06 定稿)

> 設計原則承襲 ADR-0006 / 觀測性架構:**JSONL 事件是單一真相源,人讀輸出是事件的 render 結果**。

#### 7.7.1 進行中(預設)

stdout 只印 per-module 進度標頭 + `exec_cmd`(`lib/general.sh`,語法高亮)印出的主要命令行;子命令自身的 stdout/stderr **不 stream**,捕捉進 JSONL(`body: cmd_exec`,attributes 含 `exit` / `duration_ms`):

```
[2/8] docker: installing...
  $ sudo apt-get update
  $ sudo apt-get install -y docker-ce docker-ce-cli ...
  ✔ docker installed (32s)
```

- **失敗時**:自動 dump 該 module 子命令輸出最後 ~20 行 + `trace_id` + log 檔路徑
- `--verbose`:子命令輸出即時 stream
- `--quiet`:連進度行都不印(只剩 warn / error)

#### 7.7.2 結尾「Action required」聚合

「事後要做」訊息**不在裝完當下印**(會被後續輸出洗掉),統一走結構化事件 → 結尾衍生:

1. `module_emit_post_install` / `module_emit_reboot_required`(module-spec §4.10)發 JSONL 事件:
   `{"body":"action_required","attributes":{"kind":"post_install|reboot|path","service.name":"<module>","message":"<i18n-resolved>"}}`
2. Engine 於 session 結尾從本 session 的 `action_required` 事件**衍生**人讀聚合區:
   ```
   ── Action required ─────────────────────
   docker:  Run 'newgrp docker' or re-login to use docker without sudo.
   neovim:  PATH must include $HOME/.local/bin
   ⚠ Reboot required (nvidia-driver). Run: sudo reboot
   ```
3. Agent 以 `jq 'select(.body=="action_required")'` 取得完全相同資訊 — stdout 與 log 永不分歧(AC-35)

---

## 8. TUI Wireframe

> **TUI = CLI 的前端**(2026-06-06 定稿,見 G4):TUI 只負責畫面與收集選擇 — 選單資料來源是 `setup_ubuntu list --json` / `detect --json`(ADR-0019 schema),所有動作 fork `setup_ubuntu <subcommand>` 子程序執行。TUI 自身不 source engine lib、不寫 state。

### 8.1 主選單

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

#### 執行模型(Q43 / Q44,2026-06-06 round-4 定稿)

- **主選單分類項只顯示非空 CATEGORY**(Q44):`experimental` 目前為空故無選單項;未來有 module 時自動出現,不需改 spec。原「Advanced(Experimental / custom)」項已移除,「custom」概念廢除(user-local module 依其 `CATEGORY` 歸入對應分類)
- **勾選累積器模型**(Q43):Base / Recommended / Optional 子選單為**純勾選** — `< OK >` 把本頁勾選存回 TUI process 記憶體、`< Back >` 放棄本頁勾選。所有勾選只存在於記憶體,**不落地**
- **`< Run >` 是唯一批次執行點**:進 Review & Install 畫面(完整清單 + dep 摘要)→ Proceed 才清幕 fork CLI pipeline(§7.7);Back / Cancel 回主選單、勾選保留。無任何勾選時按 Run 印 `nothing selected` 返回
- **`< Exit >`**:直接退出,記憶體勾選全丟,**無副作用**
- **例外**:Quick Setup(自帶 Review → Proceed,§8.2.1)與 Manage Installed(走 §8.4 確認對話框)維持自帶執行 — 最終皆 fork 同一條 CLI pipeline,G4 單一安裝路徑不變

### 8.2 子選單範例:Optional(按 TAGS 分組)

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

> Module 在 TUI 內按 `TAGS[0]` 自動分組;每個 module 只在第一個 tag 群組顯示,避免重複勾選混淆。
>
> **Dep 鏈顯示**(arch §18.2 Q-A3,2026-06-06 定稿):勾選 module 時 dep 鏈預設**折疊**,僅顯示「will pull N deps」一行提示;可展開明細。gum / whiptail 雙後端行為一致。

### 8.2.1 Quick Setup 多 step 流程

Quick Setup(主選單第 1 項)會逐步引導使用者,**不是一鍵全裝**,避免一次勾選爆量:

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

`optional - 其他`(§6.3.3)不在 Quick Setup 內,使用者要用主選單第 4 項「Optional」進入逐項選擇。

#### Proceed 後執行畫面(2026-06-06 定稿)

Review 按 Proceed 後 **TUI 清幕退出,改以 CLI pipeline 輸出**(§7.7:exec_cmd 命令流 + 結尾 Action required 聚合)。不做 gauge / progress 類 widget(AC-11 要求 CLI / TUI 安裝行為完全一致 — 共用同一條輸出 pipeline 讓 AC-11 天然成立)。

#### Cancel / 中斷行為

Quick Setup 採「Prepare → Execute」分階段:

| 階段 | Cancel / SIGINT 行為 |
|---|---|
| Step 1 ~ 4(prepare,累積選擇)| TUI exit。**無副作用** — 所有選擇在 TUI process 記憶體 only,platform override 不寫到 config.ini 直到 Review |
| Review screen 按 Proceed **前** | 同上,純 cancel |
| Review screen 按 Proceed **後**(install pipeline running) | SIGINT → engine 收到 → 當前 module 跑完當前那步收尾 → 印 partial summary(已裝 / 未裝)→ exit 6。state.json **反映實際**:已成功的留,未完成的不寫(同 Q1 partial install policy / ADR-0015)|

v0.1 **不支援 resume**(中斷後得從頭跑 Quick Setup)。Quick Setup 內 state 是純記憶體關聯陣列。

#### Quick Setup 的 manual flag(ADR-0010)

user 在 TUI 看到清單 + Proceed = 顯式同意每一個。Quick Setup 安裝的所有 module 在 state.json 標 **`manual=true`**(跟 CLI `setup_ubuntu install fzf eza zoxide` 顯式 named 一致)。

dep 鏈拉進來、user 沒在 TUI 勾的 module → 維持 `manual=false`(orphan-eligible)。範例:
- user 在 Step 2 勾 `neovim`,Step 3 「Pick individually」只勾 `lazygit` + `eza`
- engine 為了 neovim 自動拉 `fzf` + `ripgrep` + `fdfind` + `fnm`
- 結果:`neovim` / `lazygit` / `eza` `manual=true`,`fzf` / `ripgrep` / `fdfind` / `fnm` `manual=false`

### 8.3 子選單範例:Manage Installed

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

> Manage Installed 內也可切換到「按 type 分組」檢視(cli-essentials / agent / editor / ...,同 `TAGS[0]` 分組),便於管理大量已裝 module。

### 8.4 確認對話框(破壞性操作)

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

### 8.5 後端偵測(ADR-0023:gum 優先,whiptail fallback,dialog 已移除)

後端集合固定為 **gum + whiptail**:兩者都能原生渲染 4 個 contract widget。
gum(`charmbracelet/gum`)是現代化的單一靜態 Go binary(多架構:x86_64 /
rpi4/5 / Jetson);`whiptail` 是 Ubuntu Server / Desktop default 已 ship 的
保底 fallback(Priority: important),所以實務上幾乎不會 trigger fatal。

偵測 + 啟動流程:

```bash
# 偽碼
if [[ -n "$TUI_BACKEND" ]]; then
  : # --backend gum|whiptail 已指定 → 跳過偵測與安裝詢問(invalid → exit 2 + usage)
elif command -v gum >/dev/null; then
  TUI_BACKEND="gum"
elif [[ -t 0 ]]; then
  # gum 缺席且 interactive:純 stdin/stdout read prompt(預設 Yes,不假設任何 TUI 工具)
  read -rp "Install gum for a nicer TUI? [Y/n] " ans
  if [[ "$ans" != [Nn]* ]]; then
    setup_ubuntu install gum   # fork CLI 安裝(TUI 自己不裝任何東西,G4)
    command -v gum >/dev/null && TUI_BACKEND="gum" || TUI_BACKEND="whiptail"
  else
    TUI_BACKEND="whiptail"
  fi
elif command -v whiptail >/dev/null; then
  TUI_BACKEND="whiptail"   # 非 interactive:不詢問,直接 whiptail
else
  log_fatal "TUI requires 'gum' or 'whiptail' (default Ubuntu).
             Both missing — your install is unusually stripped.
             Fix:  sudo apt install whiptail
             Or:   use CLI mode: setup_ubuntu install <module>"
fi
```

**`--backend gum|whiptail`**:強制 `TUI_BACKEND` 並**跳過偵測與安裝詢問**
(invalid 值 → exit 2 + usage),讓 CI/QA 在任一後端已裝的情況下強測另一個
(`just tui --backend whiptail`,沿用既有 `tui *args` pass-through recipe)。

TUI 自己**不**裝任何東西(G4):需要 gum 時 fork `setup_ubuntu install gum`,
安裝詢問是純文字 prompt(該時點還沒有任何 TUI 工具可用)。沒 sudo 環境跑
TUI 退 code 4 提示改用 CLI(gum 走 user-home 安裝,whiptail fallback 不需 sudo)。

---

## 9. Module Contract(完整定義)

> 完整 spec 在 `doc/module-spec.md`。Author 操作指南在 `doc/guide/module-authoring.md`。此處為摘要。

### 9.1 Required metadata(放檔頭)

```bash
NAME="docker"
VERSION_PROVIDED="apt-managed"
CATEGORY="recommended"                   # base | recommended | optional | experimental
TAGS=("container" "devops")              # TAGS[0] 決定 TUI 分組
HOMEPAGE="https://docs.docker.com/engine/"

# i18n 用 declare -A(關聯陣列),helper module_i18n_get 查表
declare -A DESCRIPTION=(
    [en]="Docker Engine + Compose plugin"
    [zh-TW]="Docker 容器引擎 + Compose 外掛"
)
declare -A POST_INSTALL_MESSAGE=(        # 裝完後 engine 印給使用者(optional)
    [en]="Run 'newgrp docker' or re-login to use docker without sudo."
    [zh-TW]="執行 'newgrp docker' 或重新登入以免 sudo 使用 docker。"
)
declare -A WARN_MESSAGE=()               # RISK_LEVEL=high 時 install 前顯示(optional)

SUPPORTED_UBUNTU=("22.04" "24.04" "26.04")
SUPPORTED_PLATFORMS=("desktop" "server" "wsl")
DEPENDS_ON=("apt-essentials")
CONFLICTS_WITH=()
SUPPORTS_USER_HOME=false                 # 是否支援 non-sudo 安裝
RISK_LEVEL="low"                         # low | medium | high
REBOOT_REQUIRED=false                    # bool — install 後是否需重開
INSTALL_TARGET_DEFAULT="sudo"            # sudo | user-home | auto
TEST_VERIFY_CMD="docker --version"       # verify() 預設執行(idempotent + 快)
```

砍除欄位(v0.1 不再用):`DESCRIPTION_EN` / `DESCRIPTION_ZH_TW`(改 `declare -A DESCRIPTION`)、`MAINTAINER`、`RECOVERY_FALLBACK`、`PARALLEL_GROUP`、`INSTALL_TIME_ESTIMATE`、`DISK_SPACE_ESTIMATE`。

> **`DEPENDS_ON` 規則(Q39,2026-06-06)**:元素**只允許 module 名**(registry 內解析得到的 `NAME`),不得填 apt pkg 名(如 `git` — 它由 `apt-essentials` 提供)或平台條件(平台限制走 `SUPPORTED_PLATFORMS`)。`doctor --validate-modules` 驗證每個 dep 都能解析,解析不到 = metadata 不合法(exit 2)。

### 9.2 Required functions(10 個 lifecycle 全 mandatory,ADR-0002;另加 2 helper phase)

```bash
detect()          # 0 = 此 module 可在當前環境執行
is_recommended()  # 0 = 在當前環境建議勾選(會看 INIT_UBUNTU_FORM_FACTOR)
is_installed()    # 0 = 已安裝
install()         # 安裝(idempotent;會看 INIT_UBUNTU_INSTALL_TARGET)
upgrade()         # 升級到 latest(idempotent;archetype 預設可用)
remove()          # 移除(保留 config,idempotent;Engine 同時刪 Sidecar)
purge()           # 完整移除(含 config,idempotent;Engine 同時刪 Sidecar)
verify()          # 0 = 裝後驗收(post-install acceptance);install 失敗等同 install 失敗(ADR-0015)
is_outdated()     # 0 = 有新版可裝(GitHub 用 Sidecar 比對;APT 用 `apt list --upgradable`)
doctor()          # 0 = 運行時健檢;有 daemon/group/runtime config 的 module 必須覆寫(ADR-0009)
```

Helper-provided phases(由 `lib/module_helper.sh` 統一實作,作者不寫):

```bash
info              # standalone CLI 印 metadata(module_standalone_info)
status            # standalone CLI 印 is_installed / is_outdated / Sidecar 版本(module_standalone_status)
```

12 phase 總共 = 10 lifecycle + 2 helper。CLI `setup_ubuntu show <m>` 對應 standalone `info`;CLI `list --installed` 對應 standalone `status`。底層共用 helper 預設實作。

Archetype A/B/C(apt / github-release / config-drop)的 `module_use_*_archetype` macro 一次綁定全部 10 個 lifecycle;只有 archetype D(custom)需作者自寫。覆寫 archetype 預設用 super-call pattern:`install() { module_default_apt_install || return $?; _extra_step; }`。

### 9.3 Module 範本(v2 dual-mode)

```bash
#!/usr/bin/env bash
# module/docker.module.sh

# ── Dual-mode header(standalone vs engine 自動切換)─────────
MODULE_STANDALONE="true"
[[ "${BASH_SOURCE[0]}" != "${0}" ]] && MODULE_STANDALONE="false"
if [[ "${MODULE_STANDALONE}" == "true" ]]; then
    set -euo pipefail
    shopt -s inherit_errexit 2>/dev/null || true
    MODULE_DIR="${MODULE_DIR:-$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)}"
    REPO_ROOT="${REPO_ROOT:-$(cd -- "${MODULE_DIR}/.." && pwd -P)}"
    LIB_DIR="${LIB_DIR:-${REPO_ROOT}/lib}"
    source "${LIB_DIR}/logger.sh"
    source "${LIB_DIR}/general.sh"
    source "${LIB_DIR}/module_helper.sh"
fi

# ── Metadata(見 §9.1)──────────────────────────────────────
NAME="docker"
VERSION_PROVIDED="apt-managed"
CATEGORY="recommended"
declare -A DESCRIPTION=(
    [en]="Docker Engine + Compose plugin"
    [zh-TW]="Docker 容器引擎 + Compose 外掛"
)
# ... 其餘 metadata 省略

# ── Lifecycle:hand-written(docker 需特殊 apt repo 設定,不套 archetype)──
APT_PKGS=("docker-ce" "docker-ce-cli" "containerd.io" "docker-buildx-plugin" "docker-compose-plugin")

is_installed() { dpkg -l docker-ce 2>/dev/null | grep -q '^ii'; }
detect()       { command -v lsb_release >/dev/null && [[ "$(lsb_release -is)" == "Ubuntu" ]]; }
is_recommended() {
    is_installed && return 1
    systemd-detect-virt --container --quiet 2>/dev/null && return 1
    return 0
}

install() {
    module_dryrun_guard install "apt repo setup + apt-install ${APT_PKGS[*]}" && return 0
    module_skip_if_installed && return 0
    # ... apt repo 設定 + apt-get install + usermod -aG docker
}
# upgrade / remove / purge / verify / is_outdated / doctor 同上 pattern
# 完整範例見 doc/module/docker.md

# ── Standalone footer ───────────────────────────────────────
if [[ "${MODULE_STANDALONE:-false}" == "true" ]]; then
    module_standalone_main "$@"
fi
```

**Pure archetype 範例(neovim)** 用 `module_use_github_release_archetype` 一行綁定 10 個 lifecycle,作者只填 metadata + GITHUB_REPO/INSTALL_DIR 等資料欄位 + 寫 detect/is_recommended。完整範例見 `doc/guide/archetype-cookbook.md`。

---

## 10. Configuration & State

**統一規則 [N14]**:所有 config 寫到 `${XDG_CONFIG_HOME:-$HOME/.config}/<tool-or-module>/`,**不寫**到 `$HOME/` 根層。例外:某些工具的歷史包袱(如 `~/.bashrc`)可保留,但 module metadata 需註記 `LEGACY_DOTFILE=true`。

### 10.1 State 檔(XDG)

`${XDG_STATE_HOME:-$HOME/.local/state}/init_ubuntu/state.json`

**並發與損毀(2026-06-06 定稿)**:
- 寫入以 `flock -w 30` 互斥(`.state.lock`):等待期間印一行提示;30 秒超時退 code 1,印鎖持有者資訊(PID / 鎖檔路徑)
- 讀到損毀 JSON:自動 `mv` 為 `state.json.corrupt.<ts>` 後 fail fast(exit 1),印「已備份;重跑 install 可重建記錄(module idempotent),或手動修復後改名放回」。**不靜默重建**(不丟 manual / dep 資料);自動修復屬 `doctor --fix`(0.3.0)

每個 installed module 拆 **`synced`**(可跨機)+ **`local`**(本機 only)兩段(ADR-0018)。Sync / import / export 只攜 `synced`,receiver 自己重建 `local`。

```json
{
  "version": "0.1.0",
  "installed": {
    "docker": {
      "synced": {
        "manual": true,
        "depends_on": ["apt-essentials"],
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
        "user_home_root": "/home/cyc/.local/lib/init_ubuntu/neovim"
      }
    },
    "apt-essentials": {
      "synced": {
        "manual": true,
        "depends_on": [],
        "version_provided": "apt-managed",
        "installed_at": "2026-05-13T14:20:11+08:00",
        "installed_by": "init_ubuntu@v0.1.0"
      },
      "local": {
        "install_target_resolved": "sudo",
        "frozen_pkgs": ["git", "vim", "curl", "wget", "ca-certificates", "build-essential", "htop", "unzip", "jq", "software-properties-common"],
        "frozen_platform": "desktop"
      }
    }
  }
}
```

#### Synced 欄位(跨機)

| 欄位 | 型別 | 說明 |
|---|---|---|
| `version` | string | state schema 版本(SemVer)— 升版透過 ADR-0008 forward-only migration |
| `installed.<name>.synced.manual` | boolean | user 顯式 named(true)或 engine 拉 dep(false);sticky-to-true(ADR-0010) |
| `installed.<name>.synced.depends_on` | string[] | 此次實際裝完的 dep snapshot(不是 metadata `DEPENDS_ON`)。`--no-deps` install 時為 `[]`(ADR-0010) |
| `installed.<name>.synced.version_provided` | string | 安裝當下 module 提供的版本 |
| `installed.<name>.synced.installed_at` | string(ISO 8601) | 安裝時間 |
| `installed.<name>.synced.installed_by` | string | 安裝工具版本 |

#### Local 欄位(本機)

| 欄位 | 型別 | 說明 | 適用 module |
|---|---|---|---|
| `installed.<name>.local.install_target_resolved` | `sudo`/`user-home` | 此機決定的目標 | 所有 module |
| `installed.<name>.local.user_home_root` | path | user-home 安裝根目錄(ADR-0017) | user-home install only |
| `installed.<name>.local.frozen_pkgs` | string[] | 安裝當下 freeze 的 pkg 集(經 compat filter)| `apt-essentials` only(ADR-0011) |
| `installed.<name>.local.frozen_platform` | string | freeze 當下偵測到的 form factor(診斷用) | `apt-essentials` only |

舊 PRD draft 用過 `dependents_of`(reverse-dep)欄位 — **已廢除**(ADR-0010 改用 forward-dep snapshot `synced.depends_on`,reverse 查詢 on-demand)。

#### 10.1.1 Sidecar(per-module 版本記錄)

`${XDG_STATE_HOME:-$HOME/.local/state}/init_ubuntu/versions/<name>` — 一個檔記一個 module 安裝當下的版本字串(`apt-managed` / `v0.10.2` / ...)。

| 欄位 | 結構 |
|---|---|
| 內容 | 單行字串(`VERSION_PROVIDED` 的當下值,如 `v0.10.2`) |
| 用途 | `is_outdated()` 比對「裝的版本 vs upstream latest」(主要 GitHub release archetype) |
| Engine 寫入 | install / upgrade 成功寫;`remove` / `purge` 刪(module-spec.md §4.7.4) |
| Standalone 寫入 | install / upgrade 成功寫;`remove` / `purge` 刪。Sidecar 是「裝了什麼版本」事實,跨模式一致(ADR-0001) |
| `state.json` 寫入 | Engine 寫;Standalone **不**寫(ADR-0001) |
| 不變式 | `is_installed()==false` ↔ Sidecar 不存在 |

### 10.2 Log

`${XDG_STATE_HOME:-$HOME/.local/state}/init_ubuntu/logs/<YYYY-MM-DD-HHMMSS>.jsonl`

**Log 主要使用對象是 agent**(Claude / Codex / Gemini)做問題診斷,因此採用**結構化 JSONL** 格式(每行一個 JSON object,易被工具切片與查詢)。stdout 同時印人類可讀格式。

每次 `install` / `remove` / `purge` 產一個 `.jsonl` 檔。Schema **對齊 ADR-0006(OTel Logs Data Model + W3C Trace Context,2026-06-06 同步;舊 `ts/level/module/event/payload` 命名作廢)**:

```json
{"timestamp":"2026-05-13T14:22:33.123456Z","severity_text":"INFO","body":"install_start","trace_id":"0193cdef-...","span_id":"install_docker_001","attributes":{"service.name":"docker","version":"apt-managed","install_target":"sudo","dry_run":false}}
{"timestamp":"2026-05-13T14:22:34.001234Z","severity_text":"INFO","body":"cmd_exec","trace_id":"0193cdef-...","span_id":"install_docker_001","attributes":{"service.name":"docker","cmd":"sudo apt-get update","exit":0,"duration_ms":1430}}
{"timestamp":"2026-05-13T14:23:02.654321Z","severity_text":"INFO","body":"install_done","trace_id":"0193cdef-...","span_id":"install_docker_001","attributes":{"service.name":"docker","status":"ok"}}
```

| 欄位 | 型別 | 說明 |
|---|---|---|
| `timestamp` | ISO 8601(UTC,微秒) | 事件時間(OTel 標準欄位名) |
| `severity_text` | enum(`DEBUG` / `INFO` / `WARN` / `ERROR` / `FATAL`) | 等級 |
| `body` | string | 事件代號 enum(`install_start` / `cmd_exec` / `dep_resolved` / `snapshot_taken` / `recovery_triggered` / `install_done` / `action_required` / ...),**不是自由句子** |
| `trace_id` | string | 一次 engine 執行(session)共用,串起跨 module 事件鏈 |
| `span_id` | string | 單一 module 的單一 lifecycle 操作 |
| `attributes` | object | 業務資料容器;`service.name` = module 名(engine 層事件為 `"engine"`) |

**Session 開頭**會印一筆 `session_start` 含當下環境偵測快照(`form_factor` / `os` / `arch` / `gpu` / ...)。**Session 結尾**印 `session_end` 含 exit code + 統計(ok / skipped / failed 個數)。

人讀 stdout 輸出規範見 §7.7(進度行 + exec_cmd 命令流;結尾聚合由事件衍生),**檔案存的是 JSONL** — 兩者同源(log 事件為單一真相源)。

**保留策略(0.1.0,AC-33;arch §18.2 Q-A4)**:session 結尾自動清理 — 保留最近 **30 天**且至多 **100 個** `.jsonl` 檔,任一條件超過即從最舊開始刪(類 logrotate,無外部依賴)。

### 10.3 User config

`${XDG_CONFIG_HOME:-$HOME/.config}/init_ubuntu/config.ini`(INI 風格,**對標 base** repo 慣例)

**這是生成檔,不可手動編輯**。要修改透過 `setup_ubuntu config set/unset` subcommand(見 §7.2),工具會 round-trip 保留 comments / 排序。檔頭固定印一段警告:

```ini
# ===========================================================================
# THIS FILE IS AUTO-GENERATED BY setup_ubuntu. DO NOT EDIT BY HAND.
# Edit via:  setup_ubuntu config set <key> <value>
#            setup_ubuntu config unset <key>
# Manual edits will be preserved on a best-effort basis but may be overwritten
# by future schema migrations without notice.
# ===========================================================================
```

`setup_ubuntu doctor --fix`(0.3.0)會偵測 hand-edit(用 checksum)並警告。

```ini
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
enabled = false                        # 三態 enabled:Quick Setup / --recommended 過濾時
                                       #   true  = 強制納入,不管 is_recommended() 結果
                                       #   false = 強制排除,不管 is_recommended() 結果
                                       #   未設 = 讓 module 自己的 is_recommended() 決定

[modules.docker]
enabled = true                         # 強制納入 Quick Setup,即使 is_recommended() 回 1

[secrets]
backend = auto                         # auto | pass | gnome-keyring | encrypted-file
```

---

## 11. Acceptance Criteria

### 11.1 v0.1 (MVP) — 必須通過

**Ship gate**:標 `v0.1-mandatory` 的 AC 全綠才 tag `v0.1.0`。**無 due date(個人 project,有空才推進)**。

26.04 配套(2026-06-06 定稿):**26.04 即日起 mandatory,無豁免**。CI 矩陣維度是 **Docker image**(`docker_image: ubuntu:22.04 / 24.04 / 26.04`),不是 GitHub Actions runner 版本 — 測試依 ADR-0004 全部跑在 container 內,runner 固定用 stable `ubuntu-24.04` 即可,`ubuntu-26.04` runner GA 與否無關緊要(截至 2026-06-06 仍未 GA,actions/runner-images #13855 / #13964 open)。AC-3 / AC-18 不再帶 `continue-on-error`。

| ID | 條件 | Scope |
|---|---|---|
| AC-1 | 在乾淨 `ubuntu:22.04` container 內 `setup_ubuntu install --base -y` 成功 | v0.1-mandatory |
| AC-2 | 在乾淨 `ubuntu:24.04` container 內同樣指令成功 | v0.1-mandatory |
| AC-3 | 在乾淨 `ubuntu:26.04` container 內同樣指令成功 | v0.1-mandatory |
| AC-4 | `setup_ubuntu install neovim` 自動拉入所有 dep 並裝完 | v0.1-mandatory |
| AC-5 | `setup_ubuntu install neovim` 跑兩次,第二次仍 exit 0(idempotent) | v0.1-mandatory |
| AC-6 | `setup_ubuntu remove neovim` → `setup_ubuntu install neovim` 連續執行可成功 | v0.1-mandatory |
| AC-7 | `setup_ubuntu purge docker` 後 `~/.docker` 與 `/etc/docker` 不存在 | v0.1-mandatory |
| AC-8 | `setup_ubuntu detect --json` 在 NVIDIA 機器輸出 `"gpu": {"vendor": "nvidia", ...}`(ship gate 以 mock `nvidia-smi` / sysfs fixture 在 Docker 內驗證,Q52;真機驗證列 post-0.1.0 人工 checklist) | v0.1-mandatory |
| AC-9 | 在容器內跑 `setup_ubuntu detect` 偵測到 `"form_factor": "container"` 並把 nvidia-driver 從推薦排除 | v0.1-mandatory |
| AC-10 | TUI(gum 與 whiptail 兩種後端,ADR-0023)主選單可顯示、可勾選、可退出(Q43 執行模型)。驗證雙層:`tui_backend.sh` mock 下的「勾選累積 → Run → 產生的 CLI 命令字串」bats 單元測 + CI 內 expect/偽 tty 對兩後端各跑一次煙霧測(`--backend` 強制各後端;開主選單 → 進 Optional 勾一項 → OK → Exit) | v0.1-mandatory |
| AC-11 | CLI 與 TUI 同一個 module 安裝結果完全一致(state.json diff = 0) | v0.1-mandatory |
| AC-12 | `--dry-run` 不對檔案系統做任何寫入(用 strace 驗證) | v0.1-mandatory |
| AC-13 | 無 sudo 環境下,`setup_ubuntu install eza` 走 user-home 安裝(裝到 `$HOME/.local/bin/eza`)且 `eza --version` 可執行 | v0.1-mandatory |
| AC-14 | `setup_ubuntu export A.json` → 在另一台 `setup_ubuntu import A.json` 結果一致 | v0.1-mandatory |
| AC-15 | `setup_ubuntu sync user@host` 推送後對端 state.json 含預期 module(ship gate 以雙 container + sshd 模擬兩台機器,Q52) | v0.1-mandatory |
| AC-16 | 非 tty 輸出(`setup_ubuntu list | cat`)自動關閉 ANSI 色彩 | v0.1-mandatory |
| AC-17 | bats unit test 覆蓋率 >= 80%(by kcov) | v0.1-mandatory |
| AC-18 | integration test 在 GitHub Actions 上 `ubuntu:22.04` + `ubuntu:24.04` + `ubuntu:26.04` Docker image 矩陣全綠 | v0.1-mandatory |
| AC-19 | 寫一個新的 dummy module(<10 行)能被 engine 自動發現並列入 `list` | v0.1-mandatory |
| AC-20 | `setup_secrets ssh-key generate` 互動產 key 不入 shell history | v0.1-mandatory |
| AC-22 | `setup_ubuntu upgrade neovim` 跑完(GitHub API 以 bats-mock 固定 latest 回應,Q46 — gate 零網路依賴),Sidecar `${XDG_STATE_HOME}/init_ubuntu/versions/neovim` 內版本與 mock latest 對齊;真實 API 驗證為本機手動 best-effort | v0.1-mandatory |
| AC-23 | `bash module/docker.module.sh install --dry-run` 跑完,Sidecar 寫入正確(Standalone 模式)但 `state.json` 完全沒變(ADR-0001) | v0.1-mandatory |
| AC-24 | `setup_ubuntu doctor` 印出 env detect 結果 + 所有 installed module 的 `doctor()` 結果;`--validate-modules` flag 額外驗證每個 module 的 metadata 合法 | v0.1-mandatory |
| AC-25 | 全 10 個 lifecycle 函式對每個 module 都能跑(`bash module/<m>.module.sh <phase>` 都 exit 0 或預期 Query-no 的 exit 1,絕無「not implemented」exit 2) | v0.1-mandatory |
| AC-32 | docker daemon 停掉 → `doctor docker` exit 1 而 `verify docker` exit 0(ADR-0009) | v0.1-mandatory |
| AC-33 | 任一 session 結束後,`logs/` 內 `.jsonl` 不超過 100 檔且無超過 30 天的檔(保留策略生效,§10.2) | v0.1-mandatory |
| AC-34 | 乾淨 container(無 jq)內 `setup_ubuntu install --base -y` 經 preflight 自動裝 jq 後成功;無 sudo 時 fail-fast 退 code 4 並印安裝指引(§3.4) | v0.1-mandatory |
| AC-35 | 安裝含 `POST_INSTALL_MESSAGE` / `REBOOT_REQUIRED=true` 的 module 後,結尾印「Action required」聚合區,且內容與 `jq 'select(.body=="action_required")'` 查 log 的結果一致(§7.7.2) | v0.1-mandatory |

### 11.2 0.2.0 ~ 0.4.0 — 後續里程碑 AC

| ID | 條件 | Scope |
|---|---|---|
| AC-28 | `.adoc` 全部換為 `.md` | 0.2.0 |
| AC-30 | state.json 升級後 `state.json.v<old>.bak` 存在(ADR-0008) | 0.2.0(schema 第一次變才會觸發) |
| AC-31 | 讀到比 tool 新的 state.json 退 code 1 不改檔(ADR-0008) | 0.2.0 |
| AC-21 | nvidia-driver install 失敗時自動回復 nouveau,系統仍可開機進入桌面(ADR-0020) | 0.4.0 |
| AC-27 | `small-tools/` 已移除,README 內保留歷史說明 | 0.4.0 |
| AC-29 | i18n 全覆蓋(en + zh-TW + zh-CN + ja 四種語系皆無 untranslated 字串) | 0.4.0 |

> **AC-26(覆蓋率 100%)已撤銷**(2026-06-06):80% 硬門檻由 AC-17 把關,後續提升為 best-effort(G5)。
> **AC-32 移至 §11.1**(本就是 v0.1-mandatory)。

---

## 12. Delivery Milestones

> **執行狀態不在本文件維護**(2026-06-06 起):進度由 GitHub issues / milestones 追蹤,此處只定義範圍。M0 ~ M15 全屬 **0.1.0**;0.2.0 ~ 0.4.0 的範圍見 §5.2 Roadmap。

| Milestone | Plan |
|---|---|
| M0 - Discovery | `doc/prd/` + `doc/architecture.md` + `doc/module-spec.md` + `CONTEXT.md` + `doc/adr/` |
| M1 - Test harness | 借用 base 的 `Dockerfile.test-tools` + `justfile.ci`(原借自 `Makefile.ci`,`make`→`just` 遷移見 ADR-0022)+ `script/ci/ci.sh`(bats + bats-assert + bats-mock) |
| M2 - Engine core | `lib/dispatcher.sh` + `lib/registry.sh` + `lib/runner.sh` + `lib/resolver.sh` + `lib/module_helper.sh` + 10 v2 modules |
| M3 - Detect engine | `lib/detect.sh` + `lib/platform.sh` + `setup_ubuntu detect` |
| M4 - State + log | `lib/state.sh` + `lib/state_io.sh` + `lib/logger.sh`(JSONL + 30 天/100 檔保留,AC-33)+ flock concurrency |
| M5 - CLI | `setup_ubuntu.sh` subcommands(含 `upgrade` / `verify` / `doctor` 入口 + `list` 各 flag + `--verbose/--quiet/--color` wire) |
| M6 - TUI | `setup_ubuntu_tui.sh` + `lib/tui_backend.sh`(含 tag 分組 / Quick Setup 多 step / dep 鏈折疊顯示)。TUI = CLI 前端(G4):讀 `--json`、寫 fork `setup_ubuntu`;測試 = backend mock 單元 + expect 煙霧(AC-10) |
| M7 - Module migration | Batch A(10 個 v2 module + helpers + template)/ Batch B(cli-essentials 9 個,含新建 ripgrep,Q41)/ Batch C(agent + 其他 optional 12 個,Q42 / Q50 / Q51) |
| M8 - i18n + color | `lib/i18n.sh`(`i18n_detect_lang` / `i18n_sanitize_lang`,對標 base)+ `lib/color.sh`;module 用 `declare -A` + `module_i18n_get` |
| M9 - Sync + Secrets | `lib/sync.sh`(SSH push/pull)+ `setup_secrets.sh`(SSH key / GPG / token) |
| M10 - Unit tests 80% | 239 + N modules × ~50 tests ≈ 600+ unit tests。CI 切「per-module job」(每 module 一個 job,matrix 從 `ls module/*.module.sh` discover step 動態生;`fail-fast: false`;`timeout-minutes: 5`;`just -f justfile.ci test-unit <name>` 入口);path-filter(dorny/paths-filter)讓 PR 只跑改動的 module job,main push 跑完整 cartesian |
| M11 - Integration tests | `ubuntu:22.04` + `ubuntu:24.04` + `ubuntu:26.04` 矩陣 |
| M12 - Coverage + CI | kcov + GitHub Actions |
| M13 - Code review | code-reviewer x 2 + security-reviewer 並行 |
| M14 - Docs | `doc/guide/` 4 篇手寫 + `doc/module/` 自動 INDEX + per-module 文件;README 改寫(`.adoc`→`.md` 全轉屬 0.2.0,AC-28) |
| M15 - Post-install management 驗收 | 確認裝完後 CLI + TUI 仍可管理(install / upgrade / remove / verify / doctor / sync) |

> 原 M16(Coverage 100%)已撤銷(同 AC-26,2026-06-06):80% gate 由 M10 / AC-17 把關,提升為 best-effort。

---

## 13. 決定事項(原 Open Questions,已收斂)

| # | Question | **決定** |
|---|---|---|
| Q1 | `apt-essentials.module.sh` 該裝哪些套件? | **Universal devel pkg list,全平台同一份**(ADR-0011 修正版,2026-05-20):任何 devel 平台都裝 `git` / `vim` / `curl` / `wget` / `ca-certificates` / `build-essential` / `htop` / `unzip` / `jq` / `software-properties-common`,僅以「相容性 + 功能重複」filter 排除 |
| Q2 | `fish` 應放 base 還是 recommended? | **recommended**(永遠 `is_recommended=true`,給機會取消) |
| Q3 | `neovim` 是否拆分 dep? | **拆開**;先安裝 dep(`fzf` / `lazygit` / `ripgrep` / `fdfind` / `fnm`)才安裝 nvim,讓 dep 可重用 |
| Q4 | `fnm` 該獨立 module 還是埋在 neovim? | **獨立**,符合 Q3 精神;依「可複用 + 好管理」為主,不要為單一 tool 把 dep 綁定 |
| Q5 | `nvimdots` config 是 module 一部分還是另一個 module? | **內嵌**在 `neovim.module.sh`;但 install 時**顯示推薦勾選**,user 按 Enter 或確認即安裝(default 同意) |
| Q6 | `module/config/` 內的 config 檔該怎麼套用? | **配 config-drop archetype 走正常 install pipeline**(ADR-0014,2026-05-20):每個 config bundle 有 `<name>-config.module.sh`,用 `setup_ubuntu install <name>-config` 套用;批次用 `install --tag=config`。**`config load` subcommand 已砍**(與 `config get/set/unset/show` 名稱重疊易混) |
| Q7 | `experimental` 分類是否保留? | **保留**作為未來不穩定 module 入口;但 `dual-system-time-sync` 不該放這層,後續重新分類 |
| Q8 | 是否要在 v0.1 就支援 import / export state? | **v0.1 就要有**(已從 nice-to-have 提前到必備) |
| Q9 | `setup_ubuntu install --recommended` 是否包含 `nvidia-driver`? | **可包含**,但需使用者 dual-check 確認(`RISK_LEVEL=high` 觸發 `WARN_MESSAGE` 顯示在 install 之前);failure recovery 透過 `POST_INSTALL_MESSAGE` 提示使用者手動切回 nouveau,**v0.1 不自動回滾**;自動回滾排入 **0.4.0**(AC-21,ADR-0020;見 §13.2 Q22 metadata 收斂) |
| Q10 | `purge` 是否要連 dep 一起 purge? | **不要**;純 purge 自己。要清 dep 用 `--with-orphans`(只清沒被其他 module 依賴的 dep) |
| Q11 | Module 檔名 kebab-case 還是 snake_case? | **kebab-case** |
| Q12 | 是否要支援 `setup_ubuntu rollback`? | **不做**;移入 Backlog(§5.3)。upgrade 失敗的 archetype rollback(§7.6)已涵蓋主要需求 |

> 設計細節層次的決定(parallel 預設、sync 簽章、secrets backend 選擇、平台 allowlist 策略、高風險 module snapshot 範圍、non-sudo 模式 apt-essentials 處理)收斂進 `doc/architecture.md` §18 開放問題與決定。

### 13.2 v2 contract 細則決議(2026-05 grilling)

| # | Question | **決定** |
|---|---|---|
| Q13 | Engine 是否補 `upgrade` / `verify` / `doctor` 入口? | **補**;state.json 在 upgrade 成功時 bump version + timestamp(同 install) |
| Q14 | `setup_ubuntu doctor` 不帶名語意? | 印 env detect + 跑所有 `installed=true` 的 `doctor()`;`--validate-modules` flag 跑 metadata lint |
| Q15 | install→verify 是否自動跑? | **自動跑;verify 失敗 = install 失敗**(ADR-0015,2026-05-20 修訂):state.json 不寫;pipeline 自動呼 module 的 `purge()` 收拾 side effects;退 code 6。原案「log warn 但 state.json 照記 installed」已被取代,理由是會造成 state 三態化 |
| Q16 | `setup_ubuntu update` 不帶參? | ~~rescan registry(對應 `apt update`,不是升級)~~ → **superseded by Q40**(2026-06-06):`update` 已砍,registry in-memory |
| Q17 | `purge` mandatory? | **是**;後升級為 10 個 lifecycle 全 mandatory(ADR-0002) |
| Q18 | `is_outdated` / `doctor` mandatory? | **是**(同 Q17,全 10 mandatory) |
| Q19 | GitHub release `is_outdated` 如何判? | 用 Sidecar(`${XDG_STATE_HOME}/init_ubuntu/versions/<name>`)記安裝版本,跟 GitHub API latest 比對 |
| Q20 | `doctor` 預設行為? | delegate `verify`(後宣告者勝可覆寫加深度檢查) |
| Q21 | CLI 對標 apt 整理範圍? | rename lifecycle `update()` → `upgrade()`;`status` deprecate 到 `list --installed`;`detect` 保留並整合進 `doctor` 開頭 |
| Q22 | Metadata 欄位收斂? | 砍 5(`MAINTAINER` / `RECOVERY_FALLBACK` / `PARALLEL_GROUP` / `INSTALL_TIME_ESTIMATE` / `DISK_SPACE_ESTIMATE`),留 4 forward-compat(`INSTALL_TARGET_DEFAULT` / `SUPPORTED_PLATFORMS` / `SUPPORTS_USER_HOME` / `RISK_LEVEL`) |
| Q23 | i18n 儲存格式? | `declare -A` 關聯陣列;新增 `lib/i18n.sh`(`i18n_detect_lang` / `i18n_sanitize_lang`,對標 base);白名單 `{en, zh-TW, zh-CN, ja}` |
| Q24 | Template 結構? | 拆 4 檔:`module-apt` / `module-github-release` / `module-config` / `module-custom`,各對應一個 archetype;共有 header 用 hash spec 比對防漂移 |
| Q25 | `TEST_VERIFY_CMD` 安全性? | personal-use 信任 metadata 寫死,用 `bash -c` 直接跑(無防注入) |
| Q26 | Sidecar 位置? | `${XDG_STATE_HOME}/init_ubuntu/versions/<name>`(跟 `state.json` 同層,XDG-正解) |
| Q27 | Archetype 覆寫慣例? | super-call pattern:macro 後重寫函式,內部先呼叫 `module_default_*_<phase>` 再加 extra |
| Q28 | Standalone vs Engine 狀態分界? | Standalone 寫 Sidecar + 印 messages,**不**寫 `state.json` / 不解 DEPENDS_ON(ADR-0001) |
| Q29 | bats spec 範圍? | 每 module ~50 tests(smoke / metadata / 10 lifecycle dry-run / no-side-fx / idempotency / standalone CLI / module 特化);CI 之後切 per-module layer |
| Q30 | Exit code 設計? | 沿用 PRD §7.4;code 2 擴語意「metadata 不合法」,code 7 擴語意「任何遠端/網路操作失敗」 |
| Q31 | APT `is_outdated` 實作? | `apt list --upgradable | grep "^pkg/"` 對每個 `APT_PKGS` 檢查;不主動 `apt update`,把 freshness 責任推給使用者 |
| Q32 | `CONFLICTS_WITH` 檢查時機? | install + upgrade 兩處都檢查;觸發時 exit 5 |
| Q33 | Module cwd 規範? | 只准 subshell `(cd ...; cmd)`,禁 `cd` / `pushd` |
| Q34 | Parallel install? | **不做**;`dpkg` lock + sudo 互斥讓 apt 不可並行;非 apt 並行收益不足 |
| Q35 | User-local module 區? | Engine 額外掃 `${XDG_CONFIG_HOME}/init_ubuntu/module/`,撞名時 user-local 勝(log_warn 提示) |
| Q36 | Module 「disable / 強制裝」機制? | `[modules.<name>] enabled = true|false|未設` 三態;影響 Quick Setup / `--recommended` 過濾 |
| Q37 | 文件分層? | `doc/guide/` 4 篇手寫 + `doc/module/INDEX.md` 自動生成 + 每 module 一個 `doc/module/<name>.md` 寫架構流程 |

### 13.3 Round-4 grilling 決議(2026-06-06,PRD 1.1.0)

> 原則:**以 robust 為導向,明顯有問題的直接拿掉**。對應 GitHub issue #38。

| # | Question | **決定** |
|---|---|---|
| Q38 | `config load` 已砍(Q6)但 §5.1 / §7.3 殘留? | **清掉殘留**;範例改 `setup_ubuntu install git-config`(config-drop 走正常 install pipeline,功能零損失) |
| Q39 | `DEPENDS_ON=("git")` 懸空(`git` 非 module)? | **dep 一律是 module 名**;`git-config` / `lazygit` / `fzf` 三處改 `apt-essentials`;§9.1 補規則,`doctor --validate-modules` lint |
| Q40 | `update` 要重建的 registry 不存在? | **砍 `update` subcommand**;registry 明定 in-memory(每次執行動態掃);`apt update` 無對應 — 本地檔無 index 可過期;版本情報:gh-latest cache(隨需抓+TTL 1h)/ apt 委派系統(Q31)。supersedes Q16 |
| Q41 | `ripgrep` 被三處引用但 catalog 漏列? | **補 `ripgrep.module.sh`** 進 §6.3.1(apt archetype,grep 替代);CLI Essentials 8→9;M7 Batch B 同步 |
| Q42 | `gnome-terminal-config` 去向矛盾(§6.3.3 vs §6.5)? | **從 catalog 移除**;隨 `tool/` 整批搬 `tool/`,v0.2+ 逐檔決定;M7 Batch C 11→10 |
| Q43 | TUI「Save & Exit」無物可存? | **勾選累積器模型**:主選單 `< Run >`+`< Exit >`;勾選子選單 `< OK >`+`< Back >`;Run→Review→Proceed 唯一批次執行點;Quick Setup / Manage Installed 自帶執行;AC-10 斷言同步 |
| Q44 | 空 Advanced 選單(experimental 零 module、custom 無定義)? | **通則:主選單只顯示非空 CATEGORY**;`custom` 字眼廢除(user-local module 依 CATEGORY 歸類) |
| Q45 | sync `--include-config` 無定義且與 ADR-0018 / §10.3 衝突? | **砍**;§16.2 flag 與 §7.2 對齊;config.ini 是本機生成檔不跨機;個人設定同步由 config-drop module 涵蓋 |
| Q46 | AC-22 綁真實 GitHub API,CI 先天 flaky? | **改 bats-mock**(固定 latest 回應),gate 零網路依賴;真實 API 驗證留本機手動 |
| Q47 | `--lang` 只列 2 語系,白名單有 4? | **對齊四語系** `en\|zh-TW\|zh-CN\|ja`;未翻譯 fallback `en`(AC-29 於 0.4.0 收尾) |
| Q48 | state.json 範例版本 0.2.0 vs MVP 0.1.0? | **統一 0.1.0**;首次 schema 變更才 bump + 觸發 AC-30 migration |
| Q49 | anydesk 依賴欄寫平台條件? | **dep 改 `apt-essentials`**;條件移 `SUPPORTED_PLATFORMS=("desktop")`(Q39 規則一併防堵) |

### 13.4 Issue triage 決議(2026-06-06,PRD 1.2.0)

| # | Question | **決定** |
|---|---|---|
| Q50 | notion 只活在 small-tools(#35;0.4.0 移除 small-tools 後安裝路徑消失)? | **補 `notion.module.sh`** 進 §6.3.3(github-release archetype,吃 notion-electron `.deb`);#35 的 snap→deb hotfix 照做(legacy 路徑),module 化排 M7 Batch C |
| Q51 | jetson-stats / `jtop` 無著陸點(#37;§15.4 jetson-orin 不裝 nvidia-driver)? | **補 `jetson-stats.module.sh`** 進 §6.3.3(`hardware` tag,`SUPPORTED_PLATFORMS=("jetson-orin")`,pip 安裝);#37 重寫對齊 module 形態,排 M7 Batch C |
| Q52 | AC-8(NVIDIA 真機)/ AC-15(兩台機器)在 CI 容器內無法字面驗證? | **ship gate 一律以 Docker 模擬為準**(同 Q46 精神,ADR-0004):AC-8 用 mock `nvidia-smi` / sysfs fixture;AC-15 用雙 container + sshd 跑真 SSH 流程。真硬體(NVIDIA 工作站 / RPi / Jetson / WSL)驗證列 post-0.1.0 `ready-for-human` checklist issue,不擋 tag(2026-06-07,PRD 1.2.1) |

---

## 14. Sensitive Tools sub-tool [N4]

> 完整設計見 `doc/architecture.md` §15。

### 14.1 範疇

獨立於 `setup_ubuntu` 主流程的**另一個工具** `setup_secrets.sh`,專處理:
- SSH key 生成 / 載入 / 拷貝到遠端
- GPG key 生成 / 匯入
- API token / PAT 安全儲存
- 互動輸入密碼(不入 shell history)

### 14.2 子命令骨架

```
setup_secrets ssh-key generate
setup_secrets ssh-key load
setup_secrets ssh-key copy <user@host>
setup_secrets gpg generate
setup_secrets token set <name>
setup_secrets token get <name>
setup_secrets list
setup_secrets remove <name>
```

### 14.3 儲存後端優先序

1. `pass`(if installed)
2. `gnome-keyring`(if available)
3. fallback:`age` / `openssl enc` 加密檔放 `~/.config/init_ubuntu/secrets/<name>.enc`

**絕不寫明文**。

### 14.4 與主 engine 的關係

- 共用 `lib/logger.sh` / `lib/i18n.sh` / `lib/color.sh`
- **不**走 module pipeline
- `setup_ubuntu_tui` 主選單提供「Manage Secrets」入口跳轉

---

## 15. Multi-Platform Support [N9]

> 完整設計見 `doc/architecture.md` §14。

### 15.1 支援的 form factor

| 平台 | 偵測方法 | v0.1 支援度 |
|---|---|---|
| `desktop` (x86_64) | `$XDG_CURRENT_DESKTOP` 非空 | **完整** |
| `server` (x86_64) | 桌面為空 + x86_64 | **完整** |
| `wsl` | `/proc/sys/fs/binfmt_misc/WSLInterop` | **完整** |
| `rpi-4` / `rpi-5` (arm64) | `/proc/device-tree/model` | **基本**(部分 module 不支援 arm64) |
| `jetson-orin` (arm64) | `/etc/nv_tegra_release` + Orin | **基本** |
| `container` | `systemd-detect-virt --container` | **限測試用**(自動排除 host-only) |
| `vm` | `systemd-detect-virt --vm` | 視為 server |

### 15.2 平台選擇互動

- **CLI**:自動偵測;支援 `--profile=server|desktop|jetson` 覆寫
- **TUI**:System Info 畫面顯示偵測結果並**詢問是否同意**(允許覆寫)
- `~/.config/init_ubuntu/config.ini` 可 pin `[platform] override=server`

### 15.3 Module 平台支援宣告

Module metadata 加 `SUPPORTED_PLATFORMS`(string[],見 `doc/module-spec.md` §3.3):

```bash
SUPPORTED_PLATFORMS=("desktop" "server")    # 不支援 SBC
```

不在 allowlist 的平台:engine 在 Quick Setup / `--recommended` 過濾時**先**檢查 `SUPPORTED_PLATFORMS` ⊇ 當前 `INIT_UBUNTU_FORM_FACTOR`,平台不合就排除(不再 call `is_recommended()`);**再**對通過平台檢查的 module 看 `[modules.<name>] enabled` 三態(Q36),最後對「未設 enabled」的 module call `is_recommended()`。`--force` 可跨過全部過濾強裝。

### 15.4 平台差異化的 module 範例

| Module | desktop | server | jetson-orin | wsl |
|---|---|---|---|---|
| `apt-essentials` | + GUI 套件 | 純 CLI | Jetson SDK 子集 | 純 CLI |
| `nvidia-driver` | 推薦(若有卡) | 推薦(若有卡) | **不裝**(內建) | 不推薦 |
| `font` | 推薦 | 不裝 | 不裝 | 不裝 |
| `docker` | 推薦 | 推薦 | 推薦(+ NVIDIA Toolkit) | 推薦(Docker Desktop integration) |

---

## 16. Sync 機制 [N8]

> 完整設計見 `doc/architecture.md` §16。

### 16.1 目標

跨機快速同步「**裝了哪些 module**」,但**絕不傳 secrets**。

### 16.2 子命令

```bash
# Push 本機狀態到對端(預設 dry-run;--apply 才套用,ADR-0013)
setup_ubuntu sync <user@host> [--modules base,recommended] [--include-user-local-modules] [--apply]

# Pull 對端狀態
setup_ubuntu sync <user@host> --pull [--apply]
```

> Flag 清單以 §7.2 為準(Q45);`--include-config` 已砍 — config.ini 是本機生成檔(§10.3),不跨機;個人設定同步由 config-drop module 涵蓋(隨 module 集合 sync 過去,對端 install 時套用)。

### 16.3 流程

1. SSH 連線測試(`--strict-host-key-checking=yes`)
2. 對端工具檢查(2026-06-06 定稿):若對端無 `setup_ubuntu` → **退 code 7 + 印三行 bootstrap 教學**(同 §3.4:apt install git → git clone → 執行)。**不自動 rsync / 不遠端動 sudo**(rsync 會產生無 `.git` 的孤兒安裝,self-upgrade 斷裂)。版本偏差:state schema 同版即可 sync(ADR-0008 把關);工具版本不同僅 warn
3. `setup_ubuntu export` 本機 state.json 過濾後成 payload.json
4. SCP 推送
5. 對端 `setup_ubuntu import payload.json`(內部走 install pipeline)
6. log 串流回本機

### 16.4 安全性

- **絕不傳**:SSH key / GPG key / token / 任何 `setup_secrets` 管的東西
- 認證:**只接受** SSH key,工具流程內**不收 password**
- 沒 key 上線時 fail fast,提示「先用 `setup_secrets ssh-key copy ...`」

### 16.5 v0.1 範疇

- ✅ Push / Pull state.json
- ❌ Bootstrap 對端(**已砍**,2026-06-06:對端無工具 → 退 code 7 + 三行教學,見 §16.3 步驟 2;不自動 rsync)
- ❌ Payload 簽章(**已砍**,2026-06-06:SSH 通道已認證已加密,見 §5.3)
- ❌ Push secrets(`setup_secrets sync` 在 Backlog §5.3;目前一律手動處理)

---

## 17. Post-install Self-Management [N15]

### 17.1 原則

裝完之後,使用者**永遠可以**繼續用同一套工具管理環境:

```bash
setup_ubuntu list --installed         # 看裝了什麼
setup_ubuntu list --upgradable        # 看哪些有新版
setup_ubuntu install eza              # 隨時新增
setup_ubuntu upgrade neovim           # 升級單一 module
setup_ubuntu purge nvidia-driver -y   # 隨時移除
setup_ubuntu sync user@laptop         # 推到別台
setup_ubuntu verify docker            # 檢查裝得對不對
setup_ubuntu doctor                   # 健康檢查(env detect + 所有 module doctor)
setup_ubuntu_tui                      # 互動式管理
```

### 17.2 與 base repo 標準流程的差異

不採用 `init.sh` symlinks 路徑(那會把 repo 變 Docker container repo)。我們的工具**自己**是 entry point,裝完後:

- `setup_ubuntu` / `setup_ubuntu_tui` / `setup_secrets` 三個檔案保持可執行
- 可加進 `$PATH`(`install` 子命令完成時提示)
- state.json 持續被讀寫

### 17.3 工具自身的升級路徑

- `setup_ubuntu self-upgrade`(0.3.0,2026-06-06 定稿):**主路徑 `git fetch` + 顯示 changelog 摘要 + `git pull --ff-only`**(安裝即 §3.4 的 git clone);偵測到無 `.git`(tarball 安裝)時改走 GitHub release 下載。release tag 兩種路徑都照常發佈
- 升級不影響既有 state.json(`state.json.version` migration 保護)

---

## Appendix A: 與既有檔案的對應關係

> 此對應表為初版規劃;實作階段可視需求**拆分更細粒度**(例:某 module 拆成多個 module、某 helper 從一個檔案抽出多個檔案)。

| 既有檔案 | 新位置 | 動作 |
|---|---|---|
| `setup_ubuntu.sh` | `setup_ubuntu.sh`(同名重寫) | 改寫為 CLI dispatcher |
| (無) | `setup_ubuntu_tui.sh` | 新建 |
| (無) | `setup_secrets.sh` | 新建(§14) |
| `module/setup_docker.sh` | `module/docker.module.sh` | 改寫 |
| `module/setup_font.sh` | `module/font.module.sh` | 改寫 |
| `module/setup_neovim.sh` | `module/neovim.module.sh` + 拆出 `fnm` `fzf` `zoxide` `lazygit` `fdfind` 各自 module | 大幅拆分(Q3 + Q4) |
| `module/setup_nvidia_driver.sh` | `module/nvidia-driver.module.sh` | 改寫(加 RISK_LEVEL=high + 失敗回復,Q9) |
| `module/setup_qmk_firmware.sh` | `module/qmk-firmware.module.sh` | 改寫 |
| `module/setup_shell.sh` | `module/shell.module.sh` | 改寫 |
| `module/setup_small_tools.sh` | (拆成各自 module) | 刪除 |
| `module/setup_vscode.sh` | `module/vscode.module.sh`(optional) | 改寫(從 recommended 降級) |
| `module/anydesk.sh` | `module/anydesk.module.sh` | 改寫 |
| `module/submodules/*.sh` (8 個) | `module/<name>.module.sh`(8 個 `cli-essentials` optional module,見 §6.3.1) | 改寫 |
| (無) | `module/ripgrep.module.sh` | 新建(apt archetype,grep 替代;Q41) |
| (無) | `module/claude-code.module.sh` / `codex.module.sh` / `gemini.module.sh` | 新建(3 大 agent) |
| (無) | `module/notion.module.sh` | 新建(github-release archetype,notion-electron `.deb`;Q50 / #35) |
| (無) | `module/jetson-stats.module.sh` | 新建(pip 安裝 `jtop`,jetson-orin only;Q51 / #37) |
| `module/function/logger.sh` | `lib/logger.sh` | 整理(可能拆 file logging 出去) |
| `module/function/general.sh` | `lib/general.sh` + `lib/detect.sh` + `lib/platform.sh` | 拆分(平台分類抽到獨立檔) |
| `module/function/test/test_*.sh` | `test/unit/logger_spec.bats` 與 `general_spec.bats` | 重寫為 bats |
| `tool/*`(整個目錄) | **搬遷到 repo 根目錄 `tool/`** | v0.1 不處理,僅搬遷;v0.2+ 個別決定 |
| └ `tool/remove/*.sh` | (隨上面整個目錄搬遷) | v0.1 不處理(改寫 remove/purge 邏輯延後) |
| └ `tool/trash-maintenance.sh` | (隨上面搬遷) | **不放 module pipeline / 不放 TUI**(一次性腳本) |
| └ `tool/setup_terminal_font_size.sh` | (隨上面搬遷) | v0.1 不處理 |
| └ `tool/dual_system_time_sync.sh` | (隨上面搬遷) | v0.1 不處理 |
| └ `tool/copy_*.sh` | (隨上面搬遷) | v0.1 不處理 |
| └ `tool/ros1/*` | (隨上面搬遷) | v0.1 不處理 |
| `module/config/*` | 不動 — 由各對應 module 引用 | 保留 |
| `template/*_tmp.sh` | `template/module-{apt,github-release,config,custom}.template.sh` + `template/test.template.bats` | 改寫為新契約模板(4 個 archetype 各一,共用 shared sections,drift 由 `template_consistency_spec.bats` 把關) |
| `small-tools/*` | 0.4.0 移除,內容已分散到對應 module | deprecation 路徑(§6.6) |
| `gh-upgrade-README.md` | 評估歸入 `doc/` 或保留 | 評估 |
| `install-nvidia-driver.sh` | 與 `module/nvidia-driver.module.sh` 整合 | 整合 |
| `run_claude.sh` | 不動 | 保留 |
| `*.adoc` | `*.md`(rewrite,不只是改副檔名) | 全改 |
