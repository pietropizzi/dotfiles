#!/bin/bash
input=$(cat)

# Rough water footprint per dollar of API spend, using cost as a proxy for compute
# because the status line gets no session-wide token count. Includes data center
# cooling and the water used to generate the electricity. Published estimates vary
# by about 10x (roughly 0.2-3 L/$), so treat the result as an order of magnitude.
WATER_LITERS_PER_USD=0.5

# Parse all fields in one jq call. Fields are joined with the ASCII unit separator
# instead of a tab, because `read` collapses consecutive whitespace IFS characters
# and would shift fields when one is empty.
IFS=$'\x1f' read -r cwd model version cost api_ms ctx_pct effort worktree ctx_tokens ctx_size water_ml < <(
  jq -r --argjson liters_per_usd "$WATER_LITERS_PER_USD" '[
    .workspace.current_dir // .cwd // "",
    .model.display_name // "?",
    .version // "?",
    .cost.total_cost_usd // 0,
    (.cost.total_api_duration_ms // 0 | floor),
    (.context_window.used_percentage // 0 | floor),
    .effort.level // "",
    .workspace.git_worktree // "",
    .context_window.total_input_tokens // 0,
    .context_window.context_window_size // 0,
    ((.cost.total_cost_usd // 0) * $liters_per_usd * 1000 | floor)
  ] | map(tostring) | join("\u001f")' <<<"$input"
)
dir=${cwd##*/}

# Git info
git_branch=""
git_repo=""
if git_toplevel=$(git -C "$cwd" --no-optional-locks rev-parse --show-toplevel 2>/dev/null); then
  git_repo=${git_toplevel##*/}
  git_branch=$(git -C "$cwd" --no-optional-locks branch --show-current 2>/dev/null)
  git_branch=${git_branch:-$(git -C "$cwd" --no-optional-locks rev-parse --short HEAD 2>/dev/null)}
fi

# Format cost
cost_fmt=$(printf '$%.2f' "$cost")

# Format water (e.g. 250ml, 1.2L)
water_ml=${water_ml:-0}
if (( water_ml >= 1000 )); then
  water_fmt="$(( water_ml / 1000 )).$(( (water_ml % 1000) / 100 ))L"
else
  water_fmt="${water_ml}ml"
fi

# Format tokens (e.g. 950, 126k, 1.2M)
format_tokens() {
  local n=${1:-0}
  if (( n >= 1000000 )); then
    local tenths=$(( (n % 1000000) / 100000 ))
    if (( tenths > 0 )); then
      printf "%d.%dM" $(( n / 1000000 )) "$tenths"
    else
      printf "%dM" $(( n / 1000000 ))
    fi
  elif (( n >= 1000 )); then
    printf "%dk" $(( n / 1000 ))
  else
    printf "%d" "$n"
  fi
}
tokens_fmt=$(format_tokens "$ctx_tokens")
(( ctx_size > 0 )) && tokens_fmt+="/$(format_tokens "$ctx_size")"

# Format API time
api_ms=${api_ms:-0}
if [ "$api_ms" -ge 60000 ] 2>/dev/null; then
  api_fmt="$(( api_ms / 60000 ))m$(( (api_ms % 60000) / 1000 ))s"
elif [ "$api_ms" -ge 1000 ] 2>/dev/null; then
  api_sec=$(( api_ms / 1000 ))
  api_dec=$(( (api_ms % 1000) / 100 ))
  api_fmt="${api_sec}.${api_dec}s"
else
  api_fmt="${api_ms}ms"
fi

# Progress bar (10 chars)
ctx_pct=${ctx_pct:-0}
bar_pct=$ctx_pct
(( bar_pct > 100 )) && bar_pct=100
bar_width=10
filled=$(( bar_pct * bar_width / 100 ))
empty=$(( bar_width - filled ))
bar=""
for ((i=0; i<filled; i++)); do bar+="█"; done
for ((i=0; i<empty; i++)); do bar+="░"; done

# Bar color based on usage
if [ "$ctx_pct" -ge 80 ] 2>/dev/null; then
  bar_color=$'\033[31m'  # red
elif [ "$ctx_pct" -ge 50 ] 2>/dev/null; then
  bar_color=$'\033[33m'  # yellow
else
  bar_color=$'\033[32m'  # green
fi

# Colors
C=$'\033[36m'   # cyan
G=$'\033[32m'   # green
M=$'\033[35m'   # magenta
Y=$'\033[33m'   # yellow
D=$'\033[2m'    # dim
R=$'\033[0m'    # reset
SEP="${D}│${R}"

# Build status line
line=""

# Directory
line+="${C}${dir}${R}"

# Git repo (show if different from dir name)
if [ -n "$git_repo" ] && [ "$git_repo" != "$dir" ]; then
  line+=" ${D}(${git_repo})${R}"
fi

# Git branch (short SHA when detached)
if [ -n "$git_branch" ]; then
  line+=" ${G}⎇ ${git_branch}${R}"
fi

# Worktree
if [ -n "$worktree" ]; then
  line+=" ${M}⌥ ${worktree}${R}"
fi

line+=" ${SEP} "

# Model + effort
line+="${M}${model}${R}"
if [ -n "$effort" ]; then
  line+=" ${Y}[${effort}]${R}"
fi

line+=" ${SEP} "

# Context progress bar
line+="${bar_color}${bar}${R} ${ctx_pct}%"
line+=" ${D}·${R} ${C}${tokens_fmt}${R}"

line+=" ${SEP} "

# Cost
line+="${Y}${cost_fmt}${R}"
line+=" ${D}·${R} ${C}💧 ~${water_fmt}${R}"

line+=" ${SEP} "

# API time
line+="${D}⏱ ${api_fmt}${R}"

line+=" ${SEP} "

# Version
line+="${D}v${version}${R}"

printf '%s' "$line"
