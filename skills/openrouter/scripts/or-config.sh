# or-config.sh — persistent model selection, sourced (never executed).
#
# Precedence, highest first:
#   1. an explicit -m flag on the command
#   2. an exported env var (OR_WORKER_MODEL / OR_SMALL_MODEL / OR_ORACLE_MODEL)
#   3. ~/.claude/skills/openrouter/config.env   <- written by `setup.sh --model`
#   4. the built-in default baked into each script
#
# config.env uses `: "${VAR:=value}"` so it only fills gaps — exporting a var in
# your shell, or passing -m, always wins over the stored default.
[ -n "${OR_CONFIG_SH:-}" ] && return 0
OR_CONFIG_SH=1

or_config_file() {
  printf '%s' "${OR_CONFIG_FILE:-$HOME/.claude/skills/openrouter/config.env}"
}

or_load_config() {
  local f; f="$(or_config_file)"
  # shellcheck disable=SC1090
  [ -f "$f" ] && . "$f"
  return 0
}

# or_set_model <worker-model> [oracle-model] — writes config.env atomically.
or_set_model() {
  local f worker oracle tmp
  f="$(or_config_file)"; worker="$1"; oracle="${2:-$1}"
  mkdir -p "$(dirname "$f")" || return 1
  tmp="$f.tmp.$$"
  cat > "$tmp" <<EOF
# Written by setup.sh --model. Edit freely, or re-run setup.sh --model <id>.
# These are defaults only: an exported env var or an explicit -m flag wins.
: "\${OR_WORKER_MODEL:=$worker}"
: "\${OR_SMALL_MODEL:=$worker}"
: "\${OR_ORACLE_MODEL:=$oracle}"
EOF
  mv "$tmp" "$f"
}
