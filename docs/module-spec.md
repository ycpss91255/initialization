# Module Specification

> 此文件定義 `module/<name>.module.sh` 的契約。**任何符合此契約的 module 都會被 engine 自動載入,無需修改 engine 程式碼。**

---

## 1. 檔案命名

- 位置:`module/<name>.module.sh`
- `<name>` 規則:`kebab-case`,符合 regex `^[a-z][a-z0-9-]*$`
- 副檔名固定 `.module.sh`,讓 engine 用 glob 安全掃描

範例合法名稱:
- `docker.module.sh`
- `nvidia-driver.module.sh`
- `claude-code-config.module.sh`

範例不合法名稱:
- `Docker.module.sh`(大寫)
- `nvidia_driver.module.sh`(底線,不是 kebab)
- `2nvidia.module.sh`(數字開頭)
- `docker.sh`(缺少 `.module` 中綴)

---

## 2. Module 檔案結構

每個 module 檔案分三段,**順序必須是**:

1. Shebang + strict mode
2. Metadata(全域變數宣告)
3. Lifecycle 函式定義

### 2.1 完整模板

```bash
#!/usr/bin/env bash
# module/docker.module.sh

set -euo pipefail
shopt -s inherit_errexit 2>/dev/null || true

# ===========================================================
# Metadata
# ===========================================================

NAME="docker"
VERSION_PROVIDED="apt-managed"
DESCRIPTION_EN="Docker Engine + Compose plugin"
DESCRIPTION_ZH_TW="Docker 容器引擎 + Compose 外掛"
CATEGORY="recommended"
TAGS=("container" "devops")
SUPPORTED_UBUNTU=("22.04" "24.04")
DEPENDS_ON=("apt-essentials")
CONFLICTS_WITH=()

# ===========================================================
# Lifecycle
# ===========================================================

detect() {
    command -v lsb_release >/dev/null 2>&1 && \
        [[ "$(lsb_release -is)" == "Ubuntu" ]]
}

is_recommended() {
    ! is_installed && ! systemd-detect-virt --container --quiet
}

is_installed() {
    dpkg -l docker-ce 2>/dev/null | grep -q '^ii'
}

install() {
    log_info "Installing docker-ce..."
    sudo apt-get update
    sudo apt-get install -y \
        docker-ce \
        docker-ce-cli \
        containerd.io \
        docker-compose-plugin
    sudo usermod -aG docker "${USER}"
    log_info "Done. Re-login required for group membership."
}

remove() {
    log_info "Removing docker-ce (config retained)..."
    sudo apt-get remove -y \
        docker-ce \
        docker-ce-cli \
        containerd.io \
        docker-compose-plugin
}

purge() {
    log_info "Purging docker-ce + config..."
    sudo apt-get purge -y \
        docker-ce \
        docker-ce-cli \
        containerd.io \
        docker-compose-plugin
    sudo rm -rf /var/lib/docker /etc/docker
    rm -rf "${HOME}/.docker"
}
```

---

## 3. Metadata 規範

每個 metadata 變數的**型別、合法值、預設值、必要性**如下。

### 3.1 必要欄位

#### `NAME` (string, required)

- 必須與檔名前綴一致(`docker.module.sh` 必須 `NAME="docker"`)
- 字元集:`[a-z0-9-]`,首字元必須是字母
- 用於 CLI 引用:`setup_ubuntu install <NAME>`

#### `DESCRIPTION_EN` (string, required)

- 一句話英文描述,< 80 字元
- 出現在 `list` 輸出與 TUI 選單

#### `DESCRIPTION_ZH_TW` (string, required)

- 一句話繁中描述,< 50 字元
- 對應 `--lang=zh-TW` 時顯示

#### `CATEGORY` (string, required)

- 列舉值:`base` | `recommended` | `optional` | `experimental`
- 一個 module 只能屬於一個 category

#### `SUPPORTED_UBUNTU` (string[], required)

- bash 陣列,內含支援的 Ubuntu 版本字串
- 範例:`SUPPORTED_UBUNTU=("22.04" "24.04")`
- 若空陣列,表示「不限制」(慎用)
- Engine 在當前 Ubuntu 版本不在此清單時拒絕安裝

### 3.2 選填欄位

#### `VERSION_PROVIDED` (string, optional)

- 描述本 module 將安裝的版本
- 合法值:
  - `apt-managed`(由 apt 決定)
  - `latest`(每次取 GitHub 最新)
  - 具體版本字串(`v0.10.2`)
- 預設:`unknown`

#### `TAGS` (string[], optional)

- 用於 TUI / `list --tag=<>` 過濾
- 慣用 tag:`container` / `devops` / `editor` / `shell` / `cli` / `gui` / `hardware` / `gpu`
- 預設:`()`

#### `DEPENDS_ON` (string[], optional)

- 此 module 依賴的其他 module 名稱(name 而非檔名)
- Engine 在 install 時自動把這些 dep 也納入 install order
- 預設:`()`
- **不可有循環依賴**;engine 啟動時偵測到循環會 exit 5

#### `CONFLICTS_WITH` (string[], optional)

- 此 module 不能與哪些 module 共存
- Install 時如另一方已裝,exit 失敗並提示
- 預設:`()`

#### `MAINTAINER` (string, optional)

- 維護者標記(便於後續多人協作)
- 格式:`Name <email>`
- 預設:無

#### `HOMEPAGE` (string, optional)

- 此 module 對應工具的官方網址
- 預設:無

### 3.3 進階欄位(因 N6 / N9 / N17 / N3 引入)

#### `SUPPORTS_USER_HOME` (boolean, optional)

- `true` = module 在無 sudo 環境下也能裝(裝到 `$HOME/.local/`)
- `false` = module 必須 sudo(如 `docker`、`nvidia-driver`),無 sudo 時 engine 會跳過 + 警告
- 預設:`false`(保守)

#### `SUPPORTED_PLATFORMS` (string[], optional)

- 列出此 module 可裝的 form factor(對應 `lib/platform.sh` 輸出)
- 合法值:`desktop` / `server` / `rpi-4` / `rpi-5` / `jetson-orin` / `wsl` / `container` / `vm`
- 空陣列 = 不限制(視同支援全部)
- 範例:`SUPPORTED_PLATFORMS=("desktop" "server")` — 不支援 SBC
- 預設:`()`(不限)

#### `RISK_LEVEL` (string, optional)

- 列舉值:`low` | `medium` | `high`
- `high` 的 module(如 `nvidia-driver`)觸發:
  - install 前 dual-check(使用者確認)
  - install 前自動 snapshot 系統狀態
  - install 失敗時嘗試自動回復(`RECOVERY_FALLBACK` 行為)
- 預設:`low`

#### `RECOVERY_FALLBACK` (string, optional)

- `RISK_LEVEL=high` 才使用
- 描述失敗時的回復目標(例:`nouveau`、`generic-driver`)
- 預設:無

#### `PARALLEL_GROUP` (string, optional)

- 列舉值:`apt` | `download` | `config` | `custom`
- 同 group 的 module 不可同時跑;不同 group 可並行(v0.3+ 啟用)
- 預設:`apt`(保守,序列化)

#### `INSTALL_TARGET_DEFAULT` (string, optional)

- 列舉值:`sudo` | `user-home` | `auto`
- module 預設安裝目標;`auto` 由 engine 依環境決定
- 預設:`auto`

---

## 4. Lifecycle 函式規範

### 4.1 必要函式

每個 module 必須**全部**實作以下 6 個函式:

| 函式 | 簽名 | 回傳 | 副作用 | Idempotent |
|---|---|---|---|---|
| `detect()` | `() -> int` | 0=支援當前環境,非 0=不支援 | 無(只讀環境) | 是 |
| `is_recommended()` | `() -> int` | 0=建議勾選,非 0=預設不勾 | 無 | 是 |
| `is_installed()` | `() -> int` | 0=已裝,非 0=未裝 | 無 | 是 |
| `install()` | `() -> int` | 0=成功,非 0=失敗 | **裝套件、修改系統** | **必須** |
| `remove()` | `() -> int` | 0=成功,非 0=失敗 | **移除套件,保留 config** | **必須** |
| `purge()` | `() -> int` | 0=成功,非 0=失敗 | **移除套件 + config + state** | **必須** |

### 4.2 Idempotency 要求

- `install()` 被重複呼叫**必須** exit 0
  - 若已裝,可以直接 return 0(也可重複裝以更新版本)
- `remove()` 被重複呼叫**必須** exit 0
  - 若不存在,直接 return 0
- `purge()` 同上

驗證方式:integration test 會跑每個 lifecycle 兩次,assert 兩次都 exit 0。

### 4.3 函式可用的全域上下文

由 engine 注入,module 可直接使用:

| 變數 | 來源 | 範例值 |
|---|---|---|
| `${USER}` | 當前使用者 | `cyc` |
| `${HOME}` | 家目錄 | `/home/cyc` |
| `${INIT_UBUNTU_DRY_RUN}` | flag `--dry-run` | `true` / `false` |
| `${INIT_UBUNTU_LANG}` | 當前語言 | `en` / `zh-TW` |
| `${INIT_UBUNTU_VERBOSE}` | flag `--verbose` | `true` / `false` |
| `${INIT_UBUNTU_STATE_DIR}` | state 目錄 | `${HOME}/.local/state/init_ubuntu` |
| `${INIT_UBUNTU_DETECT}` | detect 結果 JSON | `{"os":..., "gpu":...}` |
| `${INIT_UBUNTU_INSTALL_TARGET}` | 由 engine 決定的安裝目標 [N6] | `sudo` / `user-home` |
| `${INIT_UBUNTU_FORM_FACTOR}` | 平台分類 [N9] | `desktop` / `server` / `rpi-5` / `jetson-orin` / `wsl` |
| `${INIT_UBUNTU_NO_COLOR}` | 是否關閉 ANSI [N12] | `0` / `1` |

Module 必須**僅**使用這些變數,不可期待其他全域狀態存在。

### 4.3.1 跨平台 `is_recommended()` 範例 [N9]

```bash
is_recommended() {
    case "${INIT_UBUNTU_FORM_FACTOR}" in
        desktop)
            ! is_installed
            ;;
        server|wsl|container)
            return 1  # 不推薦給無頭環境
            ;;
        rpi-*|jetson-orin)
            return 1  # SBC 預設不裝(可手動 install)
            ;;
        *)
            return 1
            ;;
    esac
}
```

### 4.3.2 對 sudo 與 user-home 雙模式的 `install()` 範例 [N6]

```bash
install() {
    case "${INIT_UBUNTU_INSTALL_TARGET}" in
        sudo)
            sudo apt-get install -y eza
            ;;
        user-home)
            local _ver=""
            get_github_pkg_latest_version _ver "eza-community/eza"
            curl -fsSL --retry 3 \
                "https://github.com/eza-community/eza/releases/download/v${_ver}/eza_x86_64-unknown-linux-gnu.tar.gz" \
                | tar -xz -C "${HOME}/.local/bin/"
            ;;
        *)
            log_error "Unknown INSTALL_TARGET: ${INIT_UBUNTU_INSTALL_TARGET}"
            return 1
            ;;
    esac
}
```

### 4.4 函式必須使用的 helper

從 `lib/general.sh` 與 `lib/logger.sh` 載入(engine 已 source):

| Helper | 必須 / 建議 | 用途 |
|---|---|---|
| `log_info` / `log_warn` / `log_error` | **必須** | 統一日誌格式 |
| `log_fatal` | **禁止** | 會 kill engine;失敗用 `return 1` |
| `apt_pkg_manager --install` | **建議** | 取代裸 `apt-get install`,有自動 retry |
| `exec_cmd` | **建議** | 用於印出將執行的命令 + dry-run 支援 |
| `have_sudo_access` | engine 已查 | module 內可省略 |
| `get_github_pkg_latest_version` | **建議** | 抓 GitHub release 版本號 |
| `backup_file` | **建議** | 覆寫前備份既有檔案 |
| `create_temp_file` | **建議** | 自動清理的臨時檔 |

### 4.5 Dry-run 處理

若 `${INIT_UBUNTU_DRY_RUN}` 為 `"true"`:
- **禁止**呼叫任何會修改檔案系統的命令(`apt-get install`、`rm`、`cp`、`mkdir` 等)
- 改用 `log_info "[DRY-RUN] would: <command>"` 印出將執行的內容
- 仍可呼叫 `is_installed` 等只讀檢查

推薦寫法:

```bash
install() {
    if [[ "${INIT_UBUNTU_DRY_RUN:-false}" == "true" ]]; then
        log_info "[DRY-RUN] would: sudo apt-get install -y docker-ce ..."
        return 0
    fi
    sudo apt-get install -y docker-ce ...
}
```

或用 `exec_cmd`(自動處理 dry-run):

```bash
install() {
    exec_cmd "sudo apt-get install -y docker-ce ..."
}
```

### 4.6 Sudo 範圍

- 僅在需要的命令前加 `sudo`,不要整個函式跑在 sudo bash 下
- 不可呼叫 `sudo -i` / `sudo -s`(會 spawn root shell)
- 不可 `chmod 777` 或 `chown -R root:root` 改使用者檔案

### 4.7 失敗回傳

- 用 `return 1`(或非 0),**不要** `exit`
- Engine 攔截 return,寫 log,繼續下一個 module
- `exit` 會把 engine 整個 kill,違反契約

### 4.8 不可使用

- `set +e`(關掉 error trap),engine 已啟用,不准關
- `trap ... EXIT`(會干擾 engine 自己的 trap)
- `cd <path>`(會改變 engine 的 cwd);用 `pushd`/`popd` 或 subshell
- 修改 `IFS` / `PATH` 等核心變數的全域值(可在 subshell 內改)
- source 任意檔案(除非該檔在本 module 自帶的 config 子目錄內)
- 直接呼叫其他 module 的函式(用 dep 機制讓 engine 處理順序)

---

## 5. 範例:複雜 module(neovim)

```bash
#!/usr/bin/env bash
# module/neovim.module.sh

set -euo pipefail
shopt -s inherit_errexit 2>/dev/null || true

# ===========================================================
# Metadata
# ===========================================================

NAME="neovim"
VERSION_PROVIDED="latest"
DESCRIPTION_EN="Neovim editor with nvimdots config"
DESCRIPTION_ZH_TW="Neovim 編輯器 + nvimdots 個人設定"
CATEGORY="recommended"
TAGS=("editor" "cli")
SUPPORTED_UBUNTU=("22.04" "24.04")
DEPENDS_ON=("apt-essentials" "git-config" "fzf" "lazygit" "fdfind" "fnm")
CONFLICTS_WITH=()
HOMEPAGE="https://neovim.io/"

# ===========================================================
# Lifecycle
# ===========================================================

readonly _NVIM_INSTALL_DIR="/opt/nvim"
readonly _NVIM_BIN="/usr/local/bin/nvim"

detect() {
    [[ "$(uname -m)" == "x86_64" ]]
}

is_recommended() {
    return 0
}

is_installed() {
    [[ -x "${_NVIM_BIN}" ]] && [[ -d "${_NVIM_INSTALL_DIR}" ]]
}

install() {
    if [[ "${INIT_UBUNTU_DRY_RUN:-false}" == "true" ]]; then
        log_info "[DRY-RUN] would install neovim to ${_NVIM_INSTALL_DIR}"
        return 0
    fi

    local _version=""
    get_github_pkg_latest_version _version "neovim/neovim"
    log_info "Installing Neovim v${_version}..."

    local _tmp=""
    create_temp_file _tmp "nvim" "tar.gz"
    curl -fsSL --retry 3 -o "${_tmp}" \
        "https://github.com/neovim/neovim/releases/download/v${_version}/nvim-linux-x86_64.tar.gz"

    if [[ -e "${_NVIM_INSTALL_DIR}" ]]; then
        backup_file "${_NVIM_INSTALL_DIR}"
        sudo rm -rf "${_NVIM_INSTALL_DIR}"
    fi

    sudo mkdir -p "${_NVIM_INSTALL_DIR}"
    sudo tar -C "${_NVIM_INSTALL_DIR}" --strip-components=1 -xzf "${_tmp}"
    sudo ln -sfn "${_NVIM_INSTALL_DIR}/bin/nvim" "${_NVIM_BIN}"

    _install_nvimdots_config
}

remove() {
    if [[ "${INIT_UBUNTU_DRY_RUN:-false}" == "true" ]]; then
        log_info "[DRY-RUN] would remove neovim from ${_NVIM_INSTALL_DIR}"
        return 0
    fi
    sudo rm -f "${_NVIM_BIN}"
    sudo rm -rf "${_NVIM_INSTALL_DIR}"
}

purge() {
    remove
    rm -rf "${HOME}/.config/nvim"
    rm -rf "${HOME}/.local/share/nvim"
    rm -rf "${HOME}/.cache/nvim"
}

# ===========================================================
# Helpers (private, 加底線前綴)
# ===========================================================

_install_nvimdots_config() {
    log_info "Installing nvimdots config..."
    local _module_dir="${BASH_SOURCE[0]%/*}"
    cp -r "${_module_dir}/config/neovim/nvimdots_config" \
        "${HOME}/.config/nvim/lua/user"
}
```

---

## 6. Module 內部目錄結構

若 module 需要附帶 config / asset 檔,放在 `module/config/<name>/` 下:

```
module/
├── neovim.module.sh
├── docker.module.sh
└── config/
    ├── neovim/
    │   ├── nvimdots_config/
    │   │   └── ...
    │   └── fnm_shell_config/
    │       ├── config.bash
    │       └── fnm.fish
    └── fish/
        └── config.fish
```

Module 內讀取自帶 config:

```bash
readonly _MODULE_CONFIG_DIR="${BASH_SOURCE[0]%/*}/config/neovim"
# 或更穩健:
readonly _MODULE_CONFIG_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/config/neovim" && pwd)"
```

**禁止**使用相對於 cwd 的路徑(`./config/neovim/`),會在 engine 不同 cwd 時失敗。

### 6.1 使用者 config 寫入路徑(N14)

當 `install()` 需要將 config 寫到使用者家目錄時,**統一寫到** `${XDG_CONFIG_HOME:-$HOME/.config}/<module-or-tool>/`,**不要**寫到 `$HOME/` 根層(如 `~/.myrc`、`~/.tool-config`)。

| 內容類型 | 寫入位置 |
|---|---|
| Module 對應工具的 config(如 nvim) | `~/.config/nvim/`(沿用工具預設) |
| Module 自管的本工具狀態 | `~/.config/init_ubuntu/<module>/`(本工具命名空間) |
| 純 dotfile(無法改路徑的歷史包袱,如 `~/.bashrc`) | 容許,但 module metadata 需註記 `LEGACY_DOTFILE=true` |

`install()` 若違反此規則,unit test 會抓出(`test/unit/modules/<name>_spec.bats` 內含 path assertion)。

---

## 7. 測試契約

每個 module 必須附帶單元測試 `test/unit/modules/<name>_spec.bats`,**最少涵蓋**:

| 測試 case | 必要 |
|---|---|
| Metadata 完整性(NAME / DESCRIPTION / CATEGORY 都有定義) | **必須** |
| `detect()` 在預期環境下回 0 | **必須** |
| `detect()` 在不支援環境下回非 0 | **必須** |
| `is_installed()` 未裝時回非 0(mock dpkg / which) | **必須** |
| `is_installed()` 已裝時回 0 | **必須** |
| `install()` 一次成功 | **必須** |
| `install()` 兩次成功(idempotent) | **必須** |
| `remove()` 一次成功 | **必須** |
| `remove()` 兩次成功(idempotent) | **必須** |
| `purge()` 後 config 確實清掉(mock fs) | **必須** |
| `--dry-run` 時 install 不呼叫 apt-get | **必須** |

範例骨架見 `template/test.template.bats`(將於 Phase 3 建立)。

---

## 8. 驗證工具

Engine 提供 `setup_ubuntu doctor --validate-modules`(v1.x)自動檢查所有 module:

- Metadata 必要欄位完整
- 函式名稱與簽名正確
- `NAME` 與檔名一致
- `DEPENDS_ON` 內的 module 都存在
- `CONFLICTS_WITH` 內的 module 都存在
- 無循環依賴

v0.1 階段可手動跑 `scripts/lint-modules.sh`(將於 Phase 2 建立)。

---

## 9. Module 範例索引

| 複雜度 | 範例 | 學習重點 |
|---|---|---|
| 簡單 | `module/eza.module.sh`(將建立)| 純 apt install,無 dep |
| 中等 | `module/docker.module.sh`(本檔 §2.1)| apt repo + group 加入 |
| 複雜 | `module/neovim.module.sh`(本檔 §5)| GitHub release + 自帶 config + 多 dep |
| 環境感知 | `module/nvidia-driver.module.sh`(待建)| 偵測 GPU + 拒絕在 container 內裝 |
| Config-only | `module/git-config.module.sh`(待建)| 只 copy 檔案,不裝套件 |

---

## 10. FAQ

### Q1: 我的 module 需要在 install 後重啟 / re-login,該怎麼處理?

不要呼叫 `reboot` / `pkill -USR1 ...`。在 `install()` 結尾用 `log_warn` 提示使用者:

```bash
log_warn "Docker installed. Run 'newgrp docker' or re-login to use docker without sudo."
```

### Q2: install 失敗到一半,系統處於不一致狀態,該怎麼回滾?

v0.1 **不要求**自動回滾(複雜度過高)。建議:
- 用 `backup_file` 在覆寫前備份
- 失敗時 log 出備份位置,讓使用者手動還原

### Q3: 我的 module 想呼叫另一個 module 的 helper,可以嗎?

不行。請把共用 helper 抽到 `lib/general.sh`(或新建 `lib/<topic>.sh`)。Module 之間**不互相依賴函式**,只透過 `DEPENDS_ON` 宣告安裝順序。

### Q4: 我能不能讓 module 在 install 時詢問使用者選項?

v0.1 不行。Module 必須是非互動的。若需要使用者輸入,把選項放到:
- CLI flag(如 `--variant=minimal`)— Engine 透過環境變數注入
- TUI submenu — TUI 收集後傳入 engine

### Q5: module 可以動態生成其他 module 嗎?

不行。Module 是靜態檔案,registry 只在啟動時掃描。
