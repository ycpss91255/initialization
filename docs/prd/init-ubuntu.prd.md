---
name: init-ubuntu
version: 0.1.0-draft
status: draft
owner: ycpss91255
created: 2026-05-13
updated: 2026-05-13
---

# PRD: init_ubuntu — Ubuntu 環境初始化工具

> 將既有的 `setup_ubuntu.sh` / `module/setup_*.sh` 重新組織為一套**模組化、可測試、有 CLI + TUI 雙前端、支援 install / remove / purge / update / upgrade / sync 等 apt-style 完整生命週期**的 Ubuntu 環境初始化工具。

---

## 1. Vision & Goals

### 1.1 Vision

讓**本人**在一台**全新 Ubuntu 機器**(包含 server、desktop、RPi 4/5、Jetson Orin、WSL 等多平台)上,透過單一工具完成個人化開發環境配置,並能在**重灌、換機、跨機同步、調整需求**時以最小成本還原或調整環境。

### 1.2 Goals

| # | Goal | Measurable Outcome |
|---|---|---|
| G1 | 一鍵安裝預設工具集 | `setup_ubuntu install --recommended` 在 Ubuntu 22.04 / 24.04 / **26.04** 乾淨機上 30 分鐘內裝完 |
| G2 | 環境感知推薦 | 偵測到 NVIDIA GPU / WSL / 容器 / VM / SBC 時自動調整推薦清單 |
| G3 | 完整生命週期 | 每個 module 都有 `install` / `remove` / `purge` 行為,可重複呼叫(idempotent) |
| G4 | CLI 與 TUI 雙前端共享同一 engine | 兩個前端的行為完全一致 |
| G5 | 高測試覆蓋率 | 起始 80%,目標 100%,全部在 Docker 內驗證 |
| G6 | CI/CD 可整合 | GitHub Actions 上 `ubuntu-22.04` / `ubuntu-24.04` / **`ubuntu-26.04`** 矩陣全綠 |
| G7 | 易擴充 | 新增一個 module 不需要改 engine 程式碼,只要符合 `module-spec.md` 契約 |
| G8 | 並行安裝(nice-to-have) | 對非 apt 來源的 module(curl / git / cargo)在 v0.3+ 啟用 worker pool。受 `dpkg` lock 限制,apt 操作仍序列化 |

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
| US-11 | CI 使用者 | 在 Docker 內 `make test` 跑完所有測試 | 在 GitHub Actions 持續驗證 |
| US-12 | 安全意識使用者 | 用 `setup_secrets ssh-key generate` 互動產 key 並安全儲存 token | 不會忘記安全性的細節 |

---

## 5. Feature List

### 5.1 必備(v0.1 MVP)

**Engine**
- Module engine(loader + registry + dispatcher + dependency resolver)
- 環境偵測引擎(JSON 輸出,含 form_factor 平台分類)
- 依賴解析(拓樸排序、循環偵測)
- 狀態追蹤(`~/.local/state/init_ubuntu/state.json`)
- 日誌(`~/.local/state/init_ubuntu/logs/<ts>.log`)
- Module 生命週期:`install` / `remove` / `purge` / `is_installed` / `detect` / `is_recommended`
- Sudo 偵測 + non-sudo fallback(user-home install,可由 `--install-target` 覆寫)
- 4 層分類:`base` / `recommended` / `optional` / `experimental`

**CLI subcommands(對標 apt 的常用使用方式)**
- `install` / `remove` / `purge`
- `update`(刷新 module 清單與 GitHub release 快取)
- `upgrade [<m>]`(重裝 latest 版的 module)
- `search <kw>` / `show <m>`
- `list` / `status` / `detect` / `doctor`
- `config load`(批次套用 module/config/* 的 dotfile)
- `sync <user@host>`(跨機 SSH push/pull,見 §16)
- `import <file>` / `export <file>`(state 匯出入,**v0.1 就要有**)
- `--version` / `--help`
- `--dry-run` 對所有破壞性操作

**TUI**
- `setup_ubuntu_tui` 多層選單(`dialog` / `whiptail` 雙後端)
- 主選單含 Manage Installed / Manage Secrets 入口
- Optional / Advanced 子選單按 `TAGS[0]` 分組(monitor / cli / agent / editor / ...)
- 安裝完成後仍能用 CLI / TUI 管理(見 §17)

**輸出與 i18n**
- i18n(en + zh-TW),**對標 `ycpss91255-docker/base` 的 i18n 設計**(`_detect_lang` + `_t` 函式)
- ANSI 色彩**自動偵測**(後台 / 非 tty / `NO_COLOR=1` 自動關閉)
- `--color=auto|always|never`(預設 `auto`)

**測試 / CI**
- Docker 內完整測試框架(bats + bats-mock + fishtape + kcov)
- GitHub Actions CI:`ubuntu-22.04` / `ubuntu-24.04` / **`ubuntu-26.04`** 矩陣

**子工具**
- `setup_secrets.sh`(見 §14):SSH key / GPG / token 互動式安全處理

### 5.2 nice-to-have(v0.3 / v1.x)

- **並行安裝**(v0.3+ 啟用):對 non-apt module 用 worker pool;apt 操作仍受 `dpkg` lock 序列化
- `setup_ubuntu upgrade <module>`(同 apt upgrade,但走各 module 自己的 `install()` 重跑)
- `setup_ubuntu self-upgrade`(從 GitHub release 拉最新工具)
- Module repository(`setup_ubuntu module add <git-url>`,第三方 module)
- `setup_ubuntu doctor --fix`(自動修復狀態檔失真)
- `setup_secrets sync ...`(secrets 跨機,GPG 簽章保護)
- Sync payload 簽章(防 MITM)

### 5.3 未來(v2+)

- 支援 Debian 衍生(非 Ubuntu)
- Wayland-aware 推薦
- 蘋果硬體偵測 + 對應 driver 推薦
- Web UI(若有需求)

---

## 6. Module Catalog

### 6.1 base(預設啟用,Quick Setup 必裝)

依平台情境動態挑選套件清單(server / desktop 不同;見 §15)。最低保證裝 `git` / `vim` 等通用簡單工具。

| Module 檔名 | 來源 | 說明 | 依賴 |
|---|---|---|---|
| `apt-essentials.module.sh` | (新建) | 最低集:`git` / `vim` / `curl` / `wget` / `ca-certificates`;**desktop** 加 `build-essential` / `htop` / `unzip` / `jq` / `software-properties-common`;**server** 維持最低集 | — |
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
| `git-config.module.sh` | `module/config/git_config` | git 全域設定 | git | 永遠(日用必裝) |

> **vscode 從 recommended 降級為 optional**(已不是主力編輯器)— 見 §6.3。
> **tmux / ssh-config / git-config 從 optional 升級為 recommended**(本人日用必裝)。


### 6.3 optional(預設不勾選,使用者主動選擇)

`optional` 按 `TAGS[0]` 分為三個次群組,TUI Quick Setup 會逐群詢問是否安裝;CLI 可用 `setup_ubuntu install --tag=<group>` 一次裝整群。

#### 6.3.1 CLI Essentials(`TAGS=("cli-essentials")`)— 強烈推薦,Quick Setup 預設 yes

日用 CLI 工具(`ls` / `cd` / `cat` / `find` / `git` UI 等的現代替代)。

| Module 檔名 | 來源 | 說明 | 依賴 |
|---|---|---|---|
| `lazygit.module.sh` | `module/submodule/lazygit.sh` | Git TUI | git |
| `lazydocker.module.sh` | `module/submodule/lazydocker.sh` | Docker TUI | docker |
| `fzf.module.sh` | `module/submodule/fzf.sh` | Fuzzy finder | git |
| `eza.module.sh` | `module/submodule/eza.sh` | `ls` 替代 | — |
| `zoxide.module.sh` | `module/submodule/zoxide.sh` | `cd` 替代 | — |
| `batcat.module.sh` | `module/submodule/batcat.sh` | `cat` 替代(語法高亮) | — |
| `fdfind.module.sh` | `module/submodule/fdfind.sh` | `find` 替代 | — |
| `fnm.module.sh` | (新建,拆自 setup_neovim.sh) | Fast Node Manager | — |

> 這些 module 也是 `neovim.module.sh` 的 dep — 裝 neovim 時會自動拉,但也可單獨裝。

#### 6.3.2 Agent CLI(`TAGS=("agent")`)— 多選一(或多選 / 不選)

三大 AI CLI agent,Quick Setup 預設 multi-select(0~3 個)。

| Module 檔名 | 來源 | 說明 | 依賴 |
|---|---|---|---|
| `claude-code.module.sh` | (新建) | Anthropic Claude Code CLI | — |
| `codex.module.sh` | (新建) | OpenAI Codex CLI | — |
| `gemini.module.sh` | (新建) | Google Gemini CLI | — |
| `claude-code-config.module.sh` | `module/config/claude/` | Claude Code 個人 settings(裝完 claude-code 才裝) | claude-code |

#### 6.3.3 其他(各種 `TAGS[0]`)— 環境/硬體特定或備選

| Module 檔名 | 來源 | 說明 | 依賴 | TAGS[0] |
|---|---|---|---|---|
| `vscode.module.sh` | `module/setup_vscode.sh` | VS Code(從 recommended 降級) | apt-essentials | editor |
| `yazi.module.sh` | `module/submodule/yazi.sh` | TUI file manager | — | filemgr |
| `ranger.module.sh` | `module/config/ranger/rifle.conf` | ranger 檔案管理 | — | filemgr |
| `lnav.module.sh` | `module/config/lnav_pkg/` | log navigator | — | logs |
| `qmk-firmware.module.sh` | `module/setup_qmk_firmware.sh` | QMK 韌體開發環境 | apt-essentials, build-essential | hardware |
| `anydesk.module.sh` | `module/anydesk.sh` | AnyDesk 遠端桌面 | 有桌面環境 | remote |
| `gnome-terminal-config.module.sh` | `module/tools/copy_gnome_terminal_config.sh` | gnome-terminal 設定 | 桌面 = GNOME | desktop |

> TUI 在 §6.3.3 內進一步按 `TAGS[0]` 子分組顯示(`editor` / `filemgr` / `logs` / `hardware` / `remote` / `desktop`)。

### 6.4 experimental(預設不裝,有風險或不穩定)

`experimental` 分類保留,作為未來不穩定 module 的入口。**目前無 module 在此類**(`dual-system-time-sync` / `trash-maintenance` 為一次性腳本,不放 TUI / module pipeline 內,見 §6.5)。

### 6.5 module/tools/* 處理

> **v0.1 整個 `module/tools/` 不處理**;一次性腳本(如 `trash.sh`)不放在 TUI 內 / 不模組化。

**v0.1 操作**:
- `module/tools/*` 整個目錄**搬遷到 repo 根目錄**(如 `tools/`),作為臨時存放區
- 不進 module catalog、不出現在 TUI、不走 install pipeline
- 各檔案後續(v0.2+)再個別討論去向

涵蓋的檔案:
- `module/tools/setup_terminal_font_size.sh`
- `module/tools/copy_neovim_local_config.sh`
- `module/tools/copy_gnome_terminal_config.sh`
- `module/tools/dual_system_time_sync.sh`
- `module/tools/trash-maintenance.sh`(原規劃 experimental,撤回)
- `module/tools/ros1/*`
- `module/tools/remove/*.sh`

### 6.6 small-tools/ 退場路徑

`small-tools/install.sh` 內裝的東西基本與上述 module 重疊,規劃:
- v0.1 釋出:`small-tools/` 維持原狀,可獨立執行
- v0.2:在 `setup_ubuntu list` 標示「small-tools/ deprecated,請改用 `setup_ubuntu install --base`」
- v0.5:`small-tools/` 移除,README 內僅保留歷史說明

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
| `install` | `<module>...` | `-y / --yes`、`--dry-run`、`--no-deps`、`--base`、`--recommended`、`--all-base`、`--category=<n>`、`--install-target=auto\|sudo\|user-home`、`--force` | 安裝指定 module(自動帶 dep) | `apt install` |
| `remove` | `<module>...` | `-y / --yes`、`--dry-run`、`--with-orphans` | 移除 module(保留 config) | `apt remove` |
| `purge` | `<module>...` | `-y / --yes`、`--dry-run`、`--with-orphans` | 完整移除 module + config | `apt purge` |
| `update` | — | — | 刷新 module 清單與 GitHub release 版本快取 | `apt update` |
| `upgrade` | `[<module>...]` | `-y`、`--dry-run` | 重跑各 module `install()` 升級到 latest | `apt upgrade` |
| `search` | `<keyword>` | — | 在 NAME / DESCRIPTION / TAGS 內搜尋 | `apt search` |
| `show` | `<module>` | — | 印出 module 完整 metadata | `apt show` |
| `list` | — | `--category=<n>`、`--installed`、`--available`、`--tag=<t>`、`--json` | 列出 module | `apt list` |
| `status` | `[<module>]` | `--json` | 顯示已裝 module 與版本 | — |
| `detect` | — | `--json` | 環境偵測結果 | — |
| `doctor` | — | `--fix`(v1.x) | 健康檢查(state 檔 vs 實況) | — |
| `config load` | `[<module>]` | `-y` | 批次套用 module/config/*(對映 module 的 config 部分,不裝主程式) | — |
| `config set` | `<key>` `<value>` | — | 修改 `~/.config/init_ubuntu/config.ini` 的單一鍵值(取代手動編輯) | — |
| `config get` | `<key>` | — | 讀取單一鍵值 | — |
| `config unset` | `<key>` | — | 移除單一鍵值(回復為預設) | — |
| `config show` | — | `--json` | 印出整個有效 config(覆寫關係 + default) | — |
| `sync` | `<user@host>` | `--modules=<list>`、`--include-config`、`--pull`、`--dry-run` | SSH 跨機同步(見 §16) | — |
| `import` | `<file>` | `-y`、`--dry-run` | 從 export 過的 state.json 還原 | — |
| `export` | `<file>` | `--modules=<list>` | 匯出 state.json 子集 | — |
| `help` | `[<subcommand>]` | — | 顯示說明 | `apt --help` |
| `version` | — | — | 顯示版本 | `apt --version` |

### 7.3 範例

```bash
# 一鍵裝完所有 recommended(會依環境推薦自動勾選)
setup_ubuntu install --recommended -y

# 對標 apt 的常用流程
setup_ubuntu update
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

# 套用 module config(不裝主程式)
setup_ubuntu config load git-config
```

### 7.4 Exit code

| Code | 意義 |
|---|---|
| 0 | 成功 |
| 1 | 一般錯誤 |
| 2 | 引數錯誤(unknown subcommand / module 名拼錯) |
| 3 | 環境不支援(non-Ubuntu / 不支援的 Ubuntu 版本) |
| 4 | sudo 不可用且 module 不支援 user-home |
| 5 | 依賴循環 / 依賴解析失敗 |
| 6 | 部分 module 失敗(其他成功) |
| 7 | sync / SSH 失敗 |

### 7.5 Global flags

| Flag | 說明 |
|---|---|
| `--lang=en\|zh-TW` | 強制語言 |
| `--quiet` | 不輸出 info(只輸出 warn / error) |
| `--verbose / -v` | 輸出 debug 等級 |
| `--color=auto\|always\|never` | ANSI 色彩控制;**預設 `auto`,自動偵測 tty / `$NO_COLOR` / `$TERM=dumb` / 後台執行**,適合輸出彩色才開 |
| `--state-dir=<path>` | 改寫 state 目錄(預設 `${XDG_STATE_HOME:-$HOME/.local/state}/init_ubuntu`) |
| `--install-target=auto\|sudo\|user-home` | 強制安裝目標(預設 `auto`) |
| `--profile=server\|desktop\|jetson\|...` | 強制平台 form factor(覆寫自動偵測) |

---

## 8. TUI Wireframe

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
|   5.  Advanced  -->         Experimental / custom         |
|   6.  Manage Installed -->  Update / Remove / Purge       |
|   7.  Manage Secrets   -->  setup_secrets (SSH/GPG)       |
|   8.  System Info           Environment detection details |
|                                                           |
|   <  Save & Exit  >    <  Cancel  >                       |
+-----------------------------------------------------------+
```

### 8.2 子選單範例:Optional(按 TAGS 分組)

```
+- Optional Modules ----------------------------------------+
|                                                           |
|  monitor:                                                 |
|    [ ] btop          (top alternative)                    |
|    [ ] htop                                               |
|                                                           |
|  cli:                                                     |
|    [ ] eza           (ls alternative)                     |
|    [ ] zoxide        (cd alternative)                     |
|    [ ] batcat                                             |
|                                                           |
|  agent:                                                   |
|    [ ] claude-code                                        |
|    [ ] codex                                              |
|    [ ] gemini                                             |
|                                                           |
|  <  Apply  >   <  Back  >                                 |
+-----------------------------------------------------------+
```

> Module 在 TUI 內按 `TAGS[0]` 自動分組;每個 module 只在第一個 tag 群組顯示,避免重複勾選混淆。

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

Step 3/4: CLI Essentials suite?  (8 tools)
  lazygit / lazydocker / fzf / eza / zoxide / batcat / fdfind / fnm
  [ Yes, install all ]  [ Pick individually ]  [ Skip ]

Step 4/4: AI agent CLI?  (multi-select)
  [x] claude-code     (recommended)
  [ ] codex
  [ ] gemini
  [ Continue ]

Review & Install  -->  顯示完整安裝清單,Proceed / Back / Cancel
```

`optional - 其他`(§6.3.3)不在 Quick Setup 內,使用者要用主選單第 4 項「Optional」進入逐項選擇。

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

> Manage Installed 內也可切換到「按 type 分組」檢視(monitor / cli / agent / editor / ...),便於管理大量已裝 module。

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

### 8.5 後端偵測

```bash
# 偽碼
if command -v dialog >/dev/null; then
  TUI_BACKEND="dialog"
elif command -v whiptail >/dev/null; then
  TUI_BACKEND="whiptail"
else
  log_fatal "Install 'dialog' or 'whiptail' first: sudo apt install dialog"
fi
```

---

## 9. Module Contract(完整定義)

> 完整 spec 在 `docs/module-spec.md`。此處為摘要。

### 9.1 Required metadata(放檔頭)

```bash
NAME="docker"
VERSION_PROVIDED="apt-managed"
DESCRIPTION_EN="Docker Engine + Compose plugin"
DESCRIPTION_ZH_TW="Docker 容器引擎 + Compose 外掛"
CATEGORY="recommended"                  # base | recommended | optional | experimental
TAGS=("container" "devops")             # TAGS[0] 決定 TUI 分組
SUPPORTED_UBUNTU=("22.04" "24.04" "26.04")
SUPPORTED_PLATFORMS=("desktop" "server" "wsl")
DEPENDS_ON=("apt-essentials")
CONFLICTS_WITH=()
SUPPORTS_USER_HOME=false                # 是否支援 non-sudo 安裝
RISK_LEVEL="low"                        # low | medium | high
PARALLEL_GROUP="apt"                    # apt | download | config | custom
```

### 9.2 Required functions

```bash
detect()          # 0 = 此 module 可在當前環境執行
is_recommended()  # 0 = 在當前環境建議勾選(會看 INIT_UBUNTU_FORM_FACTOR)
is_installed()    # 0 = 已安裝
install()         # 安裝(idempotent;會看 INIT_UBUNTU_INSTALL_TARGET)
remove()          # 移除(保留 config,idempotent)
purge()           # 完整移除(含 config,idempotent)
```

### 9.3 Module 範本

```bash
#!/usr/bin/env bash
# module/docker.module.sh

NAME="docker"
DESCRIPTION_EN="Docker Engine + Compose plugin"
DESCRIPTION_ZH_TW="Docker 容器引擎 + Compose 外掛"
CATEGORY="recommended"
TAGS=("container" "devops")
SUPPORTED_UBUNTU=("22.04" "24.04" "26.04")
DEPENDS_ON=("apt-essentials")
SUPPORTS_USER_HOME=false

detect()         { command -v lsb_release >/dev/null && [[ "$(lsb_release -is)" == "Ubuntu" ]]; }
is_recommended() { ! is_installed && ! systemd-detect-virt --container --quiet; }
is_installed()   { dpkg -l docker-ce 2>/dev/null | grep -q '^ii'; }

install() {
    sudo apt-get update
    sudo apt-get install -y docker-ce docker-ce-cli containerd.io docker-compose-plugin
    sudo usermod -aG docker "${USER}"
}

remove() {
    sudo apt-get remove -y docker-ce docker-ce-cli containerd.io docker-compose-plugin
}

purge() {
    sudo apt-get purge -y docker-ce docker-ce-cli containerd.io docker-compose-plugin
    sudo rm -rf /var/lib/docker /etc/docker
    rm -rf "${HOME}/.docker"
}
```

---

## 10. Configuration & State

**統一規則 [N14]**:所有 config 寫到 `${XDG_CONFIG_HOME:-$HOME/.config}/<tool-or-module>/`,**不寫**到 `$HOME/` 根層。例外:某些工具的歷史包袱(如 `~/.bashrc`)可保留,但 module metadata 需註記 `LEGACY_DOTFILE=true`。

### 10.1 State 檔(XDG)

`${XDG_STATE_HOME:-$HOME/.local/state}/init_ubuntu/state.json`

```json
{
  "version": "0.1.0",
  "installed": {
    "docker": {
      "version_provided": "apt-managed",
      "installed_at": "2026-05-13T14:22:33+08:00",
      "installed_by": "init_ubuntu@v0.1.0",
      "manual": false
    },
    "neovim": {
      "version_provided": "v0.10.2",
      "installed_at": "2026-05-13T14:25:01+08:00",
      "installed_by": "init_ubuntu@v0.1.0",
      "manual": false,
      "dependents_of": ["fzf", "lazygit", "fdfind"]
    }
  }
}
```

| 欄位 | 型別 | 說明 |
|---|---|---|
| `version` | string | state schema 版本(SemVer) |
| `installed.<name>.version_provided` | string | 安裝當下 module 提供的版本(`apt-managed` / `v0.10.2` / ...) |
| `installed.<name>.installed_at` | string(ISO 8601) | 安裝時間 |
| `installed.<name>.installed_by` | string | 安裝工具版本 |
| `installed.<name>.manual` | boolean | 是否使用者手動指定(非作為 dep) |
| `installed.<name>.dependents_of` | string[] | 此 module 是哪些 module 的 dep(用於 `--with-orphans` 判斷) |

### 10.2 Log

`${XDG_STATE_HOME:-$HOME/.local/state}/init_ubuntu/logs/<YYYY-MM-DD-HHMMSS>.jsonl`

**Log 主要使用對象是 agent**(Claude / Codex / Gemini)做問題診斷,因此採用**結構化 JSONL** 格式(每行一個 JSON object,易被工具切片與查詢)。stdout 同時印人類可讀格式。

每次 `install` / `remove` / `purge` 產一個 `.jsonl` 檔。每筆 log entry 的 schema:

```json
{"ts":"2026-05-13T14:22:33+08:00","level":"info","module":"docker","event":"install_start","payload":{"version":"apt-managed","install_target":"sudo","dry_run":false}}
{"ts":"2026-05-13T14:22:34+08:00","level":"info","module":"docker","event":"cmd_exec","payload":{"cmd":"sudo apt-get update","exit":0,"duration_ms":1430}}
{"ts":"2026-05-13T14:22:45+08:00","level":"info","module":"docker","event":"cmd_exec","payload":{"cmd":"sudo apt-get install -y docker-ce ...","exit":0,"duration_ms":11200}}
{"ts":"2026-05-13T14:23:02+08:00","level":"info","module":"docker","event":"install_done","payload":{"status":"ok"}}
```

| 欄位 | 型別 | 說明 |
|---|---|---|
| `ts` | ISO 8601 | 事件時間 |
| `level` | enum(`debug` / `info` / `warn` / `error` / `fatal`) | 等級 |
| `module` | string \| null | 哪個 module(engine 層事件為 null) |
| `event` | string | 事件代號(`install_start` / `cmd_exec` / `dep_resolved` / `snapshot_taken` / `recovery_triggered` / `install_done` / ...)|
| `payload` | object | 事件特定資料 |

**Session 開頭**會印一筆 `session_start` 含當下環境偵測快照(`form_factor` / `os` / `arch` / `gpu` / ...)。**Session 結尾**印 `session_end` 含 exit code + 統計(ok / skipped / failed 個數)。

額外的人類可讀單行格式仍會印到 stdout(`tee` 模式),但**檔案存的是 JSONL**。

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

`setup_ubuntu doctor`(v1.x)會偵測 hand-edit(用 checksum)並警告。

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

[modules]
disabled = ["qmk-firmware"]            # 永遠不推薦這個 module

[secrets]
backend = auto                         # auto | pass | gnome-keyring | encrypted-file
```

---

## 11. Acceptance Criteria

### 11.1 v0.1 (MVP) — 必須通過

| ID | 條件 |
|---|---|
| AC-1 | 在乾淨 `ubuntu:22.04` container 內 `setup_ubuntu install --base -y` 成功 |
| AC-2 | 在乾淨 `ubuntu:24.04` container 內同樣指令成功 |
| AC-3 | 在乾淨 `ubuntu:26.04` container 內同樣指令成功 |
| AC-4 | `setup_ubuntu install neovim` 自動拉入所有 dep 並裝完 |
| AC-5 | `setup_ubuntu install neovim` 跑兩次,第二次仍 exit 0(idempotent) |
| AC-6 | `setup_ubuntu remove neovim` → `setup_ubuntu install neovim` 連續執行可成功 |
| AC-7 | `setup_ubuntu purge docker` 後 `~/.docker` 與 `/etc/docker` 不存在 |
| AC-8 | `setup_ubuntu detect --json` 在 NVIDIA 機器輸出 `"gpu": {"vendor": "nvidia", ...}` |
| AC-9 | 在容器內跑 `setup_ubuntu detect` 偵測到 `"form_factor": "container"` 並把 nvidia-driver 從推薦排除 |
| AC-10 | TUI(dialog 與 whiptail 兩種後端)主選單可顯示、可選擇、可儲存退出 |
| AC-11 | CLI 與 TUI 同一個 module 安裝結果完全一致(state.json diff = 0) |
| AC-12 | `--dry-run` 不對檔案系統做任何寫入(用 strace 驗證) |
| AC-13 | 無 sudo 環境下,`setup_ubuntu install eza` 走 user-home 安裝(裝到 `$HOME/.local/bin/eza`)且 `eza --version` 可執行 |
| AC-14 | `setup_ubuntu export A.json` → 在另一台 `setup_ubuntu import A.json` 結果一致 |
| AC-15 | `setup_ubuntu sync user@host` 推送後對端 state.json 含預期 module |
| AC-16 | 非 tty 輸出(`setup_ubuntu list | cat`)自動關閉 ANSI 色彩 |
| AC-17 | bats unit test 覆蓋率 >= 80%(by kcov) |
| AC-18 | integration test 在 GitHub Actions `ubuntu-22.04` + `ubuntu-24.04` + `ubuntu-26.04` 矩陣全綠 |
| AC-19 | 寫一個新的 dummy module(<10 行)能被 engine 自動發現並列入 `list` |
| AC-20 | `setup_secrets ssh-key generate` 互動產 key 不入 shell history |
| AC-21 | nvidia-driver install 失敗時自動回復 nouveau,系統仍可開機進入桌面 |

### 11.2 v1.0 — 額外要求

| ID | 條件 |
|---|---|
| AC-22 | 覆蓋率 100% |
| AC-23 | `small-tools/` 已移除,README 內保留歷史說明 |
| AC-24 | `.adoc` 全部換為 `.md` |
| AC-25 | i18n en + zh-TW 全覆蓋(無 untranslated string) |

---

## 12. Delivery Milestones

| Milestone | Plan | Status |
|---|---|---|
| M0 - Discovery | `.claude/prds/init-ubuntu.prd.md` + `docs/architecture.md` + `docs/module-spec.md` | in-progress |
| M1 - Test harness | 借用 base 的 `Dockerfile.test-tools` + 客製 + `Makefile` + `script/ci/ci.sh` | pending |
| M2 - Engine core | `lib/dispatcher.sh` + `lib/registry.sh` + `lib/runner.sh` + 1 reference module(`docker`) | pending |
| M3 - Detect engine | `lib/detect.sh` + `lib/platform.sh` + `setup_ubuntu detect` | pending |
| M4 - State + log | `lib/state.sh` + `lib/state_io.sh` + `lib/log.sh` | pending |
| M5 - CLI | `setup_ubuntu.sh` 所有 subcommand(含 update/upgrade/search/show/import/export) | pending |
| M6 - TUI | `setup_ubuntu_tui.sh` + `lib/tui_backend.sh`(含 tag 分組) | pending |
| M7 - Module migration | 將現有 ~15 module 改寫為新介面(neovim 拆 dep) | pending |
| M8 - i18n + color | `lib/i18n.sh` + `lib/color.sh`(對標 base) | pending |
| M9 - Sync + Secrets | `lib/sync.sh` + `setup_secrets.sh` | pending |
| M10 - Unit tests 80% | bats + bats-mock + fishtape | pending |
| M11 - Integration tests | `ubuntu:22.04` + `ubuntu:24.04` + `ubuntu:26.04` 矩陣 | pending |
| M12 - Coverage + CI | kcov + GitHub Actions | pending |
| M13 - Code review | code-reviewer x 2 + security-reviewer 並行 | pending |
| M14 - Docs + .adoc->.md | README 改寫,docs/ 補齊 | pending |
| M15 - Post-install management 驗收 | 確認裝完後 CLI + TUI 仍可管理(install / remove / sync / status) | pending |
| M16 - Coverage 100% | 後續迭代 | pending |

---

## 13. 決定事項(原 Open Questions,已收斂)

| # | Question | **決定** |
|---|---|---|
| Q1 | `apt-essentials.module.sh` 該裝哪些套件? | **依平台調整**;最低保證 `git` / `vim` 等通用簡單工具;desktop 加 `build-essential` / `htop` / `unzip` / `jq` / `software-properties-common`;server 維持最低集 |
| Q2 | `fish` 應放 base 還是 recommended? | **recommended**(永遠 `is_recommended=true`,給機會取消) |
| Q3 | `neovim` 是否拆分 dep? | **拆開**;先安裝 dep(`fzf` / `lazygit` / `ripgrep` / `fdfind` / `fnm`)才安裝 nvim,讓 dep 可重用 |
| Q4 | `fnm` 該獨立 module 還是埋在 neovim? | **獨立**,符合 Q3 精神;依「可複用 + 好管理」為主,不要為單一 tool 把 dep 綁定 |
| Q5 | `nvimdots` config 是 module 一部分還是另一個 module? | **內嵌**在 `neovim.module.sh`;但 install 時**顯示推薦勾選**,user 按 Enter 或確認即安裝(default 同意) |
| Q6 | `module/config/` 內的 config 檔該怎麼套用? | 每個有對應的 `<name>-config.module.sh` 含 install / remove;**另加 subcommand `config load`** 做批次套用 |
| Q7 | `experimental` 分類是否保留? | **保留**作為未來不穩定 module 入口;但 `dual-system-time-sync` 不該放這層,後續重新分類 |
| Q8 | 是否要在 v0.1 就支援 import / export state? | **v0.1 就要有**(已從 nice-to-have 提前到必備) |
| Q9 | `setup_ubuntu install --recommended` 是否包含 `nvidia-driver`? | **可包含**,但需使用者 dual-check 確認;若是 CI 測試或偵測到會改 kernel module,**install 失敗時必須自動回復**到可開機狀態(`RISK_LEVEL=high` + `RECOVERY_FALLBACK=nouveau`) |
| Q10 | `purge` 是否要連 dep 一起 purge? | **不要**;純 purge 自己。要清 dep 用 `--with-orphans`(只清沒被其他 module 依賴的 dep) |
| Q11 | Module 檔名 kebab-case 還是 snake_case? | **kebab-case** |
| Q12 | 是否要支援 `setup_ubuntu rollback`? | **v0.1 不做**,v1.x 評估 |

> 設計細節層次的決定(parallel 預設、sync 簽章、secrets backend 選擇、平台 allowlist 策略、高風險 module snapshot 範圍、non-sudo 模式 apt-essentials 處理)收斂進 `docs/architecture.md` §18 開放問題與決定。

---

## 14. Sensitive Tools sub-tool [N4]

> 完整設計見 `docs/architecture.md` §15。

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

> 完整設計見 `docs/architecture.md` §14。

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

Module metadata 加 `SUPPORTED_PLATFORMS`(string[],見 `docs/module-spec.md` §3.3):

```bash
SUPPORTED_PLATFORMS=("desktop" "server")    # 不支援 SBC
```

不在 allowlist 的平台:`is_recommended()` 永遠 false,但允許 `--force` 強裝。

### 15.4 平台差異化的 module 範例

| Module | desktop | server | jetson-orin | wsl |
|---|---|---|---|---|
| `apt-essentials` | + GUI 套件 | 純 CLI | Jetson SDK 子集 | 純 CLI |
| `nvidia-driver` | 推薦(若有卡) | 推薦(若有卡) | **不裝**(內建) | 不推薦 |
| `font` | 推薦 | 不裝 | 不裝 | 不裝 |
| `docker` | 推薦 | 推薦 | 推薦(+ NVIDIA Toolkit) | 推薦(Docker Desktop integration) |

---

## 16. Sync 機制 [N8]

> 完整設計見 `docs/architecture.md` §16。

### 16.1 目標

跨機快速同步「**裝了哪些 module**」,但**絕不傳 secrets**。

### 16.2 子命令

```bash
# Push 本機狀態到對端(預設)
setup_ubuntu sync <user@host> [--modules base,recommended] [--include-config] [--dry-run]

# Pull 對端狀態
setup_ubuntu sync <user@host> --pull
```

### 16.3 流程

1. SSH 連線測試(`--strict-host-key-checking=yes`)
2. 對端 bootstrap(若無 `setup_ubuntu`,rsync 工具過去)
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
- ✅ Bootstrap 對端
- ❌ Payload 簽章(v1.x)
- ❌ Push secrets(由 `setup_secrets sync ...` v1.x 處理)

---

## 17. Post-install Self-Management [N15]

### 17.1 原則

裝完之後,使用者**永遠可以**繼續用同一套工具管理環境:

```bash
setup_ubuntu list --installed         # 看裝了什麼
setup_ubuntu install eza              # 隨時新增
setup_ubuntu purge nvidia-driver -y   # 隨時移除
setup_ubuntu sync user@laptop         # 推到別台
setup_ubuntu doctor                   # 健康檢查
setup_ubuntu_tui                      # 互動式管理
```

### 17.2 與 base repo 標準流程的差異

不採用 `init.sh` symlinks 路徑(那會把 repo 變 Docker container repo)。我們的工具**自己**是 entry point,裝完後:

- `setup_ubuntu` / `setup_ubuntu_tui` / `setup_secrets` 三個檔案保持可執行
- 可加進 `$PATH`(`install` 子命令完成時提示)
- state.json 持續被讀寫

### 17.3 工具自身的升級路徑

- `setup_ubuntu self-upgrade`(v1.x):從 GitHub release 拉最新版
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
| `module/submodule/*.sh` (8 個) | `module/<name>.module.sh`(8 個 `cli-essentials` optional module,見 §6.3.1) | 改寫 |
| (無) | `module/claude-code.module.sh` / `codex.module.sh` / `gemini.module.sh` | 新建(3 大 agent) |
| `module/function/logger.sh` | `lib/logger.sh` | 整理(可能拆 file logging 出去) |
| `module/function/general.sh` | `lib/general.sh` + `lib/detect.sh` + `lib/platform.sh` | 拆分(平台分類抽到獨立檔) |
| `module/function/test/test_*.sh` | `test/unit/logger_spec.bats` 與 `general_spec.bats` | 重寫為 bats |
| `module/tools/*`(整個目錄) | **搬遷到 repo 根目錄 `tools/`** | v0.1 不處理,僅搬遷;v0.2+ 個別決定 |
| └ `module/tools/remove/*.sh` | (隨上面整個目錄搬遷) | v0.1 不處理(改寫 remove/purge 邏輯延後) |
| └ `module/tools/trash-maintenance.sh` | (隨上面搬遷) | **不放 module pipeline / 不放 TUI**(一次性腳本) |
| └ `module/tools/setup_terminal_font_size.sh` | (隨上面搬遷) | v0.1 不處理 |
| └ `module/tools/dual_system_time_sync.sh` | (隨上面搬遷) | v0.1 不處理 |
| └ `module/tools/copy_*.sh` | (隨上面搬遷) | v0.1 不處理 |
| └ `module/tools/ros1/*` | (隨上面搬遷) | v0.1 不處理 |
| `module/config/*` | 不動 — 由各對應 module 引用 | 保留 |
| `template/*_tmp.sh` | `template/module.template.sh` + `template/test.template.bats` | 改寫為新契約模板 |
| `small-tools/*` | v0.5 移除,內容已分散到對應 module | deprecation 路徑 |
| `gh-upgrade-README.md` | 評估歸入 `docs/` 或保留 | 評估 |
| `install-nvidia-driver.sh` | 與 `module/nvidia-driver.module.sh` 整合 | 整合 |
| `run_claude.sh` | 不動 | 保留 |
| `*.adoc` | `*.md`(rewrite,不只是改副檔名) | 全改 |
