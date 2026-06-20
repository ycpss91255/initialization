#!/usr/bin/env bats
# test/unit/general_spec.bats — smoke + targeted unit tests for lib/general.sh
#
# batch A scope: confirm general.sh sources cleanly and the key helper
# functions are defined.
#
# AC-17 extension (issue #122): behavior-level tests of the public surface —
# exec_cmd (streaming + capture mode per PRD §7.7.1), sudo helper, backup /
# temp-file / pkg-status / apt-mirror / apt_pkg_manager / GitHub-version
# helpers, and the platform detection helpers. External commands (sudo,
# apt-get, dpkg-query, curl) are stubbed via shell functions or PATH shims —
# no Action Phase ever runs for real (ADR-0004 container, no host installs).

load "${BATS_TEST_DIRNAME}/../helper/common"

setup() {
    setup_test_env
    export LOG_LEVEL="INFO"
    export LOG_COLOR="false"
}

teardown() {
    teardown_test_env
}

# ── Smoke: source without crashing ───────────────────────────────────────────

@test "lib/general.sh sources without error" {
    run bash -c "source '${LIB_DIR}/general.sh'"
    assert_success
}

@test "lib/general.sh transitively sources lib/logger.sh (TTY_COLORS_READY set)" {
    run bash -c "source '${LIB_DIR}/general.sh' && echo \"loaded=\${TTY_COLORS_READY}\""
    assert_success
    assert_output --partial "loaded=true"
}

# ── Function existence checks ────────────────────────────────────────────────

@test "exec_cmd is defined" {
    run bash -c "source '${LIB_DIR}/general.sh' && declare -F exec_cmd"
    assert_success
    assert_output --partial "exec_cmd"
}

@test "have_sudo_access is defined" {
    run bash -c "source '${LIB_DIR}/general.sh' && declare -F have_sudo_access"
    assert_success
    assert_output --partial "have_sudo_access"
}

@test "backup_file is defined" {
    run bash -c "source '${LIB_DIR}/general.sh' && declare -F backup_file"
    assert_success
    assert_output --partial "backup_file"
}

@test "create_temp_file is defined" {
    run bash -c "source '${LIB_DIR}/general.sh' && declare -F create_temp_file"
    assert_success
    assert_output --partial "create_temp_file"
}

@test "check_pkg_status is defined" {
    run bash -c "source '${LIB_DIR}/general.sh' && declare -F check_pkg_status"
    assert_success
    assert_output --partial "check_pkg_status"
}

@test "setup_apt_mirror is defined" {
    run bash -c "source '${LIB_DIR}/general.sh' && declare -F setup_apt_mirror"
    assert_success
    assert_output --partial "setup_apt_mirror"
}

@test "apt_pkg_manager is defined" {
    run bash -c "source '${LIB_DIR}/general.sh' && declare -F apt_pkg_manager"
    assert_success
    assert_output --partial "apt_pkg_manager"
}

@test "get_github_pkg_latest_version is defined" {
    run bash -c "source '${LIB_DIR}/general.sh' && declare -F get_github_pkg_latest_version"
    assert_success
    assert_output --partial "get_github_pkg_latest_version"
}

@test "environment detection helpers are defined (check_in_WSL, check_in_docker, check_in_mac)" {
    run bash -c "source '${LIB_DIR}/general.sh' && declare -F check_in_WSL check_in_docker check_in_mac"
    assert_success
    assert_output --partial "check_in_WSL"
    assert_output --partial "check_in_docker"
    assert_output --partial "check_in_mac"
}

# ── Targeted behavior: exec_cmd echoes the rendered command ──────────────────

@test "exec_cmd with EXEC_CMD_NO_PRINT=true does not echo command preamble" {
    run bash -c "export EXEC_CMD_NO_PRINT=true; source '${LIB_DIR}/general.sh' && exec_cmd echo hello"
    assert_success
    assert_output --partial "hello"
}

# ── Targeted behavior: check_in_docker runs without crashing ─────────────────
# (Inside the test-tools:local container, /.dockerenv exists, so the function
#  exports IN_DOCKER=true. We verify it doesn't crash; exact value depends on
#  cgroup detection which we don't pin here.)

@test "check_in_docker runs without error inside container" {
    run bash -c "source '${LIB_DIR}/general.sh' && check_in_docker"
    assert_success
}

# ── exec_cmd: streaming mode (legacy standalone callers) ─────────────────────

@test "exec_cmd prints rendered command preamble and executes it (streaming mode)" {
    run bash -c "source '${LIB_DIR}/general.sh' && exec_cmd 'echo hello-marker'"
    assert_success
    assert_output --partial '$ echo'
    assert_output --partial "hello-marker"
}

@test "exec_cmd propagates the command's non-zero exit status (streaming mode)" {
    run bash -c "export EXEC_CMD_NO_PRINT=true; source '${LIB_DIR}/general.sh' && exec_cmd '(exit 7)'"
    assert_failure 7
}

# ── exec_cmd: capture mode (PRD §7.7.1, engine pipeline) ─────────────────────

@test "exec_cmd capture mode suppresses child stdout (not streamed)" {
    run bash -c "
        export EXEC_CMD_NO_PRINT=true INIT_UBUNTU_CMD_CAPTURE=true
        source '${LIB_DIR}/general.sh'
        exec_cmd 'echo captured-marker'
    "
    assert_success
    refute_output --partial "captured-marker"
}

@test "exec_cmd capture mode emits one cmd_exec JSONL event (cmd/exit/duration_ms/output)" {
    local _log="${INIT_UBUNTU_TEST_SCRATCH}/events.jsonl"
    run bash -c "
        export EXEC_CMD_NO_PRINT=true INIT_UBUNTU_CMD_CAPTURE=true
        export INIT_UBUNTU_LOG_FILE='${_log}' INIT_UBUNTU_CURRENT_MODULE='specmod'
        source '${LIB_DIR}/general.sh'
        exec_cmd 'echo capture-payload'
        jq -e . '${_log}' >/dev/null && echo json-ok
        cat '${_log}'
    "
    assert_success
    assert_output --partial "json-ok"
    assert_output --partial '"body":"cmd_exec"'
    assert_output --partial '"severity_text":"INFO"'
    assert_output --partial '"service.name":"specmod"'
    assert_output --partial '"cmd":"echo capture-payload"'
    assert_output --partial '"exit":0'
    assert_output --partial '"duration_ms":'
    assert_output --partial "capture-payload"
}

@test "exec_cmd capture mode logs failures with ERROR severity and exit code" {
    local _log="${INIT_UBUNTU_TEST_SCRATCH}/events.jsonl"
    run bash -c "
        export EXEC_CMD_NO_PRINT=true INIT_UBUNTU_CMD_CAPTURE=true
        export INIT_UBUNTU_LOG_FILE='${_log}'
        source '${LIB_DIR}/general.sh'
        exec_cmd 'false'
        cat '${_log}'
    "
    assert_success
    assert_output --partial '"severity_text":"ERROR"'
    assert_output --partial '"exit":1'
}

@test "exec_cmd capture mode propagates the command's non-zero exit status" {
    run bash -c "
        export EXEC_CMD_NO_PRINT=true INIT_UBUNTU_CMD_CAPTURE=true
        source '${LIB_DIR}/general.sh'
        exec_cmd '(exit 5)'
    "
    assert_failure 5
}

@test "exec_cmd capture mode with INIT_UBUNTU_VERBOSE=true streams child output live" {
    run bash -c "
        export EXEC_CMD_NO_PRINT=true INIT_UBUNTU_CMD_CAPTURE=true INIT_UBUNTU_VERBOSE=true
        source '${LIB_DIR}/general.sh'
        exec_cmd 'echo live-marker'
    "
    assert_success
    assert_output --partial "live-marker"
}

@test "exec_cmd verbose capture propagates exit status under pipefail (module sub-shell semantics)" {
    run bash -c "
        set -o pipefail
        export EXEC_CMD_NO_PRINT=true INIT_UBUNTU_CMD_CAPTURE=true INIT_UBUNTU_VERBOSE=true
        source '${LIB_DIR}/general.sh'
        exec_cmd '(exit 3)'
    "
    assert_failure 3
}

@test "exec_cmd capture mode appends child output to INIT_UBUNTU_CMD_OUTPUT_FILE" {
    local _buf="${INIT_UBUNTU_TEST_SCRATCH}/cmd_output.txt"
    run bash -c "
        export EXEC_CMD_NO_PRINT=true INIT_UBUNTU_CMD_CAPTURE=true
        export INIT_UBUNTU_CMD_OUTPUT_FILE='${_buf}'
        source '${LIB_DIR}/general.sh'
        exec_cmd 'echo buffered-line-1'
        exec_cmd 'echo buffered-line-2'
        cat '${_buf}'
    "
    assert_success
    assert_output --partial "buffered-line-1"
    assert_output --partial "buffered-line-2"
}

# ── have_sudo_access ─────────────────────────────────────────────────────────

@test "have_sudo_access returns 0 when running as root" {
    [[ "${EUID}" -eq 0 ]] || skip "test container runs as root"
    # The alpine test image has no /usr/bin/sudo, so the root branch falls
    # into its apt-get self-install attempt — shim apt-get on PATH so the
    # attempt is a no-op (never a real install; ADR-0004 hard rule 2).
    local _stub_bin="${INIT_UBUNTU_TEST_SCRATCH}/bin"
    mkdir -p "${_stub_bin}"
    printf '#!/bin/sh\nexit 0\n' > "${_stub_bin}/apt-get"
    chmod +x "${_stub_bin}/apt-get"
    run bash -c "
        export PATH='${_stub_bin}':\"\${PATH}\" EXEC_CMD_NO_PRINT=true
        source '${LIB_DIR}/general.sh'
        have_sudo_access
    "
    assert_success
}

# ── backup_file ──────────────────────────────────────────────────────────────

@test "backup_file fails fatally when BACKUP_DIR is unset" {
    run bash -c "
        unset BACKUP_DIR
        source '${LIB_DIR}/general.sh'
        backup_file '${INIT_UBUNTU_TEST_SCRATCH}/whatever.txt'
    "
    assert_failure
    assert_output --partial "BACKUP_DIR is not set"
}

@test "backup_file copies an existing file into BACKUP_DIR" {
    printf 'payload\n' > "${INIT_UBUNTU_TEST_SCRATCH}/src.txt"
    run bash -c "
        export BACKUP_DIR='${INIT_UBUNTU_TEST_SCRATCH}/backup'
        source '${LIB_DIR}/general.sh'
        backup_file '${INIT_UBUNTU_TEST_SCRATCH}/src.txt'
    "
    assert_success
    run cat "${INIT_UBUNTU_TEST_SCRATCH}/backup/src.txt"
    assert_output "payload"
}

@test "backup_file warns and skips missing files but still copies the rest" {
    printf 'kept\n' > "${INIT_UBUNTU_TEST_SCRATCH}/kept.txt"
    run bash -c "
        export BACKUP_DIR='${INIT_UBUNTU_TEST_SCRATCH}/backup'
        source '${LIB_DIR}/general.sh'
        backup_file '${INIT_UBUNTU_TEST_SCRATCH}/missing.txt' '${INIT_UBUNTU_TEST_SCRATCH}/kept.txt'
    "
    assert_success
    assert_output --partial "File not found, skip"
    run cat "${INIT_UBUNTU_TEST_SCRATCH}/backup/kept.txt"
    assert_output "kept"
}

@test "backup_file errors when called with no file arguments" {
    run bash -c "
        export BACKUP_DIR='${INIT_UBUNTU_TEST_SCRATCH}/backup'
        source '${LIB_DIR}/general.sh'
        backup_file
    "
    assert_failure
    assert_output --partial "need files to backup"
}

# ── create_temp_file ─────────────────────────────────────────────────────────

@test "create_temp_file creates a /tmp file with prefix + extension and sets outvar" {
    run bash -c "
        source '${LIB_DIR}/general.sh'
        create_temp_file _tmp_path 'specprefix' 'txt'
        echo \"path=\${_tmp_path}\"
        [[ -f \"\${_tmp_path}\" ]] && echo file-exists
        rm -f -- \"\${_tmp_path}\"
    "
    assert_success
    assert_output --partial "path=/tmp/specprefix_"
    assert_output --partial ".txt"
    assert_output --partial "file-exists"
}

@test "create_temp_file -d creates a temp folder" {
    run bash -c "
        source '${LIB_DIR}/general.sh'
        create_temp_file -d -- _tmp_path 'specfolder'
        [[ -d \"\${_tmp_path}\" ]] && echo folder-exists
        rm -rf -- \"\${_tmp_path}\"
    "
    assert_success
    assert_output --partial "folder-exists"
}

@test "create_temp_file sanitizes unsafe characters out of the prefix" {
    run bash -c "
        source '${LIB_DIR}/general.sh'
        create_temp_file _tmp_path 'bad/pre fix'
        echo \"path=\${_tmp_path}\"
        rm -f -- \"\${_tmp_path}\"
    "
    assert_success
    assert_output --partial "path=/tmp/badprefix_"
}

@test "create_temp_file rejects unknown options with a usage fatal" {
    run bash -c "
        source '${LIB_DIR}/general.sh'
        create_temp_file -z -- _tmp_path 'specprefix'
    "
    assert_failure
    assert_output --partial "Usage:"
}

# ── check_pkg_status ─────────────────────────────────────────────────────────

@test "check_pkg_status --exec returns 0 for an available command" {
    run bash -c "source '${LIB_DIR}/general.sh' && check_pkg_status --exec -- bash"
    assert_success
}

@test "check_pkg_status --exec returns 1 for a missing command" {
    run bash -c "source '${LIB_DIR}/general.sh' && check_pkg_status --exec -- definitely-not-a-cmd-xyz"
    assert_failure 1
}

@test "check_pkg_status --install returns 0 when dpkg-query reports installed" {
    run bash -c "
        source '${LIB_DIR}/general.sh'
        dpkg-query() { printf 'ii \n'; }
        check_pkg_status --install -- somepkg
    "
    assert_success
}

@test "check_pkg_status --install returns 1 when package is not installed" {
    run bash -c "
        source '${LIB_DIR}/general.sh'
        dpkg-query() { return 1; }
        check_pkg_status --install -- somepkg
    "
    assert_failure 1
}

@test "check_pkg_status without a mode option fails fatally" {
    run bash -c "source '${LIB_DIR}/general.sh' && check_pkg_status -- bash"
    assert_failure
    assert_output --partial "Unknown mode"
}

# ── setup_apt_mirror ─────────────────────────────────────────────────────────

@test "setup_apt_mirror fails fatally when the path does not exist" {
    run bash -c "
        export EXEC_CMD_NO_PRINT=true
        source '${LIB_DIR}/general.sh'
        setup_apt_mirror --path '${INIT_UBUNTU_TEST_SCRATCH}/no-such-path' -- 'mirror.example.com' 'origin.example.com'
    "
    assert_failure
    assert_output --partial "Path not found"
}

@test "setup_apt_mirror rewrites origin url to mirror url in a .list file (keeps .bak)" {
    local _list="${INIT_UBUNTU_TEST_SCRATCH}/test.list"
    printf 'deb http://origin.example.com/ubuntu noble main\n' > "${_list}"
    run bash -c "
        export EXEC_CMD_NO_PRINT=true
        source '${LIB_DIR}/general.sh'
        setup_apt_mirror --path '${_list}' -- 'mirror.example.com' 'origin.example.com'
    "
    assert_success
    run cat "${_list}"
    assert_output --partial "mirror.example.com"
    refute_output --partial "origin.example.com"
    run cat "${_list}.bak"
    assert_output --partial "origin.example.com"
}

@test "setup_apt_mirror --dry-run leaves the file untouched" {
    local _list="${INIT_UBUNTU_TEST_SCRATCH}/dry.list"
    printf 'deb http://origin.example.com/ubuntu noble main\n' > "${_list}"
    run bash -c "
        export EXEC_CMD_NO_PRINT=true
        source '${LIB_DIR}/general.sh'
        setup_apt_mirror --dry-run --path '${_list}' -- 'mirror.example.com' 'origin.example.com'
    "
    assert_success
    assert_output --partial "Dry run"
    run cat "${_list}"
    assert_output --partial "origin.example.com"
    [[ ! -e "${_list}.bak" ]]
}

@test "setup_apt_mirror directory mode rewrites .list files and skips other files" {
    local _dir="${INIT_UBUNTU_TEST_SCRATCH}/aptdir"
    mkdir -p "${_dir}"
    printf 'deb http://origin.example.com/ubuntu noble main\n' > "${_dir}/a.list"
    printf 'origin.example.com\n' > "${_dir}/notes.txt"
    run bash -c "
        export EXEC_CMD_NO_PRINT=true
        source '${LIB_DIR}/general.sh'
        setup_apt_mirror --path '${_dir}' -- 'mirror.example.com' 'origin.example.com'
    "
    assert_success
    run cat "${_dir}/a.list"
    assert_output --partial "mirror.example.com"
    run cat "${_dir}/notes.txt"
    assert_output "origin.example.com"
}

@test "setup_apt_mirror reports a no-op when the origin URL is absent (regression #152)" {
    # The {\$_file} typo (#152) made cmp open a literal '{/path' that never
    # exists, so cmp always reported "differ" and the no-op branch (post-sed
    # file identical to its .bak) was dead code: a run that changes nothing was
    # silently treated as success. This is the ONLY branch the typo affected —
    # the positive / directory / dry-run tests above all pass even WITH the bug,
    # which is why it slipped through. A no-op must be detected and reported.
    local _f="${INIT_UBUNTU_TEST_SCRATCH}/noop.list"
    printf 'deb http://archive.ubuntu.com/ubuntu noble main\n' > "${_f}"
    run bash -c "
        export EXEC_CMD_NO_PRINT=true
        source '${LIB_DIR}/general.sh'
        setup_apt_mirror --path '${_f}' -- 'mirror.example.com' 'not-present.example.com'
    "
    assert_success
    assert_output --partial "Failed to setup APT source mirror"
}

# ── apt_pkg_manager (sudo / apt-get / dpkg-query stubbed — never real) ───────

@test "apt_pkg_manager rejects --no-update outside the install action" {
    run bash -c "
        source '${LIB_DIR}/general.sh'
        apt_pkg_manager --remove --no-update -- cowsay
    "
    assert_failure
    assert_output --partial "only supports install action"
}

@test "apt_pkg_manager rejects --purge with the install action" {
    run bash -c "
        source '${LIB_DIR}/general.sh'
        apt_pkg_manager --purge --install -- cowsay
    "
    assert_failure
    assert_output --partial "only supports remove action"
}

@test "apt_pkg_manager fails fatally when no packages are given" {
    run bash -c "
        source '${LIB_DIR}/general.sh'
        apt_pkg_manager --install --no-update --
    "
    assert_failure
    assert_output --partial "Package quantity is zero"
}

@test "apt_pkg_manager installs a package via stubbed sudo/apt" {
    run bash -c "
        export EXEC_CMD_NO_PRINT=true
        source '${LIB_DIR}/general.sh'
        sudo() { return 0; }
        apt_pkg_manager --install --no-update -- cowsay
    "
    assert_success
}

@test "apt_pkg_manager reports install failure when apt cannot install the package" {
    run bash -c "
        export EXEC_CMD_NO_PRINT=true
        source '${LIB_DIR}/general.sh'
        sudo() { [[ \"\$1\" == \"apt-cache\" ]] && return 0; return 1; }
        apt_pkg_manager --install --no-update -- cowsay
    "
    assert_failure 1
    assert_output --partial "Install failed"
}

@test "apt_pkg_manager aborts install when apt-get update fails" {
    run bash -c "
        export EXEC_CMD_NO_PRINT=true
        source '${LIB_DIR}/general.sh'
        sudo() { return 1; }
        apt_pkg_manager --install -- cowsay
    "
    assert_failure
    assert_output --partial "Failed to update package list"
}

@test "apt_pkg_manager remove skips packages that are not installed (no apt call)" {
    run bash -c "
        export EXEC_CMD_NO_PRINT=true
        source '${LIB_DIR}/general.sh'
        sudo() { echo 'SUDO_INVOKED'; }
        dpkg-query() { return 1; }
        apt_pkg_manager --remove -- cowsay
    "
    assert_success
    refute_output --partial "SUDO_INVOKED"
}

@test "apt_pkg_manager --remove --purge passes --purge to apt-get remove" {
    run bash -c "
        export EXEC_CMD_NO_PRINT=true
        source '${LIB_DIR}/general.sh'
        sudo() { echo \"\$*\"; }
        dpkg-query() { printf 'ii \n'; }
        apt_pkg_manager --remove --purge -- cowsay
    "
    assert_success
    assert_output --partial "apt-get remove -y --purge cowsay"
}

@test "apt_pkg_manager returns 1 when apt-get remove fails" {
    run bash -c "
        export EXEC_CMD_NO_PRINT=true
        source '${LIB_DIR}/general.sh'
        sudo() { return 1; }
        dpkg-query() { printf 'ii \n'; }
        apt_pkg_manager --remove -- cowsay
    "
    assert_failure 1
    assert_output --partial "Remove failed"
}

# ── get_github_pkg_latest_version (curl stubbed; jq is real in-container) ────

@test "get_github_pkg_latest_version fails fatally on invalid repo format" {
    run bash -c "
        source '${LIB_DIR}/general.sh'
        get_github_pkg_latest_version PKG_VERSION 'no-slash-repo'
    "
    assert_failure
    assert_output --partial "Invalid GitHub repository format"
}

@test "get_github_pkg_latest_version resolves tag_name and strips leading v" {
    run bash -c "
        source '${LIB_DIR}/general.sh'
        curl() { printf '{\"tag_name\":\"v9.9.9\"}'; }
        get_github_pkg_latest_version PKG_VERSION 'owner/repo'
        echo \"ver=\${PKG_VERSION}\"
    "
    assert_success
    assert_output --partial "ver=9.9.9"
}

@test "get_github_pkg_latest_version fails fatally when the API request fails" {
    run bash -c "
        source '${LIB_DIR}/general.sh'
        curl() { return 22; }
        get_github_pkg_latest_version PKG_VERSION 'owner/repo'
    "
    assert_failure
    assert_output --partial "Failed to get GitHub API response"
}

@test "get_github_pkg_latest_version fails fatally when no version is found in the response" {
    run bash -c "
        source '${LIB_DIR}/general.sh'
        curl() { printf 'not-json'; }
        get_github_pkg_latest_version PKG_VERSION 'owner/repo'
    "
    assert_failure
    assert_output --partial "No valid release version"
}

# ── Platform helpers (check_in_WSL / check_in_mac / get_system_param) ────────

@test "check_in_WSL exports IN_WSL=true when WSL_DISTRO_NAME is set" {
    run bash -c "
        source '${LIB_DIR}/general.sh'
        export WSL_DISTRO_NAME='Ubuntu-24.04'
        check_in_WSL
        echo \"wsl=\${IN_WSL:-unset}\"
    "
    assert_success
    assert_output --partial "wsl=true"
}

@test "check_in_WSL leaves IN_WSL unset outside WSL" {
    run bash -c "
        source '${LIB_DIR}/general.sh'
        unset WSL_DISTRO_NAME IN_WSL
        check_in_WSL
        echo \"wsl=\${IN_WSL:-unset}\"
    "
    assert_success
    assert_output --partial "wsl=unset"
}

@test "check_in_mac leaves IN_MAC unset on Linux" {
    run bash -c "
        source '${LIB_DIR}/general.sh'
        unset IN_MAC
        check_in_mac
        echo \"mac=\${IN_MAC:-unset}\"
    "
    assert_success
    assert_output --partial "mac=unset"
}

@test "get_system_param exports SYSTEM_ID matching /etc/os-release" {
    run bash -c "
        source '${LIB_DIR}/general.sh'
        _expected=\"\$(. /etc/os-release && printf '%s' \"\${ID}\")\"
        get_system_param
        [[ -n \"\${SYSTEM_ID}\" && \"\${SYSTEM_ID}\" == \"\${_expected}\" ]] && echo system-id-match
    "
    assert_success
    assert_output --partial "system-id-match"
}

@test "check_in_mac exports IN_MAC=true when uname reports Darwin" {
    run bash -c "
        source '${LIB_DIR}/general.sh'
        uname() { echo Darwin; }
        unset IN_MAC
        check_in_mac
        echo \"mac=\${IN_MAC:-unset}\"
    "
    assert_success
    assert_output --partial "mac=true"
}

# ── _general_epoch_ms fallback (no %N support) ───────────────────────────────

@test "exec_cmd capture mode uses second-precision epoch fallback when date lacks %N" {
    local _log="${INIT_UBUNTU_TEST_SCRATCH}/events.jsonl"
    run bash -c "
        export EXEC_CMD_NO_PRINT=true INIT_UBUNTU_CMD_CAPTURE=true
        export INIT_UBUNTU_LOG_FILE='${_log}'
        source '${LIB_DIR}/general.sh'
        date() {
            if [[ \"\$1\" == '+%s%3N' ]]; then printf 'not-a-number'; else printf '1700000000'; fi
        }
        exec_cmd 'echo fallback-clock'
        cat '${_log}'
    "
    assert_success
    assert_output --partial '"duration_ms":'
    assert_output --partial "fallback-clock"
}

# ── library guard (run as executable, not sourced) ───────────────────────────

@test "lib/general.sh prints a library warning when executed directly" {
    run bash "${LIB_DIR}/general.sh"
    assert_success
    assert_output --partial "is a library, not a executable script"
    assert_output --partial "test/test_logger.sh"
}

# ── create_temp_file failure branches ────────────────────────────────────────

@test "create_temp_file fails fatally when mktemp cannot create the file" {
    run bash -c "
        source '${LIB_DIR}/general.sh'
        mktemp() { return 1; }
        create_temp_file _tmp_path 'specprefix' 'txt'
    "
    assert_failure
    assert_output --partial "Failed to create temporary file"
}

@test "create_temp_file -d fails fatally when mktemp cannot create the folder" {
    run bash -c "
        source '${LIB_DIR}/general.sh'
        mktemp() { return 1; }
        create_temp_file -d -- _tmp_path 'specfolder'
    "
    assert_failure
    assert_output --partial "Failed to create temporary folder"
}

# ── setup_apt_mirror additional branches ─────────────────────────────────────

@test "setup_apt_mirror --dry-run on a directory previews .list files without writing" {
    local _dir="${INIT_UBUNTU_TEST_SCRATCH}/drydir"
    mkdir -p "${_dir}"
    printf 'deb http://origin.example.com/ubuntu noble main\n' > "${_dir}/a.list"
    run bash -c "
        export EXEC_CMD_NO_PRINT=true
        source '${LIB_DIR}/general.sh'
        setup_apt_mirror --dry-run --path '${_dir}' -- 'mirror.example.com' 'origin.example.com'
    "
    assert_success
    assert_output --partial "Dry run"
    run cat "${_dir}/a.list"
    assert_output --partial "origin.example.com"
    [[ ! -e "${_dir}/a.list.bak" ]]
}

@test "setup_apt_mirror directory mode processes a non-.list/.sources file as skipped" {
    local _dir="${INIT_UBUNTU_TEST_SCRATCH}/skipdir"
    mkdir -p "${_dir}"
    printf 'origin.example.com\n' > "${_dir}/config.cfg"
    run bash -c "
        export EXEC_CMD_NO_PRINT=true LOG_LEVEL=DEBUG
        source '${LIB_DIR}/general.sh'
        setup_apt_mirror --path '${_dir}' -- 'mirror.example.com' 'origin.example.com'
    "
    assert_success
    assert_output --partial "Skip non-APT source file"
    run cat "${_dir}/config.cfg"
    assert_output "origin.example.com"
}

@test "setup_apt_mirror file mode rewrites a single .sources file" {
    local _src="${INIT_UBUNTU_TEST_SCRATCH}/test.sources"
    printf 'URIs: http://origin.example.com/ubuntu\n' > "${_src}"
    run bash -c "
        export EXEC_CMD_NO_PRINT=true
        source '${LIB_DIR}/general.sh'
        setup_apt_mirror --path '${_src}' -- 'mirror.example.com' 'origin.example.com'
    "
    assert_success
    run cat "${_src}"
    assert_output --partial "mirror.example.com"
    refute_output --partial "origin.example.com"
}

@test "setup_apt_mirror --dry-run on a single .list file previews without writing" {
    local _list="${INIT_UBUNTU_TEST_SCRATCH}/drysingle.list"
    printf 'deb http://origin.example.com/ubuntu noble main\n' > "${_list}"
    run bash -c "
        export EXEC_CMD_NO_PRINT=true
        source '${LIB_DIR}/general.sh'
        setup_apt_mirror --dry-run --path '${_list}' -- 'mirror.example.com' 'origin.example.com'
    "
    assert_success
    assert_output --partial "Dry run"
    [[ ! -e "${_list}.bak" ]]
}

# ── apt_pkg_manager additional branches ──────────────────────────────────────

@test "apt_pkg_manager rejects --only-upgrade outside the install action" {
    run bash -c "
        source '${LIB_DIR}/general.sh'
        apt_pkg_manager --remove --only-upgrade -- cowsay
    "
    assert_failure
    assert_output --partial "only supports install action"
}

@test "apt_pkg_manager install --only-upgrade passes --only-upgrade to apt-get" {
    run bash -c "
        export EXEC_CMD_NO_PRINT=true
        source '${LIB_DIR}/general.sh'
        sudo() { echo \"\$*\"; }
        apt_pkg_manager --install --no-update --only-upgrade -- cowsay
    "
    assert_success
    assert_output --partial "apt-get install -y --only-upgrade"
}

@test "apt_pkg_manager install marks a package not found in apt-cache as failed" {
    run bash -c "
        export EXEC_CMD_NO_PRINT=true
        source '${LIB_DIR}/general.sh'
        sudo() { return 1; }
        apt_pkg_manager --install --no-update -- nonexistent-pkg-xyz
    "
    assert_failure 1
    assert_output --partial "Install failed"
}

# ── get_github_pkg_latest_version wget fallback path ─────────────────────────

@test "get_github_pkg_latest_version falls back to wget+grep when curl/jq are unavailable" {
    run bash -c "
        source '${LIB_DIR}/general.sh'
        check_pkg_status() { [[ \"\$3\" == 'curl' || \"\$3\" == 'jq' ]] && return 1; return 0; }
        apt_pkg_manager() { return 1; }
        wget() { printf '{\"tag_name\":\"v3.4.5\"}'; }
        get_github_pkg_latest_version PKG_VERSION 'owner/repo'
        echo \"ver=\${PKG_VERSION}\"
    "
    assert_success
    assert_output --partial "ver=3.4.5"
}

@test "get_github_pkg_latest_version wget fallback fails fatally when wget errors" {
    run bash -c "
        source '${LIB_DIR}/general.sh'
        check_pkg_status() { [[ \"\$3\" == 'curl' || \"\$3\" == 'jq' ]] && return 1; return 0; }
        apt_pkg_manager() { return 1; }
        wget() { return 4; }
        get_github_pkg_latest_version PKG_VERSION 'owner/repo'
    "
    assert_failure
    assert_output --partial "Failed to get GitHub API response"
}

@test "get_github_pkg_latest_version fails fatally when wget+grep fallback tools cannot install" {
    run bash -c "
        source '${LIB_DIR}/general.sh'
        check_pkg_status() { return 1; }
        apt_pkg_manager() { return 1; }
        get_github_pkg_latest_version PKG_VERSION 'owner/repo'
    "
    assert_failure
    assert_output --partial "Unable to install 'curl jq' or 'wget grep sed' tools"
}
