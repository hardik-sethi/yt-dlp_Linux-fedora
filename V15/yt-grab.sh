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
MAX_RETRIES=10

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
        read -r -p "${B}?${R} $msg ${D}[$default]${R} " reply \
            || die "Input aborted"
        printf '%s\n' "${reply:-$default}"
    else
        read -r -p "${B}?${R} $msg " reply \
            || die "Input aborted"
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

        read -r -p "  > " pick \
            || die "Input aborted"

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

    read -r -p "${B}?${R} $msg ${D}[$hint]${R} " yn \
        || die "Input aborted"

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

# Float-safe comparison: returns 0 if a <= b, else 1.
time_le() {
    awk -v a="$1" -v b="$2" 'BEGIN{exit !(a<=b)}'
}

expand_tilde() {
    local p="$1"
    printf '%s' "${p/#\~/$HOME}"
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

            # Note: picks the Brave channel (Stable/Beta/Nightly) whose
            # Default profile has the most recently touched Cookies file.
            # If you use multiple profiles (Profile 1, Profile 2, …) you
            # may need to override via the env var, e.g.
            #   COOKIES_FROM_BROWSER='brave:/path/to/Profile 1'

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

    # yt-dlp writes subs as <base>.en.vtt, <base>.en-orig.vtt, etc.
    # The previous pattern "${base}".*.vtt expanded to <base>..*.vtt
    # (literal double-dot) and matched nothing. The patterns below have
    # no extra dot, so <base>*.vtt matches <base>.en.vtt correctly.

    rm -f \
        "${base}"*.vtt \
        "${base}"*.srt \
        "${base}".webp \
        "${base}".jpg \
        "${base}".png \
        "${base}".part \
        "${base}".*.part \
        2>/dev/null || true
}

# Find the produced output file under outdir/outname by trying known
# container extensions, in order of likelihood.
find_outfile() {

    local outdir="$1"
    local outname="$2"

    local ext

    for ext in mp4 mkv webm m4a opus; do

        if [[ -f "$outdir/${outname}.${ext}" ]]; then
            printf '%s\n' "$outdir/${outname}.${ext}"
            return 0
        fi
    done

    return 1
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

    default_name=$(sanitize "$raw_title")

    # Fallback after sanitize, in case the title was all special chars
    # (e.g. "///???") and sanitize stripped it to empty.
    [[ -z "$default_name" ]] && default_name="video"

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
    local -a fragment_args=()
    local -a sponsorblock_args=()
    local -a overwrite_args=()

    local start=""
    local end=""
    local clip_mode=false
    local container="mkv"

    if [[ "$mode" == "Section (time range)" ]]; then

        clip_mode=true
        container="mp4"

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

            # Use float-safe comparison; (( … )) with HH:MM:SS.mmm
            # values would otherwise choke on the decimal.
            if time_le "$(to_seconds "$end")" "$(to_seconds "$start")"; then
                warn "End time must be after start time"
                continue
            fi

            break
        done

        sec_args=(
            --downloader ffmpeg
            --download-sections "*${start}-${end}"
            --force-overwrites
        )

    else

        fragment_args=(
            --concurrent-fragments 8
        )

        sponsorblock_args=(
            --sponsorblock-remove sponsor
        )

        overwrite_args=(
            --continue
            --no-overwrites
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

    # Format selection: prefer the smaller Opus audio track, fall back
    # to any best audio. Removed the tbr caps — YouTube routinely serves
    # 1080p at 6-8 Mbps, and the old `tbr<=5000` filter kicked us into
    # the fallback branch instead of giving a clean merge.
    # Also dropped the hardcoded format-id 250 (opus ~70k); YouTube's
    # numeric IDs aren't a stable API, so we select by codec instead.
    local fmt=""

    if [[ -n "$height" ]]; then
        fmt="bv*[height<=${height}]+ba[acodec=opus]/bv*[height<=${height}]+ba/b[height<=${height}]"
    else
        fmt="bv*+ba[acodec=opus]/bv*+ba/b"
    fi

    local sort_string="res,fps,hdr:12,vcodec:av01,vcodec:vp9.2,vcodec:vp9,+size,+br,+aext"

    local outname
    local outdir

    outname=$(ask "Output filename (no extension):" "$default_name")
    outdir=$(ask "Output directory:" "$PWD")

    # ask() returns the raw string; bash does not expand ~ inside a
    # quoted variable, so "~/Videos" would be created as a literal
    # directory named "~". Expand manually.
    outdir=$(expand_tilde "$outdir")

    mkdir -p "$outdir"

    if [[ "$clip_mode" == true ]]; then
        # Scope cleanup to known media extensions, so an outname like
        # "video" doesn't nuke unrelated video.txt / video.bak.
        local ext
        for ext in mp4 mkv webm m4a opus part vtt srt jpg png webp; do
            rm -f "$outdir/${outname}.${ext}" 2>/dev/null || true
            rm -f "$outdir/${outname}".*."${ext}" 2>/dev/null || true
        done
    fi

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
       [[ "$USE_ARIA2" == true ]] &&
       [[ "$clip_mode" == false ]]; then

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
    echo "  Audio      : Opus preferred (smaller)"
    echo "  Container  : ${container^^}"
    echo "  Thumbnail  : Embedded JPG"

    if [[ "$clip_mode" == true ]]; then
        echo "  Clip Mode  : Accurate ffmpeg trimming"
        echo "  SponsorBlock : Disabled"
    else
        echo "  SponsorBlock : Enabled"
    fi

    if [[ ${#downloader_args[@]} -gt 0 ]]; then
        echo "  Downloader : aria2c (16 connections)"
    else
        echo "  Downloader : ffmpeg/native"
    fi

    [[ -n "$cookies_resolved" ]] \
        && echo "  Cookies    : $cookies_resolved"

    echo "  Output     : $outdir"

    echo

    confirm "Proceed?" || {
        warn "Aborted"
        exit 0
    }

    info "Downloading..."

    # Note on subtitles: --write-auto-subs + --embed-subs will both
    # embed and leave the external .vtt on disk. cleanup_temp() below
    # removes the leftover external files.

    if [[ "$clip_mode" == true ]]; then

        yt-dlp \
            "${cookie_args[@]}" \
            "${sec_args[@]}" \
            -f "$fmt" \
            -S "$sort_string" \
            --remux-video mp4 \
            --embed-metadata \
            --embed-thumbnail \
            --convert-thumbnails jpg \
            --embed-subs \
            --write-auto-subs \
            --sub-langs "en.*" \
            --parse-metadata "title:%(meta_title)s" \
            --no-playlist \
            --retries "$MAX_RETRIES" \
            --fragment-retries "$MAX_RETRIES" \
            --extractor-retries "$MAX_RETRIES" \
            --file-access-retries "$MAX_RETRIES" \
            --retry-sleep 3 \
            --socket-timeout 30 \
            --http-chunk-size 10M \
            -o "$outdir/${outname}.%(ext)s" \
            "$url"

    else

        yt-dlp \
            "${cookie_args[@]}" \
            "${downloader_args[@]}" \
            "${fragment_args[@]}" \
            "${sponsorblock_args[@]}" \
            "${overwrite_args[@]}" \
            -f "$fmt" \
            -S "$sort_string" \
            --merge-output-format mkv \
            --embed-metadata \
            --embed-thumbnail \
            --convert-thumbnails jpg \
            --embed-subs \
            --write-auto-subs \
            --sub-langs "en.*" \
            --parse-metadata "title:%(meta_title)s" \
            --no-playlist \
            --retries "$MAX_RETRIES" \
            --fragment-retries "$MAX_RETRIES" \
            --extractor-retries "$MAX_RETRIES" \
            --file-access-retries "$MAX_RETRIES" \
            --retry-sleep 3 \
            --socket-timeout 30 \
            --http-chunk-size 10M \
            --compat-options no-live-chat \
            -o "$outdir/${outname}.%(ext)s" \
            "$url"
    fi

    echo

    # Don't trust the assumed container — clip remux to mp4 can
    # silently end up as mkv depending on source codecs, and the
    # full-video path may pick webm. Find whatever actually landed.
    local outfile
    outfile=$(find_outfile "$outdir" "$outname") \
        || die "Download failed — no output file found"

    cleanup_temp "$outdir/$outname"

    ok "Saved → $outfile"

    echo "${D}Size: $(du -h "$outfile" | cut -f1)${R}"

    local actual_sec=""
    local expected_sec=""

    actual_sec=$(
        ffprobe \
            -v error \
            -select_streams v:0 \
            -show_entries stream=duration \
            -of csv=p=0 \
            "$outfile" \
            | head -n1
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
