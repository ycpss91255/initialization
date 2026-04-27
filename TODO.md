# TODO

[] add clean ai agent log and session

• 可以用 ranger 的 --choosedir 功能，退出時把最後目錄寫到暫存檔，再讓 shell cd 過去。

  範例（bash/zsh）：

  # 放到 ~/.bashrc 或 ~/.zshrc
  r() {
    local tempfile
    tempfile="$(mktemp -t ranger-cd.XXXXXX)"
    ranger --choosedir="$tempfile" "$@"
    if [ -f "$tempfile" ]; then
      local dir
      dir="$(cat "$tempfile")"
      rm -f "$tempfile"
      [ -n "$dir" ] && cd "$dir"
    fi
  }

  之後用 r 進入 ranger，按 q 退出就會切到 ranger 最後所在路徑。
## 修復筆電合蓋黑畫面

1. 進入 TTY 終端：在黑畫面按 `Ctrl + Alt + F2`，輸入帳號密碼登入
2. 恢復桌面：`sudo systemctl restart gdm`
3. 確認設定有生效：
   ```bash
   grep HandleLidSwitch /etc/systemd/logind.conf
   ```
   應該要看到：
   ```
   HandleLidSwitch=ignore
   HandleLidSwitchExternalPower=ignore
   HandleLidSwitchDocked=ignore
   ```
   如果沒改到：`sudo nano /etc/systemd/logind.conf`
4. 安全地套用設定（不中斷桌面）：
   ```bash
   sudo systemctl kill -s HUP systemd-logind
   ```
5. 測試：合上筆電蓋子，等幾秒後打開，確認桌面還在、SSH 連線沒斷

> 重點：以後改 logind 設定，用 `kill -s HUP` 而不是 `restart`，就不會再出現黑畫面。

## Config sync 腳本

目前 `module/config/` 是透過 `cp` / `cp -r` 一次性複製到 `~/.config/`、`~/.ssh/` 等位置（見 `setup_shell.sh:133`、`setup_small_tools.sh:111/154/268/291`、`setup_neovim.sh:208/282`），部署後 local 編輯不會反映回 repo，兩邊會漂移。曾考慮改 symlink，但顧慮以下問題後放棄：

- SSH 嚴格權限檢查（target 需 600、repo 目錄權限）
- 編輯器 atomic write 會把 symlink 換回普通檔案
- 目錄 symlink 會讓 fish history / 生成 completions 滲漏進 repo
- Repo 路徑變動會讓所有 link 失效

改為寫一支雙向 sync 腳本處理：

- [] `module/tools/sync_config.sh`
  - [] `--check` / `status`：掃描 `module/config/` 下所有受管檔案，比對 local 對應路徑，列出 diff（identical / local-newer / repo-newer / missing）
  - [] `--pull`：local → repo（把 local 修改抓回 repo，給 commit 用）
  - [] `--push`：repo → local（把 repo 版本套到 local，給新機器或還原用）
  - [] 支援 dry-run，實際寫入前先顯示將變更的檔案
  - [] 寫入前備份到 `$BACKUP_DIR`
  - [] 以一份「受管清單」定義 repo path ↔ local path 的對應（可放在腳本內或獨立 manifest 檔），避免硬 coding 分散在各 setup 腳本
- [] 挑選一兩個容易踩雷的檔案先驗證（`ssh_config`、`git_config`、`fish/config.fish`）
- [] 確認過後，把 `setup_*.sh` 裡的 `cp` 改為呼叫 `sync_config.sh --push`，統一部署路徑

## 新機器設定 tmux-powerline Gmail 未讀計數

密碼透過 gnome-keyring 管理，不落地明文、不放進 repo。每台機器產各自的 app password。

前置：
- `sudo apt install libsecret-tools gnome-keyring libpam-gnome-keyring`
- 確認 gnome-keyring-daemon 有跑 (`pgrep -af keyring`) 且 PAM auto-unlock 生效（預設桌面登入會解）

流程：

1. 到 <https://myaccount.google.com/apppasswords> 產一組 app password，label 建議 `tmux-powerline@<hostname>`（方便事後在 Google 後台辨識 / 撤銷）
2. 存進 keyring（不會進 shell history）：
   ```bash
   secret-tool store --label='tmux-powerline gmail' service tmux-powerline account gmail
   ```
   prompt 出現時把 16 字元密碼貼上
3. 驗證：
   ```bash
   echo "[$(secret-tool lookup service tmux-powerline account gmail)]"
   ```
   應看到 `[xxxx xxxx xxxx xxxx]`
4. 重載 tmux status bar：
   ```bash
   tmux source-file ~/.config/tmux/tmux.conf
   ```

移除 / 換密碼：
```bash
secret-tool clear service tmux-powerline account gmail
# 然後重跑 step 2
```

repo 端：
- `module/config/tmux/tmux-powerline/config.sh` 已改成從 `${XDG_CONFIG_HOME:-$HOME/.config}/tmux-powerline/secrets.sh` source，後者呼叫 `secret-tool lookup` 查 keyring
- `secrets.sh` 不追蹤、per-machine，於 `chmod 600`

> 舊 app password `zkld bkbg mefc hpfv` 已撤銷，但仍在 git 歷史 commit `d83af7f` 中。若在意可用 `git filter-repo` 重寫歷史 + force push；不處理也 ok（密碼已失效）。

## gnome-keyring 記憶體洩漏（2026-04-27 踩雷紀錄）

### 症狀
Ubuntu 24.04 連續開機數天後 RAM 被 `gnome-keyring-daemon` 吃光。實際觀察：單一 daemon RSS 從正常的幾十 MB 一路爬到 **13 GB**（系統總 RAM 30 GB，其中 12 GB 都是 keyring 在吃，已開始狂用 swap）。

### 根因
tmux-powerline 的 `config.sh` 會在**每次狀態列刷新**（每秒多次，多個 pane × 多個 segment 同時觸發）重新 source `secrets.sh`，每次都呼叫一次 `secret-tool lookup` → 對 daemon 做一輪 `OpenSession` + `SearchItems` + `GetSecrets`。

實測 dbus-monitor 抓 60 秒：
- **652 次完整循環、平均每秒 11 次**
- daemon 在這種頻率下會洩漏未釋放的 session 物件，**~5 MB/min**
- `gnome-keyring 46.1-2ubuntu0.2`（Ubuntu 24.04 noble）的已知行為，跟 PKCS#11 component 無關（拔掉只剩 `secrets` 後仍漏）

journal 裡的線索：`asked to register item /org/freedesktop/secrets/collection/login/<N>, but it's already registered` — 同一個 Gmail item 被反覆碰觸的副作用。

### 修復
`module/config/tmux/tmux-powerline/secrets.sh`（已追蹤）改用 `tmux setenv -g` 把首次查到的密碼快取在 **tmux global session env**：

- 首次 source：empty → secret-tool lookup 一次 → `tmux setenv -g` 寫入 → export
- 後續 source：env var 已存在 → 直接 export，**完全不碰 D-Bus**
- 副作用：rotate 密碼後要清 cache（見 `secrets.sh` 註解）

修完驗證：30 秒 D-Bus method call 從 326 次掉到 **0 次**，daemon RSS delta = **0 KB / 30s**。

### 部署到新機器
跟「新機器設定 tmux-powerline Gmail 未讀計數」流程整合，多一個前置步驟：

```bash
mkdir -p ~/.config/tmux-powerline
cp module/config/tmux/tmux-powerline/secrets.sh ~/.config/tmux-powerline/
chmod 600 ~/.config/tmux-powerline/secrets.sh
# 然後再做 secret-tool store / verify / reload
```

### 驗證指令（任何時候懷疑又漏了）
```bash
# A. 看 daemon RSS 是否在長
PID=$(systemctl --user show -p MainPID gnome-keyring-daemon.service --value)
awk '/^VmRSS/{print $2" kB"}' /proc/$PID/status

# B. 抓 30 秒 D-Bus 流量，應該 0 次
timeout 30 dbus-monitor --session "interface='org.freedesktop.Secret.Service'" 2>&1 \
  | grep -c "^method call"

# C. 清 cache、強制 secrets.sh 重抓（rotate 密碼後或 debug 用）
tmux setenv -gu TMUX_POWERLINE_SEG_MAILCOUNT_GMAIL_PASSWORD
```

### 緊急止血（如果哪天 daemon 又爆了）
```bash
# 1. 砍掉肥的 daemon（systemd socket activation 會自動重啟成 ~10 MB 的乾淨版）
sudo kill -9 $(systemctl --user show -p MainPID gnome-keyring-daemon.service --value)

# 2. 確認 secrets.sh 是有 cache 邏輯的版本（line 23 起應該是 if [ -z ... ]）
grep -A1 "TMUX_POWERLINE_SEG_MAILCOUNT_GMAIL_PASSWORD" ~/.config/tmux-powerline/secrets.sh
```

### 額外保險（已套但非必需）
為了避免未來其他 client 又戳到 PKCS#11 component 觸發類似 bug，已加 systemd user override 砍掉 pkcs11 component：

`~/.config/systemd/user/gnome-keyring-daemon.service.d/override.conf`：
```ini
[Service]
ExecStart=
ExecStart=/usr/bin/gnome-keyring-daemon --foreground --components=secrets --control-directory=/run/user/1000/keyring
```

主修是 secrets.sh 的 cache，這個 override 是雙保險，可選擇要不要在新機器套用。

## Trash 自動維護（2026-04-27 設定）

`rm` 在 fish 走 `trash-put`（`module/config/fish/functions/rm.fish`），垃圾桶 trash-cli 沒有原生容量上限，需要靠排程清理。

### 維護腳本
`module/tools/trash-maintenance.sh`：
1. `trash-empty -f $MAX_DAYS` 砍掉超過 N 天的項目
2. 若 `~/.local/share/Trash/files` 仍超過 `$MAX_GB`，從 `info/*.trashinfo` 的 mtime 最舊的開始砍直到低於上限
3. 預設 `MAX_DAYS=90`、`MAX_GB=50`，可用環境變數覆蓋

### 部署位置
| 機器 | 腳本 | 排程 | 額外 |
|---|---|---|---|
| local (這台) | `~/.local/bin/trash-maintenance.sh` → repo symlink | crontab 每日 03:00 | GNOME Privacy 也開了 90 天 auto-delete（`gsettings set org.gnome.desktop.privacy {remove-old-trash-files true, old-files-age uint32 90}`）|
| `core.yunchien-server` | `~/.local/bin/trash-maintenance.sh`（實體 copy）| crontab 每日 03:00 | 無 GUI，純靠 cron |

兩邊 cron 一致：
```
0 3 * * * $HOME/.local/bin/trash-maintenance.sh >> $HOME/.local/state/trash-maintenance.log 2>&1
```

### 手動驗證 / 操作
```bash
# 看目前大小（files/ = 真實垃圾，info/ = metadata，expunged/ = 砍不掉的殘骸）
du -sh ~/.local/share/Trash/{files,info,expunged}

# 立刻跑一次（dry-run 看會做什麼）
MAX_GB=50 MAX_DAYS=90 bash -x ~/.local/bin/trash-maintenance.sh

# 看 cron 紀錄
tail -f ~/.local/state/trash-maintenance.log

# 改容量上限：直接編 crontab 或在 cron 行前加環境變數
# 例：MAX_GB=20 ~/.local/bin/trash-maintenance.sh
```

### 注意：expunged/ 不在維護範圍
`~/.local/share/Trash/expunged/` 是 trash-cli 想刪但因檔案權限 / 持有失敗的殘骸（local 上目前約 10GB，主要是 isaac-sim docker cache 在 root 名下）。腳本不碰這塊，要清需要：
```bash
sudo rm -rf ~/.local/share/Trash/expunged
```

### 新機器部署步驟
```bash
# 1. 確認 trash-cli 已裝
sudo apt-get install -y trash-cli

# 2. 部署 fish rm function
mkdir -p ~/.config/fish/functions
cp module/config/fish/functions/rm.fish ~/.config/fish/functions/

# 3. 部署維護腳本（headless 機器用 copy；有 repo 的機器可 symlink）
mkdir -p ~/.local/bin ~/.local/state
cp module/tools/trash-maintenance.sh ~/.local/bin/
chmod +x ~/.local/bin/trash-maintenance.sh

# 4. 安裝 crontab
(crontab -l 2>/dev/null; echo "0 3 * * * \$HOME/.local/bin/trash-maintenance.sh >> \$HOME/.local/state/trash-maintenance.log 2>&1") | crontab -

# 5.（有 GNOME 的話）開 Privacy 90 天 auto-delete
gsettings set org.gnome.desktop.privacy remove-old-trash-files true
gsettings set org.gnome.desktop.privacy old-files-age 'uint32 90'
```

## ADD items
[] sudo apt install ripgrep
[] NAS mount
  [] sudo apt install cifs-utils autofs (driver)
  [] sudo apt install smbclient (check tool)
    - smbclient -L <IP> -U <USER>
[] libreoffice
  - sudo add-apt-repository ppa:libreoffice/ppa
[] claude code
  [] pipx install claude-monitor
- tmuxp
  [] sudo apt remove tmuxp python3-libtmux
  [] pipx install tmuxp
- yazi dep glow
  - https://github.com/charmbracelet/glow
- auto update script

claude config
- reduce motion: true
  - 減少畫面跳動與捲動後畫面錯亂問題
- verbose output: true
  - 能清楚看到每個 tool call 的請求與結果
- default permission mode: Bypass Permission
  - 降低跑到一半中斷的機率(有用但不是萬能)

## Claude Code statusline (cc-statusline plugin)

cc-statusline 的 README 建議 `statusLine.command` 寫 `node ${CLAUDE_PLUGIN_ROOT}/statusline.js`，但**從使用者層級 `~/.claude/settings.json` 引用時 `${CLAUDE_PLUGIN_ROOT}` 不會展開**（Claude Code 只在 plugin 自己的 hooks/commands 注入此變數）。實測 dump 環境變數確認此行為。

解法：用 wrapper script 自己解析 plugin 路徑。

- 已建立 `module/config/claude/run-statusline.sh`，glob `~/.claude/plugins/cache/cc-statusline/cc-statusline/*/` 取最新版本目錄後 `exec node`
- 新機器手動步驟：
  1. `claude plugin marketplace add NYCU-Chung/cc-statusline`
  2. `claude plugin install cc-statusline@cc-statusline`
  3. `ln -s "$REPO/module/config/claude/run-statusline.sh" ~/.claude/run-statusline.sh`
  4. `~/.claude/settings.json` 加入：
     ```json
     "statusLine": {
       "type": "command",
       "command": "/home/<user>/.claude/run-statusline.sh",
       "refreshInterval": 30
     }
     ```
- TODO
  - [] 建立 `module/setup_claude.sh`：自動處理 plugin 安裝、symlink 部署、settings.json 注入（與 `Config sync 腳本` 章節整合）
  - [] 確認 settings.json 是否要進 repo（含 enabledPlugins / env 等可能敏感設定）

https://gist.github.com/coodoo/4ccb8e9ab3f5b586f9beb8b7ef5f6d75

- KVM stack
# 裝 KVM stack
sudo apt install qemu-kvm libvirt-daemon-system libvirt-clients \
                 bridge-utils virt-manager ovmf

# 把你自己加進 libvirt / kvm group
sudo usermod -aG libvirt,kvm $USER

# 登出再登入（或 newgrp libvirt）

# 驗證
virsh list --all    # 應該能跑，不報錯
kvm-ok              # 應該說 "KVM acceleration can be used"
