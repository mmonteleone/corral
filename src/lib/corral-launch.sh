# Launch supported third-party coding harnesses against a running corral server.
#
# Detects a running corral server process (llama-server or mlx_lm.server),
# configures the harness to point at that server's OpenAI-compatible /v1
# endpoint, backs up file-backed config when it changes, and execs the harness.
#
# Supported harnesses: pi, opencode, codex
#
# JSON/JSONC handling:
#   _strip_jsonc()            — awk program that strips // and /* */ comments
#                               and trailing commas from JSONC input.
#   _normalize_json_for_merge() — pre-processes existing config for deep merge.
#   _render_merged_json_file()  — deep-merges a patch into an existing JSON file.
#
# Config write safety:
#   _write_text_file_with_backup() — atomic write with .bak.TIMESTAMP backup.
#
# Launch templates live in src/launch/*.tmpl and are inlined by
# tools/build.sh between BEGIN/END_BUILTIN_LAUNCH_TEMPLATES markers.
# shellcheck shell=bash

CORRAL_LAUNCH_PROVIDER_ID="corral-launch"

cmd_launch_usage() {
  cat <<EOF
Usage: $SCRIPT_NAME launch [--port <port>] <pi|opencode|codex> [-- <extra args...>]

Arguments:
  pi|opencode|codex  Supported coding harness to configure and launch.

Options:
  --port <port>      Use a specific running corral server when multiple are active.

Corral inspects the selected running server, configures the harness to point at
that server's OpenAI-compatible endpoint and model, and then launches the
harness. File-backed harness configs are backed up next to the original when
they change.

Notes:
  - pi and opencode work with llama-server and mlx_lm.server.
  - codex requires a llama-server with /v1/responses support.

Examples:
  $SCRIPT_NAME launch pi
  $SCRIPT_NAME launch --port 8082 opencode
  $SCRIPT_NAME launch --port 9000 codex
EOF
}

cmd_launch() {
  if [[ $# -eq 0 ]]; then
    cmd_launch_usage
    return 1
  fi

  if [[ "$1" == "-h" || "$1" == "--help" ]]; then
    cmd_launch_usage
    return 0
  fi

  if ! _parse_launch_args "$@"; then
    echo "$REPLY_LAUNCH_ERROR" >&2
    cmd_launch_usage >&2
    return 1
  fi

  if [[ "$REPLY_LAUNCH_SHOW_HELP" == "true" ]]; then
    cmd_launch_usage
    return 0
  fi

  local requested_port="$REPLY_LAUNCH_REQUESTED_PORT"
  local tool="$REPLY_LAUNCH_TOOL"
  local extra_args=("${REPLY_LAUNCH_EXTRA_ARGS[@]+"${REPLY_LAUNCH_EXTRA_ARGS[@]}"}")

  _validate_launch_tool "$tool"

  require_cmds date "$tool"
  CORRAL_LAUNCH_RUN_TIMESTAMP="$(_launch_timestamp)"

  if ! _launch_resolve_target "$tool" "$requested_port"; then
    return 1
  fi

  printf 'Using corral server on port %s (%s, model %s)\n' \
    "$REPLY_LAUNCH_PORT" "$REPLY_LAUNCH_PROCESS" "$REPLY_LAUNCH_MODEL"

  case "$tool" in
    pi)
      require_cmds jq
      _configure_pi_launch "$REPLY_LAUNCH_ENDPOINT" "$REPLY_LAUNCH_MODEL" "$CORRAL_LAUNCH_PROVIDER_ID" "$REPLY_LAUNCH_CONTEXT_WINDOW" "$REPLY_LAUNCH_MAX_TOKENS"
      ;;
    opencode)
      require_cmds jq
      _configure_opencode_launch "$REPLY_LAUNCH_ENDPOINT" "$REPLY_LAUNCH_MODEL" "$CORRAL_LAUNCH_PROVIDER_ID" "$REPLY_LAUNCH_CONTEXT_WINDOW" "$REPLY_LAUNCH_MAX_TOKENS"
      ;;
    codex)
      ;;
  esac

  printf 'Launching %s against %s (model: %s)\n' \
    "$tool" "$REPLY_LAUNCH_ENDPOINT" "$REPLY_LAUNCH_MODEL"

  case "$tool" in
    pi)
      exec pi "${extra_args[@]+"${extra_args[@]}"}"
      ;;
    opencode)
      exec opencode "${extra_args[@]+"${extra_args[@]}"}"
      ;;
    codex)
      _write_codex_model_catalog "$REPLY_LAUNCH_MODEL" "$REPLY_LAUNCH_CONTEXT_WINDOW"
      exec codex \
        -c "model=$(_toml_string_literal "$REPLY_LAUNCH_MODEL")" \
        -c "model_catalog_json=$(_toml_string_literal "$REPLY_CODEX_MODEL_CATALOG")" \
        -c 'web_search="disabled"' \
        -c "model_provider=$(_toml_string_literal "$CORRAL_LAUNCH_PROVIDER_ID")" \
        -c "model_providers.${CORRAL_LAUNCH_PROVIDER_ID}.name=\"Corral\"" \
        -c "model_providers.${CORRAL_LAUNCH_PROVIDER_ID}.base_url=$(_toml_string_literal "$REPLY_LAUNCH_ENDPOINT")" \
        -c "model_providers.${CORRAL_LAUNCH_PROVIDER_ID}.wire_api=\"responses\"" \
        -c "model_providers.${CORRAL_LAUNCH_PROVIDER_ID}.experimental_bearer_token=\"corral\"" \
        "${extra_args[@]+"${extra_args[@]}"}"
      ;;
  esac
}

_get_builtin_launch_template_content() {
  local name="$1"
  # BEGIN_BUILTIN_LAUNCH_TEMPLATES
  local template_dir
  template_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../launch"
  if [[ -f "${template_dir}/${name}.tmpl" ]]; then
    cat "${template_dir}/${name}.tmpl"
    return 0
  fi
  return 1
  # END_BUILTIN_LAUNCH_TEMPLATES
}

_render_launch_template() {
  local template_name="$1"
  local provider_id="$2"
  local endpoint="$3"
  local model="$4"
  local context_window="${5:-65536}"
  local max_tokens="${6:-4096}"
  local template

  template="$(_get_builtin_launch_template_content "$template_name")" || \
    die "unknown launch template '${template_name}'"

  template="${template//__CORRAL_PROVIDER_ID__/$provider_id}"
  template="${template//__CORRAL_ENDPOINT__/$endpoint}"
  template="${template//__CORRAL_MODEL__/$model}"
  template="${template//__CORRAL_CONTEXT_WINDOW__/$context_window}"
  template="${template//__CORRAL_MAX_TOKENS__/$max_tokens}"
  printf '%s\n' "$template"
}

_launch_timestamp() {
  date -u +"%Y%m%dT%H%M%SZ"
}

_toml_string_literal() {
  local value="$1"
  value="${value//\\/\\\\}"
  value="${value//\"/\\\"}"
  printf '"%s"' "$value"
}

_json_string_literal() {
  local value="$1"
  value="${value//\\/\\\\}"
  value="${value//\"/\\\"}"
  value="${value//$'\n'/\\n}"
  value="${value//$'\r'/\\r}"
  value="${value//$'\t'/\\t}"
  printf '"%s"' "$value"
}

_write_codex_model_catalog() {
  local model="$1"
  local context_window="${2:-65536}"
  local instructions="You are Codex, a coding agent. Help the user by editing files, running commands when appropriate, and explaining results concisely."
  local catalog_path

  [[ -n "$context_window" ]] || context_window="65536"
  catalog_path="$(mktemp "${TMPDIR:-/tmp}/corral-codex-model-catalog.XXXXXX")"

  cat > "$catalog_path" <<EOF
{"models":[{"slug":$(_json_string_literal "$model"),"display_name":$(_json_string_literal "$model"),"description":"Corral local model","default_reasoning_level":"medium","supported_reasoning_levels":[{"effort":"low","description":"Fast responses with lighter reasoning"},{"effort":"medium","description":"Balances speed and reasoning depth"},{"effort":"high","description":"Greater reasoning depth"}],"shell_type":"local","visibility":"list","supported_in_api":true,"priority":0,"base_instructions":$(_json_string_literal "$instructions"),"model_messages":{"instructions_template":$(_json_string_literal "$instructions"),"instructions_variables":{"personality_default":"","personality_pragmatic":""}},"supports_reasoning_summaries":false,"default_reasoning_summary":"none","support_verbosity":false,"default_verbosity":"low","apply_patch_tool_type":"function","web_search_tool_type":"text","truncation_policy":{"mode":"tokens","limit":10000},"supports_parallel_tool_calls":false,"supports_image_detail_original":false,"context_window":${context_window},"max_context_window":${context_window},"effective_context_window_percent":95,"experimental_supported_tools":[],"input_modalities":["text"],"supports_search_tool":false}]}
EOF

  REPLY_CODEX_MODEL_CATALOG="$catalog_path"
}

_ensure_parent_dir() {
  local path="$1"
  mkdir -p "$(dirname "$path")"
}

# Write text to a config file, preserving the previous version in a timestamped
# backup when the on-disk content changes.
#
# Sets:
#   REPLY_FILE_UPDATED -> "1" when the file changed, otherwise "0"
#   REPLY_FILE_BACKUP  -> backup path when one was created, otherwise empty
_write_text_file_with_backup() {
  local path="$1"
  local content="$2"
  local backup_existing_match="${3:-0}"
  local current=""

  REPLY_FILE_UPDATED="0"
  REPLY_FILE_BACKUP=""

  if [[ -f "$path" ]]; then
    current="$(cat "$path")"
  fi

  if [[ "$current" == "$content" ]]; then
    if [[ "$backup_existing_match" == "1" && -f "$path" ]] && ! compgen -G "${path}.bak.*" > /dev/null; then
      REPLY_FILE_BACKUP="${path}.bak.${CORRAL_LAUNCH_RUN_TIMESTAMP}"
      cp "$path" "$REPLY_FILE_BACKUP"
    fi
    return 0
  fi

  _ensure_parent_dir "$path"

  if [[ -f "$path" ]]; then
    REPLY_FILE_BACKUP="${path}.bak.${CORRAL_LAUNCH_RUN_TIMESTAMP}"
    cp "$path" "$REPLY_FILE_BACKUP"
  fi

  local tmp_file
  tmp_file="$(mktemp "$(dirname "$path")/.corral-launch.$(basename "$path").XXXXXX")"
  printf '%s\n' "$content" > "$tmp_file"
  mv "$tmp_file" "$path"
  REPLY_FILE_UPDATED="1"
}

# Print the awk program used by _strip_jsonc().
# In source mode this reads src/awk/jsonc.awk from disk; tools/build.sh
# replaces the marked block with an inlined heredoc in standalone builds.
_strip_jsonc_awk() {
# BEGIN_JSONC_AWK
  local awk_path
  awk_path="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../awk/jsonc.awk"
  cat "$awk_path"
# END_JSONC_AWK
}

_strip_jsonc() {
  awk "$(_strip_jsonc_awk)"
}

_normalize_json_for_merge() {
  local json_text="$1"
  local jsonc_mode="${2:-0}"
  local merge_mode="${3:-default}"
  local jq_filter='.'

  if [[ -z "${json_text//[$' \t\r\n']/}" ]]; then
    printf '{}\n'
    return 0
  fi

  if [[ "$jsonc_mode" == "1" ]]; then
    json_text="$(printf '%s' "$json_text" | _strip_jsonc)"
    if [[ -z "${json_text//[$' \t\r\n']/}" ]]; then
      printf '{}\n'
      return 0
    fi
  fi

  case "$merge_mode" in
    pi-models)
      # shellcheck disable=SC2016  # jq program is intentionally single-quoted.
      jq_filter='def is_provider_entry: type == "object" and (has("api") or has("baseUrl") or has("models"));
        if type != "object" then
          {}
        elif has("providers") then
          if (.providers | type) != "object" then
            error("existing models.json has invalid '\''providers'\'' structure")
          else
            .
          end
        else
          reduce keys_unsorted[] as $key
            (. + {providers: {}};
              if (.[$key] | is_provider_entry) then
                .providers[$key] = .[$key] | del(.[$key])
              else
                .
              end)
        end'
      ;;
  esac

  printf '%s' "$json_text" | jq "$jq_filter"
}

_render_merged_json_file() {
  local path="$1"
  local patch_text="$2"
  local jsonc_mode="${3:-0}"
  local merge_mode="${4:-default}"
  local current_text=""
  local current_json
  local current_canonical
  local merged_json
  local merged_canonical

  if [[ -f "$path" ]]; then
    current_text="$(cat "$path")"
  fi

  current_json="$(_normalize_json_for_merge "$current_text" "$jsonc_mode" "$merge_mode")"
  merged_json="$(jq -s '
    if (.[0] | type) == "object" and (.[1] | type) == "object" then
      .[0] * .[1]
    else
      .[1]
    end
  ' <(printf '%s\n' "$current_json") <(printf '%s\n' "$patch_text"))"

  current_canonical="$(printf '%s\n' "$current_json" | jq -cS '.')"
  merged_canonical="$(printf '%s\n' "$merged_json" | jq -cS '.')"

  if [[ -f "$path" && "$current_canonical" == "$merged_canonical" ]]; then
    if [[ -n "$current_text" && "$current_text" != *$'\n' ]]; then
      printf '%s\n' "$current_text"
    else
      printf '%s' "$current_text"
    fi
    return 0
  fi

  printf '%s\n' "$merged_json"
}

_report_file_update() {
  local path="$1"
  if [[ "$REPLY_FILE_UPDATED" == "1" ]]; then
    if [[ -n "$REPLY_FILE_BACKUP" ]]; then
      printf 'Backed up %s to %s\n' "$path" "$REPLY_FILE_BACKUP"
    fi
    printf 'Updated %s\n' "$path"
  else
    printf 'Config already matched %s\n' "$path"
  fi
}

_launch_is_server_process() {
  case "$1" in
    llama-server|mlx_lm.server) return 0 ;;
    *) return 1 ;;
  esac
}

_launch_tool_supports_process() {
  local tool="$1"
  local process_name="$2"

  if ! _launch_is_server_process "$process_name"; then
    return 1
  fi

  case "$tool" in
    pi|opencode)
      return 0
      ;;
    codex)
      [[ "$process_name" == "llama-server" ]]
      return
      ;;
    *)
      return 1
      ;;
  esac
}

# Resolve the single running corral server compatible with the requested tool.
#
# Sets:
#   REPLY_LAUNCH_PROCESS      -> process name (llama-server or mlx_lm.server)
#   REPLY_LAUNCH_PORT         -> server port
#   REPLY_LAUNCH_MODEL        -> model identifier passed to the server
#   REPLY_LAUNCH_CONTEXT_WINDOW -> discovered context size, or empty when unavailable
#   REPLY_LAUNCH_MAX_TOKENS   -> discovered max token limit, or empty when unavailable
#   REPLY_LAUNCH_ENDPOINT     -> OpenAI-compatible base URL for the harness config
_launch_resolve_target() {
  local tool="$1"
  local requested_port="${2:-}"
  local rows eligible_rows=""

  rows="$(emit_runtime_process_rows)"

  while IFS=$'\t' read -r pid process_name port model context_window max_tokens; do
    [[ -n "$pid" ]] || continue
    if ! _launch_tool_supports_process "$tool" "$process_name"; then
      continue
    fi
    if [[ -n "$requested_port" && "$port" != "$requested_port" ]]; then
      continue
    fi
    eligible_rows+="${pid}"$'\t'"${process_name}"$'\t'"${port}"$'\t'"${model}"$'\t'"${context_window}"$'\t'"${max_tokens}"$'\n'
  done <<< "$rows"

  if [[ -z "$eligible_rows" ]]; then
    die "no compatible corral server found. Start one with '$SCRIPT_NAME serve ...' and use '$SCRIPT_NAME ps' to inspect running servers."
  fi

  local row_count
  row_count="$(printf '%s' "$eligible_rows" | awk 'NF { count += 1 } END { print count + 0 }')"
  if [[ "$row_count" -gt 1 ]]; then
    printf 'Multiple compatible corral servers are running; choose one with --port:\n' >&2
    print_tsv_table 'llllll' $'PID\tPROCESS\tPORT\tMODEL\tCONTEXT\tMAX_TOKENS' <<< "$eligible_rows" >&2
    return 1
  fi

  IFS=$'\t' read -r _ REPLY_LAUNCH_PROCESS REPLY_LAUNCH_PORT REPLY_LAUNCH_MODEL REPLY_LAUNCH_CONTEXT_WINDOW REPLY_LAUNCH_MAX_TOKENS <<< "$eligible_rows"
  [[ "$REPLY_LAUNCH_CONTEXT_WINDOW" == "-" ]] && REPLY_LAUNCH_CONTEXT_WINDOW=""
  [[ "$REPLY_LAUNCH_MAX_TOKENS" == "-" ]] && REPLY_LAUNCH_MAX_TOKENS=""
  REPLY_LAUNCH_ENDPOINT="http://127.0.0.1:${REPLY_LAUNCH_PORT}/v1"
}

_pi_agent_dir() {
  printf '%s\n' "${PI_CODING_AGENT_DIR:-$HOME/.pi/agent}"
}

_opencode_config_path() {
  local config_root="${XDG_CONFIG_HOME:-$HOME/.config}/opencode"
  if [[ -f "${config_root}/opencode.jsonc" ]]; then
    printf '%s\n' "${config_root}/opencode.jsonc"
  else
    printf '%s\n' "${config_root}/opencode.json"
  fi
}

_configure_pi_launch() {
  local endpoint="$1"
  local model="$2"
  local provider_id="$3"
  local context_window="${4:-}"
  local max_tokens="${5:-}"
  local agent_dir settings_path models_path settings_patch models_patch rendered

  agent_dir="$(_pi_agent_dir)"
  settings_path="${agent_dir}/settings.json"
  models_path="${agent_dir}/models.json"

  settings_patch="$(_render_launch_template "pi-settings" "$provider_id" "$endpoint" "$model" "$context_window" "$max_tokens")"
  rendered="$(_render_merged_json_file "$settings_path" "$settings_patch")"
  _write_text_file_with_backup "$settings_path" "$rendered" 1
  _report_file_update "$settings_path"

  models_patch="$(_render_launch_template "pi-models" "$provider_id" "$endpoint" "$model" "$context_window" "$max_tokens")"
  rendered="$(_render_merged_json_file "$models_path" "$models_patch" 0 "pi-models")"
  _write_text_file_with_backup "$models_path" "$rendered" 1
  _report_file_update "$models_path"
}

_configure_opencode_launch() {
  local endpoint="$1"
  local model="$2"
  local provider_id="$3"
  local context_window="${4:-}"
  local max_tokens="${5:-}"
  local config_path patch rendered jsonc_mode="0"

  config_path="$(_opencode_config_path)"
  [[ "$config_path" == *.jsonc ]] && jsonc_mode="1"

  patch="$(_render_launch_template "opencode" "$provider_id" "$endpoint" "$model" "$context_window" "$max_tokens")"
  rendered="$(_render_merged_json_file "$config_path" "$patch" "$jsonc_mode")"
  _write_text_file_with_backup "$config_path" "$rendered"
  _report_file_update "$config_path"
}

# Parse arguments for cmd_launch.
#
# Sets:
#   REPLY_LAUNCH_REQUESTED_PORT -> optional --port value
#   REPLY_LAUNCH_TOOL           -> launch target name
#   REPLY_LAUNCH_EXTRA_ARGS     -> passthrough args after '--'
#   REPLY_LAUNCH_SHOW_HELP      -> "true" when -h/--help was passed
#   REPLY_LAUNCH_ERROR          -> explanatory error string on failure
_parse_launch_args() {
  REPLY_LAUNCH_REQUESTED_PORT=""
  REPLY_LAUNCH_TOOL=""
  REPLY_LAUNCH_EXTRA_ARGS=()
  REPLY_LAUNCH_SHOW_HELP="false"
  REPLY_LAUNCH_ERROR=""

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --port)
        option_value_present "$@" || {
          REPLY_LAUNCH_ERROR="missing value for --port"
          return 1
        }
        [[ "$2" =~ ^[0-9]+$ ]] || {
          REPLY_LAUNCH_ERROR="invalid port '${2}'"
          return 1
        }
        REPLY_LAUNCH_REQUESTED_PORT="$2"
        shift 2
        ;;
      --)
        shift
        REPLY_LAUNCH_EXTRA_ARGS=("$@")
        break
        ;;
      -h|--help)
        REPLY_LAUNCH_SHOW_HELP="true"
        return 0
        ;;
      -* )
        REPLY_LAUNCH_ERROR="Unknown argument: $1"
        return 1
        ;;
      *)
        if [[ -n "$REPLY_LAUNCH_TOOL" ]]; then
          REPLY_LAUNCH_ERROR="Unknown argument: $1"
          return 1
        fi
        REPLY_LAUNCH_TOOL="$1"
        shift
        ;;
    esac
  done

  if [[ -z "$REPLY_LAUNCH_TOOL" && "$REPLY_LAUNCH_SHOW_HELP" != "true" ]]; then
    REPLY_LAUNCH_ERROR="missing launch target"
    return 1
  fi
}

_validate_launch_tool() {
  case "$1" in
    pi|opencode|codex) ;;
    *) die "unsupported launch target '${1}'. Expected one of: pi, opencode, codex" ;;
  esac
}
