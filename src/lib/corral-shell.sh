# Shell integration helpers for corral.
#
# Manages shell profile and completion installation. Provides:
#   - Shell config helpers: _escape_double_quoted_string(), _bash_startup_file(),
#     _zsh_startup_file(), _zsh_completions_dir(), _upsert_managed_block()
#   - PATH integration: install_path()
#   - Completion installation: install_completions()
# shellcheck shell=bash

# Add the llama.cpp bin directory to the user's shell profile (fish, zsh, or
# bash) so it persists across new terminal sessions.
install_path() {
  local current_link="$1"
  local profile_mode="$2"
  local parent_shell
  local escaped_current_link
  parent_shell="$(basename "${SHELL:-bash}")"
  escaped_current_link="$(_escape_double_quoted_string "$current_link")"

  local begin_marker="# BEGIN corral"
  local end_marker="# END corral"
  # The BEGIN/END sentinel lines make the PATH addition idempotent:
  # re-running install will not append a duplicate entry to the shell profile.

  if ! shell_profile_edits_allowed "$profile_mode"; then
    echo "Skipping shell profile edits. Add this to your PATH manually:"
    echo "  $current_link"
    return 0
  fi

  case "$parent_shell" in
    fish)
      local fish_conf="${HOME}/.config/fish/config.fish"
      _upsert_managed_block "$fish_conf" "$begin_marker" "$end_marker" "fish_add_path \"$escaped_current_link\""
      echo "Configured PATH in $fish_conf"
      ;;
    zsh)
      local zshrc="${ZDOTDIR:-$HOME}/.zshrc"
      _upsert_managed_block "$zshrc" "$begin_marker" "$end_marker" "export PATH=\"$escaped_current_link:\$PATH\""
      echo "Configured PATH in $zshrc"
      ;;
    bash)
      local bash_conf
      bash_conf="$(_bash_startup_file)"
      _upsert_managed_block "$bash_conf" "$begin_marker" "$end_marker" "export PATH=\"$escaped_current_link:\$PATH\""
      echo "Configured PATH in $bash_conf"
      ;;
    *)
      echo
      echo "Add this to your PATH:"
      echo "  $current_link"
      ;;
  esac
}

install_completions() {
  local profile_mode="$1"

  local parent_shell
  parent_shell="$(basename "${SHELL:-bash}")"

  case "$parent_shell" in
    fish)
      local dest_dir="${HOME}/.config/fish/completions"
      mkdir -p "$dest_dir"
      completions_fish > "${dest_dir}/${SCRIPT_NAME}.fish"
      echo "Installed fish completions -> ${dest_dir}/${SCRIPT_NAME}.fish"
      ;;
    zsh)
      local dest_dir
      local zshrc
      local loader_begin="# BEGIN corral zsh completions"
      local loader_end="# END corral zsh completions"
      local escaped_dest_dir
      local loader_body
      dest_dir="$(_zsh_completions_dir)"
      zshrc="$(_zsh_startup_file)"
      escaped_dest_dir="$(_escape_double_quoted_string "$dest_dir")"
      mkdir -p "$dest_dir"
      completions_zsh > "${dest_dir}/_${SCRIPT_NAME}"
      loader_body="$(cat <<EOF
if (( \${fpath[(Ie)"$escaped_dest_dir"]} == 0 )); then
  fpath=("$escaped_dest_dir" \$fpath)
fi
if (( ! \$+functions[compdef] )); then
  autoload -Uz compinit
  compinit
fi
EOF
)"
      if shell_profile_edits_allowed "$profile_mode"; then
        _upsert_managed_block "$zshrc" "$loader_begin" "$loader_end" "$loader_body"
        echo "Configured zsh completions loader in $zshrc"
      else
        echo "Zsh completions installed -> ${dest_dir}/_${SCRIPT_NAME}"
        echo "Add $dest_dir to fpath and run compinit from $zshrc to enable them."
        return 0
      fi
      echo "Installed zsh completions  -> ${dest_dir}/_${SCRIPT_NAME}"
      ;;
    bash)
      local dest="${HOME}/.bash_completion.d/${SCRIPT_NAME}"
      local bash_conf
      local loader_begin="# BEGIN corral bash completions"
      local loader_end="# END corral bash completions"
      local loader_body
      mkdir -p "${HOME}/.bash_completion.d"
      completions_bash > "$dest"
      bash_conf="$(_bash_startup_file)"
      loader_body="# corral shell completions"$'\n'"for f in ~/.bash_completion.d/*; do [[ -f \"\$f\" ]] && source \"\$f\"; done"
      if shell_profile_edits_allowed "$profile_mode"; then
        _upsert_managed_block "$bash_conf" "$loader_begin" "$loader_end" "$loader_body"
        echo "Configured bash completions loader in $bash_conf"
      else
        echo "Bash completions installed -> $dest"
        echo "Source them manually from $bash_conf if you want shell completion support."
        return 0
      fi
      echo "Installed bash completions -> $dest"
      ;;
    *)
      return 0
      ;;
  esac
}

# Escape a string for safe inclusion inside a double-quoted shell config line.
# Newlines are rejected because they would corrupt the managed config block.
_escape_double_quoted_string() {
  local value="$1"

  if [[ "$value" == *$'\n'* || "$value" == *$'\r'* ]]; then
    die "shell profile values cannot contain newlines"
  fi

  value="${value//\\/\\\\}"
  value="${value//\"/\\\"}"
  value="${value//\$/\\$}"
  value="${value//\`/\\\`}"
  printf '%s' "$value"
}

# Return the bash startup file corral should manage on this platform.
_bash_startup_file() {
  if [[ "$(uname -s)" == "Darwin" && -f "${HOME}/.bash_profile" ]]; then
    printf '%s' "${HOME}/.bash_profile"
  else
    printf '%s' "${HOME}/.bashrc"
  fi
}

_zsh_startup_file() {
  printf '%s' "${ZDOTDIR:-$HOME}/.zshrc"
}

_zsh_completions_dir() {
  printf '%s' "${ZDOTDIR:-$HOME}/.zfunc"
}

# Replace or append a managed block inside a shell config file.
_upsert_managed_block() {
  local file_path="$1"
  local begin_marker="$2"
  local end_marker="$3"
  local block_body="$4"
  local tmp_file
  local wrote_block="false"
  local inside_block="false"
  local line

  mkdir -p "$(dirname "$file_path")"
  touch "$file_path"
  tmp_file="$(mktemp)"

  while IFS= read -r line || [[ -n "$line" ]]; do
    if [[ "$inside_block" == "true" ]]; then
      if [[ "$line" == "$end_marker" ]]; then
        inside_block="false"
      fi
      continue
    fi

    if [[ "$line" == "$begin_marker" ]]; then
      if [[ "$wrote_block" == "false" ]]; then
        printf '%s\n%s\n%s\n' "$begin_marker" "$block_body" "$end_marker" >> "$tmp_file"
        wrote_block="true"
      fi
      inside_block="true"
      continue
    fi

    printf '%s\n' "$line" >> "$tmp_file"
  done < "$file_path"

  if [[ "$wrote_block" == "false" ]]; then
    [[ -s "$tmp_file" ]] && printf '\n' >> "$tmp_file"
    printf '%s\n%s\n%s\n' "$begin_marker" "$block_body" "$end_marker" >> "$tmp_file"
  fi

  mv "$tmp_file" "$file_path"
}
