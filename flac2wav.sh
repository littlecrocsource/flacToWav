#!/usr/bin/env bash
# =============================================================================
# flac2wav.sh — FLAC -> WAV (LPCM 16-bit / 44.1 kHz) for Pioneer DEH-80PRS
#
# The DEH-80PRS plays WAV only as LPCM 8/16-bit, 16-48 kHz (no FLAC, no
# 24-bit, nothing above 48 kHz), so 16-bit/44.1 kHz is the correct target.
#
# Usage:
#   ./flac2wav.sh              interactive picker (current folder)
#   ./flac2wav.sh --all        convert every .flac in the folder
#   ./flac2wav.sh song.flac …  convert the given file(s)
#   ./flac2wav.sh -y …         overwrite existing .wav without asking
#   ./flac2wav.sh -d DIR …     work in DIR instead of current folder
#   ./flac2wav.sh -h           help
# =============================================================================
set -u -o pipefail

# ---------- colors (disabled when not on a terminal) -------------------------
if [[ -t 1 ]]; then
    C_OK=$'\e[1;92m'  C_ERR=$'\e[1;91m'  C_WARN=$'\e[1;93m'
    C_INFO=$'\e[1;96m' C_MAG=$'\e[1;95m' C_GRN=$'\e[5;1;32m' C_END=$'\e[0m'
else
    C_OK='' C_ERR='' C_WARN='' C_INFO='' C_MAG='' C_GRN='' C_END=''
fi

OUTDIR="wav16"
OVERWRITE=0
ALL=0
WORKDIR="."

usage() { sed -n '2,16p' "$0" | sed 's/^# \{0,1\}//'; exit 0; }

die() { printf '%s\n' "${C_ERR}Error:${C_END} $*" >&2; exit 1; }

# ---------- option parsing ----------------------------------------------------
ARGS=()
while (( $# )); do
    case "$1" in
        -h|--help) usage ;;
        -y|--yes|--overwrite) OVERWRITE=1 ;;
        --all|-a) ALL=1 ;;
        -d|--dir) shift; [[ ${1:-} ]] || die "-d needs a folder"; WORKDIR=$1 ;;
        --) shift; ARGS+=("$@"); break ;;
        -*) die "unknown option: $1 (see -h)" ;;
        *) ARGS+=("$1") ;;
    esac
    shift
done

[[ -d $WORKDIR ]] || die "folder not found: $WORKDIR"
cd "$WORKDIR" || die "cannot enter folder: $WORKDIR"

# ---------- dependency check --------------------------------------------------
command -v ffmpeg  >/dev/null 2>&1 || die "ffmpeg is not installed (sudo apt install ffmpeg)"
command -v ffprobe >/dev/null 2>&1 || die "ffprobe is not installed (it ships with ffmpeg)"

# ---------- helpers -----------------------------------------------------------
# True if the file's actual content is FLAC (not just the extension).
is_real_flac() {
    # 1) magic bytes: every real FLAC file starts with "fLaC"
    #    (ffprobe alone trusts the extension, so a renamed file would slip past)
    local magic codec
    magic=$(head -c 4 -- "$1" 2>/dev/null)
    [[ $magic == "fLaC" ]] || return 1
    # 2) ffprobe must also see a decodable FLAC audio stream
    codec=$(ffprobe -v error -select_streams a:0 -show_entries stream=codec_name \
            -of default=noprint_wrappers=1:nokey=1 -- "$1" 2>/dev/null) || return 1
    [[ $codec == flac ]]
}

convert_file() {
    local in=$1 base out
    base=${in##*/}          # strip any path
    out="$OUTDIR/${base%.[Ff][Ll][Aa][Cc]}.wav"

    if [[ ! -f $in ]]; then
        printf '%s\n' "${C_ERR}skip${C_END}  $in — file not found"
        return 1
    fi
    if ! is_real_flac "$in"; then
        printf '%s\n' "${C_ERR}skip${C_END}  $in — not a real FLAC file"
        return 1
    fi
    if [[ -e $out && $OVERWRITE -eq 0 ]]; then
        printf '%s\n' "${C_WARN}skip${C_END}  $in — $out already exists (use -y to overwrite)"
        return 2
    fi

    printf '%s\n' "${C_INFO}conv${C_END}  $in -> $out"
    # -vn        drop embedded cover art (crashes the WAV muxer otherwise)
    # aresample  44.1 kHz, 16-bit, triangular dither for 24-bit sources
    if ffmpeg -hide_banner -loglevel error -y -i "$in" -vn \
              -map_metadata 0 \
              -af aresample=out_sample_rate=44100:out_sample_fmt=s16:dither_method=triangular_hp \
              -c:a pcm_s16le -- "$out"; then
        return 0
    else
        printf '%s\n' "${C_ERR}fail${C_END}  $in — ffmpeg error, no output written"
        rm -f -- "$out"
        return 1
    fi
}

# ---------- banner ------------------------------------------------------------
printf '%s' "
 ____ _             ${C_GRN}______${C_END}
/  __) |           ${C_GRN}(_____ \\ ${C_END}
| |__| | ____  ____  ${C_GRN}____) ) _ _  ____ _   _${C_END}
|  __) |/ _  |/ ___)${C_GRN}/_____/ | | |/ _  | | | |${C_END}
| |  | ( ( | ( (___ ${C_GRN}______| | | ( ( | |\\ V /${C_END}
|_|  |_|\\_||_|\\____|${C_GRN}_______)____|\\_||_| \\_/${C_END}

${C_MAG}FLAC -> WAV  LPCM 16-bit / 44.1 kHz  (Pioneer DEH-80PRS)${C_END}

"

# ---------- build the candidate list -----------------------------------------
shopt -s nullglob nocaseglob
flacs=(*.flac)
shopt -u nocaseglob

SELECTED=()

if (( ${#ARGS[@]} )); then
    SELECTED=("${ARGS[@]}")                 # files given on the command line
elif (( ALL )); then
    (( ${#flacs[@]} )) || die "no .flac files in $(pwd)"
    SELECTED=("${flacs[@]}")
else
    # ---------- interactive picker -------------------------------------------
    (( ${#flacs[@]} )) || die "no .flac files in $(pwd)"
    printf '%s\n' "Found ${#flacs[@]} FLAC file(s) in $(pwd):"
    printf '\n'
    for i in "${!flacs[@]}"; do
        printf '  %s%3d%s) %s\n' "$C_INFO" $((i+1)) "$C_END" "${flacs[$i]}"
    done
    printf '\n%s\n' "Select: numbers and ranges (e.g. 1 3 5-8), ${C_OK}a${C_END} = all, ${C_ERR}q${C_END} = quit"

    while :; do
        printf '%s' "${C_WARN}choice> ${C_END}"
        read -r reply || exit 1
        reply=${reply//,/ }                                  # allow commas
        [[ $reply =~ ^[[:space:]]*[qQ][[:space:]]*$ ]] && { printf '%s\n' "${C_INFO}[ nothing converted ]${C_END}"; exit 0; }
        if [[ $reply =~ ^[[:space:]]*[aA][[:space:]]*$ ]]; then
            SELECTED=("${flacs[@]}"); break
        fi
        # validate: only digits, spaces and ranges like 5-8
        if [[ ! $reply =~ ^[[:space:]]*[0-9]+([[:space:]-]+[0-9]+)*[[:space:]]*$ ]]; then
            printf '%s\n' "${C_ERR}Invalid input.${C_END} Use numbers, ranges (5-8), a, or q."
            continue
        fi
        SELECTED=() ; ok=1
        for tok in $reply; do
            if [[ $tok =~ ^([0-9]+)-([0-9]+)$ ]]; then
                lo=${BASH_REMATCH[1]} hi=${BASH_REMATCH[2]}
            elif [[ $tok =~ ^[0-9]+$ ]]; then
                lo=$tok hi=$tok
            else
                ok=0; break
            fi
            if (( lo < 1 || hi > ${#flacs[@]} || lo > hi )); then
                printf '%s\n' "${C_ERR}Out of range:${C_END} $tok (valid: 1-${#flacs[@]})"
                ok=0; break
            fi
            for (( n=lo; n<=hi; n++ )); do SELECTED+=("${flacs[$((n-1))]}"); done
        done
        (( ok && ${#SELECTED[@]} )) && break
    done
fi

# de-duplicate while keeping order
declare -A seen=()
UNIQUE=()
for f in "${SELECTED[@]}"; do
    [[ ${seen[$f]:-} ]] && continue
    seen[$f]=1; UNIQUE+=("$f")
done

# ---------- confirm -----------------------------------------------------------
printf '\n%s\n' "${#UNIQUE[@]} file(s) queued -> $OUTDIR/"
while :; do
    printf '%s' "${C_WARN}Continue? [y/N]: ${C_END}"
    read -r confirm || exit 1
    case "$confirm" in
        [yY]|[yY][eE][sS]) break ;;
        [nN]|[nN][oO]|"")  printf '%s\n' "${C_INFO}[ program aborted ]${C_END}"; exit 0 ;;
        *) printf '%s\n' "Please answer y or n." ;;
    esac
done
printf '\n'

# ---------- convert -----------------------------------------------------------
mkdir -p -- "$OUTDIR" || die "cannot create $OUTDIR/"
done_n=0 skip_n=0 fail_n=0
for f in "${UNIQUE[@]}"; do
    convert_file "$f"
    case $? in
        0) ((done_n++)) ;;
        2) ((skip_n++)) ;;
        *) ((fail_n++)) ;;
    esac
done

printf '\n%s\n' "${C_OK}done:${C_END} $done_n   ${C_WARN}skipped:${C_END} $skip_n   ${C_ERR}failed:${C_END} $fail_n"
(( fail_n )) && exit 1
exit 0
