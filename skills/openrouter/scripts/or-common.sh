# or-common.sh — shared OpenRouter key resolution/storage for the sibling scripts.
#
# This file is SOURCED, never executed: it only defines functions and sets a
# guard variable, and leaves the caller's `set -euo pipefail` (and shell state)
# untouched. Callers near the top of their script do:
#   . "$(dirname "$0")/or-common.sh"
#
# It exists because the key-resolution logic was duplicated (and macOS-only) in
# or-chat.sh and or-proxy.sh. This is the single source of truth, generalized to
# macOS / Linux / Windows-Git-Bash. A key is resolved from, in order: the
# OPENROUTER_API_KEY env var, the OS keyring, or a plain file (see or_key_file).
# A keyring or file miss must never abort early — only or_resolve_key's final
# fallback exits.
[ -n "${OR_COMMON_SH:-}" ] && return 0
OR_COMMON_SH=1

# Prints the OS class: macos | linux | windows. Anything unrecognized is treated
# as "linux" — the safest generic-POSIX default. WSL reports Linux and is
# therefore correctly handled here as linux.
or_os() {
  case "$(uname -s)" in
    Darwin) echo macos ;;
    Linux) echo linux ;;
    MINGW*|MSYS*|CYGWIN*) echo windows ;;
    *) echo linux ;;
  esac
}

# Prints the plain-file key path for this OS (does NOT create it). Windows has a
# proper per-user APPDATA dir; POSIX uses the XDG convention with HOME fallback,
# so the key file lives in a predictable location across shells/users.
or_key_file() {
  case "$(or_os)" in
    windows) printf '%s' "${APPDATA:-$HOME/AppData/Roaming}/openrouter/key" ;;
    *) printf '%s' "${XDG_CONFIG_HOME:-$HOME/.config}/openrouter/key" ;;
  esac
}

# Prints the OpenRouter key to stdout. First hit wins: env var, then OS keyring,
# then the plain file. Nothing found -> help on stderr and `exit 3`. A keyring or
# file miss must NOT abort early (no shell exit here) — only the final fallback
# does, so an absent key never silently kills a sibling mid-flight.
or_resolve_key() {
  local key key_file
  if [ -n "${OPENROUTER_API_KEY:-}" ]; then
    printf '%s' "$OPENROUTER_API_KEY"
    return
  fi

  case "$(or_os)" in
    macos)
      # Keychain item "openrouter-api-key" (service) / "openrouter" (account).
      # -n guard: a zero-length Keychain item exits 0, which would otherwise
      # "resolve" to an empty key instead of falling through to the file.
      if key="$(security find-generic-password -s openrouter-api-key -w 2>/dev/null)" \
         && [ -n "$key" ]; then
        printf '%s' "$key"
        return
      fi
      ;;
    linux)
      # secret-tool is the freedesktop keyring CLI (Secret Service). Only use it
      # if present on PATH; a headless box with no keyring daemon is common and
      # the lookup failure is not fatal — fall through to the plain file.
      if command -v secret-tool >/dev/null 2>&1 \
         && key="$(secret-tool lookup service openrouter-api-key account openrouter 2>/dev/null)" \
         && [ -n "$key" ]; then
        printf '%s' "$key"
        return
      fi
      ;;
    windows)
      # No native keyring on Git-Bash (DPAPI/Credential Manager is out of scope);
      # skip straight to the plain file.
      ;;
  esac

  key_file="$(or_key_file)"
  if [ -f "$key_file" ] && [ -s "$key_file" ]; then
    # -s guards the empty file; trim surrounding whitespace so stray newlines
    # from a careless editor don't end up in the Authorization header.
    tr -d '[:space:]' < "$key_file"
    return
  fi

  or_key_help >&2
  exit 3
}

# Stores the key using the best backend for this OS, then prints one line saying
# where it went. Falls back to the plain file where the keyring is unavailable
# (e.g. secret-tool absent) or fails (headless box). Returns non-zero if storage
# genuinely failed.
or_store_key() {
  local key os key_file
  key="$1"
  os="$(or_os)"

  case "$os" in
    macos)
      if security add-generic-password -U -s openrouter-api-key -a openrouter -w "$key" >/dev/null 2>&1; then
        echo "stored in macOS Keychain (item: openrouter-api-key)"
        return 0
      fi
      # Keychain write failed (e.g. a locked keychain); fall through to file so a
      # key is never lost just because the keyring is unhappy.
      ;;
    linux)
      if command -v secret-tool >/dev/null 2>&1 \
         && printf '%s' "$key" | secret-tool store \
              --label='OpenRouter API key' service openrouter-api-key account openrouter >/dev/null 2>&1; then
        echo "stored in Secret Service keyring (service: openrouter-api-key)"
        return 0
      fi
      # secret-tool absent or the store failed (no keyring daemon is the common
      # case on a headless box) — fall through to the plain file.
      ;;
    windows)
      # No native keyring on Git-Bash; plain file is the intended behavior.
      ;;
  esac

  key_file="$(or_key_file)"
  # Write with umask 077 in effect so the file is never briefly world-readable,
  # then pin 600 for good measure; only the bare key, no export/quotes, and at
  # most the one trailing newline.
  if ! mkdir -p "$(dirname "$key_file")" 2>/dev/null \
     || ! (umask 077 && printf '%s\n' "$key" > "$key_file") \
     || ! chmod 600 "$key_file" 2>/dev/null; then
    echo "ERROR: could not write key file: $key_file" >&2
    return 1
  fi
  echo "stored in plain file: $key_file"
  return 0
}

# Prints per-OS instructions for storing a key. Used in error paths (see
# or_resolve_key's fallback). Always offers the env-var option, which works on
# every platform regardless of keyring availability.
or_key_help() {
  local key_file os
  key_file="$(or_key_file)"
  os="$(or_os)"
  echo "ERROR: no OpenRouter key. Set OPENROUTER_API_KEY or store one:"
  case "$os" in
    macos)
      echo "  security add-generic-password -s openrouter-api-key -a openrouter -w '<key>'"
      ;;
    linux)
      if command -v secret-tool >/dev/null 2>&1; then
        echo "  secret-tool store --label='OpenRouter API key' service openrouter-api-key account openrouter"
      else
        # Include the mkdir: on a machine that has never stored a key the parent
      # dir does not exist and a bare redirect fails.
      echo "  mkdir -p '$(dirname "$key_file")' && printf '%s' '<key>' > '$key_file' && chmod 600 '$key_file'"
      fi
      ;;
    windows)
      # Include the mkdir: on a machine that has never stored a key the parent
      # dir does not exist and a bare redirect fails.
      echo "  mkdir -p '$(dirname "$key_file")' && printf '%s' '<key>' > '$key_file' && chmod 600 '$key_file'"
      ;;
  esac
  echo "  (or, for this session only: export OPENROUTER_API_KEY='<key>')"
}
