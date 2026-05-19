#!/usr/bin/env bash
# yt-grab — Interactive YouTube downloader
# Optimized for Fedora/Linux with yt-dlp + ffmpeg + aria2c

set -Eeuo pipefail

# ─────────────────────────────────────────────────────────────
# USER CONFIG
# ─────────────────────────────────────────────────────────────

COOKIES_FROM_BROWSER="${COOKIES_FROM_BROWSER:-brave}"

DEFAULT_RESOLUTION_MENU_INDEX=4
USE_ARIA2=true
KEEP_TEMP_FILES=false

# ─────────────────────────────────────────────────────────────
# STYLING
# ─────────────────────────────────────────────────────────────

B=$'\e[1m'
D=$'\e[2m'
R=$'\e[0m'

RED=$'\e[31m'
GRN=$'\e[32m'
YLW=$'\e[33m'
BLU=$'\e[34m'
CYN=$'\e[36m'

banner() {
cat <<EOF

${CYN}${B}
╔════════════════════════════════════════════╗
║   yt-grab :: YouTube Downloader           ║
╚════════════════════════════════════════════╝
${R}

EOF
}

die() {
    echo "${RED}✗${R} $*" >&2
    exit 1
}

info() {
    echo "${BLU}::${R} $*"
}

ok() {
    echo "${GRN}✓${R} $*"
}

warn() {
    echo "${YLW}!${R} $*" >&2
}

# ─────────────────────────────────────────────────────────────
# DEPENDENCIES
# ─────────────────────────────────────────────────────────────

check_deps() {

    command -v yt-dlp >/dev/null \
        || die "yt-dlp not found"

    command -v ffmpeg >/dev/null \
        || die "ffmpeg not found"

    command -v ffprobe >/dev/null \
        || die "ffprobe not found"

    if [[ "$USE_ARIA2" == true ]]; then
        command -v aria2c >/dev/null \
            || warn "aria2c not found — using native downloader"
    fi

    ok "Dependencies OK"
}

# ─────────────────────────────────────────────────────────────
# HELPERS
# ─────────────────────────────────────────────────────────────

ask() {

    local msg="$1"
    local default="${2:-}"
    local reply

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

    local pick
    local i=1

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

        warn "pick 1-${#opts[@]}"
    done
}

confirm() {

    local msg="$1"
    local default="${2:-y}"

    local yn
    local hint

    [[ "$default" == "y" ]] \
        && hint="Y/n" \
        || hint="y/N"

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
    sed 's/^_//;s/_$//' |
    cut -c1-120
}

to_seconds() {

    awk -v t="$1" '
    BEGIN {
        n = split(t, a, ":")

        if (n == 3)
            print a[1]*3600 + a[2]*60 + a[3]
        else if (n == 2)
            print a[1]*60 + a[2]
        else
            print a[1]
    }'
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

            local root
            local channel
            local mtime

            for root in "${roots[@]}"; do

                [[ -d "$root" ]] || continue

                for channel in "$root"/*/; do

                    [[ -f "${channel}Default/Cookies" ]] || continue

                    mtime=$(
                        stat -c %Y "${channel}Default/Cookies" \
                        2>/dev/null || echo 0
                    )

                    if (( mtime > best_mtime )); then
                        best="${channel%/}"
                        best_mtime=$mtime
                    fi
                done
            done

            [[ -n "$best" ]] \
                && printf '%s:%s\n' "$src" "$best" \
                || printf '%s\n' "$src"
            ;;

        *)
            printf '%s\n' "$src"
            ;;
    esac
}

cleanup_temp() {

    [[ "$KEEP_TEMP_FILES" == true ]] && return

    local base="$1"

    rm -f \
        "${base}".*.vtt \
        "${base}".*.srt \
        "${base}".webp \
        "${base}".jpg \
        "${base}".png \
        "${base}".part* \
        2>/dev/null || true
}

detect_container() {

    local codec="$1"

    case "$codec" in
        av01|vp9)
            printf '%s\n' "mkv"
            ;;
        *)
            printf '%s\n' "mp4"
            ;;
    esac
}

# ─────────────────────────────────────────────────────────────
# MAIN
# ─────────────────────────────────────────────────────────────

main() {

    banner

    check_deps

    echo

    local url

    url=$(ask "YouTube URL:")

    [[ -n "$url" ]] \
        || die "URL required"

    info "Resolving video metadata..."

    local meta
    local raw_title
    local raw_duration
    local default_name

    meta=$(
        yt-dlp \
            --no-playlist \
            --print "%(title)s" \
            --print "%(duration_string)s" \
            "$url" 2>/dev/null || true
    )

    raw_title=$(printf '%s\n' "$meta" | sed -n '1p')
    raw_duration=$(printf '%s\n' "$meta" | sed -n '2p')

    default_name=$(sanitize "${raw_title:-video}")

    [[ -n "$raw_title" ]] \
        && echo "${D}   title:    $raw_title${R}"

    [[ -n "$raw_duration" ]] \
        && echo "${D}   duration: $raw_duration${R}"

    local mode

    mode=$(
        menu "Download what?" 1 \
            "Full video" \
            "Section (time range)"
    )

    local -a sec_args=()

    local start=""
    local end=""

    if [[ "$mode" == "Section (time range)" ]]; then

        while true; do

            start=$(ask "Start time:" "0:00")

            valid_time "$start" \
                && break

            warn "Invalid time format"
        done

        while true; do

            end=$(ask "End time:" "$raw_duration")

            valid_time "$end" \
                || {
                    warn "Invalid time format"
                    continue
                }

            if (( $(to_seconds "$end") <= $(to_seconds "$start") )); then
                warn "End time must be after start time"
                continue
            fi

            break
        done

        sec_args=(
            --download-sections "*${start}-${end}"
        )
    fi

    local qual

    qual=$(
        menu "Max resolution?" "$DEFAULT_RESOLUTION_MENU_INDEX" \
            "Best available" \
            "2160p (4K)" \
            "1440p" \
            "1080p" \
            "720p" \
            "480p"
    )

    local height=""

    case "$qual" in
        "2160p (4K)") height=2160 ;;
        "1440p") height=1440 ;;
        "1080p") height=1080 ;;
        "720p") height=720 ;;
        "480p") height=480 ;;
    esac

    local video_codec="av01"

    local fmt=""

    if [[ -n "$height" ]]; then
        fmt="bv*[vcodec^=${video_codec}][height<=${height}]+ba/bv*[height<=${height}]+ba/b"
    else
        fmt="bv*[vcodec^=${video_codec}]+ba/bv*+ba/b"
    fi

    local container

    container=$(detect_container "$video_codec")

    local outname
    local outdir

    outname=$(ask "Output filename (no extension):" "$default_name")
    outdir=$(ask "Output directory:" "$PWD")

    mkdir -p "$outdir"

    local outfile="$outdir/${outname}.${container}"

    local -a cookie_args=()
    local cookies_resolved=""

    if [[ -n "$COOKIES_FROM_BROWSER" ]]; then

        cookies_resolved=$(
            resolve_cookies_source "$COOKIES_FROM_BROWSER"
        )

        cookie_args=(
            --cookies-from-browser "$cookies_resolved"
        )
    fi

    local -a downloader_args=()

    if command -v aria2c >/dev/null &&
       [[ "$USE_ARIA2" == true ]]; then

        downloader_args=(
            --downloader aria2c
            --downloader-args "aria2c:-x16 -s16 -k1M"
        )
    fi

    echo
    echo "${B}Plan:${R}"

    echo "  URL        : $url"
    echo "  Mode       : $mode"

    [[ -n "$start" ]] \
        && echo "  Section    : $start → $end"

    echo "  Resolution : ${height:+≤${height}p}"
    echo "  Video      : AV1 preferred"
    echo "  Audio      : AAC preferred"
    echo "  Container  : $container"

    if [[ ${#downloader_args[@]} -gt 0 ]]; then
        echo "  Downloader : aria2c (16 connections)"
    else
        echo "  Downloader : native"
    fi

    [[ -n "$cookies_resolved" ]] \
        && echo "  Cookies    : $cookies_resolved"

    echo "  Output     : $outfile"

    echo

    confirm "Proceed?" || {
        warn "Aborted"
        exit 0
    }

    info "Downloading..."

    yt-dlp \
        "${cookie_args[@]}" \
        "${downloader_args[@]}" \
        "${sec_args[@]}" \
        -f "$fmt" \
        -S "codec:h264,res,fps,acodec:aac" \
        --embed-metadata \
        --embed-thumbnail \
        --embed-subs \
        --write-auto-subs \
        --sub-langs "en.*" \
        --sponsorblock-remove sponsor \
        --convert-thumbnails webp \
        --parse-metadata "title:%(meta_title)s" \
        --no-playlist \
        --no-overwrites \
        --continue \
        --concurrent-fragments 8 \
        --retries infinite \
        --fragment-retries infinite \
        --extractor-retries infinite \
        --file-access-retries infinite \
        --retry-sleep 3 \
        --socket-timeout 30 \
        --http-chunk-size 10M \
        --remote-components ejs:github \
        --compat-options no-live-chat \
        --downloader-args "ffmpeg_i:-reconnect 1 -reconnect_streamed 1 -reconnect_delay_max 30 -reconnect_on_network_error 1" \
        -o "$outdir/${outname}.%(ext)s" \
        "$url"

    echo

    [[ -f "$outfile" ]] || {

        local detected_file

        detected_file=$(
            find "$outdir" \
                -maxdepth 1 \
                -type f \
                -name "${outname}.*" \
                | head -n1
        )

        [[ -n "$detected_file" ]] \
            && outfile="$detected_file" \
            || die "Download failed"
    }

    cleanup_temp "$outdir/$outname"

    ok "Saved → $outfile"

    echo "${D}Size: $(du -h "$outfile" | cut -f1)${R}"

    local actual_sec=""
    local expected_sec=""

    actual_sec=$(
        ffprobe \
            -v error \
            -show_entries format=duration \
            -of default=noprint_wrappers=1:nokey=1 \
            "$outfile"
    )

    if [[ -n "$start" && -n "$end" ]]; then

        expected_sec=$(
            awk \
                -v s="$(to_seconds "$start")" \
                -v e="$(to_seconds "$end")" \
                'BEGIN{print e-s}'
        )

        printf \
            "${GRN}Clip OK${R} ${D}(%.1fs expected ~%.0fs)${R}\n" \
            "$actual_sec" \
            "$expected_sec"
    fi

    echo

    ok "Done"
}

main "$@"
