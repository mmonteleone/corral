# Shared utility helpers for corral.
# shellcheck shell=bash

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

ANSI_COLOR_RESET=$'\033[0m'
ANSI_COLOR_BLACK=$'\033[30m'
ANSI_COLOR_RED=$'\033[31m'
ANSI_COLOR_GREEN=$'\033[32m'
ANSI_COLOR_YELLOW=$'\033[33m'
ANSI_COLOR_BLUE=$'\033[34m'
ANSI_COLOR_MAGENTA=$'\033[35m'
ANSI_COLOR_CYAN=$'\033[36m'
ANSI_COLOR_WHITE=$'\033[37m'

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

# Print text with a named ANSI color unconditionally.
_wrap_color() {
  local color_name="$1"
  local text="$2"

  printf '%s%s%s' "$(_ansi_color "$color_name")" "$text" "$ANSI_COLOR_RESET"
}

# Print text with a named ANSI color when stdout supports it; otherwise print
# the original text unchanged.
_wrap_stdout_color() {
  local color_name="$1"
  local text="$2"

  if _stdout_supports_color; then
    _wrap_color "$color_name" "$text"
  else
    printf '%s' "$text"
  fi
}

# Return 0 when stdout is an interactive terminal that should receive ANSI
# color sequences.
_stdout_supports_color() {
  _stream_supports_color 1
}

# Print a tab-separated table with dynamic column widths.
# Arguments:
#   $1 = alignment string using 'l' (left) or 'r' (right) per column.
#   $2 = header row as a single tab-separated string.
# Data rows are read from stdin as tab-separated lines.
_print_tsv_table() {
  local alignments="$1"
  local header_tsv="$2"
  local header_color_start=""
  local header_color_end=""

  if _stdout_supports_color; then
    header_color_start="$ANSI_COLOR_CYAN"
    header_color_end="$ANSI_COLOR_RESET"
  fi

  {
    printf '%s\n' "$header_tsv"
    cat
  } | awk -v FS='\t' -v OFS='  ' -v alignments="$alignments" \
      -v header_color_start="$header_color_start" -v header_color_end="$header_color_end" '
    function repeat(ch, count, out, i) {
      out = ""
      for (i = 0; i < count; i++) {
        out = out ch
      }
      return out
    }

    function visible_length(value, plain) {
      plain = value
      gsub(/\033\[[0-9;]*m/, "", plain)
      return length(plain)
    }

    {
      row_count++
      if (NF > col_count) {
        col_count = NF
      }
      for (i = 1; i <= NF; i++) {
        cells[row_count, i] = $i
        if (visible_length($i) > widths[i]) {
          widths[i] = visible_length($i)
        }
      }
    }

    END {
      if (row_count == 0) {
        exit 0
      }

      for (row = 1; row <= row_count; row++) {
        if (row == 1 && header_color_start != "") {
          printf "%s", header_color_start
        }
        for (col = 1; col <= col_count; col++) {
          value = cells[row, col]
          width = widths[col]
          if (substr(alignments, col, 1) == "r") {
            printf "%" width "s", value
          } else {
            printf "%-" width "s", value
          }
          if (col < col_count) {
            printf OFS
          }
        }
        if (row == 1 && header_color_end != "") {
          printf "%s", header_color_end
        }
        printf "\n"
      }
    }
  '
}

# Prepend the llama.cpp current/ bin dir to PATH if it is not already present.
# ${x/#\~/$HOME}: replace a leading '~' with $HOME inside a variable value;
# the shell's built-in tilde expansion does not apply to variable assignments
# or values that come from other variables.
ensure_llama_in_path() {
  local install_root="${CORRAL_INSTALL_ROOT:-$DEFAULT_INSTALL_ROOT}"
  # ${x/#\~/$HOME}: bash string substitution anchored to the start (#).
  # Replaces a literal '~' at position 0 with the real HOME path; necessary
  # because tilde expansion only happens at parse time, not in variable values.
  install_root="${install_root/#\~/$HOME}"
  local current_link="${install_root}/current"
  # ":$PATH:" sandwich: wrapping PATH in colons lets the glob *":dir:"*
  # match the dir at the beginning, middle, or end without special-casing.
  if [[ -d "$current_link" ]] && [[ ":$PATH:" != *":${current_link}:"* ]]; then
    export PATH="${current_link}:${PATH}"
  fi
}

# Return "mlx" or "llama.cpp" as the platform-based default backend.
# macOS arm64 (Apple Silicon) defaults to mlx; all other platforms default to llama.cpp.
# shellcheck disable=SC2329
_platform_default_backend() {
  if [[ "$(uname -s)" == "Darwin" && "$(uname -m)" == "arm64" ]]; then
    printf 'mlx'
  else
    printf 'llama.cpp'
  fi
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
    backend="$(_platform_default_backend)"
  fi

  case "$backend" in
    mlx|llama.cpp) printf '%s' "$backend" ;;
    *) die "unknown backend '${backend}': must be 'mlx' or 'llama.cpp'" ;;
  esac
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
_is_mlx_platform() {
  [[ "$(uname -s)" == "Darwin" && "$(uname -m)" == "arm64" ]]
}

# Verify that mlx_lm CLI tools are accessible on PATH.
# shellcheck disable=SC2329
require_mlx_lm() {
  command -v mlx_lm.chat >/dev/null 2>&1 || \
    command -v mlx_lm.generate >/dev/null 2>&1 || \
    die "mlx_lm not found. Install it first: $SCRIPT_NAME install --backend mlx"
}
