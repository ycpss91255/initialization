# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## 專案概述

Ubuntu 系統初始化與開發環境建置工具。透過 Bash 腳本自動化安裝及設定各種開發工具、系統套件與組態檔。

## 重要使用原則

- **目前尚未建立 setup 腳本的測試**，因此在跨機器遷移設定或建置環境時，**暫不建議直接執行 repo 內的 `setup_*.sh` / `submodule/*.sh`**。應以手動複製設定檔、手動安裝工具為主，待測試完善後再改用自動化腳本。
- **`small-tools/` 為舊版本，已不再維護**：除非使用者明確要求，否則不要更新或同步 `small-tools/` 下的任何檔案（包含設定檔、安裝腳本等）。所有新的修改只套用到 `module/` 目錄下的對應檔案。

## 執行指令

```bash
# 完整系統建置（需要 sudo）
./setup_ubuntu.sh

# 輕量安裝（精簡替代方案）
cd small-tools && ./install.sh

# 個別模組安裝
./module/setup_docker.sh
./module/setup_neovim.sh
./module/setup_shell.sh
./module/setup_small_tools.sh

# 執行函式測試（視覺輸出驗證，非自動化斷言）
bash module/function/test/test_logger.sh
bash module/function/test/test_general.sh

# 移除腳本
./module/tools/remove/remove_docker.sh
./module/tools/remove/remove_neovim.sh
```

## 架構

### 進入點與模組系統

`setup_ubuntu.sh` 是主要的協調腳本，負責 source 並執行所有 `module/setup_*.sh`。每個 setup 模組也可獨立執行，透過雙模式判斷：

```bash
MAIN_FILE="true"; [[ "${BASH_SOURCE[0]}" != "${0}" ]] && MAIN_FILE="false"
```

`MAIN_FILE` 為 true（直接執行）時，腳本自行設定環境變數（`FUNCTION_PATH`、`CONFIG_PATH` 等）。為 false（被 source）時，繼承父腳本的環境變數。

### 模組依賴關係

```text
setup_ubuntu.sh
  ├── function/logger.sh    # 最先載入 - 彩色日誌輸出
  ├── function/general.sh   # 第二載入 - exec_cmd、sudo、備份、apt 輔助函式
  ├── setup_*.sh            # 主要元件安裝模組
  └── submodule/*.sh        # 單一工具安裝器（由 setup_shell.sh / setup_small_tools.sh 呼叫）
```

### 主要目錄

- **`module/function/`** - 共用 Bash 函式庫（`logger.sh`、`general.sh`），所有模組皆會 source
- **`module/config/`** - 版本控管的設定檔，透過 symlink 部署到 `~/.config/`、`~/.ssh/` 等
- **`module/submodule/`** - 單一工具安裝器（fzf、zoxide、batcat、eza、lazygit 等）
- **`module/tools/`** - 獨立工具腳本（日誌打包、ROS bag 工具、移除腳本）
- **`small-tools/`** - 舊版輕量替代方案，已不再維護（不要更新此目錄）
- **`template/`** - 新模組、子模組、函式與測試的樣板

## Bash 慣例

所有腳本使用 strict mode：
```bash
set -euo pipefail
shopt -s inherit_errexit &>/dev/null || true
```

模組設定的標準環境變數：
- `SCRIPT_PATH` - 當前腳本所在目錄
- `FUNCTION_PATH` - `module/function/` 的路徑
- `CONFIG_PATH` - `module/config/` 的路徑
- `SUBMODULE_PATH` - `module/submodule/` 的路徑
- `BACKUP_DIR` - 帶時間戳的備份目錄（`~/.backup/YYYY-MM-DD-HH:MM:SS`）

使用 `general.sh` 的 `exec_cmd()` 執行指令（帶彩色輸出）。使用 `logger.sh` 的 `log_info`、`log_warn`、`log_error`、`log_fatal`、`log_debug` 記錄日誌。日誌等級與顏色由 `LOG_LEVEL` 和 `LOG_COLOR` 環境變數控制。

## 建立新模組

使用 `template/` 中的樣板作為起點：
- `module_tmp.sh` - 新 setup 模組
- `submodule_tmp.sh` - 新工具安裝器
- `func_tmp.sh` - 新函式庫
- `test_tmp.sh` - 新測試
