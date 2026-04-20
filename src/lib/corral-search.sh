# Search and browse helpers for corral.
#
# HuggingFace model search and browser integration. Provides:
#   - cmd_search() — queries the HF /api/models endpoint with backend-scoped
#     filters (gguf or mlx), pagination, and multiple sort orders.
#   - cmd_browse() — opens or prints a HuggingFace model page URL.
#
# GGUF quant introspection is handled by the jq asset in src/jq/search-quants.jq,
# surfaced through _search_quants_jq_defs().
# shellcheck shell=bash

cmd_search_usage() {
  cat <<EOF
Usage: $SCRIPT_NAME search [--backend <mlx|llama.cpp>] [QUERY] [--sort <by>] [--limit <n>] [--quants] [--quiet]

Arguments:
  QUERY         Optional search term (e.g. "gemma", "qwen", "llama")

Searches HuggingFace for backend-compatible models.
If --backend is omitted, the platform default backend is used: MLX on macOS
Apple Silicon, otherwise llama.cpp.

Options:
  --backend <backend>
                Backend search mode: llama.cpp (filter=gguf) or mlx (filter=mlx).
                If omitted, defaults to the platform backend.
  --sort <by>   Sort order: trending (default), downloads, newest.
  --limit <n>   Maximum number of results. Defaults to 20.
  --quants      llama.cpp only. Also show available quant variants per model
                With --quiet: prints one MODEL:QUANT per line when quants exist,
                otherwise prints MODEL.
  --quiet       Print only model identifiers, one per line.
EOF
}

# Print the jq helper definitions used by llama.cpp/GGUF search rendering.
# In source mode this reads src/jq/search-quants.jq from disk; tools/build.sh
# replaces the marked block with an inlined heredoc in standalone builds.
_search_quants_jq_defs() {
# BEGIN_SEARCH_QUANTS_JQ
  local jq_path
  jq_path="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../jq/search-quants.jq"
  cat "$jq_path"
# END_SEARCH_QUANTS_JQ
}

# Parse arguments for cmd_search.
#
# Sets:
#   REPLY_SEARCH_BACKEND_FLAG -> raw --backend value, or empty
#   REPLY_SEARCH_QUERY        -> optional positional query string
#   REPLY_SEARCH_SORT         -> sort choice
#   REPLY_SEARCH_LIMIT        -> raw --limit value
#   REPLY_SEARCH_QUANTS       -> "true" when --quants was passed
#   REPLY_SEARCH_QUIET        -> "true" when --quiet was passed
#   REPLY_SEARCH_SHOW_HELP    -> "true" when -h/--help was passed
#   REPLY_SEARCH_ERROR        -> explanatory error string on failure
_parse_search_args() {
  REPLY_SEARCH_BACKEND_FLAG=""
  REPLY_SEARCH_QUERY=""
  REPLY_SEARCH_SORT="trending"
  REPLY_SEARCH_LIMIT="20"
  REPLY_SEARCH_QUANTS="false"
  REPLY_SEARCH_QUIET="false"
  REPLY_SEARCH_SHOW_HELP="false"
  REPLY_SEARCH_ERROR=""

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --backend)
        [[ $# -ge 2 && -n "${2:-}" ]] || {
          REPLY_SEARCH_ERROR="missing value for --backend"
          return 1
        }
        REPLY_SEARCH_BACKEND_FLAG="$2"
        _validate_backend_flag "$REPLY_SEARCH_BACKEND_FLAG"
        shift 2
        ;;
      --sort)
        [[ $# -ge 2 && -n "${2:-}" ]] || {
          REPLY_SEARCH_ERROR="missing value for --sort"
          return 1
        }
        REPLY_SEARCH_SORT="$2"
        shift 2
        ;;
      --limit)
        [[ $# -ge 2 && -n "${2:-}" ]] || {
          REPLY_SEARCH_ERROR="missing value for --limit"
          return 1
        }
        REPLY_SEARCH_LIMIT="$2"
        shift 2
        ;;
      --quants)
        REPLY_SEARCH_QUANTS="true"
        shift
        ;;
      --quiet)
        REPLY_SEARCH_QUIET="true"
        shift
        ;;
      -h|--help)
        REPLY_SEARCH_SHOW_HELP="true"
        return 0
        ;;
      *)
        if [[ -z "$REPLY_SEARCH_QUERY" ]]; then
          REPLY_SEARCH_QUERY="$1"
          shift
        else
          REPLY_SEARCH_ERROR="Unknown argument: $1"
          return 1
        fi
        ;;
    esac
  done
}

_search_api_sort() {
  case "$1" in
    trending) printf 'trendingScore' ;;
    downloads) printf 'downloads' ;;
    newest) printf 'lastModified' ;;
    *) die "unknown sort value '${1}': must be trending, downloads, or newest" ;;
  esac
}

_build_search_api_url() {
  local backend="$1"
  local api_sort="$2"
  local limit="$3"
  local query="${4:-}"
  local base_url="https://huggingface.co/api/models?sort=${api_sort}&direction=-1&full=true"

  if [[ -n "$query" ]]; then
    # URL-encode the query string using jq's built-in @uri formatter, avoiding
    # a dependency on python, perl, or other external URL-encoding utilities.
    local encoded_query
    encoded_query="$(printf '%s' "$query" | jq -Rr @uri)"
    base_url+="&search=${encoded_query}"
  fi

  case "$backend" in
    llama.cpp) base_url+="&filter=gguf" ;;
    mlx) base_url+="&filter=mlx" ;;
  esac

  base_url+="&limit=${limit}"
  printf '%s' "$base_url"
}

_emit_mlx_search_results() {
  local results="$1"
  local quiet="$2"

  if [[ "$quiet" == "true" ]]; then
    printf '%s' "$results" | jq -r '.[] | .modelId'
  else
    printf '%s' "$results" \
      | jq -r '.[] | [.modelId, "mlx", (.downloads // 0 | tostring)] | @tsv' \
      | _print_tsv_table 'llr' $'MODEL\tBACKEND\tDOWNLOADS'
  fi
}

_emit_llama_search_results() {
  local results="$1"
  local quiet="$2"
  local quants="$3"
  local jq_quants_defs=""

  if [[ "$quants" == "true" ]]; then
    jq_quants_defs="$(_search_quants_jq_defs)"
  fi

  if [[ "$quiet" == "true" ]]; then
    if [[ "$quants" == "true" ]]; then
      printf '%s' "$results" | jq -r "${jq_quants_defs}"'
        .[] | .modelId as $m | (quants | if length > 0 then .[] | ($m + ":" + .) else $m end)'
    else
      printf '%s' "$results" | jq -r '.[] | .modelId'
    fi
    return 0
  fi

  if [[ "$quants" == "true" ]]; then
    # @tsv: jq formatter that joins array elements with tab characters.
    # Paired with IFS=$'\t' in the read loop below, this provides reliable
    # field splitting even when values contain spaces.
    printf '%s' "$results" \
      | jq -r "${jq_quants_defs}"'
          .[] |
          .modelId as $model |
          [
            [$model, "llama.cpp", (.downloads // 0 | tostring)],
            (quants[]? | ["  " + $model + ":" + ., "", ""])
          ]
          | .[]
          | @tsv' \
      | _print_tsv_table 'llr' $'MODEL\tBACKEND\tDOWNLOADS'
  else
    printf '%s' "$results" \
      | jq -r '.[] | [.modelId, "llama.cpp", (.downloads // 0 | tostring)] | @tsv' \
      | _print_tsv_table 'llr' $'MODEL\tBACKEND\tDOWNLOADS'
  fi
}

cmd_search() {
  if ! _parse_search_args "$@"; then
    echo "$REPLY_SEARCH_ERROR" >&2
    cmd_search_usage >&2
    return 1
  fi

  if [[ "$REPLY_SEARCH_SHOW_HELP" == "true" ]]; then
    cmd_search_usage
    return 0
  fi

  local BACKEND_FLAG="$REPLY_SEARCH_BACKEND_FLAG"
  local query="$REPLY_SEARCH_QUERY"
  local sort_by="$REPLY_SEARCH_SORT"
  local limit="$REPLY_SEARCH_LIMIT"
  local quants="$REPLY_SEARCH_QUANTS"
  local quiet="$REPLY_SEARCH_QUIET"

  # Search always uses a single backend-specific server-side filter.
  local BACKEND=""
  if [[ -n "$BACKEND_FLAG" ]]; then
    BACKEND="$(resolve_backend "$BACKEND_FLAG")"
  else
    BACKEND="$(resolve_backend)"
  fi

  if [[ "$BACKEND" == "mlx" && "$quants" == "true" ]]; then
    echo "Warning: --quants is only supported for llama.cpp/GGUF search; ignoring for MLX." >&2
    quants="false"
  fi

  [[ "$limit" =~ ^[0-9]+$ ]] || die "invalid --limit value '${limit}': must be a positive integer"
  (( limit > 0 )) || die "invalid --limit value '${limit}': must be greater than zero"

  local api_sort
  api_sort="$(_search_api_sort "$sort_by")"

  require_cmds curl jq

  local hf_token="${HF_TOKEN:-${HF_HUB_TOKEN:-${HUGGING_FACE_HUB_TOKEN:-}}}"
  local auth_header=()
  [[ -n "$hf_token" ]] && auth_header=(-H "Authorization: Bearer ${hf_token}")

  local base_url
  base_url="$(_build_search_api_url "$BACKEND" "$api_sort" "$limit" "$query")"

  # ${auth_header[@]+"${auth_header[@]}"}: safely expand an array that might
  # be empty under 'set -u'. If auth_header has no elements, this expands to
  # nothing instead of triggering an "unbound variable" error.
  # NOTE: this comment intentionally lives outside the $() block — bash
  # backslash-continuation lines cannot contain inline comments.
  local results
  results="$(curl -fsSL \
    --connect-timeout 15 \
    --max-time 30 \
    "${auth_header[@]+"${auth_header[@]}"}" \
    -H "User-Agent: ${SCRIPT_NAME}" \
    "$base_url")"

  local count
  count="$(printf '%s' "$results" | jq 'length')"

  if [[ "$count" -eq 0 ]]; then
    if [[ -n "$query" ]]; then
      echo "No models found for: $query"
    else
      echo "No models found."
    fi
    return 0
  fi

  if [[ "$BACKEND" == "mlx" ]]; then
    _emit_mlx_search_results "$results" "$quiet"
    return 0
  fi

  _emit_llama_search_results "$results" "$quiet" "$quants"
}

cmd_browse_usage() {
  cat <<EOF
Usage: $SCRIPT_NAME browse <MODEL_NAME> [--print]

Arguments:
  MODEL_NAME    HuggingFace model identifier, e.g. unsloth/gemma-4-26B-A4B-it-GGUF

Opens the HuggingFace page for a model in your browser.

Options:
  --print       Print the URL instead of opening a browser.
EOF
}

cmd_browse() {
  if [[ $# -eq 0 || "$1" == "-h" || "$1" == "--help" ]]; then
    cmd_browse_usage
    [[ $# -eq 0 ]] && return 1 || return 0
  fi

  local model_spec="$1"
  local print_only="false"
  shift

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --print)   print_only="true"; shift ;;
      -h|--help) cmd_browse_usage; return 0 ;;
      *)         echo "Unknown argument: $1" >&2; cmd_browse_usage >&2; return 1 ;;
    esac
  done

  _parse_model_spec "$model_spec"
  local model_name="$REPLY_MODEL"
  local url="https://huggingface.co/${model_name}"

  if [[ "$print_only" == "true" ]]; then
    echo "$url"
    return 0
  fi

  # Platform-specific "open URL in default browser" command.
  # macOS provides 'open', most Linux desktops provide 'xdg-open'.
  local open_cmd=""
  case "$(uname -s)" in
    Darwin) open_cmd="open" ;;
    Linux)  open_cmd="xdg-open" ;;
  esac

  if [[ -n "$open_cmd" ]] && command -v "$open_cmd" >/dev/null 2>&1; then
    "$open_cmd" "$url"
  else
    echo "$url"
  fi
}
