#!/usr/bin/env bash
# yt-grab — Interactive YouTube downloader
# Fedora/Linux with yt-dlp + ffmpeg + aria2c
#
# v13 — clip duration metadata properly fixed via post-download remux pass
#       (the previous versions only papered over the symptom)

set -Eeuo pipefail

# ─────────────────────────────────────────────────────────────
# USER CONFIG
# ─────────────────────────────────────────────────────────────

COOKIES_FROM_BROWSER="${COOKIES_FROM_BROWSER:-brave}"
DEFAULT_RESOLUTION_MENU_INDEX=4    # 1080p
USE_ARIA2=true                     # full-video mode only
KEEP_TEMP_FILES=false

# Container per mode. MP4's per-track mdhd tracks duration from sample
# counts, which survives the section-download stream-copy quirk better
# than MKV's single SegmentInfo Duration element. Switch to "mkv" here
# if your player has AV1/Opus-in-MP4 issues.
CLIP_CONTAINER="mp4"
FULL_CONTAINER="mkv"

# Clip boundary tolerance: ffmpeg cuts at the nearest keyframe, so the
# real clip can be a second or two off from the requested range. Mark
# the result OK if it's within this window.
CLIP_TOLERANCE_SEC=2

# ─────────────────────────────────────────────────────────────
# STYLING
# ─────────────────────────────────────────────────────────────

B=$'\e[1m'; D=$'\e[2m'; R=$'\e[0m'
RED=$'\e[31m'; GRN=$'\e[32m'; YLW=$'\e[33m'; BLU=$'\e[34m'; CYN=$'\e[36m'

banner() {
cat <<EOF

${CYN}${B}╔════════════════════════════════════════════╗
║   yt-grab :: YouTube Downloader            ║
╚════════════════════════════════════════════╝${R}

EOF
}

die()  { echo "${RED}✗${R} $*" >&2; exit 1; }
info() { echo "${BLU}::${R} $*"; }
ok()   { echo "${GRN}✓${R} $*"; }
warn() { echo "${YLW}!${R} $*" >&2; }

# Friendly Ctrl-C: don't dump a traceback, just exit cleanly.
trap 'echo; warn "Interrupted"; exit 130' INT TERM

# ─────────────────────────────────────────────────────────────
# DEPENDENCIES
# ─────────────────────────────────────────────────────────────

check_deps() {
    command -v yt-dlp  >/dev/null || die "yt-dlp not found"
    command -v ffmpeg  >/dev/null || die "ffmpeg not found"
    command -v ffprobe >/dev/null || die "ffprobe not found"

    if [[ "$USE_ARIA2" == true ]] && ! command -v aria2c >/dev/null; then
        warn "aria2c not found — full-video mode will use native downloader"
    fi

    ok "Dependencies OK"
}

# ─────────────────────────────────────────────────────────────
# INPUT HELPERS
# ─────────────────────────────────────────────────────────────

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
    local msg="$1" default="$2"; shift 2
    local -a opts=("$@")
    local pick i=1

    printf '%s?%s %s\n' "$B" "$R" "$msg" >&2
    for o in "${opts[@]}"; do
        if (( i == default )); then
            printf '   %s%d)%s %s %s(default)%s\n' \
                "$CYN" "$i" "$R" "$o" "$D" "$R" >&2
        else
            printf '   %s%d)%s %s\n' "$CYN" "$i" "$R" "$o" >&2
        fi
        ((i++))
    done

    while true; do
        read -r -p "  > " pick
        [[ -z "$pick" ]] && pick="$default"
        if [[ "$pick" =~ ^[0-9]+$ ]] && (( pick >= 1 && pick <= ${#opts[@]} )); then
            printf '%s\n' "${opts[$((pick-1))]}"
            return
        fi
        warn "Pick 1-${#opts[@]}"
    done
}

confirm() {
    local msg="$1" default="${2:-y}" yn hint
    [[ "$default" == "y" ]] && hint="Y/n" || hint="y/N"
    read -r -p "${B}?${R} $msg ${D}[$hint]${R} " yn
    yn="${yn,,}"; [[ -z "$yn" ]] && yn="$default"
    [[ "$yn" == "y" || "$yn" == "yes" ]]
}

# ─────────────────────────────────────────────────────────────
# VALIDATION & TIME UTILITIES
# ─────────────────────────────────────────────────────────────

valid_time() {
    [[ "$1" =~ ^([0-9]+:)?([0-9]+:)?[0-9]+(\.[0-9]+)?$ ]]
}

sanitize() {
    printf '%s' "$1" \
        | sed 's#[/:*?"<>|\\]##g' \
        | tr -s '[:space:]' '_' \
        | sed 's/^_//;s/_$//' \
        | cut -c1-120
}

to_seconds() {
    awk -v t="$1" 'BEGIN {
        n = split(t, a, ":")
        if (n == 3)      print a[1]*3600 + a[2]*60 + a[3]
        else if (n == 2) print a[1]*60 + a[2]
        else             print a[1]
    }'
}

# 12:50 -> 12-50, 1:23:45 -> 1-23-45 (filename-safe)
compact_time() { printf '%s' "$1" | tr ':' '-'; }

# ─────────────────────────────────────────────────────────────
# COOKIE SOURCE RESOLUTION
# ─────────────────────────────────────────────────────────────

resolve_cookies_source() {
    local src="$1"
    [[ "$src" == *:* ]] && { printf '%s\n' "$src"; return; }

    case "$src" in
        brave)
            local roots=(
                "$HOME/.config/BraveSoftware"
                "$HOME/.var/app/com.brave.Browser/config/BraveSoftware"
            )
            local best="" best_mtime=0 root channel mtime
            for root in "${roots[@]}"; do
                [[ -d "$root" ]] || continue
                for channel in "$root"/*/; do
                    [[ -f "${channel}Default/Cookies" ]] || continue
                    mtime=$(stat -c %Y "${channel}Default/Cookies" \
                        2>/dev/null || echo 0)
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

# ─────────────────────────────────────────────────────────────
# FORMAT SELECTOR
# ─────────────────────────────────────────────────────────────

build_format() {
    local height="$1"
    case "$height" in
        480)  printf 'bv*[height<=480][tbr<=1200]+ba/b[height<=480]\n' ;;
        720)  printf 'bv*[height<=720][tbr<=2500]+ba/b[height<=720]\n' ;;
        1080) printf 'bv*[height<=1080][tbr<=5000]+ba/b[height<=1080]\n' ;;
        1440) printf 'bv*[height<=1440][tbr<=9000]+ba/b[height<=1440]\n' ;;
        2160) printf 'bv*[height<=2160][tbr<=18000]+ba/b[height<=2160]\n' ;;
        *)    printf 'bv*+ba/b\n' ;;
    esac
}

# Codec preference. MP4 plays Opus fine in modern players but some
# legacy ones don't, so prefer AAC there.
build_sort_string() {
    local container="$1"
    if [[ "$container" == "mp4" ]]; then
        printf 'res,fps,hdr:12,vcodec:av01,vcodec:vp9.2,vcodec:vp9,acodec:mp4a,acodec:opus\n'
    else
        printf 'res,fps,hdr:12,vcodec:av01,vcodec:vp9.2,vcodec:vp9,acodec:opus\n'
    fi
}

# ─────────────────────────────────────────────────────────────
# CLEANUP
# ─────────────────────────────────────────────────────────────

cleanup_temp() {
    [[ "$KEEP_TEMP_FILES" == true ]] && return
    local base="$1"
    rm -f \
        "${base}".*.vtt \
        "${base}".*.srt \
        "${base}".webp \
        "${base}".png \
        "${base}".part* \
        "${base}".temp.* \
        2>/dev/null || true
}

# ─────────────────────────────────────────────────────────────
# CLIP DURATION REPAIR
# ─────────────────────────────────────────────────────────────
#
# Why this exists:
#
# When yt-dlp does a section download with --downloader ffmpeg, ffmpeg
# stream-copies the packets covering [start, end] of the DASH stream.
# The packets carry their original PTS values, so MKV's SegmentInfo
# Duration ends up being max_pts (which is the original `end` timestamp,
# e.g. 1045s) instead of (end - start). The actual sample data is the
# correct length — only the container's reported duration is wrong.
#
# A one-shot remux with +genpts regenerates PTS from packet order, and
# -avoid_negative_ts make_zero anchors the first frame at 0. After this
# pass ffprobe sees the real clip length and every player respects it.
#
# This is fast (no re-encode, just remux) and runs in 1-2 seconds.

repair_clip_duration() {
    local file="$1"
    local ext="${file##*.}"
    local tmp="${file%.${ext}}.fix.${ext}"

    info "Repairing clip duration metadata..."

    # -movflags +faststart only meaningful for MP4 (moves moov to head)
    local -a mov_args=()
    [[ "$ext" == "mp4" ]] && mov_args=(-movflags +faststart)

    if ffmpeg -y -v error \
        -fflags +genpts \
        -i "$file" \
        -map 0 \
        -c copy \
        -avoid_negative_ts make_zero \
        "${mov_args[@]}" \
        "$tmp"; then
        mv -f "$tmp" "$file"
        ok "Duration metadata repaired"
    else
        rm -f "$tmp"
        warn "Repair pass failed — content is correct, only the reported duration may be off"
    fi
}

# ─────────────────────────────────────────────────────────────
# DURATION REPORT
# ─────────────────────────────────────────────────────────────

# Pulls stream-level duration (computed from packet timestamps) AND
# format-level duration (container header). When the bug bites these
# disagree; when everything's healthy they match.
probe_durations() {
    local file="$1"
    local stream_sec format_sec

    stream_sec=$(ffprobe -v error \
        -select_streams v:0 \
        -show_entries stream=duration \
        -of csv=p=0 \
        "$file" | head -n1)

    format_sec=$(ffprobe -v error \
        -show_entries format=duration \
        -of csv=p=0 \
        "$file" | head -n1)

    printf '%s %s\n' "${stream_sec:-0}" "${format_sec:-0}"
}

# ─────────────────────────────────────────────────────────────
# MAIN
# ─────────────────────────────────────────────────────────────

main() {
    banner
    check_deps
    echo

    # ── 1. URL ───────────────────────────────────────────────
    local url
    url=$(ask "YouTube URL:")
    [[ -n "$url" ]] || die "URL required"

    # ── 2. Metadata ──────────────────────────────────────────
    info "Resolving video metadata..."
    local meta raw_title raw_duration default_name
    meta=$(yt-dlp \
        --no-playlist \
        --print "%(title)s" \
        --print "%(duration_string)s" \
        "$url" 2>/dev/null || true)

    raw_title=$(printf '%s\n' "$meta" | sed -n '1p')
    raw_duration=$(printf '%s\n' "$meta" | sed -n '2p')
    default_name=$(sanitize "${raw_title:-video}")

    [[ -n "$raw_title"    ]] && echo "${D}   title:    $raw_title${R}"
    [[ -n "$raw_duration" ]] && echo "${D}   duration: $raw_duration${R}"

    # ── 3. Mode ──────────────────────────────────────────────
    local mode
    mode=$(menu "Download what?" 1 "Full video" "Section (time range)")

    local clip_mode=false
    local start="" end=""
    local container="$FULL_CONTAINER"

    if [[ "$mode" == "Section (time range)" ]]; then
        clip_mode=true
        container="$CLIP_CONTAINER"

        # start
        while true; do
            start=$(ask "Start time:" "0:00")
            valid_time "$start" && break
            warn "Invalid time format (use s, m:s, or h:m:s)"
        done

        # end: must be > start and (if known) <= total duration
        while true; do
            end=$(ask "End time:" "$raw_duration")
            if ! valid_time "$end"; then
                warn "Invalid time format"; continue
            fi
            if (( $(to_seconds "$end") <= $(to_seconds "$start") )); then
                warn "End must be after start"; continue
            fi
            if [[ -n "$raw_duration" ]] \
                && (( $(to_seconds "$end") > $(to_seconds "$raw_duration") )); then
                warn "End ($end) exceeds video length ($raw_duration)"; continue
            fi
            break
        done

        # Bake range into the default filename so a clip and a full
        # download (or two different clips) don't fight for the same
        # path and trigger yt-dlp's "already downloaded" skip.
        default_name="${default_name}_$(compact_time "$start")-$(compact_time "$end")"
    fi

    # ── 4. Quality ───────────────────────────────────────────
    local qual height fmt sort_string
    qual=$(menu "Max resolution?" "$DEFAULT_RESOLUTION_MENU_INDEX" \
        "Best available" "2160p (4K)" "1440p" "1080p" "720p" "480p")

    case "$qual" in
        "2160p (4K)") height=2160 ;;
        "1440p")      height=1440 ;;
        "1080p")      height=1080 ;;
        "720p")       height=720  ;;
        "480p")       height=480  ;;
        *)            height=""   ;;
    esac

    fmt=$(build_format "$height")
    sort_string=$(build_sort_string "$container")

    # ── 5. Output ────────────────────────────────────────────
    local outname outdir
    outname=$(ask "Output filename (no extension):" "$default_name")
    outdir=$(ask "Output directory:" "$PWD")
    mkdir -p "$outdir"

    # Pre-clean stale artefacts in clip mode. Without this, an existing
    # .mkv/.mp4 with the same name causes yt-dlp to skip the actual
    # download and post-process the wrong file.
    if [[ "$clip_mode" == true ]]; then
        rm -f "$outdir/${outname}".* 2>/dev/null || true
    fi

    # ── 6. Cookies ───────────────────────────────────────────
    local -a cookie_args=()
    local cookies_resolved=""
    if [[ -n "$COOKIES_FROM_BROWSER" ]]; then
        cookies_resolved=$(resolve_cookies_source "$COOKIES_FROM_BROWSER")
        cookie_args=(--cookies-from-browser "$cookies_resolved")
    fi

    # ── 7. Downloader (aria2c for full mode only) ────────────
    local -a downloader_args=()
    local downloader_label="ffmpeg (section)"
    if [[ "$clip_mode" == false ]]; then
        if [[ "$USE_ARIA2" == true ]] && command -v aria2c >/dev/null; then
            downloader_args=(
                --downloader aria2c
                --downloader-args "aria2c:-x16 -s16 -k1M"
            )
            downloader_label="aria2c (16 connections)"
        else
            downloader_label="native"
        fi
    fi

    # ── 8. Plan ──────────────────────────────────────────────
    echo
    echo "${B}Plan:${R}"
    printf '  %-13s : %s\n' "URL" "$url"
    printf '  %-13s : %s\n' "Mode" "$mode"
    [[ -n "$start" ]] && printf '  %-13s : %s → %s\n' "Section" "$start" "$end"
    printf '  %-13s : %s\n' "Resolution" "${height:+≤${height}p}"
    printf '  %-13s : %s\n' "Container" "${container^^}"
    printf '  %-13s : %s\n' "Thumbnail" "Embedded JPG"
    if [[ "$clip_mode" == true ]]; then
        printf '  %-13s : %s\n' "Clip pipeline" "section → repair PTS"
        printf '  %-13s : %s\n' "SponsorBlock" "disabled (clip-safe)"
    else
        printf '  %-13s : %s\n' "SponsorBlock" "enabled"
    fi
    printf '  %-13s : %s\n' "Downloader" "$downloader_label"
    [[ -n "$cookies_resolved" ]] \
        && printf '  %-13s : %s\n' "Cookies" "$cookies_resolved"
    printf '  %-13s : %s\n' "Output" "$outdir"
    echo

    confirm "Proceed?" || { warn "Aborted"; exit 0; }

    info "Downloading..."

    # ── 9. yt-dlp ───────────────────────────────────────────
    #
    # Two separate invocations because clip and full mode want different
    # downloaders, different overwrite behaviour, different sponsor
    # handling, and a different remux/merge step. One conditional-array
    # mega-command is harder to read than two focused ones.

    if [[ "$clip_mode" == true ]]; then
        yt-dlp \
            "${cookie_args[@]}" \
            --downloader ffmpeg \
            --download-sections "*${start}-${end}" \
            --force-overwrites \
            -f "$fmt" \
            -S "$sort_string" \
            --remux-video "$container" \
            --embed-metadata \
            --embed-thumbnail \
            --convert-thumbnails jpg \
            --embed-subs \
            --write-auto-subs \
            --sub-langs "en.*" \
            --parse-metadata "title:%(meta_title)s" \
            --no-playlist \
            --retries infinite \
            --fragment-retries infinite \
            --extractor-retries infinite \
            --file-access-retries infinite \
            --retry-sleep 3 \
            --socket-timeout 30 \
            --remote-components ejs:github \
            --compat-options no-live-chat \
            -o "$outdir/${outname}.%(ext)s" \
            "$url"
    else
        yt-dlp \
            "${cookie_args[@]}" \
            "${downloader_args[@]}" \
            --concurrent-fragments 8 \
            --sponsorblock-remove sponsor \
            --continue \
            --no-overwrites \
            -f "$fmt" \
            -S "$sort_string" \
            --merge-output-format "$container" \
            --embed-metadata \
            --embed-thumbnail \
            --convert-thumbnails jpg \
            --embed-subs \
            --write-auto-subs \
            --sub-langs "en.*" \
            --parse-metadata "title:%(meta_title)s" \
            --no-playlist \
            --retries infinite \
            --fragment-retries infinite \
            --extractor-retries infinite \
            --file-access-retries infinite \
            --retry-sleep 3 \
            --socket-timeout 30 \
            --http-chunk-size 10M \
            --remote-components ejs:github \
            --compat-options no-live-chat \
            -o "$outdir/${outname}.%(ext)s" \
            "$url"
    fi
    echo

    local outfile="$outdir/${outname}.${container}"
    [[ -f "$outfile" ]] || die "Download failed — expected $outfile"

    cleanup_temp "$outdir/$outname"

    # ── 10. Clip duration repair ─────────────────────────────
    if [[ "$clip_mode" == true ]]; then
        repair_clip_duration "$outfile"
    fi

    # ── 11. Report ───────────────────────────────────────────
    ok "Saved → $outfile"
    echo "${D}Size: $(du -h "$outfile" | cut -f1)${R}"

    read -r stream_sec format_sec <<<"$(probe_durations "$outfile")"

    if [[ "$clip_mode" == true ]]; then
        local expected_sec diff
        expected_sec=$(awk \
            -v s="$(to_seconds "$start")" \
            -v e="$(to_seconds "$end")" \
            'BEGIN{print e-s}')

        diff=$(awk -v a="$stream_sec" -v e="$expected_sec" \
            'BEGIN{d=a-e; if(d<0) d=-d; print d}')

        if awk -v d="$diff" -v t="$CLIP_TOLERANCE_SEC" \
            'BEGIN{exit !(d<=t)}'; then
            printf "${GRN}Clip OK${R} ${D}(stream=%.1fs, container=%.1fs, expected≈%.0fs)${R}\n" \
                "$stream_sec" "$format_sec" "$expected_sec"
        else
            warn "Duration mismatch: stream=${stream_sec}s container=${format_sec}s expected≈${expected_sec}s"
            echo "${D}Verify with: mpv \"$outfile\"${R}"
        fi
    else
        printf "${D}Duration: stream=%.1fs container=%.1fs${R}\n" \
            "$stream_sec" "$format_sec"
    fi

    echo
    ok "Done"
}

main "$@"
