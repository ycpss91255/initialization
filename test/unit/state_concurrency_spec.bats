#!/usr/bin/env bats
# test/unit/state_concurrency_spec.bats — lib/state.sh flock concurrency
#
# Stream S2: state.json concurrency (PRD §10.1).
#
# These tests exercise the flock serialization contract in lib/state.sh
# (`_state_locked_write` + `_state_flock_acquire`) under deterministic,
# forced contention rather than relying on lucky races:
#
#   1. Two concurrent writers serialize — the final state.json is valid
#      JSON (jq -e) with BOTH module records present (no interleaved /
#      half-written object, no lost update).
#   2. A writer holding the lock blocks a second writer until release; the
#      second writer then completes inside the -w (timeout) window.
#   3. The lock is released on holder exit, so a follow-up writer acquires
#      it immediately (no leaked lock, no spurious wait notice).
#
# Contention is forced with a FIFO barrier: the lock holder blocks reading
# the FIFO until the test deterministically unblocks it, so the contender
# is guaranteed to hit the lock while it is held — no timing guesswork.
#
# Contract under test (lib/state.sh header):
#   - flock on ${state_dir}/.state.lock for every write
#   - INIT_UBUNTU_LOCK_TIMEOUT (default 30) bounds the wait
#   - holder PID published to <lock>.pid while held, removed on release

load "${BATS_TEST_DIRNAME}/../helper/common"

setup() {
    setup_test_env
    export LOG_LEVEL=INFO
    export LOG_COLOR=false
}

teardown() {
    teardown_test_env
}

_load_state() {
    # shellcheck source=../../lib/state.sh
    source "${LIB_DIR}/state.sh"
}

# ── barrier helper ───────────────────────────────────────────────────────────
#
# Spawn a background writer that grabs the state lock, then blocks on a FIFO
# read until the test writes a byte to release it. While blocked it holds the
# lock, so any concurrent writer is guaranteed to contend. The holder records
# its PID to <lock>.pid (the same convention real writers use) and, after
# being released, performs a real state_record_install so its record must
# also survive in the final file.
#
# Usage:
#   _spawn_blocked_holder <fifo> <module-name> <version>
#   ... (lock is now held) ...
#   printf 'go\n' > "<fifo>"     # release the holder
#   wait "${HOLDER_PID}"
_spawn_blocked_holder() {
    local _fifo="$1" _name="$2" _version="$3"
    local _lock; _lock="$(_state_lock_path)"

    (
        exec 9>>"${_lock}"
        flock -x 9
        printf '%s' "${BASHPID}" > "${_lock}.pid"
        # Block until released — lock stays held the whole time.
        read -r _ < "${_fifo}"
        # Do real work under the held lock, then drop the pid + lock on exit.
        if command -v jq >/dev/null 2>&1; then
            local _path; _path="$(state_get_path)"
            local _tmp; _tmp="$(mktemp "${_path}.XXXXXX")"
            jq --arg n "${_name}" --arg v "${_version}" \
                '.installed[$n] = {synced: {version_provided: $v}}' \
                "${_path}" > "${_tmp}" && mv "${_tmp}" "${_path}"
        fi
        rm -f "${_lock}.pid"
    ) &
    HOLDER_PID=$!

    # Wait until the holder actually owns the lock (pid file present).
    local _i
    for _i in $(seq 1 50); do
        [[ -f "${_lock}.pid" ]] && return 0
        sleep 0.1
    done
    return 1
}

# ── 1. serialization: both records land, file stays valid JSON ───────────────

@test "two concurrent writers serialize: final state.json is valid JSON with both records" {
    _load_state
    state_init

    # Fire two real writers concurrently. flock must serialize them so the
    # read-modify-write of each never interleaves into a corrupt file.
    ( state_record_install alpha true v-alpha ) &
    local _pid_a=$!
    ( state_record_install beta false v-beta ) &
    local _pid_b=$!
    wait "${_pid_a}"
    wait "${_pid_b}"

    local _p; _p="$(state_get_path)"

    # File must parse as a JSON object (no half-written / interleaved bytes).
    run jq -e 'type == "object"' "${_p}"
    assert_success

    # BOTH records must be present — neither writer clobbered the other.
    run jq -r '.installed | keys | sort | join(",")' "${_p}"
    assert_success
    assert_output "alpha,beta"

    # Each record kept its own version (no lost update / cross-contamination).
    [[ "$(jq -r '.installed.alpha.synced.version_provided' "${_p}")" == "v-alpha" ]]
    [[ "$(jq -r '.installed.beta.synced.version_provided' "${_p}")" == "v-beta" ]]
    [[ "$(jq -r '.installed.alpha.synced.manual' "${_p}")" == "true" ]]
    [[ "$(jq -r '.installed.beta.synced.manual' "${_p}")" == "false" ]]
}

@test "many concurrent writers all serialize without losing or corrupting records" {
    _load_state
    state_init

    local _i
    for _i in 1 2 3 4 5 6 7 8; do
        ( state_record_install "mod-${_i}" false "v${_i}" ) &
    done
    wait

    local _p; _p="$(state_get_path)"
    run jq -e 'type == "object"' "${_p}"
    assert_success
    run jq -r '.installed | keys | length' "${_p}"
    assert_success
    assert_output "8"
}

# ── 2. holder blocks a contender within the -w window ────────────────────────

@test "writer holding the lock blocks a second writer until release (within -w window)" {
    _load_state
    state_init

    local _fifo="${INIT_UBUNTU_TEST_SCRATCH}/barrier.fifo"
    mkfifo "${_fifo}"
    _spawn_blocked_holder "${_fifo}" alpha v-alpha

    # Start the contender while the lock is held. It must NOT win immediately;
    # give it a generous timeout so it survives the wait, then release the
    # holder and let it acquire the lock and complete.
    local _out="${INIT_UBUNTU_TEST_SCRATCH}/contender.out"
    (
        INIT_UBUNTU_LOCK_TIMEOUT=20 state_record_install beta true v-beta
    ) > "${_out}" 2>&1 &
    local _contender_pid=$!

    # The contender should still be alive (blocked) shortly after launch,
    # proving it did not slip past the held lock.
    sleep 0.5
    kill -0 "${_contender_pid}" 2>/dev/null
    local _still_blocked=$?

    # Release the holder; the contender can now acquire and finish.
    printf 'go\n' > "${_fifo}"
    wait "${HOLDER_PID}"
    wait "${_contender_pid}"
    local _contender_rc=$?

    [[ "${_still_blocked}" -eq 0 ]]            # contender was blocked, not done
    [[ "${_contender_rc}" -eq 0 ]]             # then completed successfully
    run cat "${_out}"
    assert_output --partial "waiting for state lock"   # it really contended

    local _p; _p="$(state_get_path)"
    run jq -e 'type == "object"' "${_p}"
    assert_success
    # Holder's record AND the contender's record both survive.
    run jq -r '.installed | keys | sort | join(",")' "${_p}"
    assert_output "alpha,beta"
    [[ "$(jq -r '.installed.beta.synced.version_provided' "${_p}")" == "v-beta" ]]
}

# ── 3. lock released on exit: next writer acquires immediately ───────────────

@test "lock is released on holder exit: a subsequent writer acquires without contention" {
    _load_state
    state_init

    local _fifo="${INIT_UBUNTU_TEST_SCRATCH}/barrier2.fifo"
    mkfifo "${_fifo}"
    _spawn_blocked_holder "${_fifo}" alpha v-alpha

    # Release the holder and let it fully exit, freeing the lock + pid file.
    printf 'go\n' > "${_fifo}"
    wait "${HOLDER_PID}"

    local _lock; _lock="$(_state_lock_path)"
    # pid file is removed on a clean release (no leaked holder marker).
    [[ ! -f "${_lock}.pid" ]]

    # A fresh writer now runs against a free lock: it must succeed with NO
    # "waiting for state lock" notice (acquired on the first non-blocking try).
    run state_record_install beta true v-beta
    assert_success
    refute_output --partial "waiting for state lock"

    local _p; _p="$(state_get_path)"
    run jq -e 'type == "object"' "${_p}"
    assert_success
    [[ "$(jq -r '.installed.beta.synced.version_provided' "${_p}")" == "v-beta" ]]
}

@test "lock file is reusable across many sequential writers (no fd / lock leak)" {
    _load_state
    state_init

    local _i
    for _i in 1 2 3 4 5; do
        run state_record_install "seq-${_i}" false "v${_i}"
        assert_success
        refute_output --partial "waiting for state lock"
    done

    local _p; _p="$(state_get_path)"
    run jq -r '.installed | keys | length' "${_p}"
    assert_output "5"
}
