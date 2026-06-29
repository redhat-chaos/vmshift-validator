#!/usr/bin/env bash
# clusters/scripts/lib/log.sh — Structured three-tier logging for the migration pipeline.
#
# LOG_LEVEL controls verbosity:
#   1 = normal  (default) — step summaries, errors, warnings
#   2 = verbose (-v)      — substep detail, operational info
#   3 = debug   (--debug) — raw command traces, timestamps
#
# Source this file at the top of every host-side script:
#   source "${SCRIPT_DIR}/lib/log.sh"

[[ -n "${_LOG_SH_LOADED:-}" ]] && return 0
_LOG_SH_LOADED=1

# ── Configuration ─────────────────────────────────────────────
export LOG_LEVEL="${LOG_LEVEL:-1}"

# ── Color support ─────────────────────────────────────────────
# Detect TTY separately for stdout and stderr so scripts that
# send JSON to stdout (capture-prometheus-metrics.sh) can still
# get colored human messages on stderr.
_LOG_COLOR_STDOUT=0
_LOG_COLOR_STDERR=0
[[ -t 1 ]] && _LOG_COLOR_STDOUT=1
[[ -t 2 ]] && _LOG_COLOR_STDERR=1

# Override: NO_COLOR (https://no-color.org/) disables everything
if [[ -n "${NO_COLOR:-}" ]]; then
  _LOG_COLOR_STDOUT=0
  _LOG_COLOR_STDERR=0
fi

_c() {
  local fd="${1}" code="${2}"
  if [[ "$fd" == "1" && "$_LOG_COLOR_STDOUT" == "1" ]] ||
     [[ "$fd" == "2" && "$_LOG_COLOR_STDERR" == "1" ]]; then
    printf '%b' "$code"
  fi
}

_C_RESET='\033[0m'
_C_BOLD='\033[1m'
_C_DIM='\033[2m'
_C_GREEN='\033[32m'
_C_YELLOW='\033[33m'
_C_RED='\033[31m'
_C_CYAN='\033[36m'

# ── Timestamp helper ──────────────────────────────────────────
_ts() { date +"%H:%M:%S"; }

# ── Dots filler (for aligned output) ──────────────────────────
_dots() {
  local label="$1" width="${2:-50}"
  local label_len=${#label}
  local dot_count=$(( width - label_len ))
  [[ $dot_count -lt 3 ]] && dot_count=3
  printf '%*s' "$dot_count" '' | tr ' ' '.'
}

# ═══════════════════════════════════════════════════════════════
# Level-gated output — STDOUT
# ═══════════════════════════════════════════════════════════════

log.info() {
  printf '%s\n' "$*"
}

log.verbose() {
  [[ "$LOG_LEVEL" -ge 2 ]] || return 0
  printf "   $(_c 1 "$_C_DIM")%s$(_c 1 "$_C_RESET")\n" "$*"
}

log.debug() {
  [[ "$LOG_LEVEL" -ge 3 ]] || return 0
  printf "   $(_c 1 "$_C_DIM")[DEBUG %s] %s$(_c 1 "$_C_RESET")\n" "$(_ts)" "$*"
}

log.debug_err() {
  [[ "$LOG_LEVEL" -ge 3 ]] || return 0
  printf "   $(_c 2 "$_C_DIM")[DEBUG %s] %s$(_c 2 "$_C_RESET")\n" "$(_ts)" "$*" >&2
}

# ═══════════════════════════════════════════════════════════════
# Status markers
# ═══════════════════════════════════════════════════════════════

log.success() {
  printf "   $(_c 1 "$_C_GREEN")✓ %s$(_c 1 "$_C_RESET")\n" "$*"
}

log.warn() {
  printf "   $(_c 2 "$_C_YELLOW")⚠ %s$(_c 2 "$_C_RESET")\n" "$*" >&2
}

log.error() {
  printf "   $(_c 2 "$_C_RED")✗ %s$(_c 2 "$_C_RESET")\n" "$*" >&2
}

# ═══════════════════════════════════════════════════════════════
# Step management — top-level pipeline phases
#
# Usage:
#   step.begin "[1/6] CREATE VM"
#   ... do work ...
#   step.end "PASS"        # or "FAIL" or "WARN" or "SKIP"
# ═══════════════════════════════════════════════════════════════

_STEP_START=0
_STEP_LABEL=""

step.begin() {
  local label="$1"
  _STEP_LABEL="$label"
  _STEP_START=$(date +%s)
  local dots
  dots=$(_dots "$label" 42)
  printf "\n$(_c 1 "$_C_BOLD")%s$(_c 1 "$_C_RESET") %s $(_c 1 "$_C_CYAN")⏳ RUNNING$(_c 1 "$_C_RESET")\n" \
    "$label" "$dots"
}

step.end() {
  local status="${1:-PASS}"
  local elapsed=$(( $(date +%s) - _STEP_START ))
  local color icon
  case "$status" in
    PASS) color="$_C_GREEN"; icon="✅" ;;
    FAIL) color="$_C_RED";   icon="❌" ;;
    WARN) color="$_C_YELLOW"; icon="⚠️" ;;
    SKIP) color="$_C_DIM";   icon="⏭️" ;;
    *)    color="$_C_RESET"; icon="•" ;;
  esac
  local dots
  dots=$(_dots "$_STEP_LABEL" 42)
  printf "$(_c 1 "$_C_BOLD")%s$(_c 1 "$_C_RESET") %s $(_c 1 "$color")%s %s (%ds)$(_c 1 "$_C_RESET")\n" \
    "$_STEP_LABEL" "$dots" "$icon" "$status" "$elapsed"
}

# ═══════════════════════════════════════════════════════════════
# Task management — child subtasks under a step
#
# Usage:
#   task.begin "Waiting for SSH"
#   task.pass  "SSH Ready"
#   task.fail  "SSH Timeout" "gave up after 600s"
# ═══════════════════════════════════════════════════════════════

task.begin() {
  [[ "$LOG_LEVEL" -ge 2 ]] || return 0
  local label="$1"
  local dots
  dots=$(_dots "$label" 35)
  printf "   ├── %s %s $(_c 1 "$_C_CYAN")⏳$(_c 1 "$_C_RESET")\n" "$label" "$dots"
}

task.pass() {
  [[ "$LOG_LEVEL" -ge 2 ]] || return 0
  local label="$1"
  local detail="${2:-}"
  local dots
  dots=$(_dots "$label" 35)
  if [[ -n "$detail" ]]; then
    printf "   ├── %s %s $(_c 1 "$_C_GREEN")✓$(_c 1 "$_C_RESET")  %s\n" "$label" "$dots" "$detail"
  else
    printf "   ├── %s %s $(_c 1 "$_C_GREEN")✓$(_c 1 "$_C_RESET")\n" "$label" "$dots"
  fi
}

task.fail() {
  local label="$1"
  local reason="${2:-}"
  local dots
  dots=$(_dots "$label" 35)
  if [[ -n "$reason" ]]; then
    printf "   └── %s %s $(_c 1 "$_C_RED")✗ %s$(_c 1 "$_C_RESET")\n" "$label" "$dots" "$reason" >&2
  else
    printf "   └── %s %s $(_c 1 "$_C_RED")✗$(_c 1 "$_C_RESET")\n" "$label" "$dots" >&2
  fi
}

# ═══════════════════════════════════════════════════════════════
# Progress — same-line updates for polling loops
#
# Usage:
#   progress.update "DiskTransfer" "3/7 steps (2m34s)"
# ═══════════════════════════════════════════════════════════════

progress.update() {
  [[ "$LOG_LEVEL" -ge 2 ]] || return 0
  [[ -t 1 ]] || return 0
  local label="$1" detail="$2"
  local dots
  dots=$(_dots "$label" 35)
  printf "\r   ├── %s %s $(_c 1 "$_C_CYAN")⏳$(_c 1 "$_C_RESET") %s" "$label" "$dots" "$detail"
}

# ═══════════════════════════════════════════════════════════════
# Utility — box drawing for important banners
# ═══════════════════════════════════════════════════════════════

log.banner() {
  local title="$1"
  local width=60
  printf '\n'
  printf "$(_c 1 "$_C_BOLD")%s$(_c 1 "$_C_RESET")\n" "$(printf '═%.0s' $(seq 1 $width))"
  printf "$(_c 1 "$_C_BOLD")  %s$(_c 1 "$_C_RESET")\n" "$title"
  printf "$(_c 1 "$_C_BOLD")%s$(_c 1 "$_C_RESET")\n" "$(printf '═%.0s' $(seq 1 $width))"
}

log.box() {
  local width=62
  local border_top border_bottom
  border_top="╔$(printf '═%.0s' $(seq 1 $width))╗"
  border_bottom="╚$(printf '═%.0s' $(seq 1 $width))╝"
  printf '\n%s\n' "$border_top"
  for line in "$@"; do
    printf '║  %-*s║\n' "$width" "$line"
  done
  printf '%s\n' "$border_bottom"
}
