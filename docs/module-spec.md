# Module Specification

> 此文件定義 `modules/<name>.module.sh` 的契約。**任何符合此契約的 module 都會被 engine 自動載入,無需修改 engine 程式碼。**

---

## 1. 檔案命名

- 位置:`modules/<name>.module.sh`
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

每個 module 檔案分四段,**順序必須是**:

1. **Dual-mode header** — `MODULE_STANDALONE` 偵測 + 條件式 source lib(僅獨立執行時觸發)
2. **Metadata** — 全域變數宣告(NAME / VERSION_PROVIDED / DESCRIPTION list / 約束 / 風險...)
3. **Lifecycle** — 透過 archetype macro 一次綁定,或手寫 install/update/remove/purge/verify
4. **Standalone footer** — 觸發 `module_standalone_main "$@"`(僅獨立模式)

### 2.1 完整模板(archetype 版,推薦)

`templates/module-apt.template.sh`(+ `-github-release` / `-config` / `-custom`)已含完整骨架。範例 — 一個用 archetype A(apt)的 module:

```bash
#!/usr/bin/env bash
# modules/apt-essentials.module.sh — base apt utilities

# ── Dual-mode header ────────────────────────────────────────
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

# ── Metadata ────────────────────────────────────────────────
NAME="apt-essentials"
VERSION_PROVIDED="apt-managed"
CATEGORY="base"
TAGS=("apt" "base")
HOMEPAGE=""
declare -gA DESCRIPTION=(
    [en]="Curl / git / build-essential and other apt baseline"
    [zh-TW]="curl/git/build-essential 等 apt 基線工具"
)
declare -gA POST_INSTALL_MESSAGE=()
declare -gA WARN_MESSAGE=()
SUPPORTED_UBUNTU=("22.04" "24.04" "26.04")
SUPPORTED_PLATFORMS=("desktop" "server" "wsl")
DEPENDS_ON=()
CONFLICTS_WITH=()
SUPPORTS_USER_HOME=false
RISK_LEVEL="low"
REBOOT_REQUIRED=false
INSTALL_TARGET_DEFAULT="sudo"
TEST_VERIFY_CMD="command -v curl && command -v git"

# ── Archetype A binding ─────────────────────────────────────
APT_PKGS=(curl git build-essential ca-certificates)
APT_PPA=""
CONFIG_PATHS=()
module_use_apt_archetype                # ← defines is_installed/install/update/remove/purge/verify

# ── Hand-written required hooks ─────────────────────────────
detect() {
    command -v apt-get >/dev/null 2>&1
}
is_recommended() {
    ! is_installed
}

# ── Standalone footer ───────────────────────────────────────
if [[ "${MODULE_STANDALONE:-false}" == "true" ]]; then
    module_standalone_main "$@"
fi
```

對比舊版手寫 60+ 行 install/remove/purge,archetype 版只需填欄位 + 一行 macro。
「不能套 archetype」的工具(docker、nvidia-driver、font)仍可手寫所有 lifecycle,參見 §5。

---

## 3. Metadata 規範

每個 metadata 變數的**型別、合法值、預設值、必要性**如下。

### 3.1 必要欄位

#### `NAME` (string, required)

- 必須與檔名前綴一致(`docker.module.sh` 必須 `NAME="docker"`)
- 字元集:`[a-z0-9-]`,首字元必須是字母
- 用於 CLI 引用:`setup_ubuntu install <NAME>`

#### `DESCRIPTION` (string[], required) — i18n list

- bash 陣列,每個元素為 `"<lang>:<text>"` 字串
- 至少**必須**包含 `"en:..."`(fallback);其他語言可選
- engine 透過 `module_get_description [lang]` 讀取(`lib/module_helper.sh` §2)
- 範例:
  ```bash
  DESCRIPTION=(
      "en:Docker Engine + Compose plugin"
      "zh-TW:Docker 容器引擎 + Compose 外掛"
      "ja:Docker エンジン + Compose プラグイン"
  )
  ```
- 線性掃描 + en fallback,擴充新語系只需新增一行
- 同樣語法亦用於 `POST_INSTALL_MESSAGE` / `WARN_MESSAGE`(§3.2)

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
- Install 與 upgrade 時若衝突 module 已裝,engine 拒絕並回 exit 5
- 預設:`()`

#### `HOMEPAGE` (string, optional)

- 此 module 對應工具的官方網址
- 預設:無

#### `POST_INSTALL_MESSAGE` (string[], optional) — i18n list

- 與 `DESCRIPTION` 同格式(`"<lang>:<text>"`)
- install 成功後 engine 收集所有 module 的 post-install message 統一顯示
  (例:「Docker installed. Run `newgrp docker` to use without sudo.」)
- 不需要時留空陣列 `()`
- 透過 `module_get_post_install_message` 讀取;`module_emit_post_install` 由 runner 呼叫

#### `WARN_MESSAGE` (string[], optional) — i18n list

- 與 `DESCRIPTION` 同格式;`RISK_LEVEL=high` 時 install 前顯示給使用者
- 範例:「nvidia-driver:會切換目前的 GPU 驅動,可能需要重新登入或 reboot」

### 3.2.1 Helper-driven 模組(archetype)

當 module 適用 `lib/module_helper.sh` 提供的標準 lifecycle 樣板時,**只需宣告資料欄位 + 呼叫一行 archetype macro**,macro 一次定義
`is_installed / install / update / remove / purge / verify` 六個 lifecycle。Macro 之後可重新宣告任一函式以覆寫(例:apt module 自行覆寫 `verify()` 跑 smoke test)。

#### Archetype A — APT-only

| 欄位 | 型別 | 必要 | 用途 |
|---|---|---|---|
| `APT_PKGS` | string[] | **必須** | 要透過 apt 管理的套件清單 |
| `APT_PPA` | string | 選填 | `ppa:foo/bar`,install 前自動 add,purge 時 remove |
| `CONFIG_PATHS` | string[] | 選填 | purge 時要 `rm -rf` 的使用者 config 目錄 |

呼叫方式(一行 macro):
```bash
APT_PKGS=(curl git build-essential)
APT_PPA=""                       # 選填
CONFIG_PATHS=()                  # 選填
module_use_apt_archetype         # ← 一次綁定 is_installed/install/update/remove/purge/verify
```

#### Archetype B — GitHub-release tarball

| 欄位 | 型別 | 必要 | 預設 | 用途 |
|---|---|---|---|---|
| `GITHUB_REPO` | string | **必須** | — | e.g. `neovim/neovim` |
| `GITHUB_ASSET_PATTERN` | string | **必須** | — | e.g. `nvim-linux-x86_64.tar.gz` |
| `INSTALL_DIR` | path | **必須** | — | e.g. `/opt/nvim` |
| `BIN_NAME` | string | **必須** | — | 主 binary 名(如 `nvim`) |
| `BIN_PATH_IN_TAR` | path | 選填 | `bin/${BIN_NAME}` | tar 內的 binary 相對路徑 |
| `BIN_LINK` | path | 選填 | `/usr/local/bin/${BIN_NAME}` | 對外符號連結目標 |
| `STRIP_COMPONENTS` | int | 選填 | `1` | `tar --strip-components` 值 |
| `USE_SUDO` | bool | 選填 | `true` | sudo / 純使用者模式 |
| `CONFIG_PATHS` | string[] | 選填 | — | purge 時清的使用者 config |

呼叫方式:
```bash
GITHUB_REPO="neovim/neovim"
GITHUB_ASSET_PATTERN="nvim-linux-x86_64.tar.gz"
INSTALL_DIR="/opt/nvim"
BIN_NAME="nvim"
CONFIG_PATHS=("${HOME}/.config/nvim")
module_use_github_release_archetype
```

#### Archetype C — Config-drop(純檔案複製)

| 欄位 | 型別 | 必要 | 預設 | 用途 |
|---|---|---|---|---|
| `CONFIG_TEMPLATE_SRC` | path | 選填 | — | module 內附帶的 config 範本檔 |
| `CONFIG_DEST` | path | **必須** | — | 寫到使用者家目錄的目標路徑 |
| `CONFIG_MARKER` | string | 選填 | `# init_ubuntu managed` | sentinel 註解,用於 is_installed 判斷 |
| `CONFIG_MODE` | chmod字串 | 選填 | — | dest 檔案權限(e.g. `600`) |
| `CONFIG_DIR_MODE` | chmod字串 | 選填 | — | 父目錄權限(e.g. `700`) |
| `CONFIG_STUB` | string | 選填 | — | 當 `CONFIG_TEMPLATE_SRC` 缺檔時寫入的 stub 內容 |

呼叫方式:
```bash
CONFIG_TEMPLATE_SRC="${MODULE_DIR}/config/ssh/config"
CONFIG_DEST="${HOME}/.ssh/config"
CONFIG_MODE="600"
CONFIG_DIR_MODE="700"
module_use_config_archetype
```

#### 覆寫 archetype 行為

Macro 後可重新宣告任一函式以注入自訂邏輯。例 — fish 套上 PPA 之後還要設成預設 shell:
```bash
APT_PKGS=(fish)
APT_PPA="ppa:fish-shell/release-4"
module_use_apt_archetype

# Override install: archetype 處理 PPA + apt,然後加上 chsh
install() {
    module_default_apt_install || return $?
    [[ "${INIT_UBUNTU_DRY_RUN:-false}" == "true" ]] && return 0
    chsh -s "$(command -v fish)" "${USER}" || log_warn "[fish] chsh failed"
}
```

不適用任一 archetype(如 docker、nvidia-driver、font)的 module 仍可手寫 install/remove/purge/update/verify;helper 提供的三個 generic guard
(`module_dryrun_guard` / `module_skip_if_installed` / `module_skip_if_not_installed`)仍可單獨使用以避免重抄 dry-run 樣板。

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
  - install 前顯示 `WARN_MESSAGE`(`module_get_warn_message`)
  - install 前 dual-check(使用者確認)
- 預設:`low`

#### `INSTALL_TARGET_DEFAULT` (string, optional)

- 列舉值:`sudo` | `user-home` | `auto`
- module 預設安裝目標;`auto` 由 engine 依環境決定
- 預設:`auto`

#### `REBOOT_REQUIRED` (boolean, optional)

- `true` = install 完成後需要重新開機才完整生效(如 nvidia-driver、grub 變動)
- engine 在 session 結束時透過 `module_emit_reboot_required` 聚合,統一提示使用者
- 預設:`false`

### 3.4 Doctor / verify 提示欄位

#### `TEST_VERIFY_CMD` (string, optional)

- `verify()` 預設行為(`module_default_verify`)會在 `is_installed` 成功後額外執行此命令當作 smoke test
- 例:`docker run --rm hello-world` / `command -v nvim && nvim --version`
- 預設:空(只跑 `is_installed`)

---

## 4. Lifecycle 函式規範

### 4.1 必要函式 + 選填函式

每個 module 必須實作 5 個 **mandatory** 函式 + 提供 5 個 **optional** 函式以啟用進階功能。

#### Mandatory(必要 — 5)

| 函式 | 簽名 | 回傳 | 副作用 | Idempotent |
|---|---|---|---|---|
| `detect()` | `() -> int` | 0=支援當前環境,非 0=不支援 | 無(只讀環境) | 是 |
| `is_recommended()` | `() -> int` | 0=建議勾選,非 0=預設不勾 | 無 | 是 |
| `is_installed()` | `() -> int` | 0=已裝,非 0=未裝 | 無 | 是 |
| `install()` | `() -> int` | 0=成功,非 0=失敗 | **裝套件、修改系統** | **必須** |
| `remove()` | `() -> int` | 0=成功,非 0=失敗 | **移除套件,保留 config** | **必須** |

#### Optional(選填 — 5;archetype macro 會自動提供預設實作)

| 函式 | 簽名 | 回傳 | 預設行為(未實作時) | Idempotent |
|---|---|---|---|---|
| `update()` | `() -> int` | 0=成功 | 若 archetype 提供則用 archetype 的 update;否則 standalone CLI 回 exit 2「not implemented」 | **必須** |
| `purge()` | `() -> int` | 0=成功 | archetype 提供(apt-purge + CONFIG_PATHS 清空);手寫 module 強烈建議實作 | **必須** |
| `verify()` | `() -> int` | 0=驗證通過 | `module_default_verify`:`is_installed` + 視 `TEST_VERIFY_CMD` 執行 | 是 |
| `is_outdated()` | `() -> int` | 0=有新版可裝 | 標記為「未提供」;`setup_ubuntu status` 顯示為 `?` | 是 |
| `doctor()` | `() -> int` | 0=健檢通過 | fallback 到 `is_installed`;runner 用於 `setup_ubuntu doctor` | 是 |

#### 內建函式(不需 module 提供)

`module_standalone_main` 額外接受兩個 phase,這兩個由 helper 直接讀 metadata,不需 module 實作:

| Phase | 行為 |
|---|---|
| `info` | 印出 metadata(NAME / version / description / homepage / tags / dep / risk / install_time / ...) |
| `status` | 印出 `installed=yes/no` / `outdated=yes/no/(no is_outdated)` / `version` |

### 4.2 Idempotency 要求

- `install()` / `update()` 被重複呼叫**必須** exit 0
  - 已裝就 return 0(`install` 通常用 `module_skip_if_installed` 短路);`update` 可重複拉 latest
- `remove()` / `purge()` 被重複呼叫**必須** exit 0
  - 若不存在,直接 return 0(用 `module_skip_if_not_installed` 短路)
- `verify()` / `is_outdated()` / `doctor()` 是純檢查,本來就 idempotent

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

### 4.4 函式可用的 helper

從 `lib/logger.sh`、`lib/general.sh`、`lib/module_helper.sh` 載入(engine sub-shell + standalone bootstrap 都已 source):

| Helper | 必須 / 建議 | 用途 |
|---|---|---|
| `log_info` / `log_warn` / `log_error` | **必須** | 統一日誌格式 |
| `log_fatal` | **禁止** | 會 kill engine;失敗用 `return 1` |
| `module_dryrun_guard <phase> "<desc>"` | **建議** | 取代手寫 `[[ DRY_RUN == true ]] && return 0` |
| `module_skip_if_installed` / `_not_installed` | **建議** | install/remove 短路樣板 |
| `module_use_apt_archetype` 等 | **建議** | 一行綁定六個 lifecycle(§3.2.1) |
| `module_default_*` | 視需要 | 個別重用 archetype 的某一階段(自己組合) |
| `module_i18n_get` / `module_get_description` | **必須(若需 i18n)** | 取 DESCRIPTION / POST_INSTALL_MESSAGE / WARN_MESSAGE 對應語系字串 |
| `apt_pkg_manager --install` | 建議 | 取代裸 `apt-get install`,有自動 retry |
| `exec_cmd` | 建議 | 印出將執行的命令 + dry-run 支援 |
| `have_sudo_access` | engine 已查 | module 內可省略 |
| `get_github_pkg_latest_version` | 建議 | 抓 GitHub release 版本號 |
| `backup_file` | 建議 | 覆寫前備份既有檔案 |
| `create_temp_file` | 建議 | 自動清理的臨時檔 |

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

### 4.7 失敗回傳 + 自動清理(ADR-0015)

#### 4.7.1 函式回傳慣例

- 用 `return 1`(或非 0),**不要** `exit`
- Engine 攔截 return,寫 log,繼續下一個 module
- `exit` 會把 engine 整個 kill,違反契約

#### 4.7.2 install 失敗 → state.json 不寫(ADR-0015,Q1)

`install()` 退非 0 = 視為**完全沒裝**:
- `state.json.installed.<name>` **不建**(維持「state 二態」原則)
- 已成功的 transitive dep **保留**(每個 dep 自己的 `install()` 已 idempotent 完成)
- Engine 印失敗 module 清單 + 退 **code 6**(PRD §7.4 partial)
- 結構化 log event `install_failed`(ADR-0006 schema)

#### 4.7.3 verify 失敗 → 自動跑 purge() 收尾(ADR-0015,Q16)

install→verify 是一條 transaction:

```
trace_id = new_uuid
emit install_start
run install()
if install exit != 0:
  emit install_failed
  exit 6
run verify()
if verify exit != 0:
  emit verify_failed (ERROR)
  emit cleanup_start
  run purge()                              # 用既有 lifecycle 自動清 side effects
  if purge exit != 0:
    emit cleanup_failed (ERROR, "manual cleanup required")
  else:
    emit cleanup_done
  emit install_failed (cause: "verify_failed")
  exit 6
write state.json.installed.<m>
emit install_done
```

理由:install() 可能已加 apt repo / 下載 binary / 建 symlink。verify 失敗若不收拾 → 孤兒 file 累積。**用既有 `purge()`**(已 mandatory + idempotent,ADR-0002)當 rollback,零新機制。

Module 作者責任:把 `install()` 寫成「裝完留下的所有檔案/設定都該被 `purge()` 砍掉」。Archetype A/B/C 預設 purge 已正確處理。Archetype D(custom)要對稱:install 加什麼,purge 砍什麼。

### 4.7.4 Sidecar 生命週期(Q4)

Sidecar(`${XDG_STATE_HOME}/init_ubuntu/versions/<name>`)記安裝當下的版本字串(PRD §10.1.1)。

| Lifecycle 事件 | Engine 模式 | Standalone 模式 |
|---|---|---|
| `install` 成功 | 寫 Sidecar(版本) + 寫 state.json | 只寫 Sidecar |
| `install` 失敗 | 不寫 | 不寫 |
| `install` 成功 + verify 失敗(ADR-0015) | 跑 purge() → Sidecar 被刪 + state.json 不寫 | 同上(Sidecar 被刪) |
| `upgrade` 成功 | 更新 Sidecar 為新版 + 更新 state.json `version_provided` | 只更 Sidecar |
| `remove` 成功 | **刪 Sidecar** + 從 state.json 拔掉 | **刪 Sidecar** |
| `purge` 成功 | **刪 Sidecar** + 從 state.json 拔掉 | **刪 Sidecar** |

不變式(invariants):
- `is_installed() == false` ↔ Sidecar 不存在(若不符 = corruption,`doctor` 抓得到)
- `state.json.installed.<name>` 存在 → Sidecar 必存在(Engine 寫一致)
- Sidecar 存在但 `state.json.installed.<name>` 不存在 → 可能是 standalone 安裝(合法,ADR-0001)

理由:Sidecar 是「裝了什麼版本」事實。module 不在 = 「裝了哪版」這事實也不在。`remove` 對應 `apt remove`(保留 user config),但 Sidecar **不是 user config**,是 state。

### 4.8 不可使用

- `set +e`(關掉 error trap),engine 已啟用,不准關
- `trap ... EXIT`(會干擾 engine 自己的 trap)
- `cd <path>`(會改變 engine 的 cwd);用 `pushd`/`popd` 或 subshell
- 修改 `IFS` / `PATH` 等核心變數的全域值(可在 subshell 內改)
- source 任意檔案(除非該檔在本 module 自帶的 config 子目錄內)
- 直接呼叫其他 module 的函式(用 dep 機制讓 engine 處理順序)

### 4.9 雙模式入口(Dual-mode entry)

每個 module **必須**支援兩種呼叫模式:

1. **獨立模式**:`bash modules/<name>.module.sh <phase> [options]` — 使用者直接執行單一檔案,module 自己 source 依賴 + 解析參數 + 呼叫對應 lifecycle 函式
2. **Engine 模式**:`setup_ubuntu install <name>` — `lib/runner.sh` 在 sub-shell 內 source module,由 runner 控制 lifecycle 與 DEPENDS_ON resolve

兩種模式共用同一份 `install / remove / purge` 函式。差別僅在「誰呼叫」。

**設計分界**:

| | 獨立模式 | Engine 模式 |
|---|---|---|
| DEPENDS_ON 解析 | ❌ 不處理(失敗就 fail) | ✅ runner 預先 install |
| state.json 更新 | ❌ 不寫入 | ✅ runner 寫入 |
| 並行/批次 | ❌ 單檔單階段 | ✅ resolver + runner batch |
| JSONL 日誌 | ✅(LOG_LEVEL/LOG_FILE env var) | ✅ runner 額外 session event |

獨立模式假設「DEPENDS_ON 已裝好」,適合「就是要單獨灌一個工具」的情境。如要完整流程,改用 `setup_ubuntu`。

**Module 檔案結構(由 `templates/module-<archetype>.template.sh` 提供;archetype ∈ {apt, github-release, config, custom}):**

```bash
#!/usr/bin/env bash

# ── 1. Dual-mode detection + lib sourcing ───────────────────
MODULE_STANDALONE="true"
[[ "${BASH_SOURCE[0]}" != "${0}" ]] && MODULE_STANDALONE="false"

if [[ "${MODULE_STANDALONE}" == "true" ]]; then
    set -euo pipefail
    shopt -s inherit_errexit 2>/dev/null || true
    MODULE_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
    REPO_ROOT="$(cd -- "${MODULE_DIR}/.." && pwd -P)"
    LIB_DIR="${REPO_ROOT}/lib"
    source "${LIB_DIR}/logger.sh"
    source "${LIB_DIR}/general.sh"
    source "${LIB_DIR}/module_helper.sh"
fi

# ── 2. Metadata ──────────────────────────────────────────────
NAME="..."
# ...

# ── 3. Lifecycle (pick an archetype OR hand-roll) ────────────
install() { module_default_apt_install; }
# ...

# ── 4. Standalone footer ─────────────────────────────────────
if [[ "${MODULE_STANDALONE:-false}" == "true" ]]; then
    module_standalone_main "$@"
fi
```

`lib/runner.sh` 在 sub-shell 內預先 source `logger.sh / general.sh / module_helper.sh` 後才 source module,所以 engine 模式下第 1 段的 if 不觸發,第 4 段的 footer 也不觸發 — 兩段都是「獨立模式 only」。

### 4.10 Helper API(`lib/module_helper.sh`)

Helper 抽出 i18n + 三個 archetype + 三個 generic guard + standalone CLI dispatch + engine 端聚合器。**module 不需重抄 dry-run / idempotency 樣板**。

#### i18n

| Helper | 用法 | 行為 |
|---|---|---|
| `module_i18n_get <ARRAY_NAME> [lang]` | `module_i18n_get DESCRIPTION zh-TW` | nameref 讀取 caller 的 `"<lang>:<text>"` 陣列,線性掃描;找不到 lang 退到 `en` |
| `module_get_description [lang]` | 在 standalone info / engine list | thin wrapper:`module_i18n_get DESCRIPTION "$@"` |
| `module_get_post_install_message` | runner 在 session 結束時呼叫 | thin wrapper:`module_i18n_get POST_INSTALL_MESSAGE` |
| `module_get_warn_message` | engine pre-install 顯示 | thin wrapper:`module_i18n_get WARN_MESSAGE` |

#### Generic guards

| Helper | 用法 | 行為 |
|---|---|---|
| `module_dryrun_guard <phase> "<desc>"` | `module_dryrun_guard install "apt-install ${APT_PKGS[*]}" && return 0` | DRY_RUN=true → log + return 0;否則 return 1 |
| `module_skip_if_installed` | `module_skip_if_installed && return 0` | `is_installed` → return 0(已裝);否則 return 1 |
| `module_skip_if_not_installed` | `module_skip_if_not_installed && return 0` | `!is_installed` → return 0(沒裝,沒事可做);否則 return 1 |

#### Archetype helpers

| Helper | 對應欄位 | 用途 |
|---|---|---|
| `module_default_apt_is_installed` | `APT_PKGS[]` | 每個 pkg dpkg-installed 才算 |
| `module_default_apt_install` | `APT_PKGS[]`, `APT_PPA?` | sudo / dry-run / PPA add 自動處理 |
| `module_default_apt_update` | `APT_PKGS[]` | `apt-get install --only-upgrade`;尚未裝則 fallback 到 install |
| `module_default_apt_remove` | `APT_PKGS[]` | `apt-get remove`,best-effort |
| `module_default_apt_purge` | `APT_PKGS[]`, `APT_PPA?`, `CONFIG_PATHS[]?` | `apt-get purge` + remove PPA + rm CONFIG_PATHS |
| `module_default_github_release_is_installed` | `BIN_NAME`, `BIN_LINK?` | 檢查 `${BIN_LINK}` executable 或 `command -v ${BIN_NAME}` |
| `module_default_github_release_install` | `GITHUB_REPO`, `GITHUB_ASSET_PATTERN`, `INSTALL_DIR`, `BIN_NAME` 等 | 下載 + 驗證 gzip + tar 解壓 + symlink |
| `module_default_github_release_update` | 同 install | 強制重新下載 latest(GitHub release 通常 `releases/latests/download` 直指最新) |
| `module_default_github_release_remove` | `INSTALL_DIR`, `BIN_NAME`, `BIN_LINK?` | rm install dir + symlink |
| `module_default_github_release_purge` | 同上 + `CONFIG_PATHS[]?` | remove + 清 CONFIG_PATHS |
| `module_default_config_is_installed` | `CONFIG_DEST`, `CONFIG_MARKER?` | grep marker in dest |
| `module_default_config_install` | `CONFIG_DEST`, `CONFIG_TEMPLATE_SRC?` 等 | cp template + 寫 marker + chmod |
| `module_default_config_update` | 同 install | 先 `backup_file` 既有 config,再重新 drop |
| `module_default_config_remove` | `CONFIG_DEST` | `rm -f` dest |
| `module_default_config_purge` | 同 remove | alias |
| `module_default_verify` | `is_installed` + `TEST_VERIFY_CMD?` | 任何 archetype 都用;`is_installed` 通過後若 `TEST_VERIFY_CMD` 非空就跑 |

#### Archetype macros(一行綁定 6 個 lifecycle)

| Macro | 綁定函式 |
|---|---|
| `module_use_apt_archetype` | `is_installed / install / update / remove / purge / verify` 全部接到 `module_default_apt_*` + `module_default_verify` |
| `module_use_github_release_archetype` | 同上,接到 `module_default_github_release_*` |
| `module_use_config_archetype` | 同上,接到 `module_default_config_*` |

Macro 之後 module 可重新宣告任一函式以覆寫(bash 後宣告者勝)。

#### 標準入口 & engine 聚合器

| Helper | 用法 | 行為 |
|---|---|---|
| `module_standalone_main "$@"` | standalone footer | 解析 phase + 共用 flag,dispatch lifecycle / info / status |
| `module_standalone_usage` | `--help` 與錯誤路徑 | 印出 phases + options |
| `module_standalone_info` | `info` phase | 印 metadata(name/version/desc/homepage/maintainer/tags/depends/conflicts/ubuntu/platforms/risk/reboot/install_time/disk_space/verify_cmd) |
| `module_standalone_status` | `status` phase | 印 `installed` / `outdated` / `version` |
| `module_emit_post_install` | runner 於 session_end 呼叫 | 印 `[name] <post-install-msg-in-current-lang>`(空則 return 0) |
| `module_emit_reboot_required` | 同上 | 若 `REBOOT_REQUIRED=true` 印一行 |

### 4.11 Standalone CLI 約定

Module 獨立模式的 CLI 由 `module_standalone_main` 統一提供。各 module **不應**自行 reparse argv。

```
Usage: bash modules/<name>.module.sh <phase> [options]

Phases (lifecycle):
  install            run install()
  update             run update()         (exit 2 if not implemented)
  remove             run remove()
  purge              run purge()
  verify             run verify()         (exit 2 if not implemented)
  doctor             run doctor()         (exit 2 if not implemented)
  detect             run detect()         (read-only)
  is-installed       run is_installed()   (read-only)
  is-recommended     run is_recommended() (read-only)
  is-outdated        run is_outdated()    (read-only; exit 2 if not implemented)

Phases (helper-provided, no module code needed):
  info               print metadata (name/version/desc/homepage/…)
  status             print install/version/outdated state

Options:
  --dry-run, -n      side-effect free; log what would happen
  --lang=<code>      override INIT_UBUNTU_LANG for i18n output (e.g. zh-TW)
  --help,    -h
  --version, -V      print "<NAME> <VERSION_PROVIDED>"

Notes:
  Standalone invocation does NOT resolve DEPENDS_ON. Use `setup_ubuntu` for the
  engine-level flow (dep tree, batched session, state.json updates).
```

Exit codes 對齊 PRD §7.4:`0` = success;`2` = unknown phase / unknown arg / lifecycle 未實作;其他 = 來自 lifecycle 函式本身。

---

## 5. 範例:複雜 module(neovim)

```bash
#!/usr/bin/env bash
# modules/neovim.module.sh — Neovim + nvimdots personal config

# ── Dual-mode header ────────────────────────────────────────
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

# ── Metadata ────────────────────────────────────────────────
NAME="neovim"
VERSION_PROVIDED="latest"
CATEGORY="recommended"
TAGS=("editor" "cli")
HOMEPAGE="https://neovim.io/"
declare -gA DESCRIPTION=(
    [en]="Neovim editor with nvimdots config"
    [zh-TW]="Neovim 編輯器 + nvimdots 個人設定"
)
declare -gA POST_INSTALL_MESSAGE=(
    [en]="Run :Lazy sync inside nvim once after first launch."
    [zh-TW]="首次啟動後在 nvim 內執行 :Lazy sync 安裝 plugin。"
)
declare -gA WARN_MESSAGE=()
SUPPORTED_UBUNTU=("22.04" "24.04" "26.04")
SUPPORTED_PLATFORMS=("desktop" "server" "wsl")
DEPENDS_ON=("apt-essentials" "git-config" "fzf" "lazygit" "fdfind" "fnm")
CONFLICTS_WITH=()
SUPPORTS_USER_HOME=false
RISK_LEVEL="low"
REBOOT_REQUIRED=false
INSTALL_TARGET_DEFAULT="sudo"
TEST_VERIFY_CMD="command -v nvim && nvim --version | head -n1"

# ── Archetype B: GitHub release ─────────────────────────────
GITHUB_REPO="neovim/neovim"
GITHUB_ASSET_PATTERN="nvim-linux-x86_64.tar.gz"
INSTALL_DIR="/opt/nvim"
BIN_NAME="nvim"
BIN_LINK="/usr/local/bin/nvim"
USE_SUDO=true
CONFIG_PATHS=(
    "${HOME}/.config/nvim"
    "${HOME}/.local/share/nvim"
    "${HOME}/.cache/nvim"
)
module_use_github_release_archetype

# Override install: archetype handles download/extract/symlink, we add
# nvimdots config drop afterwards.
install() {
    module_default_github_release_install || return $?
    _install_nvimdots_config
}

# ── Hand-written required hooks ─────────────────────────────
detect() {
    [[ "$(uname -m)" == "x86_64" ]]
}
is_recommended() {
    ! is_installed
}

# ── Private helpers ─────────────────────────────────────────
_install_nvimdots_config() {
    [[ "${INIT_UBUNTU_DRY_RUN:-false}" == "true" ]] && {
        log_info "[${NAME}] [DRY-RUN] would copy nvimdots config to ~/.config/nvim/lua/user"
        return 0
    }
    log_info "[${NAME}] Installing nvimdots config..."
    local _src="${MODULE_DIR}/config/neovim/nvimdots_config"
    [[ -d "${_src}" ]] || { log_warn "[${NAME}] nvimdots config missing: ${_src}"; return 0; }
    mkdir -p "${HOME}/.config/nvim/lua"
    cp -r "${_src}" "${HOME}/.config/nvim/lua/user"
}

# ── Standalone footer ───────────────────────────────────────
if [[ "${MODULE_STANDALONE:-false}" == "true" ]]; then
    module_standalone_main "$@"
fi
```

---

## 6. Module 內部目錄結構

若 module 需要附帶 config / asset 檔,放在 `modules/config/<name>/` 下:

```
modules/
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

`install()` 若違反此規則,unit test 會抓出(`tests/unit/modules/<name>_spec.bats` 內含 path assertion)。

---

## 7. 測試契約

每個 module 必須附帶單元測試 `tests/unit/modules/<name>_spec.bats`,**最少涵蓋**:

| 測試 case | 必要 |
|---|---|
| Metadata 完整性(NAME / DESCRIPTION / CATEGORY / SUPPORTED_UBUNTU 都有定義) | **必須** |
| `DESCRIPTION` 至少含 `"en:..."` entry | **必須** |
| `detect()` 在預期環境下回 0 | **必須** |
| `detect()` 在不支援環境下回非 0 | **必須** |
| `is_installed()` 未裝時回非 0(mock dpkg / which) | **必須** |
| `is_installed()` 已裝時回 0 | **必須** |
| `install --dry-run` 不呼叫 apt-get / curl / sudo | **必須** |
| `install()` 一次成功 | **必須** |
| `install()` 兩次成功(idempotent) | **必須** |
| `update --dry-run`(若 module 有 archetype 或自訂 update) | **必須** |
| `remove()` 一次成功 | **必須** |
| `remove()` 兩次成功(idempotent) | **必須** |
| `purge()` 後 config 確實清掉(mock fs) | **必須** |
| `verify()` 預設行為通過(`is_installed` 成功時) | **必須** |
| Standalone `--help` / `--version` 退出碼 0 | **必須** |
| Standalone unknown phase 退出碼 2 | **必須** |
| Standalone `info` 印出 metadata、`info --lang=zh-TW` 顯示對應翻譯 | **必須** |
| Source 模式不會觸發 standalone footer(`$0` != module 路徑) | **必須** |

範例骨架見 `templates/test.template.bats`(已建立)。共用樣板測試見 `tests/unit/template_smoke_spec.bats`(套到 template 本身)與 `tests/unit/module_helper_spec.bats`(套到 `lib/module_helper.sh`)。

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
| 簡單 | `modules/eza.module.sh`(將建立)| 純 apt install,無 dep |
| 中等 | `modules/docker.module.sh`(本檔 §2.1)| apt repo + group 加入 |
| 複雜 | `modules/neovim.module.sh`(本檔 §5)| GitHub release + 自帶 config + 多 dep |
| 環境感知 | `modules/nvidia-driver.module.sh`(待建)| 偵測 GPU + 拒絕在 container 內裝 |
| Config-only | `modules/git-config.module.sh`(待建)| 只 copy 檔案,不裝套件 |

---

## 10. FAQ

### Q1: 我的 module 需要在 install 後重啟 / re-login,該怎麼處理?

不要呼叫 `reboot` / `pkill -USR1 ...`。在 `install()` 結尾用 `log_warn` 提示使用者:

```bash
log_warn "Docker installed. Run 'newgrp docker' or re-login to use docker without sudo."
```

### Q2: install 失敗到一半,系統處於不一致狀態,該怎麼回滾?

#### install() 自己失敗

state.json 不寫(ADR-0015 §4.7.2);engine 視為「完全沒裝」。
作者寫 install() 時應該:
- 用 `backup_file` 在覆寫前備份重要檔案
- 失敗時 log 出備份位置,讓使用者手動還原
- 若可能,在 `install()` 末端做 sanity check 自己退非 0

#### install() 成功但 verify() 失敗

Engine **自動呼 module 的 `purge()`** 清掉 install 留下的 side
effects(ADR-0015 §4.7.3)。所以 module 作者該確保:
- `install()` 留下的 file / config / repo / symlink,**都能被 `purge()` 砍掉**
- `purge()` 是 idempotent(ADR-0002)— 對「裝一半」也要能砍

例外 — `nvidia-driver` 等高風險 module:v0.1 仍不要求自動回 nouveau
(PRD §13.1 Q9 / AC-21 移到 v1.0)。verify 失敗仍會呼 purge,但若 purge
也失敗會印「manual cleanup required」,user 自己手 chroot 救援。

### Q3: 我的 module 想呼叫另一個 module 的 helper,可以嗎?

不行。請把共用 helper 抽到 `lib/general.sh`(或新建 `lib/<topic>.sh`)。Module 之間**不互相依賴函式**,只透過 `DEPENDS_ON` 宣告安裝順序。

### Q4: 我能不能讓 module 在 install 時詢問使用者選項?

v0.1 不行。Module 必須是非互動的。若需要使用者輸入,把選項放到:
- CLI flag(如 `--variant=minimal`)— Engine 透過環境變數注入
- TUI submenu — TUI 收集後傳入 engine

### Q5: module 可以動態生成其他 module 嗎?

不行。Module 是靜態檔案,registry 只在啟動時掃描。
