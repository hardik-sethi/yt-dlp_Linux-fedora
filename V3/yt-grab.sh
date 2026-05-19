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

# ── user config ────────────────────────────────────────────────────────────
# Browser to read cookies from. Strongly recommended if you have YouTube
# Premium — Premium accounts get much less throttling than anonymous requests.
# Leave empty ("") to skip cookies entirely. Override per-run with the env var:
#   COOKIES_FROM_BROWSER=firefox ./yt-grab.sh
#
# Directly-supported values: brave, firefox, chrome, chromium, edge, opera,
#                            safari, vivaldi, whale
# Flatpak installs of brave/firefox/chrome/chromium are auto-detected — just
# use the bare name. For other forks (Zen, Ulaa, Floorp, LibreWolf...), use
# the closest base browser + an explicit profile path:
#   firefox:~/.zen/<your-profile-dir>          — Zen (Firefox-based)
#   chromium:~/.config/Ulaa                    — Ulaa (Chromium-based)
#
# Note: the browser doesn't need to be open, but its profile DB needs to be
# readable (locked DBs from a running browser can fail to extract on some
# distros — close the browser first if you hit "could not copy cookies").
COOKIES_FROM_BROWSER="${COOKIES_FROM_BROWSER:-brave}"

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

# Resolve a COOKIES_FROM_BROWSER value into something yt-dlp can actually find.
# yt-dlp hardcodes a single native-install path per browser (e.g. Brave-Browser),
# but in practice browsers can be installed in non-default ways:
#   - Brave ships multiple channels (Stable, Beta, Nightly, Origin Beta...),
#     each as its own subdirectory under ~/.config/BraveSoftware/
#   - Flatpak installs put everything under ~/.var/app/<flatpak-id>/...
# This resolver inspects all known locations for a real cookie database. When
# multiple are found (e.g. you have both Brave stable and Brave beta), it
# picks whichever has the most recently modified Cookies file = the one you
# actively use.
#
# Returns the input unchanged if:
#   - the value already has a ':PATH' component (user told us explicitly)
#   - the browser isn't recognized
#   - nothing is found anywhere (let yt-dlp produce its own error)
resolve_cookies_source() {
    local src="$1"
    [[ "$src" == *:* ]] && { printf '%s\n' "$src"; return; }

    case "$src" in
        brave)
            # Channels live as subdirs under BraveSoftware/. Scan both native
            # config and Flatpak data roots.
            local roots=(
                "$HOME/.config/BraveSoftware"
                "$HOME/.var/app/com.brave.Browser/config/BraveSoftware"
            )
            local best="" best_mtime=0 root channel mtime
            for root in "${roots[@]}"; do
                [[ -d "$root" ]] || continue
                for channel in "$root"/*/; do
                    [[ -f "${channel}Default/Cookies" ]] || continue
                    mtime=$(stat -c %Y "${channel}Default/Cookies" 2>/dev/null) || mtime=0
                    if (( mtime > best_mtime )); then
                        best="${channel%/}"; best_mtime=$mtime
                    fi
                done
            done
            [[ -n "$best" ]] && printf '%s:%s\n' "$src" "$best" || printf '%s\n' "$src"
            ;;
        firefox|chrome|chromium)
            # Single-layer browsers — just check native vs Flatpak root.
            local native flatpak
            case "$src" in
                firefox)  native="$HOME/.mozilla/firefox"
                          flatpak="$HOME/.var/app/org.mozilla.firefox/.mozilla/firefox" ;;
                chrome)   native="$HOME/.config/google-chrome"
                          flatpak="$HOME/.var/app/com.google.Chrome/config/google-chrome" ;;
                chromium) native="$HOME/.config/chromium"
                          flatpak="$HOME/.var/app/org.chromium.Chromium/config/chromium" ;;
            esac
            [[ -d "$native"  ]] && { printf '%s\n' "$src"; return; }
            [[ -d "$flatpak" ]] && { printf '%s:%s\n' "$src" "$flatpak"; return; }
            printf '%s\n' "$src"
            ;;
        *)
            printf '%s\n' "$src"
            ;;
    esac
}

# Convert HH:MM:SS / MM:SS / SS (with optional decimals) to total seconds.
to_seconds() {
    awk -v t="$1" 'BEGIN{
        n = split(t, a, ":")
        if (n==3) print a[1]*3600 + a[2]*60 + a[3]
        else if (n==2) print a[1]*60 + a[2]
        else print a[1]
    }'
}

# Convert "HH:MM:SS" / "MM:SS" / "SS(.ms)" to seconds. With two args,
# returns arg1 - arg2.   e.g. time_to_sec 17:20 12:50 → 270
time_to_sec() {
    awk -v e="$1" -v s="${2:-0}" 'BEGIN{
        n = split(e, a, ":"); t1 = 0
        for (i = 1; i <= n; i++) t1 = t1 * 60 + a[i]
        n = split(s, a, ":"); t2 = 0
        for (i = 1; i <= n; i++) t2 = t2 * 60 + a[i]
        print t1 - t2
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

    # Resolve cookies source (handles Flatpak detection) before showing plan,
    # so the user can see exactly what'll be used.
    local -a cookie_args=()
    local cookies_resolved=""
    if [[ -n "$COOKIES_FROM_BROWSER" ]]; then
        cookies_resolved=$(resolve_cookies_source "$COOKIES_FROM_BROWSER")
        cookie_args=(--cookies-from-browser "$cookies_resolved")
    fi

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
    if [[ -n "$COOKIES_FROM_BROWSER" ]]; then
        if [[ "$cookies_resolved" != "$COOKIES_FROM_BROWSER" ]]; then
            echo "  Cookies    : $COOKIES_FROM_BROWSER ${D}(Flatpak → ${cookies_resolved#*:})${R}"
        else
            echo "  Cookies    : $COOKIES_FROM_BROWSER"
        fi
    fi
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
        "${cookie_args[@]}" \
        -f "$fmt" \
        -S "vcodec:av01,acodec:opus" \
        --merge-output-format mkv \
        --no-playlist \
        --force-overwrites \
        --retries 10 \
        --fragment-retries 10 \
        --socket-timeout 30 \
        --throttled-rate 100K \
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

    # Integrity check: compare the container's actual duration against what we
    # asked for. Per-stream duration is unreliable for Opus-in-MKV (ffprobe
    # often reports N/A), but the container's format=duration tracks where the
    # muxer actually stopped — truncation shows up here cleanly without false
    # alarms from missing per-stream metadata.
    if command -v ffprobe >/dev/null; then
        local actual_sec expected_sec=""
        actual_sec=$(ffprobe -v error -show_entries format=duration \
                     -of csv=p=0 "$outfile" 2>/dev/null || echo "")
        if [[ -n "$start" && -n "$end" ]]; then
            expected_sec=$(awk -v s="$(to_seconds "$start")" \
                               -v e="$(to_seconds "$end")" \
                               'BEGIN{print e-s}')
        elif [[ -n "$raw_duration" ]]; then
            expected_sec=$(to_seconds "$raw_duration")
        fi
        if [[ -n "$actual_sec" && "$actual_sec" != "N/A" && -n "$expected_sec" ]]; then
            # Keyframe-aligned cuts make actual slightly LONGER than expected
            # (~0-5s extra). Only flag if it's meaningfully SHORTER.
            if awk -v a="$actual_sec" -v e="$expected_sec" 'BEGIN{exit !(a < e - 5)}'; then
                echo
                warn "Output duration much shorter than expected!"
                printf "${D}  got %.1fs, expected ~%.0fs — likely truncated, re-run if needed.${R}\n" \
                    "$actual_sec" "$expected_sec"
            else
                printf "${D}Integrity OK (%.1fs, expected ~%.0fs)${R}\n" \
                    "$actual_sec" "$expected_sec"
            fi
        fi
    fi
}

main "$@"
