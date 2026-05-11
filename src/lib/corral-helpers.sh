# Shared utility helpers for corral.
#
# Foundation module sourced by all other corral modules. Provides:
#   - Error handling: die(), confirm_action(), confirm_destructive_action()
#   - Shell profile permission management: shell_profile_edits_allowed()
#   - Prerequisite checking: require_cmds()
#   - Path normalization: normalize_dir_path(), ensure_llama_in_path()
#   - ANSI colour helpers: wrap_color(), _stream_supports_color(), etc.
#   - Tabular output: print_tsv_table() — TSV-to-padded-columns formatter
#   - Backend resolution: resolve_backend(), validate_backend_flag(),
#     platform_default_backend(), require_mlx_platform(), is_mlx_platform()
# shellcheck shell=bash

# REPLY_* output convention:
#   Several modules return structured data by setting REPLY_* globals instead
#   of printing multiple lines or forcing callers through subshell parsing.
#   Common examples include:
#     parse_model_spec()              -> REPLY_MODEL, REPLY_QUANT
#     load_profile()                  -> REPLY_PROFILE_MODEL, REPLY_PROFILE_ARGS
#     _parse_model_command_args()     -> REPLY_MODEL_COMMAND_*
#     _launch_resolve_target()        -> REPLY_LAUNCH_*
#   Check each helper's doc comment before consuming its REPLY_* outputs.

# Module boundary convention:
#   - Public cross-module helpers do not use a leading underscore.
#   - Private module-local helpers do use a leading underscore.
#   Keep shared surfaces explicit so sourced-module dependencies stay readable.

# Print an error message to stderr and exit non-zero.
die() { echo "Error: $*" >&2; exit 1; }

# Prompt for a y/N confirmation on stderr. Returns 0 on yes, 1 on no or EOF.
confirm_action() {
  local prompt="$1"
  local reply

  printf '%s [y/N] ' "$prompt" >&2
  # read -r: -r prevents backslash interpretation in the reply.
  # If read hits EOF (e.g. piped input ends), it returns non-zero → return 1.
  read -r reply || return 1
  case "$reply" in
    y|Y|yes|YES|Yes) return 0 ;;
    *) return 1 ;;
  esac
}

# Determine whether shell profile edits are permitted.
# mode: "always" — permit unconditionally
#       "never"  — deny unconditionally
#       "ask"    — prompt once; the answer is cached in SHELL_PROFILE_EDIT_DECISION
#                  for the duration of this process to avoid repeated prompts.
shell_profile_edits_allowed() {
  local mode="$1"

  case "$mode" in
    always) return 0 ;;
    never) return 1 ;;
    ask)
      # Return early if we already have a cached decision from earlier in this run.
      if [[ "$SHELL_PROFILE_EDIT_DECISION" == "allow" ]]; then
        return 0
      fi
      if [[ "$SHELL_PROFILE_EDIT_DECISION" == "deny" ]]; then
        return 1
      fi
      # [[ ! -t 0 ]]: stdin is not a terminal — we're in a non-interactive context
      # (e.g. piped or scripted invocation). Default to deny instead of hanging.
      if [[ ! -t 0 ]]; then
        SHELL_PROFILE_EDIT_DECISION="deny"
        return 1
      fi
      if confirm_action "Allow corral to edit your shell profile for PATH/completion loading?"; then
        SHELL_PROFILE_EDIT_DECISION="allow"
        return 0
      fi
      SHELL_PROFILE_EDIT_DECISION="deny"
      return 1
      ;;
    *)
      die "invalid shell profile edit mode: ${mode}"
      ;;
  esac
}

# Confirm a destructive operation before proceeding.
# With force=true the prompt is skipped. In non-interactive mode (stdin not a
# terminal) the operation is refused outright unless --force was passed.
confirm_destructive_action() {
  local description="$1"
  local force="$2"

  if [[ "$force" == "true" ]]; then
    return 0
  fi

  # Non-interactive context: refuse rather than silently proceeding.
  if [[ ! -t 0 ]]; then
    die "refusing to ${description} without --force in non-interactive mode."
  fi

  if confirm_action "Proceed with ${description}?"; then
    return 0
  fi

  echo "Aborted." >&2
  return 1
}

# Verify that every listed command exists on PATH, exiting with a helpful
# message if any is missing. llama-cli/llama-server get a hint to run install.
# 'command -v' is the POSIX-portable way to check if a command exists;
# unlike 'which', it also finds builtins and functions and doesn't print output.
require_cmds() {
  for cmd in "$@"; do
    command -v "$cmd" >/dev/null 2>&1 || {
      case "$cmd" in
        llama-cli|llama-server)
          die "required command not found: $cmd (not installed? run: $SCRIPT_NAME install)" ;;
        *)
          die "required command not found: $cmd" ;;
      esac
    }
  done
}

# Return success when an option token has a non-empty, non-option value token
# following it.
# Call with the current parser argument list, e.g.:
#   option_value_present "$@" || { echo "missing value for $1" >&2; return 1; }
option_value_present() {
  [[ $# -ge 2 && -n "${2:-}" && "${2:-}" != --* ]]
}

# Expand a leading '~' and strip a trailing slash from a directory path.
# Returns the normalized path on stdout.
# Special case: preserve '/' instead of trimming it to an empty string.
normalize_dir_path() {
  local dir="$1"
  dir="${dir/#\~/$HOME}"
  if [[ "$dir" != "/" ]]; then
    dir="${dir%/}"
  fi
  printf '%s' "$dir"
}

ANSI_COLOR_RESET=$'\033[0m'
ANSI_COLOR_BLACK=$'\033[30m'
ANSI_COLOR_RED=$'\033[31m'
ANSI_COLOR_GREEN=$'\033[32m'
ANSI_COLOR_YELLOW=$'\033[33m'
ANSI_COLOR_BLUE=$'\033[34m'
ANSI_COLOR_MAGENTA=$'\033[35m'
ANSI_COLOR_CYAN=$'\033[36m'
ANSI_COLOR_WHITE=$'\033[37m'

# Print text with a named ANSI color unconditionally.
wrap_color() {
  local color_name="$1"
  local text="$2"

  printf '%s%s%s' "$(_ansi_color "$color_name")" "$text" "$ANSI_COLOR_RESET"
}

# Return 0 when stdout is an interactive terminal that should receive ANSI
# color sequences.
stdout_supports_color() {
  _stream_supports_color 1
}

# Print a tab-separated table with dynamic column widths.
# Arguments:
#   $1 = alignment string using 'l' (left) or 'r' (right) per column.
#   $2 = header row as a single tab-separated string.
# Data rows are read from stdin as tab-separated lines.
print_tsv_table() {
  local alignments="$1"
  local header_tsv="$2"
  local header_color_start=""
  local header_color_end=""

  if stdout_supports_color; then
    header_color_start="$ANSI_COLOR_CYAN"
    header_color_end="$ANSI_COLOR_RESET"
  fi

  {
    printf '%s\n' "$header_tsv"
    cat
  } | awk -v FS='\t' -v OFS='  ' -v alignments="$alignments" \
      -v header_color_start="$header_color_start" -v header_color_end="$header_color_end" \
      "$(_print_tsv_table_awk)"
}

# Prepend the llama.cpp current/ bin dir to PATH if it is not already present.
# ${x/#\~/$HOME}: replace a leading '~' with $HOME inside a variable value;
# the shell's built-in tilde expansion does not apply to variable assignments
# or values that come from other variables.
ensure_llama_in_path() {
  local install_root="${CORRAL_INSTALL_ROOT:-$DEFAULT_INSTALL_ROOT}"
  install_root="$(normalize_dir_path "$install_root")"
  local current_link="${install_root}/current"
  # ":$PATH:" sandwich: wrapping PATH in colons lets the glob *":dir:"*
  # match the dir at the beginning, middle, or end without special-casing.
  if [[ -d "$current_link" ]] && [[ ":$PATH:" != *":${current_link}:"* ]]; then
    export PATH="${current_link}:${PATH}"
  fi
}

# Return "llama.cpp" as the platform-based default backend.
# Corral now prefers llama.cpp everywhere; MLX remains available only when
# explicitly requested with --backend mlx.
# shellcheck disable=SC2329
platform_default_backend() {
  printf 'llama.cpp'
}

# Resolve the effective backend for a command.
# Precedence: explicit --backend flag value > platform default.
# Prints "mlx" or "llama.cpp".
# shellcheck disable=SC2329
resolve_backend() {
  local flag_value="${1:-}"
  local backend

  if [[ -n "$flag_value" ]]; then
    backend="$flag_value"
  else
    backend="$(platform_default_backend)"
  fi

  case "$backend" in
    mlx|llama.cpp) printf '%s' "$backend" ;;
    *) die "unknown backend '${backend}': must be 'mlx' or 'llama.cpp'" ;;
  esac
}

# Validate a raw --backend flag value without resolving a default.
# Dies with a usage error if the value is non-empty and not one of the
# recognised backends (mlx, llama.cpp). No-ops on empty values (meaning
# "no --backend was passed"). Used by cmd_install/update/uninstall/versions
# where the flag is checked before any resolution or dispatch.
validate_backend_flag() {
  local flag_value="${1:-}"
  if [[ -n "$flag_value" ]]; then
    case "$flag_value" in
      mlx|llama.cpp) ;;
      *) die "unknown backend '${flag_value}': must be 'mlx' or 'llama.cpp'" ;;
    esac
  fi
}

# Exit with a helpful message if the current platform does not support MLX.
# MLX requires macOS on Apple Silicon (arm64).
# shellcheck disable=SC2329
require_mlx_platform() {
  if [[ "$(uname -s)" != "Darwin" || "$(uname -m)" != "arm64" ]]; then
    die "MLX backend is only supported on macOS Apple Silicon (arm64). Current: $(uname -s)/$(uname -m). Use --backend llama.cpp instead."
  fi
}

# Return 0 if the current platform supports MLX (macOS Apple Silicon), 1 otherwise.
# Non-fatal check: unlike require_mlx_platform(), this does not exit on failure.
# shellcheck disable=SC2329
is_mlx_platform() {
  [[ "$(uname -s)" == "Darwin" && "$(uname -m)" == "arm64" ]]
}

# Verify that mlx_lm CLI tools are accessible on PATH.
# shellcheck disable=SC2329
require_mlx_lm() {
  command -v mlx_lm.chat >/dev/null 2>&1 || \
    command -v mlx_lm.generate >/dev/null 2>&1 || \
    die "mlx_lm not found. Install it first: $SCRIPT_NAME install --backend mlx"
}

# Print the awk program used by print_tsv_table().
# In source mode this reads src/awk/table.awk from disk; tools/build.sh
# replaces the marked block with an inlined heredoc in standalone builds.
_print_tsv_table_awk() {
# BEGIN_TABLE_AWK
  local awk_path
  awk_path="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../awk/table.awk"
  cat "$awk_path"
# END_TABLE_AWK
}

# Strip trailing spaces and tabs without requiring extglob to be enabled.
_trim_trailing_whitespace() {
  local value="$1"
  local whitespace=$' \t'
  value="${value%"${value##*[!"$whitespace"]}"}"
  printf '%s' "$value"
}

# Return 0 when the target file descriptor is an interactive terminal that
# should receive ANSI color sequences.
_stream_supports_color() {
  local fd="${1:-1}"

  [[ -t "$fd" ]] || return 1
  [[ -z "${NO_COLOR:-}" ]] || return 1
  [[ "${TERM:-}" != "dumb" ]] || return 1
}

# Resolve a symbolic ANSI color name to its escape sequence.
_ansi_color() {
  local color_name="$1"

  case "$color_name" in
    reset) printf '%s' "$ANSI_COLOR_RESET" ;;
    black) printf '%s' "$ANSI_COLOR_BLACK" ;;
    red) printf '%s' "$ANSI_COLOR_RED" ;;
    green) printf '%s' "$ANSI_COLOR_GREEN" ;;
    yellow) printf '%s' "$ANSI_COLOR_YELLOW" ;;
    blue) printf '%s' "$ANSI_COLOR_BLUE" ;;
    magenta) printf '%s' "$ANSI_COLOR_MAGENTA" ;;
    cyan) printf '%s' "$ANSI_COLOR_CYAN" ;;
    white) printf '%s' "$ANSI_COLOR_WHITE" ;;
    *) return 1 ;;
  esac
}

# Print text with a named ANSI color when stdout supports it; otherwise print
# the original text unchanged.
_wrap_stdout_color() {
  local color_name="$1"
  local text="$2"

  if stdout_supports_color; then
    wrap_color "$color_name" "$text"
  else
    printf '%s' "$text"
  fi
}
