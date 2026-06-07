# Testing Guide — init_ubuntu

> 本文檔說明如何跑測試、CI 框架的組成、以及這些檔案的**借用來源與 sync 流程**。閱讀 PRD §11 / `doc/architecture.md` §7 了解測試策略。

---

## ⚠️ HARD RULE — Tests MUST run in Docker (no exceptions)

**`bats` / module lifecycle 函式絕不直接在 host 跑。**只准透過 `make test-unit` /
`make test-integration` / `make coverage`(內部都走 `docker compose run --rm ci ...`)。

**禁止行為:**
- ❌ `bats test/unit/...`(host bats)
- ❌ `bash module/<name>.module.sh install`(host module Action Phase)
- ❌ `sudo apt-get install ...` 直接驗證 module 邏輯(host apt)

**允許行為:**
- ✅ `make test-unit` / `make test-integration` / `make coverage`
- ✅ `make lint`
- ✅ `docker compose -f compose.yaml run --rm ci bash -c "..."`(明確 in-container 一次性 debug)

**為什麼這是 hard rule:** Module Action Phase 真的會跑 `sudo apt-get` / `curl` /
`rm -rf` / `chsh` 等指令對「呼叫端的系統」生效。在 host 直接跑(就算 `--dry-run`)
只差一個忘記的 flag 就清掉 dev 機。Docker 是唯一安全隔離邊界。

**強制機制:** 完整理由與例外處理見 [ADR-0004](./adr/0004-tests-must-run-in-docker-only.md)。
`.claude/hook/test-must-use-docker.sh` 是 Claude PreToolUse hook,自動 block 違規
Bash 呼叫。

---

## 1. 快速開始

```bash
# 一次跑全部(lint + bats + 整合測試,不含 kcov,~30s)
make test

# 只跑 lint(ShellCheck + fish 語法 + Hadolint)
make lint

# 只跑 bats unit(最快,< 10s)
make test-unit

# 只跑 bats integration
make test-integration

# 完整跑含覆蓋率(kcov,慢 2-5×)
make coverage

# 清理 coverage / .tmp
make clean

# 看所有 target
make help
```

第一次跑時會先 build `test-tools:local` image(約 1-2 分鐘),後續快取重用。

---

## 2. 前置需求

- **Docker**(必要):所有測試在 `test-tools:local` 容器內跑
- **GNU make**(本地調度 `make` target)
- **bash 4+**(`script/ci/ci.sh` 用了 bash 4 array 語法)

**主機端不需要** bats / shellcheck / fish / kcov — 全部在容器內。

---

## 3. 測試結構(規劃)

> Phase 1(本階段)只建框架,test/ 內容會在 Phase 2+ 逐步加。所以 `make test` 現在跑會 skip bats(目錄不存在),但 lint 會跑。

```
test/
├── helpers/
│   └── common.bash          # bats 共用 setup/teardown / load 引用
├── unit/                    # bats unit (用 bats-mock 攔截 apt/curl/sudo)
│   ├── dispatcher_spec.bats
│   ├── registry_spec.bats
│   ├── ... (one per lib/*.sh)
│   └── module/
│       └── <name>_spec.bats # 每個 module 一個
├── integration/             # 真實裝 / 拆 / 重灌(在 Ubuntu container 內)
│   ├── install_cycle_spec.bats
│   ├── dependency_resolution_spec.bats
│   └── matrix/
│       ├── ubuntu-22.04.Dockerfile
│       ├── ubuntu-24.04.Dockerfile
│       └── ubuntu-26.04.Dockerfile
└── smoke/
    └── help_output_spec.bats
```

`doc/architecture.md` §7 與 PRD §11 是權威來源。

---

## 4. 測試工具清單(`dockerfile/Dockerfile.test-tools`)

| 工具 | 版本 | 用途 |
|---|---|---|
| `bats-core` | upstream `bats/bats:latest` | 測試框架 |
| `bats-support` | v0.3.0 | bats assertion helper |
| `bats-assert` | v2.1.0 | bats assertion helper |
| `bats-mock` | v1.2.5 | mock `apt-get` / `curl` / `sudo` 等 |
| `shellcheck` | v0.10.0 | shell 靜態分析 |
| `hadolint` | v2.12.0 | Dockerfile 靜態分析 |
| `fishtape` | master(jorgebucaran/fishtape) | fish 函式測試 |
| `kcov` | (用獨立 `kcov/kcov` debian image) | shell script 覆蓋率(產 HTML + cobertura.xml) |
| `dialog` + `whiptail` | alpine 滾動版 | TUI 後端測試 |
| `parallel` | alpine 滾動版 | bats 並行(`--jobs N`) |

所有版本鎖在 `dockerfile/Dockerfile.test-tools`(kcov 除外 — 走 `kcov/kcov` 上游 image,因為 kcov 不在 alpine 任何 repo)。

### 4.1 雙 image 設計

| Image | 用途 | 速度 |
|---|---|---|
| `test-tools:local`(alpine,本地 build) | `make test` / `make lint` / `make test-unit` / `make test-integration` | 快(image 內已預裝所有工具) |
| `kcov/kcov`(debian,從 Docker Hub 拉) | `make coverage` 唯一用途 | 慢(每次 `apt-install` bats + shellcheck) |

`make coverage` 走慢路徑是有意的:kcov 覆蓋率報告主要給 CI / release 前確認,日常開發循環用 `make test` 即可。

---

## 5. 借用自 `ycpss91255-docker/base` 的檔案

| 本 repo 檔案 | 來源(`ycpss91255-docker/base`) | sync 範圍 |
|---|---|---|
| `dockerfile/Dockerfile.test-tools` | `dockerfile/Dockerfile.test-tools` | 加 fish/fishtape/kcov/dialog/whiptail;移除 docker-cli/buildx |
| `Makefile` | `Makefile.ci`(改名) | 移除 `test-behavioural` / `init` / `upgrade` / `upgrade-check`;加 `test-unit` / `test-integration` / `build-test-tools` |
| `script/ci/ci.sh` | `script/ci/ci.sh` | 用 inline `_die` 取代 base `_lib.sh`;改 lint 範圍;加 fish 語法檢查;移除 behavioural |
| `.codecov.yaml` | `.codecov.yaml` | target 改為 `"80%"`(從 `"auto"`);擴充 ignore[] |
| `compose.yaml` | `compose.yaml` | default image 改為 `test-tools:local`;移除 `ci-behavioural`;coverage 不另開 service |

### 5.1 借用版本

- **base 版本**:`v0.28.0`
- **base commit SHA**:`ade915a693e539b2cd9e9a7a45d825c810563d59`
- **借用日期**:2026-05-13

### 5.2 為什麼不用 base 的 subtree 流程

`ycpss91255-docker/base` 的 `init.sh` 預設你的 repo 是「會 build/publish Docker image」的 container repo(會建 `build.sh` / `run.sh` / `exec.sh` symlinks 與 `Dockerfile` 等)。本 repo 是 **Ubuntu host installer**,不打算發佈 image(PRD §2 Non-Goals)。所以我們**只借 5 個檔案**,不做 `git subtree add` / `init.sh`。

詳見 `doc/architecture.md` §13.2 與 PRD §17.2。

### 5.3 怎麼同步 upstream 更新

當 `ycpss91255-docker/base` 釋出新版,評估流程:

1. 讀 `https://github.com/ycpss91255-docker/base/releases` 看 changelog
2. 對 5 個檔案逐一 `gh api` 取最新內容,跟本地 diff
3. 把符合本 repo 需求的變更**手動 merge**(注意我們的客製化要保留)
4. 更新本檔 §5.1 的「借用版本」與 SHA
5. `make test` 驗證沒壞

未來可考慮寫 `script/sync-from-base.sh` 半自動化(不排版本,屬願望性質)。

---

## 6. CI/CD pipeline 對應

| 階段 | 本地命令 | CI workflow(Phase 7 將建)|
|---|---|---|
| Lint | `make lint` | `lint` job |
| Unit | `make test-unit` | `unit` job |
| Integration | `make test-integration` | `integration-{22,24,26}.04` matrix |
| Coverage | `make coverage` | `coverage` job + codecov upload |

`.github/workflows/ci.yaml` 將於 PRD §12 M12(Coverage + CI)階段建立。

---

## 7. 覆蓋率目標

**80% 為唯一硬門檻**(PRD G5 / AC-17;`.codecov.yaml` target),提升為 best-effort。原 v0.5 / v1.0 階梯式目標已撤銷(2026-06-06 PRD 定稿,版本階梯目前至 0.4.0、1.0 暫不規劃;見 `doc/architecture.md` §8.4)。

`.codecov.yaml` 的 `threshold: 1%` 表示「允許 1% 噪音」,實際門檻 = `target - threshold = 79%`。

---

## 8. 常見問題

### Q: 第一次跑 `make test` 卡很久?
A: 在 build `test-tools:local`,需要下載 alpine + bats + fishtape 等(~150 MB)。後續 build cache 命中只需 1-2s。

### Q: 為什麼 `make test` 顯示「test/unit/ does not exist yet — skipping」?
A: Phase 1 只建測試框架,實際 bats spec 從 Phase 2 才開始加。Lint 部分(shellcheck + fish syntax + hadolint)會跑。

### Q: 我的覆蓋率被低估?(明明測了卻顯示沒覆蓋)
A: 確認 `script/ci/ci.sh` 的 `_run_coverage` 中 `--include-path` 與 `--exclude-path` 有沒有把你的檔案放對位置。`small-tools/` 與 `module/tools/` 是有意排除的(deprecated)。

### Q: 為什麼 ANSI 色彩在 CI log 內看不到?
A: ci.sh 預設不主動加色;CI runner 的 terminal 一般是非 tty,符合 PRD §7.5 `--color=auto` 設計。要強制色彩用 `--color=always`(實作後)。

### Q: 怎麼跑單一 bats 檔?
A: 進容器手動跑:
```bash
docker compose -f compose.yaml run --rm ci -c 'bats /source/test/unit/specific_spec.bats'
```

---

## 9. 故障排除

### `make test` 報「Cannot connect to the Docker daemon」
- 確認 Docker 服務有在跑:`systemctl status docker`
- 確認自己在 `docker` group:`groups | grep docker`(需要的話 `sudo usermod -aG docker $USER` 後 re-login)

### `make build-test-tools` 失敗在下載 shellcheck / hadolint
- 網路問題;若在 GFW 後,確認 DNS / proxy 可達 `github.com/releases/...`

### bats parallel 失敗(`parallel: command not found`)
- 不太可能發生(test-tools image 已內建 parallel)。若手動進入容器後不見,確認你用的是 `test-tools:local` 而非空 alpine
