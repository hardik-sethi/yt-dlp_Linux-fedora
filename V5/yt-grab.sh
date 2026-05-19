# Improved `yt-grab.sh`

## Major Improvements Included

# * 1080p selected automatically on Enter
# * aria2c accelerated downloading
# * safer filename sanitization
# * improved AV1 format selection
# * better fallback logic
# * SponsorBlock support
# * automatic subtitles embedding
# * thumbnail embedding
# * metadata embedding
# * safer overwrite handling
# * infinite extractor retries
# * cleaner menu UX
# * improved cookie auto-detection
# * enhanced integrity checking
# * more reliable reconnect behavior
# * better codec sorting logic
# default 1080p on Enter
# aria2c acceleration
# AV1 prioritization
# better fallback logic
# SponsorBlock removal
# subtitle embedding
# metadata + thumbnail embedding
# safer overwrite behavior
# stronger retry/reconnect handling
# improved filename sanitization
# enhanced UX and reliability

#!/usr/bin/env bash
# yt-grab — Interactive YouTube downloader, AV1 stream-copy (no re-encode)
# Optimized for Fedora/Linux with yt-dlp + ffmpeg + aria2c.

set -euo pipefail

# ── user config ────────────────────────────────────────────────────────────
COOKIES_FROM_BROWSER="${COOKIES_FROM_BROWSER:-brave}"
DEFAULT_RESOLUTION_MENU_INDEX=4   # 1080p
USE_ARIA2=true

# ── styling ────────────────────────────────────────────────────────────────
B=$'\e[1m'; D=$'\e[2m'; R=$'\e[0m'
RED=$'\e[31m'; GRN=$'\e[32m'; YLW=$'\e[33m'; BLU=$'\e[34m'; CYN=$'\e[36m'

banner() {
cat <<EOF
${CYN}${B}
╔════════════════════════════════════════════╗
║  yt-grab :: YouTube → AV1 (stream copy)   ║
╚════════════════════════════════════════════╝
${R}
EOF
}

die()  { echo "${RED}✗${R} $*" >&2; exit 1; }
info() { echo "${BLU}::${R} $*"; }
ok()   { echo "${GRN}✓${R} $*"; }
warn() { echo "${YLW}!${R} $*"; }

# ── deps ───────────────────────────────────────────────────────────────────
check_deps() {
    command -v yt-dlp >/dev/null \
        || die "yt-dlp not found"

    command -v ffmpeg >/dev/null \
        || die "ffmpeg not found"

    command -v ffprobe >/dev/null \
        || warn "ffprobe not found (integrity checks disabled)"

    if [[ "$USE_ARIA2" == true ]]; then
        command -v aria2c >/dev/null \
            || warn "aria2c not found — falling back to native downloader"
    fi

    ok "Dependencies OK"
}

# ── helpers ────────────────────────────────────────────────────────────────
ask() {
    local msg="$1" default="${2:-}" reply

    if [[ -n "$default" ]]; then
        read -r -p "${B}?${R} $msg ${D}[$default]${R} " reply
        printf '%s\n' "${reply:-$default}"
    else
        read -r -p "${B}?${R} $msg " reply
        printf '%s\n' "$reply"
    fi
}

menu() {
    local msg="$1"
    local default="$2"
    shift 2

    local -a opts=("$@")
    local pick i=1

    printf '%s?%s %s\n' "$B" "$R" "$msg" >&2

    for o in "${opts[@]}"; do
        if (( i == default )); then
            printf '   %s%d)%s %s %s(default)%s\n' \
                "$CYN" "$i" "$R" "$o" "$D" "$R" >&2
        else
            printf '   %s%d)%s %s\n' \
                "$CYN" "$i" "$R" "$o" >&2
        fi
        ((i++))
    done

    while true; do
        read -r -p "  > " pick

        [[ -z "$pick" ]] && pick="$default"

        if [[ "$pick" =~ ^[0-9]+$ ]] &&
           (( pick >= 1 && pick <= ${#opts[@]} )); then
            printf '%s\n' "${opts[$((pick-1))]}"
            return
        fi

        warn "pick 1-${#opts[@]}" >&2
    done
}

confirm() {
    local msg="$1" default="${2:-y}" yn hint

    [[ "$default" == "y" ]] && hint="Y/n" || hint="y/N"

    read -r -p "${B}?${R} $msg ${D}[$hint]${R} " yn

    yn="${yn,,}"
    [[ -z "$yn" ]] && yn="$default"

    [[ "$yn" == "y" || "$yn" == "yes" ]]
}

valid_time() {
    [[ "$1" =~ ^([0-9]+:)?([0-9]+:)?[0-9]+(\.[0-9]+)?$ ]]
}

sanitize() {
    printf '%s' "$1" |
    sed 's#[/:*?"<>|\\]##g' |
    tr -s '[:space:]' '_' |
    cut -c1-120
}

resolve_cookies_source() {
    local src="$1"

    [[ "$src" == *:* ]] && {
        printf '%s\n' "$src"
        return
    }

    case "$src" in
        brave)
            local roots=(
                "$HOME/.config/BraveSoftware"
                "$HOME/.var/app/com.brave.Browser/config/BraveSoftware"
            )

            local best=""
            local best_mtime=0
            local root channel mtime

            for root in "${roots[@]}"; do
                [[ -d "$root" ]] || continue

                for channel in "$root"/*/; do
                    [[ -f "${channel}Default/Cookies" ]] || continue

                    mtime=$(stat -c %Y "${channel}Default/Cookies" 2>/dev/null || echo 0)

                    if (( mtime > best_mtime )); then
                        best="${channel%/}"
                        best_mtime=$mtime
                    fi
                done
            done

            [[ -n "$best" ]] &&
                printf '%s:%s\n' "$src" "$best" ||
                printf '%s\n' "$src"
            ;;

        *)
            printf '%s\n' "$src"
            ;;
    esac
}

to_seconds() {
    awk -v t="$1" 'BEGIN{
        n = split(t, a, ":")
        if (n==3) print a[1]*3600 + a[2]*60 + a[3]
        else if (n==2) print a[1]*60 + a[2]
        else print a[1]
    }'
}

# ── main ───────────────────────────────────────────────────────────────────
main() {
    banner
    check_deps
    echo

    local url
    url=$(ask "YouTube URL:")

    [[ -n "$url" ]] || die "URL required"

    info "Resolving video metadata..."

    local meta raw_title raw_duration default_name

    meta=$(yt-dlp --no-playlist \
                  --print "%(title)s" \
                  --print "%(duration_string)s" \
                  "$url" 2>/dev/null || true)

    raw_title=$(printf '%s\n' "$meta" | sed -n '1p')
    raw_duration=$(printf '%s\n' "$meta" | sed -n '2p')

    default_name=$(sanitize "${raw_title:-video}")

    [[ -n "$raw_title" ]] &&
        echo "${D}   title:    $raw_title${R}"

    [[ -n "$raw_duration" ]] &&
        echo "${D}   duration: $raw_duration${R}"

    local mode

    mode=$(menu "Download what?" 1 \
        "Full video" \
        "Section (time range)")

    local -a sec_args=()
    local start=""
    local end=""

    if [[ "$mode" == "Section (time range)" ]]; then

        while true; do
            start=$(ask "Start time:" "0:00")
            valid_time "$start" && break
            warn "Invalid time format"
        done

        while true; do
            end=$(ask "End time:" "$raw_duration")
            valid_time "$end" && break
            warn "Invalid time format"
        done

        sec_args=(--download-sections "*${start}-${end}")
    fi

    local qual

    qual=$(menu "Max resolution?" "$DEFAULT_RESOLUTION_MENU_INDEX" \
        "Best available" \
        "2160p (4K)" \
        "1440p" \
        "1080p" \
        "720p" \
        "480p")

    local height=""

    case "$qual" in
        "2160p (4K)") height=2160 ;;
        "1440p")      height=1440 ;;
        "1080p")      height=1080 ;;
        "720p")       height=720 ;;
        "480p")       height=480 ;;
    esac

    local fmt

    if [[ -n "$height" ]]; then
        fmt="bv*[vcodec^=av01][height<=${height}]+ba[acodec^=opus]/bv*[height<=${height}]+ba/b"
    else
        fmt="bv*[vcodec^=av01]+ba[acodec^=opus]/bv*+ba/b"
    fi

    local outname outdir

    outname=$(ask "Output filename (no extension):" "$default_name")
    outdir=$(ask "Output directory:" "$PWD")

    mkdir -p "$outdir"

    local -a cookie_args=()
    local cookies_resolved=""

    if [[ -n "$COOKIES_FROM_BROWSER" ]]; then
        cookies_resolved=$(resolve_cookies_source "$COOKIES_FROM_BROWSER")
        cookie_args=(--cookies-from-browser "$cookies_resolved")
    fi

    local -a downloader_args=()

    if command -v aria2c >/dev/null && [[ "$USE_ARIA2" == true ]]; then
        downloader_args=(
            --downloader aria2c
            --downloader-args "aria2c:-x16 -s16 -k1M"
        )
    fi

    echo
    echo "${B}Plan:${R}"
    echo "  URL        : $url"
    echo "  Mode       : $mode"

    [[ -n "$start" ]] &&
        echo "  Section    : $start → $end"

    echo "  Resolution : ${height:+≤${height}p}"
    echo "  Codec pref : AV1 + Opus"
    echo "  Container  : MKV"

    if [[ ${#downloader_args[@]} -gt 0 ]]; then
        echo "  Downloader : aria2c (16 connections)"
    else
        echo "  Downloader : native"
    fi

    [[ -n "$COOKIES_FROM_BROWSER" ]] &&
        echo "  Cookies    : $cookies_resolved"

    echo "  Output     : $outdir/${outname}.mkv"

    echo

    confirm "Proceed?" || {
        warn "Aborted"
        exit 0
    }

    info "Downloading..."

    yt-dlp \
        "${cookie_args[@]}" \
        "${downloader_args[@]}" \
        -f "$fmt" \
        -S "codec:av01,res,fps,hdr:12,acodec:opus" \
        --merge-output-format mkv \
        --embed-metadata \
        --embed-thumbnail \
        --embed-subs \
        --write-auto-subs \
        --sub-langs "en.*" \
        --sponsorblock-remove sponsor \
        --no-playlist \
        --no-overwrites \
        --retries 20 \
        --fragment-retries 20 \
        --extractor-retries infinite \
        --socket-timeout 30 \
        --throttled-rate 100K \
        --remote-components ejs:github \
        --downloader-args "ffmpeg_i:-reconnect 1 -reconnect_streamed 1 -reconnect_delay_max 30 -reconnect_on_network_error 1" \
        "${sec_args[@]}" \
        -o "$outdir/${outname}.%(ext)s" \
        "$url"

    local outfile="$outdir/${outname}.mkv"

    echo

    [[ -f "$outfile" ]] || die "Download failed"

    ok "Saved → $outfile"

    echo "${D}Size: $(du -h "$outfile" | cut -f1)${R}"

    if command -v ffprobe >/dev/null; then

        local actual_sec expected_sec=""

        actual_sec=$(ffprobe -v error \
            -show_entries format=duration \
            -of csv=p=0 "$outfile" 2>/dev/null || echo "")

        if [[ -n "$start" && -n "$end" ]]; then
            expected_sec=$(awk \
                -v s="$(to_seconds "$start")" \
                -v e="$(to_seconds "$end")" \
                'BEGIN{print e-s}')
        elif [[ -n "$raw_duration" ]]; then
            expected_sec=$(to_seconds "$raw_duration")
        fi

        if [[ -n "$actual_sec" && -n "$expected_sec" ]]; then

            if awk -v a="$actual_sec" -v e="$expected_sec" 'BEGIN{exit !(a < e - 5)}'; then
                warn "Output shorter than expected"
                printf "${D}  got %.1fs, expected ~%.0fs${R}\n" \
                    "$actual_sec" "$expected_sec"
            else
                printf "${D}Integrity OK (%.1fs, expected ~%.0fs)${R}\n" \
                    "$actual_sec" "$expected_sec"
            fi
        fi
    fi
}

main "$@"
