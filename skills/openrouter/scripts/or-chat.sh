#!/usr/bin/env bash
# or-chat.sh — minimal OpenRouter client for skill-driven LLM dispatch.
#
# Usage:
#   or-chat.sh chat -m <model> [-s <system-prompt-file>] [-t <temperature>] [-x <max_tokens>] [-e <effort>] [prompt-file|-]
#     -e: OpenRouter reasoning effort max|xhigh|high|medium|low|minimal (default: max),
#         or "none" to omit the reasoning param entirely (for models without reasoning).
#         Reasoning budget is a fraction of max_tokens (max ~= 95%), so keep -x generous.
#   or-chat.sh models [filter]     # list live model ids + context + pricing (no key needed)
#   or-chat.sh key-check           # verify a key is resolvable
#
# The prompt is read from a file argument, or stdin when the argument is "-" or omitted.
# Assistant content goes to stdout; token usage and errors go to stderr.
# Key resolution: $OPENROUTER_API_KEY, then OS keyring (macOS Keychain / Linux secret-tool), then 0600 key file.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
. "$SCRIPT_DIR/or-common.sh"
. "$SCRIPT_DIR/or-config.sh"; or_load_config

cmd="${1:-}"
case "$cmd" in
  models)
    filter="${2:-}"
    curl -sf --max-time 30 https://openrouter.ai/api/v1/models \
      | jq -r --arg f "$filter" '
          .data[] | select(($f == "") or (.id | test($f; "i")))
          | [.id, (.context_length|tostring), .pricing.prompt, .pricing.completion] | @tsv' \
      | sort
    ;;

  key-check)
    key="$(or_resolve_key)"
    # No -f: a 401 body carries the diagnosis, which is the whole point here.
    resp="$(curl -s --max-time 30 -H "Authorization: Bearer $key" https://openrouter.ai/api/v1/key)"
    if jq -e '.data' <<<"$resp" >/dev/null 2>&1; then
      jq -r '"key ok — label: \(.data.label // "n/a"), usage: $\(.data.usage // 0)"' <<<"$resp"
    else
      echo "KEY CHECK FAILED: $(jq -r '.error.message // (.error | strings) // .' <<<"$resp" 2>/dev/null || printf '%s' "$resp")" >&2
      exit 1
    fi
    ;;

  chat)
    shift
    model="" system_file="" temperature="" max_tokens="32768" effort="max"
    while getopts "m:s:t:x:e:" opt; do
      case "$opt" in
        m) model="$OPTARG" ;;
        s) system_file="$OPTARG" ;;
        t) temperature="$OPTARG" ;;
        x) max_tokens="$OPTARG" ;;
        e) effort="$OPTARG" ;;
        *) exit 2 ;;
      esac
    done
    shift $((OPTIND - 1))
    # Fall back to the configured oracle model so `-m` is optional day-to-day.
    [ -n "$model" ] || model="${OR_ORACLE_MODEL:-}"
    [ -n "$model" ] || { echo "ERROR: -m <model> is required (or run setup.sh --model <id> once)" >&2; exit 2; }
    if [ -n "$system_file" ] && [ ! -f "$system_file" ]; then
      echo "ERROR: system prompt file not found: $system_file" >&2
      exit 2
    fi

    prompt_src="${1:--}"
    if [ "$prompt_src" = "-" ]; then
      prompt="$(cat)"
    else
      prompt="$(cat "$prompt_src")"
    fi
    [ -n "$prompt" ] || { echo "ERROR: empty prompt" >&2; exit 2; }

    key="$(or_resolve_key)"

    payload="$(jq -n \
      --arg model "$model" \
      --arg prompt "$prompt" \
      --arg system "$([ -n "$system_file" ] && cat "$system_file" || true)" \
      --arg temp "$temperature" \
      --arg effort "$effort" \
      --argjson max_tokens "$max_tokens" '
      {
        model: $model,
        max_tokens: $max_tokens,
        messages: (
          (if $system != "" then [{role: "system", content: $system}] else [] end)
          + [{role: "user", content: $prompt}]
        )
      }
      + (if $temp != "" then {temperature: ($temp|tonumber)} else {} end)
      + (if $effort != "none" then {reasoning: {effort: $effort}} else {} end)')"

    response="$(curl -sS --max-time 600 https://openrouter.ai/api/v1/chat/completions \
      -H "Authorization: Bearer $key" \
      -H "Content-Type: application/json" \
      -H "HTTP-Referer: https://claude.ai/code" \
      -H "X-Title: claude-code-openrouter-skill" \
      -d "$payload")"

    if ! jq -e . <<<"$response" >/dev/null 2>&1; then
      echo "OPENROUTER ERROR: non-JSON response (gateway/proxy error?):" >&2
      # Substring rather than `| head -c`: head closes the pipe early, killing
      # printf with SIGPIPE, and under pipefail the script then exits 141
      # instead of the documented 1.
      printf '%s\n' "${response:0:300}" >&2
      exit 1
    fi
    if err="$(jq -er '.error.message // (.error | strings)' <<<"$response" 2>/dev/null)"; then
      echo "OPENROUTER ERROR: $err" >&2
      exit 1
    fi

    jq -r '"usage: prompt=\(.usage.prompt_tokens // "?") completion=\(.usage.completion_tokens // "?") model=\(.model // "?")"' <<<"$response" >&2
    # content is usually a string but some providers return an array of parts
    content="$(jq -r '.choices[0].message.content
      | if type == "array" then map(.text // empty) | join("") else . // empty end' <<<"$response")"
    if [ -z "$content" ]; then
      echo "OPENROUTER ERROR: empty content in response:" >&2
      jq -c '.choices[0] // .' <<<"$response" >&2
      exit 1
    fi
    printf '%s\n' "$content"
    ;;

  *)
    echo "usage: or-chat.sh {chat|models|key-check} ..." >&2
    sed -n '2,12p' "$0" >&2
    exit 2
    ;;
esac
