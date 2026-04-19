# Search and browse helpers for corral.
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

# Inline jq helper function definitions reused across all jq invocations in cmd_search.
#
#   quant_rank    assign a numeric sort weight so higher-precision types sort first:
#                   F32 → -32, F16/BF16 → -16, QN → -N, unknown → 0.
#   quants        extract all unique quant tags from a model's .siblings[] filenames
#                 using the same separator + pattern logic as extract_quant_from_filename.
#   default_quant select the 'best default' GGUF: prefer Q4_K_M, then Q4_0,
#                 then the lexicographically first GGUF found.
# shellcheck disable=SC2016  # $ signs are jq regex anchors, not bash variables
_jq_quants_def='def quant_rank: if test("^F32$") then -32 elif test("^(BF16|F16)$") then -16 elif test("^(?:[A-Z]{2}[-_])?I?Q[0-9]+") then (capture("^(?:[A-Z]{2}[-_])?I?Q(?<n>[0-9]+)") | .n | tonumber | -.) else 0 end; def gguf_files: [.siblings[]? | .rfilename | select(type == "string" and test("[.]gguf$"; "i"))]; def has_gguf_tag: (((.tags // []) | map(ascii_downcase) | index("gguf")) != null); def has_gguf: ((gguf_files | length > 0) or ((.library_name // "" | ascii_downcase) == "gguf") or has_gguf_tag); def quants: [gguf_files[] | split("/") | last | gsub("[.]gguf$"; "") | gsub("-[0-9]+-of-[0-9]+$"; "") | (capture("[-._](?<q>(?:[A-Z]{2}[-_])?(?:I?Q[0-9]+(?:_[A-Z0-9]+)*|F16|BF16|F32))$")? | .q) | select(type == "string")] | unique | sort_by(quant_rank); def default_quant: gguf_files as $files | ((([$files[] | select(test("Q4_K_M[.-]"; "i"))] | sort | .[0]) // ([$files[] | select(test("Q4_0[.-]"; "i"))] | sort | .[0]) // ($files | sort | .[0])) as $f | if $f != null then (($f | split("/") | last | gsub("[.]gguf$"; "") | gsub("-[0-9]+-of-[0-9]+$"; "")) as $stem | (($stem | capture("[-._](?<q>(?:[A-Z]{2}[-_])?(?:I?Q[0-9]+(?:_[A-Z0-9]+)*|F16|BF16|F32))$")? | .q) // $stem)) else null end);'

cmd_search() {
  local BACKEND_FLAG=""
  local query=""
  local sort_by="trending"
  local limit=20
  local quants="false"
  local quiet="false"

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --backend) BACKEND_FLAG="${2:-}"; shift 2 ;;
      --sort)    sort_by="${2:-}"; shift 2 ;;
      --limit)   limit="${2:-}"; shift 2 ;;
      --quants)  quants="true"; shift ;;
      --quiet)   quiet="true"; shift ;;
      -h|--help) cmd_search_usage; return 0 ;;
      *)
        if [[ -z "$query" ]]; then
          query="$1"
          shift
        else
          echo "Unknown argument: $1" >&2
          cmd_search_usage >&2
          return 1
        fi
        ;;
    esac
  done

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
  case "$sort_by" in
    trending)  api_sort="trendingScore" ;;
    downloads) api_sort="downloads" ;;
    newest)    api_sort="lastModified" ;;
    *)         die "unknown sort value '${sort_by}': must be trending, downloads, or newest" ;;
  esac

  require_cmds curl jq

  local hf_token="${HF_TOKEN:-${HF_HUB_TOKEN:-${HUGGING_FACE_HUB_TOKEN:-}}}"
  local auth_header=()
  [[ -n "$hf_token" ]] && auth_header=(-H "Authorization: Bearer ${hf_token}")

  local base_url="https://huggingface.co/api/models?sort=${api_sort}&direction=-1&full=true"
  if [[ -n "$query" ]]; then
    # URL-encode the query string using jq's built-in @uri formatter, avoiding
    # a dependency on python, perl, or other external URL-encoding utilities.
    local encoded_query
    encoded_query="$(printf '%s' "$query" | jq -Rr @uri)"
    base_url+="&search=${encoded_query}"
  fi
  if [[ "$BACKEND" == "llama.cpp" ]]; then
    base_url+="&filter=gguf"
  elif [[ "$BACKEND" == "mlx" ]]; then
    base_url+="&filter=mlx"
  fi

  base_url+="&limit=${limit}"

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
    if [[ "$quiet" == "true" ]]; then
      printf '%s' "$results" | jq -r '.[] | .modelId'
    else
      printf '%s' "$results" \
        | jq -r '.[] | [.modelId, "mlx", (.downloads // 0 | tostring)] | @tsv' \
        | _print_tsv_table 'llr' $'MODEL\tBACKEND\tDOWNLOADS'
    fi
    return 0
  fi

  if [[ "$quiet" == "true" ]]; then
    if [[ "$quants" == "true" ]]; then
      printf '%s' "$results" | jq -r "${_jq_quants_def}"'
        .[] | .modelId as $m | (quants | if length > 0 then .[] | ($m + ":" + .) else $m end)'
    else
      printf '%s' "$results" | jq -r '.[] | .modelId'
    fi
  else
    if [[ "$quants" == "true" ]]; then
      # @tsv: jq formatter that joins array elements with tab characters.
      # Paired with IFS=$'\t' in the read loop below, this provides reliable
      # field splitting even when values contain spaces.
      printf '%s' "$results" \
        | jq -r "${_jq_quants_def}"'
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
  fi
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
