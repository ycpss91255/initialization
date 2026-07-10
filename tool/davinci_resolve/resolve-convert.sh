#!/usr/bin/env bash
# resolve-convert.sh — transcode H.264/AAC clips to DNxHR HQ + PCM so that
# DaVinci Resolve Free on Linux can import them (issue #267).
#
# Resolve Free on Linux ships no H.264/H.265/AAC decode licenses, so importing
# a phone/screen-recording MP4 either drops the video track or imports audio
# only. Transcoding to DNxHR HQ (intra-frame, license-free, decoded by the
# bundled DNxHR library on every platform) + PCM s16le sidesteps this.
#
# Usage:
#   resolve-convert.sh clip.mp4                 # -> clip_resolve.mov (beside source)
#   resolve-convert.sh ~/Videos/raw/            # batch every video in a dir
#   resolve-convert.sh -o ~/ready/ ~/Videos/raw # redirect all outputs to a dir
#
# Output naming (no -o): same directory as input, <stem>_resolve.mov.
# Idempotent: a source with an existing <stem>_resolve.mov is skipped, and
# directory mode never re-feeds *_resolve.mov outputs as inputs.
#
# Exit-code contract (see doc/adr/0007): this script defaults to
# `set -uo pipefail` (no -e) so a per-file ffmpeg failure can be handled
# explicitly and the remaining inputs still processed; the final exit code
# is 1 if any input failed.
set -uo pipefail

# ffmpeg binary is overridable (FFMPEG_BIN) so tests can inject a stub and
# users can point at a specific build.
FFMPEG_BIN="${FFMPEG_BIN:-ffmpeg}"

# Video container extensions picked up in directory mode.
VIDEO_EXTS=(mp4 mov mkv avi m4v)

PROG="${0##*/}"

log() { printf '[resolve-convert] %s\n' "$*"; }
err() { printf '[resolve-convert] error: %s\n' "$*" >&2; }

usage() {
    cat <<EOF
Usage: ${PROG} [-o DIR] <file|directory> [<file|directory> ...]

Transcode H.264/AAC clips to DNxHR HQ + PCM (.mov) for DaVinci Resolve
Free on Linux. Output is written beside each source as <stem>_resolve.mov,
or into DIR when -o is given.

Options:
  -o, --output DIR   Write all outputs into DIR (created if needed).
  -h, --help         Show this help and exit.
EOF
}

# Removed on INT/TERM so an interrupted transcode never leaves a partial file.
_CURRENT_OUT=""
_cleanup() {
    if [[ -n "${_CURRENT_OUT}" && -e "${_CURRENT_OUT}" ]]; then
        rm -f -- "${_CURRENT_OUT}"
    fi
    _CURRENT_OUT=""
}
trap '_cleanup; exit 130' INT TERM

# convert_one <src> <out>
# Returns 0 on success or skip, 1 on failure (partial/empty output pruned).
convert_one() {
    local src="$1" out="$2"

    if [[ -e "${out}" ]]; then
        log "skip (output exists): ${out}"
        return 0
    fi

    log "converting: ${src} -> ${out}"
    _CURRENT_OUT="${out}"
    if ! "${FFMPEG_BIN}" -hide_banner -loglevel error -y -i "${src}" \
        -c:v dnxhd -profile:v dnxhr_hq -pix_fmt yuv422p \
        -c:a pcm_s16le \
        "${out}"; then
        err "ffmpeg failed on: ${src}"
        rm -f -- "${out}"
        _CURRENT_OUT=""
        return 1
    fi

    if [[ ! -s "${out}" ]]; then
        err "produced an empty output, removing: ${out}"
        rm -f -- "${out}"
        _CURRENT_OUT=""
        return 1
    fi

    _CURRENT_OUT=""
    log "wrote: ${out}"
    return 0
}

# Emit the destination path for a source, honouring -o.
dest_for() {
    local src="$1" outdir="$2"
    local base stem dir
    base="${src##*/}"
    stem="${base%.*}"
    if [[ -n "${outdir}" ]]; then
        printf '%s/%s_resolve.mov\n' "${outdir%/}" "${stem}"
    else
        dir="${src%/*}"
        [[ "${dir}" == "${src}" ]] && dir="."
        printf '%s/%s_resolve.mov\n' "${dir%/}" "${stem}"
    fi
}

# Append every convertible video in a directory (non-recursive) to the named
# array, excluding already-converted *_resolve.mov outputs.
collect_dir() {
    local dir="$1" arr_name="$2"
    local -n _arr="${arr_name}"
    local ext f
    for ext in "${VIDEO_EXTS[@]}"; do
        while IFS= read -r -d '' f; do
            case "${f}" in
                *_resolve.mov) continue ;;
            esac
            _arr+=("${f}")
        done < <(find "${dir}" -maxdepth 1 -type f -iname "*.${ext}" -print0 2>/dev/null | sort -z)
    done
}

main() {
    local outdir=""
    local -a args=()

    while [[ $# -gt 0 ]]; do
        case "$1" in
            -o|--output)
                shift
                if [[ $# -eq 0 ]]; then
                    err "'-o' requires a directory argument"
                    return 1
                fi
                outdir="$1"
                shift
                ;;
            -h|--help)
                usage
                return 0
                ;;
            --)
                shift
                while [[ $# -gt 0 ]]; do
                    args+=("$1")
                    shift
                done
                ;;
            -*)
                err "unknown option: $1"
                return 1
                ;;
            *)
                args+=("$1")
                shift
                ;;
        esac
    done

    if [[ "${#args[@]}" -eq 0 ]]; then
        usage
        return 1
    fi

    # Validate / prepare -o target.
    if [[ -n "${outdir}" ]]; then
        if [[ -e "${outdir}" && ! -d "${outdir}" ]]; then
            err "${outdir} already exists and is not a directory"
            return 1
        fi
        if ! mkdir -p -- "${outdir}"; then
            err "could not create output directory: ${outdir}"
            return 1
        fi
    fi

    if ! command -v -- "${FFMPEG_BIN}" >/dev/null 2>&1; then
        err "ffmpeg is not installed (looked for '${FFMPEG_BIN}')"
        err "install it with: sudo apt install ffmpeg"
        return 1
    fi

    # Expand inputs (files kept as-is; directories fanned out to their videos).
    local -a inputs=()
    local rc=0 arg
    for arg in "${args[@]}"; do
        if [[ -d "${arg}" ]]; then
            collect_dir "${arg}" inputs
        elif [[ -f "${arg}" ]]; then
            inputs+=("${arg}")
        else
            err "${arg} not found"
            rc=1
        fi
    done

    local src out
    for src in "${inputs[@]}"; do
        out="$(dest_for "${src}" "${outdir}")"
        if ! convert_one "${src}" "${out}"; then
            rc=1
        fi
    done

    return "${rc}"
}

main "$@"
