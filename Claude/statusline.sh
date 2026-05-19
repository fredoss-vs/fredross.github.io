#!/usr/bin/env bash
# ╔═══════════════════════════════════════════════════════════════════════════╗
# ║  claude-statusline — Single-line with progress bars + iteration delta    ║
# ║  Style: ✦ Opus 4.6 (1M) ██░░ 10% │ Δ 12.4k │ ▲ high │ 󰥔 5h: 23% …   ║
# ╚═══════════════════════════════════════════════════════════════════════════╝

input=$(cat)
[ -z "$input" ] && printf "Claude" && exit 0
NOW=$(date +%s)

JQ_BIN="$(command -v jq 2>/dev/null || true)"
[ -z "$JQ_BIN" ] && [ -x "$HOME/.claude/bin/jq" ] && JQ_BIN="$HOME/.claude/bin/jq"
[ -z "$JQ_BIN" ] && printf "Claude" && exit 0

# ── Vibrant palette (bold + 24-bit) ─────────────────────────────────────────
RST=$'\033[0m'
B=$'\033[1m'
PURPLE=$'\033[1;38;2;200;140;255m'
BLUE=$'\033[1;38;2;80;180;255m'
CYAN=$'\033[1;38;2;0;230;220m'
GREEN=$'\033[1;38;2;80;255;120m'
YELLOW=$'\033[1;38;2;255;225;50m'
RED=$'\033[1;38;2;255;80;80m'
ORANGE=$'\033[1;38;2;255;160;50m'
PINK=$'\033[1;38;2;255;120;200m'
SKY=$'\033[1;38;2;100;210;255m'
GOLD=$'\033[1;38;2;255;200;60m'
WHITE=$'\033[1;38;2;240;240;250m'
GRAY=$'\033[38;2;100;105;130m'
DIMW=$'\033[38;2;170;175;200m'
LIME=$'\033[1;38;2;180;255;80m'

SEP=" ${GRAY}│${RST} "

# ── Colour by usage % ────────────────────────────────────────────────────────
color_pct() {
    local p=$1
    if   (( p >= 80 )); then printf "%s" "$RED"
    elif (( p >= 50 )); then printf "%s" "$YELLOW"
    elif (( p >= 30 )); then printf "%s" "$ORANGE"
    else                      printf "%s" "$GREEN"
    fi
}

# ── Mini progress bar (8 segments) ───────────────────────────────────────────
mini_bar() {
    local pct=$1
    local width=8
    local filled=$(( pct * width / 100 ))
    (( filled > width )) && filled=$width
    local empty=$(( width - filled ))
    local color; color=$(color_pct "$pct")
    local bar=""
    for (( i=0; i<filled; i++ )); do bar+="${color}█${RST}"; done
    for (( i=0; i<empty;  i++ )); do bar+="${GRAY}░${RST}"; done
    printf "%b" "$bar"
}

# ── Format token count (human-readable) ──────────────────────────────────────
fmt_tokens() {
    local t=$1
    if   (( t >= 1000000 )); then printf "%.1fM" "$(echo "$t" | awk '{printf "%.1f", $1/1000000}')"
    elif (( t >= 1000 ));    then printf "%.1fk" "$(echo "$t" | awk '{printf "%.1f", $1/1000}')"
    else                          printf "%d" "$t"
    fi
}

# ── ISO → epoch (macOS) ─────────────────────────────────────────────────────
iso_to_epoch() {
    local iso="${1%%.*}"; iso="${iso%%Z}"
    TZ=UTC date -j -f "%Y-%m-%dT%H:%M:%S" "$iso" +%s 2>/dev/null
}

# ══════════════════════════════════════════════════════════════════════════════
#  PARSE JSON
# ══════════════════════════════════════════════════════════════════════════════
model=$(echo "$input" | "$JQ_BIN" -r '.model.display_name // "Claude"')
cwd=$(echo "$input" | "$JQ_BIN" -r '.cwd // ""')

size=$(echo "$input" | "$JQ_BIN" -r '.context_window.context_window_size // 200000')
input_tokens=$(echo "$input" | "$JQ_BIN" -r '.context_window.current_usage.input_tokens // 0')
cache_create=$(echo "$input" | "$JQ_BIN" -r '.context_window.current_usage.cache_creation_input_tokens // 0')
cache_read=$(echo "$input" | "$JQ_BIN" -r '.context_window.current_usage.cache_read_input_tokens // 0')
output_tokens=$(echo "$input" | "$JQ_BIN" -r '.context_window.total_output_tokens // 0' 2>/dev/null)

session_start=$(echo "$input" | "$JQ_BIN" -r '.session.start_time // empty')
lines_added=$(echo "$input" | "$JQ_BIN" -r '.cost.total_lines_added // 0' 2>/dev/null)
lines_removed=$(echo "$input" | "$JQ_BIN" -r '.cost.total_lines_removed // 0' 2>/dev/null)
total_cost=$(echo "$input" | "$JQ_BIN" -r '.cost.total_cost_usd // empty' 2>/dev/null)

current_tokens=$(( input_tokens + cache_create + cache_read ))
total_all_tokens=$(( current_tokens + output_tokens ))
(( size == 0 )) && size=200000
ctx_pct=$(( current_tokens * 100 / size ))

# ── Context window size label (200k, 1M, etc.) ──────────────────────────────
if   (( size >= 1000000 )); then ctx_label="$(( size / 1000000 ))M"
elif (( size >= 1000 ));    then ctx_label="$(( size / 1000 ))k"
else                              ctx_label="$size"
fi

# ══════════════════════════════════════════════════════════════════════════════
#  ITERATION DELTA — track token changes between refreshes
# ══════════════════════════════════════════════════════════════════════════════
DELTA_FILE="/tmp/claude-statusline-delta.json"
DELTA_SEG=""

# Read previous snapshot
prev_total=0
prev_input=0
prev_output=0
prev_ts=0
if [[ -f "$DELTA_FILE" ]]; then
    prev_total=$("$JQ_BIN" -r '.total // 0' "$DELTA_FILE" 2>/dev/null)
    prev_input=$("$JQ_BIN" -r '.input // 0' "$DELTA_FILE" 2>/dev/null)
    prev_output=$("$JQ_BIN" -r '.output // 0' "$DELTA_FILE" 2>/dev/null)
    prev_ts=$("$JQ_BIN" -r '.ts // 0' "$DELTA_FILE" 2>/dev/null)
fi

# Compute deltas
delta_total=$(( total_all_tokens - prev_total ))
delta_input=$(( current_tokens - prev_input ))
delta_output=$(( output_tokens - prev_output ))

# If tokens increased, we're in a new or ongoing iteration → show delta
# If tokens are the same, show last known delta from file
# If tokens decreased (new session), reset
if (( delta_total > 0 )); then
    # Tokens grew — active iteration or new turn completed
    # Save current snapshot + delta
    cat > "$DELTA_FILE" <<-SNAP
	{"total":${total_all_tokens},"input":${current_tokens},"output":${output_tokens},"ts":${NOW},"last_delta_in":${delta_input},"last_delta_out":${delta_output},"last_delta_total":${delta_total}}
	SNAP
    d_in_fmt=$(fmt_tokens "$delta_input")
    d_out_fmt=$(fmt_tokens "$delta_output")
    DELTA_SEG="${SEP}${LIME}Δ${RST} ${DIMW}↓${d_in_fmt}${RST} ${DIMW}↑${d_out_fmt}${RST}"

elif (( delta_total == 0 && prev_total > 0 )); then
    # No change — show last known delta
    last_d_in=$("$JQ_BIN" -r '.last_delta_in // 0' "$DELTA_FILE" 2>/dev/null)
    last_d_out=$("$JQ_BIN" -r '.last_delta_out // 0' "$DELTA_FILE" 2>/dev/null)
    if (( last_d_in > 0 || last_d_out > 0 )); then
        d_in_fmt=$(fmt_tokens "$last_d_in")
        d_out_fmt=$(fmt_tokens "$last_d_out")
        DELTA_SEG="${SEP}${DIMW}Δ ↓${d_in_fmt} ↑${d_out_fmt}${RST}"
    fi

else
    # New session or reset — reinitialize
    cat > "$DELTA_FILE" <<-SNAP
	{"total":${total_all_tokens},"input":${current_tokens},"output":${output_tokens},"ts":${NOW},"last_delta_in":0,"last_delta_out":0,"last_delta_total":0}
	SNAP
fi

# ── Token totals segment ─────────────────────────────────────────────────────
in_fmt=$(fmt_tokens "$current_tokens")
out_fmt=$(fmt_tokens "$output_tokens")
TOK_SEG="${DIMW}↓${in_fmt} ↑${out_fmt}${RST}"

# ── Effort level ─────────────────────────────────────────────────────────────
EFFORT=$("$JQ_BIN" -r '.effortLevel // "medium"' "$HOME/.claude/settings.json" 2>/dev/null)
case "$EFFORT" in
    low)  EFFORT_SEG="${DIMW}▽ low${RST}" ;;
    high) EFFORT_SEG="${ORANGE}▲ high${RST}" ;;
    max)  EFFORT_SEG="${PINK}⬆ max${RST}" ;;
    *)    EFFORT_SEG="${YELLOW}◆ med${RST}" ;;
esac

# ── Directory (~ for home) ───────────────────────────────────────────────────
dir_display="$cwd"
[[ "$dir_display" == "$HOME"* ]] && dir_display="~${dir_display#$HOME}"

# ── Git branch ───────────────────────────────────────────────────────────────
GIT_SEG=""
if [[ -n "$cwd" ]]; then
    CF="/tmp/claudeline-$(echo "$cwd" | cksum | cut -d' ' -f1)"
    BRANCH="" STAGED=0 MODIFIED=0
    if [[ -f "$CF" ]] && (( NOW - $(stat -f %m "$CF") < 5 )); then
        IFS=$'\t' read -r BRANCH STAGED MODIFIED < "$CF"
    elif git -C "$cwd" -c gc.auto=0 rev-parse --git-dir >/dev/null 2>&1; then
        BRANCH=$(git -C "$cwd" -c gc.auto=0 branch --show-current 2>/dev/null)
        while IFS= read -r l; do
            [[ "${l:0:1}" != " " && "${l:0:1}" != "?" ]] && ((STAGED++))
            [[ "${l:1:1}" != " " && "${l:1:1}" != "?" ]] && ((MODIFIED++))
        done < <(git -C "$cwd" -c gc.auto=0 status --porcelain 2>/dev/null)
        printf '%s\t%s\t%s' "$BRANCH" "$STAGED" "$MODIFIED" > "$CF"
    fi
    if [[ -n "$BRANCH" ]]; then
        [[ ${#BRANCH} -gt 20 ]] && BRANCH="${BRANCH:0:20}…"
        GIT_SEG="${SEP}${CYAN}󰘬 ${BRANCH}${RST}"
        (( STAGED > 0 ))   && GIT_SEG+=" ${GREEN}+${STAGED}${RST}"
        (( MODIFIED > 0 )) && GIT_SEG+=" ${YELLOW}~${MODIFIED}${RST}"
    fi
fi

# ── Session duration ─────────────────────────────────────────────────────────
DUR_SEG=""
if [[ -n "$session_start" ]]; then
    start=$(iso_to_epoch "$session_start")
    if [[ -n "$start" ]]; then
        elapsed=$(( NOW - start ))
        if   (( elapsed >= 3600 )); then dur="$(( elapsed / 3600 ))h$(( (elapsed % 3600) / 60 ))m"
        elif (( elapsed >= 60 ));   then dur="$(( elapsed / 60 ))m"
        else                             dur="${elapsed}s"
        fi
        DUR_SEG="${SEP}${SKY}󰔛 ${dur}${RST}"
    fi
fi

# ── Lines changed ────────────────────────────────────────────────────────────
LINES_SEG="${SEP}${GREEN}+${lines_added}${RST}${GRAY}/${RST}${RED}-${lines_removed}${RST}"

# ══════════════════════════════════════════════════════════════════════════════
#  OAUTH TOKEN
# ══════════════════════════════════════════════════════════════════════════════
get_token() {
    local blob; blob=$(security find-generic-password -s "Claude Code-credentials" -w 2>/dev/null)
    if [[ -n "$blob" ]]; then
        local t; t=$(echo "$blob" | "$JQ_BIN" -r '.claudeAiOauth.accessToken // empty' 2>/dev/null)
        [[ -n "$t" ]] && echo "$t" && return
    fi
    local creds="$HOME/.claude/.credentials.json"
    [[ -f "$creds" ]] && "$JQ_BIN" -r '.claudeAiOauth.accessToken // empty' "$creds" 2>/dev/null
}

# ══════════════════════════════════════════════════════════════════════════════
#  FETCH SUBSCRIPTION USAGE (90 s cache)
# ══════════════════════════════════════════════════════════════════════════════
CACHE="/tmp/claude-statusline-cache.json"
CACHE_TTL=90
usage=""
if [[ -f "$CACHE" ]]; then
    age=$(( NOW - $(stat -f %m "$CACHE") ))
    (( age <= CACHE_TTL )) && usage=$(cat "$CACHE")
fi
if [[ -z "$usage" ]]; then
    token=$(get_token)
    if [[ -n "$token" ]]; then
        resp=$(curl -s --max-time 5 \
            -H "Authorization: Bearer $token" \
            -H "anthropic-beta: oauth-2025-04-20" \
            -H "User-Agent: claude-code/2.1.34" \
            "https://api.anthropic.com/api/oauth/usage" 2>/dev/null)
        if echo "$resp" | "$JQ_BIN" -e '.five_hour' >/dev/null 2>&1; then
            usage="$resp"; echo "$resp" > "$CACHE"
        fi
    fi
    [[ -z "$usage" ]] && [[ -f "$CACHE" ]] && usage=$(cat "$CACHE")
fi

# ══════════════════════════════════════════════════════════════════════════════
#  BUILD RATE-LIMIT / COST SEGMENTS
# ══════════════════════════════════════════════════════════════════════════════
COST_SEG=""
RATE_SEG=""

if [[ -n "$usage" ]]; then
    # ── Cost (if present alongside subscription) ─────────────────────────────
    if [[ -n "$total_cost" && "$total_cost" != "0" ]]; then
        cost_fmt=$(printf "%.2f" "$total_cost")
        COST_SEG="${SEP}${GOLD}\$${cost_fmt}${RST}"
    fi

    # ── 5h ────────────────────────────────────────────────────────────────────
    fh_pct=$(echo "$usage" | "$JQ_BIN" -r '.five_hour.utilization // 0' | awk '{printf "%.0f", $1}')
    fh_reset_iso=$(echo "$usage" | "$JQ_BIN" -r '.five_hour.resets_at // empty')
    fh_color=$(color_pct "$fh_pct")
    fh_cd=""
    if [[ -n "$fh_reset_iso" && "$fh_reset_iso" != "null" ]]; then
        fh_epoch=$(iso_to_epoch "$fh_reset_iso")
        if [[ -n "$fh_epoch" ]]; then
            rem=$(( fh_epoch - NOW ))
            if (( rem > 0 )); then
                fh_h=$(( rem / 3600 )); fh_m=$(( (rem % 3600) / 60 ))
                fh_cd=" ${DIMW}(${fh_h}h$(printf '%02d' $fh_m)m)${RST}"
            fi
        fi
    fi

    # ── 7d ────────────────────────────────────────────────────────────────────
    wd_pct=$(echo "$usage" | "$JQ_BIN" -r '.seven_day.utilization // 0' | awk '{printf "%.0f", $1}')
    wd_reset_iso=$(echo "$usage" | "$JQ_BIN" -r '.seven_day.resets_at // empty')
    wd_color=$(color_pct "$wd_pct")
    wd_cd=""
    if [[ -n "$wd_reset_iso" && "$wd_reset_iso" != "null" ]]; then
        wd_epoch=$(iso_to_epoch "$wd_reset_iso")
        if [[ -n "$wd_epoch" ]]; then
            rem=$(( wd_epoch - NOW ))
            if (( rem > 0 )); then
                wd_d=$(( rem / 86400 )); wd_h=$(( (rem % 86400) / 3600 ))
                wd_cd=" ${DIMW}(${wd_d}d$(printf '%02d' $wd_h)h)${RST}"
            fi
        fi
    fi

    RATE_SEG="${SEP}${fh_color}󰥔 5h ${fh_pct}%${RST}${fh_cd}"
    RATE_SEG+="${SEP}${wd_color}󰃰 7d ${wd_pct}%${RST}${wd_cd}"

elif [[ -n "$total_cost" ]]; then
    # ── API billing ──────────────────────────────────────────────────────────
    cost_fmt=$(printf "%.2f" "$total_cost")
    COST_SEG="${SEP}${GOLD}\$${cost_fmt}${RST}"
fi

# ══════════════════════════════════════════════════════════════════════════════
#  CONTEXT SEGMENT: ████░░░░ 42% (200k)
# ══════════════════════════════════════════════════════════════════════════════
ctx_color=$(color_pct "$ctx_pct")
CTX_SEG="$(mini_bar "$ctx_pct") ${ctx_color}${B}${ctx_pct}%${RST}"

# ══════════════════════════════════════════════════════════════════════════════
#  SINGLE LINE OUTPUT
#  ✦ Opus 4.6 (1M) ████░░░░ 10% ↓48.2k ↑3.1k │ Δ ↓12.4k ↑1.2k │ ▲ high │ …
# ══════════════════════════════════════════════════════════════════════════════

LINE="${PURPLE}✦ ${model}${RST} ${DIMW}(${ctx_label})${RST} ${CTX_SEG} ${TOK_SEG}"
LINE+="${DELTA_SEG}"
LINE+="${SEP}${EFFORT_SEG}"
LINE+="${RATE_SEG}"
LINE+="${GIT_SEG}"
LINE+="${SEP}${BLUE}󰉋 ${dir_display}${RST}"
LINE+="${DUR_SEG}"
LINE+="${LINES_SEG}"
LINE+="${COST_SEG}"

printf "%b\n" "$LINE"