# gh CLI 升級筆記（Ubuntu ESM 卡版本問題）

## 問題

已設定 GitHub CLI 官方 apt 來源，但 `sudo apt upgrade` 始終停在 `2.45.0`，無法升到最新版。

```
$ gh --version
gh version 2.45.0 (2026-03-17 Ubuntu 2.45.0-1ubuntu0.3+esm3)
```

## 原因

Ubuntu ESM（Expanded Security Maintenance）倉庫的 pin priority 比官方倉庫高：

```
$ apt-cache policy gh
gh:
  Installed: 2.45.0-1ubuntu0.3+esm3
  Candidate: 2.45.0-1ubuntu0.3+esm3
  Version table:
     2.90.0                   500  https://cli.github.com/packages
 *** 2.45.0-1ubuntu0.3+esm3   510  https://esm.ubuntu.com/apps/ubuntu   ← 贏
```

| 來源 | Priority |
|------|---------:|
| cli.github.com（官方 upstream） | 500 |
| esm.ubuntu.com（ESM） | **510** |

所以 apt 永遠挑 ESM 的 2.45.0（ESM 只做資安 backport，不會跟 upstream release）。

## 解法

新增 apt pinning，把 ESM 的 `gh` 套件優先級設為 `-1`（絕不安裝），其他 ESM 套件不受影響。

### 1. 建立 pin 設定

`sudo nano /etc/apt/preferences.d/github-cli`

貼上：

```
Package: gh
Pin: origin esm.ubuntu.com
Pin-Priority: -1
```

### 2. 升級

```bash
sudo apt update
sudo apt install gh
```

### 3. 驗證

```bash
gh --version
# gh version 2.90.0 ...
```

## 驗證設定是否正確

```bash
apt-cache policy gh
```

應看到 ESM 那行 priority 變成 `-1`，candidate 指向 `cli.github.com` 的最新版。

## 備註

- 未來 `sudo apt upgrade` 會自動從 cli.github.com 拿新版（2.91.0、2.92.0…）
- 不影響其他 ESM 套件的資安更新
- 若改變心意想回到 ESM 版：刪掉 `/etc/apt/preferences.d/github-cli` 即可
