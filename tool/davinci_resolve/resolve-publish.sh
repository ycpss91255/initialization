#!/usr/bin/env bash
# tool/davinci_resolve/resolve-publish.sh — re-encode DaVinci Resolve exports
# (AV1 / DNxHR) to H.264 or H.265 for wide-compatibility sharing.
#
# DaVinci Resolve Free on Linux cannot export H.264/H.265 (licensing); only
# AV1 is offered. This transcodes an existing export to H.264/H.265 via
# ffmpeg for distribution. Standalone — no install step needed.
#
# Requires ffmpeg built with libx264 and libx265
# (Ubuntu: sudo apt install ffmpeg — both encoders are included by default).
# Audio is re-encoded to AAC 192k for MP4-container compatibility.
#
# Exit-code contract (ADR-0007): default to `set -uo pipefail` so a single
# failing input does not abort the remaining inputs; errors are handled
# explicitly and the final exit code is 1 if any input failed.
set -uo pipefail

PROG="${0##*/}"

# ── Defaults ─────────────────────────────────────────────────────────────────
CODEC="h264"
CRF="18"
OUT_DIR=""

# Tracked so the interrupt trap can remove a half-written output.
CURRENT_OUTPUT=""

log() { printf '[%s] %s\n' "${PROG}" "$*"; }
err() { printf '[%s] %s\n' "${PROG}" "$*" >&2; }

usage() {
    cat <<EOF
Usage: ${PROG} [-c h264|h265] [-q CRF] [-o OUTDIR] INPUT [INPUT...]

Re-encode DaVinci Resolve exports to H.264/H.265 for sharing.

Options:
  -c CODEC   h264 (default, widest compatibility) or h265 (~40% smaller)
  -q CRF     constant rate factor; lower = better quality
             (H.264: 18-23, H.265: 20-28; default 18)
  -o OUTDIR  write outputs to OUTDIR (default: alongside each input)
  -h         show this help

Output: <stem>_<codec>.mp4 (audio re-encoded to AAC 192k).
EOF
}

# ── Arg parsing ──────────────────────────────────────────────────────────────
while getopts ':c:q:o:h' opt; do
    case "${opt}" in
        c) CODEC="${OPTARG}" ;;
        q) CRF="${OPTARG}" ;;
        o) OUT_DIR="${OPTARG}" ;;
        h)
            usage
            exit 0
            ;;
        :)
            err "option -${OPTARG} requires an argument"
            usage >&2
            exit 1
            ;;
        \?)
            err "unknown option -${OPTARG}"
            usage >&2
            exit 1
            ;;
    esac
done
shift $((OPTIND - 1))

if [[ $# -eq 0 ]]; then
    usage >&2
    exit 1
fi

# ── Validation (pure; no external tools required) ────────────────────────────
if [[ "${CODEC}" != "h264" && "${CODEC}" != "h265" ]]; then
    err "codec must be h264 or h265 (got: ${CODEC})"
    exit 1
fi

if [[ ! "${CRF}" =~ ^[0-9]+$ ]]; then
    err "CRF must be a number (got: ${CRF})"
    exit 1
fi

if [[ -n "${OUT_DIR}" && -e "${OUT_DIR}" && ! -d "${OUT_DIR}" ]]; then
    err "output target '${OUT_DIR}' already exists and is not a directory"
    exit 1
fi

# Map the friendly codec name to the ffmpeg encoder + container tag.
if [[ "${CODEC}" == "h264" ]]; then
    VCODEC="libx264"
else
    VCODEC="libx265"
fi

# ── ffmpeg availability ──────────────────────────────────────────────────────
if ! command -v ffmpeg >/dev/null 2>&1; then
    err "ffmpeg not found; install it first (Ubuntu: sudo apt install ffmpeg)"
    exit 1
fi

# Capture the encoder listing before grepping it. Piping straight into
# `grep -q` lets grep close the pipe on its first match, which sends ffmpeg
# SIGPIPE mid-write; under `set -o pipefail` that turns a *present* encoder
# into a spurious "missing" failure. `ffmpeg -encoders` prints hundreds of
# lines, so the race is real, not just a test artifact.
encoder_list="$(ffmpeg -hide_banner -encoders 2>/dev/null)"
if ! grep -qw "${VCODEC}" <<<"${encoder_list}"; then
    err "ffmpeg is missing the ${VCODEC} encoder; install a full ffmpeg build (Ubuntu: sudo apt install ffmpeg)"
    exit 1
fi

if [[ -n "${OUT_DIR}" ]]; then
    mkdir -p -- "${OUT_DIR}" || {
        err "cannot create output directory '${OUT_DIR}'"
        exit 1
    }
fi

# ── Interrupt handling ───────────────────────────────────────────────────────
on_interrupt() {
    if [[ -n "${CURRENT_OUTPUT}" && -e "${CURRENT_OUTPUT}" ]]; then
        rm -f -- "${CURRENT_OUTPUT}"
    fi
    err "interrupted; removed partial output"
    exit 1
}
trap on_interrupt INT TERM

# ── Transcode loop ───────────────────────────────────────────────────────────
exit_code=0
for input in "$@"; do
    if [[ ! -f "${input}" ]]; then
        err "input '${input}' not found or not a regular file"
        exit_code=1
        continue
    fi

    stem="${input##*/}"
    stem="${stem%.*}"
    if [[ -n "${OUT_DIR}" ]]; then
        out="${OUT_DIR%/}/${stem}_${CODEC}.mp4"
    else
        dir="${input%/*}"
        [[ "${dir}" == "${input}" ]] && dir="."
        out="${dir}/${stem}_${CODEC}.mp4"
    fi

    ffargs=(-c:v "${VCODEC}" -crf "${CRF}" -preset medium)
    [[ "${CODEC}" == "h265" ]] && ffargs+=(-tag:v hvc1)
    ffargs+=(-c:a aac -b:a 192k)

    log "Encoding '${input}' -> '${out}' (${CODEC}, CRF ${CRF})"
    CURRENT_OUTPUT="${out}"

    if ffmpeg -hide_banner -y -i "${input}" "${ffargs[@]}" "${out}" </dev/null; then
        if [[ ! -s "${out}" ]]; then
            err "ffmpeg produced an empty file for '${input}'; removing it"
            rm -f -- "${out}"
            exit_code=1
        else
            log "Wrote '${out}'"
        fi
    else
        err "ffmpeg failed on '${input}'; removing partial output"
        rm -f -- "${out}"
        exit_code=1
    fi
    CURRENT_OUTPUT=""
done

trap - INT TERM
exit "${exit_code}"
