#!/usr/bin/env bash
# Sync skills/commands/agents between this repo and a coding-agent config dir.
#
# The repo is the source of truth. Content is plain Markdown with YAML
# frontmatter, so it works with any tool that reads that layout
# (Claude Code reads ~/.claude by default).
#
# Usage:
#   ./sync.sh install            # symlink repo content into the target dir
#   ./sync.sh install --copy     # copy instead of symlink (for machines where
#                                # the repo lives on a removable/slow volume)
#   ./sync.sh capture            # pull local edits from the target back here
#   ./sync.sh status             # show what is linked / copied / missing
#
# Options:
#   --target DIR   config dir to sync with (default: ~/.claude)
set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TARGET="${HOME}/.claude"
MODE="${1:-}"
COPY=false
shift || true

while [[ $# -gt 0 ]]; do
  case "$1" in
    --copy) COPY=true; shift ;;
    --target) TARGET="$2"; shift 2 ;;
    *) echo "unknown option: $1" >&2; exit 1 ;;
  esac
done

DIRS=(skills commands agents)

install() {
  for dir in "${DIRS[@]}"; do
    mkdir -p "${TARGET}/${dir}"
    # Link/copy each top-level entry individually so content that exists
    # only on this machine is left untouched.
    for src in "${REPO_DIR}/${dir}"/*; do
      [[ -e "$src" ]] || continue
      name="$(basename "$src")"
      dest="${TARGET}/${dir}/${name}"
      if $COPY; then
        rm -rf "$dest"
        cp -R "$src" "$dest"
        echo "copied  ${dir}/${name}"
      else
        # Replace stale copies/links, but never follow a link into the repo.
        [[ -L "$dest" || -e "$dest" ]] && rm -rf "$dest"
        ln -s "$src" "$dest"
        echo "linked  ${dir}/${name}"
      fi
    done
  done
}

capture() {
  for dir in "${DIRS[@]}"; do
    [[ -d "${TARGET}/${dir}" ]] || continue
    for src in "${REPO_DIR}/${dir}"/*; do
      [[ -e "$src" ]] || continue
      name="$(basename "$src")"
      dest="${TARGET}/${dir}/${name}"
      # Only pull back entries the repo already tracks, and skip symlinks
      # (those already point into the repo).
      if [[ -e "$dest" && ! -L "$dest" ]]; then
        # Exclude runtime artifacts (openrouter skill: worker logs, gateway state).
        rsync -a --delete --exclude='.DS_Store' \
          --exclude='runs/' --exclude='.proxy.log' --exclude='.proxy.pid' \
          "$dest" "${REPO_DIR}/${dir}/"
        echo "captured ${dir}/${name}"
      fi
    done
  done
}

status() {
  for dir in "${DIRS[@]}"; do
    for src in "${REPO_DIR}/${dir}"/*; do
      [[ -e "$src" ]] || continue
      name="$(basename "$src")"
      dest="${TARGET}/${dir}/${name}"
      if [[ -L "$dest" ]]; then
        echo "linked   ${dir}/${name}"
      elif [[ -e "$dest" ]]; then
        echo "copy     ${dir}/${name}"
      else
        echo "missing  ${dir}/${name}"
      fi
    done
  done
}

case "$MODE" in
  install) install ;;
  capture) capture ;;
  status) status ;;
  *) sed -n '2,20p' "${BASH_SOURCE[0]}"; exit 1 ;;
esac
