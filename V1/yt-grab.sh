#!/usr/bin/env bash
# yt-grab — Interactive YouTube downloader, AV1 stream-copy (no re-encode)
# Built for Fedora; works on any Linux with yt-dlp + ffmpeg installed.
#
# Output: MKV containing AV1 video + Opus audio, copied byte-for-byte from
# YouTube's streams. No transcode → lossless, fast, GPU/CPU stays idle.
# Falls back to VP9/other codecs only if AV1 isn't offered at the chosen res.
#
# Usage: chmod +x yt-grab.sh && ./yt-grab.sh

set -euo pipefail

# ── styling ────────────────────────────────────────────────────────────────
B=$'\e[1m'; D=$'\e[2m'; R=$'\e[0m'
RED=$'\e[31m'; GRN=$'\e[32m'; YLW=$'\e[33m'; BLU=$'\e[34m'; CYN=$'\e[36m'

banner() {
cat <<EOF
${CYN}${B}
╔════════════════════════════════════════════╗
║  yt-grab :: YouTube → AV1 (stream copy)    ║
╚════════════════════════════════════════════╝
${R}
EOF
}

die()  { echo "${RED}✗${R} $*" >&2; exit 1; }
info() { echo "${BLU}::${R} $*"; }
ok()   { echo "${GRN}✓${R} $*"; }
warn() { echo "${YLW}!${R} $*"; }

# ── deps check ─────────────────────────────────────────────────────────────
check_deps() {
    command -v yt-dlp >/dev/null \
        || die "yt-dlp not found. Install: pipx install yt-dlp"
    # ffmpeg is still needed: yt-dlp uses it to mux the video+audio streams
    # AND as the downloader for --download-sections (so reconnect args go to it).
    command -v ffmpeg >/dev/null \
        || die "ffmpeg not found. Install: sudo dnf install ffmpeg"
    ok "yt-dlp + ffmpeg present"
}

# ── input helpers ──────────────────────────────────────────────────────────
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
    local msg="$1"; shift
    local -a opts=("$@")
    local pick i=1
    printf '%s?%s %s\n' "$B" "$R" "$msg" >&2
    for o in "${opts[@]}"; do
        printf '   %s%d)%s %s\n' "$CYN" "$i" "$R" "$o" >&2
        ((i++))
    done
    while true; do
        read -r -p "  > " pick
        if [[ "$pick" =~ ^[0-9]+$ ]] && (( pick >= 1 && pick <= ${#opts[@]} )); then
            printf '%s\n' "${opts[$((pick-1))]}"
            return
        fi
        warn "pick 1-${#opts[@]}" >&2
    done
}

# Y/n prompt. Empty input picks the default.
# Usage: confirm "Proceed?"        → default yes
#        confirm "Are you sure?" n → default no
# Returns 0 on yes, 1 on no.
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
    printf '%s' "$1" | tr -d '/\\' | tr -s '[:space:]' '_' | cut -c1-100
}

# Compare two decimal-second values; echo non-zero if diff > $3 seconds.
duration_diff_exceeds() {
    awk -v a="$1" -v b="$2" -v t="$3" 'BEGIN{
        d = a - b; if (d < 0) d = -d
        exit !(d > t)
    }'
}

# ── main flow ──────────────────────────────────────────────────────────────
main() {
    banner
    check_deps
    echo

    # URL ─────────────────────────────────────────────────────────────────
    local url
    url=$(ask "YouTube URL:")
    [[ -n "$url" ]] || die "url required"

    # Metadata up front: title (for default filename) + duration (for default
    # end-time when section-cutting). Single yt-dlp call.
    info "Resolving video metadata..."
    local meta raw_title raw_duration default_name
    meta=$(yt-dlp --no-playlist \
                  --print "%(title)s" \
                  --print "%(duration_string)s" \
                  "$url" 2>/dev/null || true)
    raw_title=$(printf '%s\n'    "$meta" | sed -n '1p')
    raw_duration=$(printf '%s\n' "$meta" | sed -n '2p')
    default_name=$(sanitize "${raw_title:-video}")
    [[ -n "$raw_title"    ]] && echo "${D}   title:    $raw_title${R}"
    [[ -n "$raw_duration" ]] && echo "${D}   duration: $raw_duration${R}"

    # Mode ────────────────────────────────────────────────────────────────
    local mode
    mode=$(menu "Download what?" "Full video" "Section (time range)")

    local -a sec_args=()
    local start="" end=""
    if [[ "$mode" == "Section (time range)" ]]; then
        while true; do
            start=$(ask "Start time (HH:MM:SS / MM:SS / seconds):" "0:00")
            valid_time "$start" && break
            warn "bad time format"
        done
        # End-time defaults to the video's full duration (= "go to the end")
        # when known; otherwise we just ask for a time and won't accept empty.
        local end_prompt
        if [[ -n "$raw_duration" ]]; then
            end_prompt="End time (Enter = end of video):"
        else
            end_prompt="End time (HH:MM:SS / MM:SS / seconds):"
        fi
        while true; do
            end=$(ask "$end_prompt" "${raw_duration:-}")
            valid_time "$end" && break
            warn "bad time format"
        done
        # No --force-keyframes-at-cuts: that triggers a CPU re-encode and
        # negates the whole point of stream-copying. Cuts align to nearest
        # keyframe (typically <2s imprecision at boundaries).
        sec_args=(--download-sections "*${start}-${end}")
    fi

    # Resolution ──────────────────────────────────────────────────────────
    local qual
    qual=$(menu "Max resolution?" \
        "Best available" "2160p (4K)" "1440p" "1080p" "720p" "480p")
    local height=""
    case "$qual" in
        "2160p (4K)") height=2160 ;;
        "1440p")      height=1440 ;;
        "1080p")      height=1080 ;;
        "720p")       height=720  ;;
        "480p")       height=480  ;;
    esac
    local fmt
    if [[ -n "$height" ]]; then
        fmt="bv*[height<=${height}]+ba/b[height<=${height}]"
    else
        fmt="bv*+ba/b"
    fi

    # Output name + dir ───────────────────────────────────────────────────
    local outname outdir
    outname=$(ask "Output filename (no extension):" "$default_name")
    outdir=$(ask "Output directory:" "$PWD")
    mkdir -p "$outdir"

    # Summary + confirm ───────────────────────────────────────────────────
    echo
    echo "${B}Plan:${R}"
    echo "  URL        : $url"
    echo "  Mode       : $mode"
    [[ -n "$start" ]] && echo "  Section    : $start → $end"
    local res_label="${height:+≤${height}p}"
    echo "  Resolution : ${res_label:-best available}"
    echo "  Codec pref : AV1 video + Opus audio (stream copy, no re-encode)"
    echo "  Container  : MKV"
    echo "  Output     : $outdir/${outname}.mkv"
    echo
    confirm "Proceed?" || { warn "aborted"; exit 0; }

    # Download ────────────────────────────────────────────────────────────
    info "Downloading (stream-copy, no transcode)..."
    # Reconnect args go to FFMPEG, which is what yt-dlp actually uses to fetch
    # --download-sections. Without these, a TLS reset silently truncates output.
    #   -reconnect 1                   : enable reconnect logic
    #   -reconnect_streamed 1          : reconnect for streamed (non-seekable) input
    #   -reconnect_delay_max 30        : wait up to 30s between retries
    #   -reconnect_on_network_error 1  : reconnect on ECONNRESET et al (ffmpeg 6+)
    # The --remote-components flag lets yt-dlp fetch its JS challenge solver
    # components from GitHub (cached after first run). Removes the [jsc] warning
    # and unlocks formats that need JS deciphering. Remove if you'd rather not
    # auto-download from GitHub.
    yt-dlp \
        -f "$fmt" \
        -S "vcodec:av01,acodec:opus" \
        --merge-output-format mkv \
        --no-playlist \
        --retries 10 \
        --fragment-retries 10 \
        --socket-timeout 30 \
        --remote-components ejs:github \
        --downloader-args "ffmpeg_i:-reconnect 1 -reconnect_streamed 1 -reconnect_delay_max 30 -reconnect_on_network_error 1" \
        "${sec_args[@]}" \
        -o "$outdir/${outname}.%(ext)s" \
        "$url"

    local outfile="$outdir/${outname}.mkv"
    echo
    if [[ ! -f "$outfile" ]]; then
        warn "Expected $outfile but didn't find it — check yt-dlp output above."
        exit 1
    fi
    ok "Saved → $outfile"
    echo "${D}Size: $(du -h "$outfile" | cut -f1)${R}"

    # Integrity check: compare video and audio stream durations. A meaningful
    # mismatch usually means a stream got truncated mid-download (network blip
    # that even reconnect couldn't recover from).
    if command -v ffprobe >/dev/null; then
        local v_dur a_dur
        v_dur=$(ffprobe -v error -select_streams v:0 \
                -show_entries stream=duration -of csv=p=0 "$outfile" 2>/dev/null || echo "")
        a_dur=$(ffprobe -v error -select_streams a:0 \
                -show_entries stream=duration -of csv=p=0 "$outfile" 2>/dev/null || echo "")
        if [[ -n "$v_dur" && -n "$a_dur" ]]; then
            if duration_diff_exceeds "$v_dur" "$a_dur" 2; then
                echo
                warn "Stream-duration mismatch detected!"
                echo "${D}  video: ${v_dur}s   audio: ${a_dur}s${R}"
                echo "${D}  Output is likely truncated. Try re-running.${R}"
            else
                echo "${D}Integrity OK (video ${v_dur}s ≈ audio ${a_dur}s)${R}"
            fi
        fi
    fi
}

main "$@"
