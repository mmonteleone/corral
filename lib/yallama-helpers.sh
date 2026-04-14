# Shared utility helpers for yallama.

die() { echo "Error: $*" >&2; exit 1; }

confirm_action() {
  local prompt="$1"
  local reply

  printf '%s [y/N] ' "$prompt" >&2
  read -r reply || return 1
  case "$reply" in
    y|Y|yes|YES|Yes) return 0 ;;
    *) return 1 ;;
  esac
}

shell_profile_edits_allowed() {
  local mode="$1"

  case "$mode" in
    always) return 0 ;;
    never) return 1 ;;
    ask)
      if [[ "$SHELL_PROFILE_EDIT_DECISION" == "allow" ]]; then
        return 0
      fi
      if [[ "$SHELL_PROFILE_EDIT_DECISION" == "deny" ]]; then
        return 1
      fi
      if [[ ! -t 0 ]]; then
        SHELL_PROFILE_EDIT_DECISION="deny"
        return 1
      fi
      if confirm_action "Allow yallama to edit your shell profile for PATH/completion loading?"; then
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

confirm_destructive_action() {
  local description="$1"
  local force="$2"

  if [[ "$force" == "true" ]]; then
    return 0
  fi

  if [[ ! -t 0 ]]; then
    die "refusing to ${description} without --force in non-interactive mode."
  fi

  if confirm_action "Proceed with ${description}?"; then
    return 0
  fi

  echo "Aborted." >&2
  return 1
}

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

# Prepend the llama.cpp current/ bin dir to PATH if it is not already there.
ensure_llama_in_path() {
  local install_root="${YALLAMA_INSTALL_ROOT:-$DEFAULT_INSTALL_ROOT}"
  install_root="${install_root/#\~/$HOME}"
  local current_link="${install_root}/current"
  if [[ -d "$current_link" ]] && [[ ":$PATH:" != *":${current_link}:"* ]]; then
    export PATH="${current_link}:${PATH}"
  fi
}
