# Inventory and removal helpers for corral.
#
# Builds the user-facing inventory across cache, profiles, and templates, and
# owns removal flows for cached models and saved profiles. Provides:
#   - cmd_list (ls)
#   - cmd_remove (rm)
# shellcheck shell=bash

cmd_list_usage() {
  cat <<EOF
Usage: $SCRIPT_NAME list [--backend <mlx|llama.cpp>] [--quiet] [--models] [--profiles] [--templates]
  $SCRIPT_NAME ls   [--backend <mlx|llama.cpp>] [--quiet] [--models] [--profiles] [--templates]

Lists backend-scoped cached models plus saved profiles and templates.

When multiple entry types are included, output is grouped into separate
sections. For GGUF models, each downloaded quant variant is shown as a
separate row (e.g. user/model:Q4_K_M).

Options:
  --backend <backend>
            Model listing backend scope: mlx or llama.cpp. Omit to include both.
  --models  Include only model entries.
  --profiles Include only profile entries.
  --templates Include only template entries.
  --quiet   Print only model[:quant] identifiers, one per line. Useful for piping.
EOF
}

cmd_list() {
  if ! _parse_list_args "$@"; then
    echo "$REPLY_LIST_ERROR" >&2
    cmd_list_usage >&2
    return 1
  fi

  if [[ "$REPLY_LIST_SHOW_HELP" == "true" ]]; then
    cmd_list_usage
    return 0
  fi

  local BACKEND_FLAG="$REPLY_LIST_BACKEND_FLAG"
  local QUIET="$REPLY_LIST_QUIET"
  local SHOW_MODELS="$REPLY_LIST_SHOW_MODELS"
  local SHOW_PROFILES="$REPLY_LIST_SHOW_PROFILES"
  local SHOW_TEMPLATES="$REPLY_LIST_SHOW_TEMPLATES"

  local BACKEND="all"
  if [[ -n "$BACKEND_FLAG" ]]; then
    BACKEND="$(resolve_backend "$BACKEND_FLAG")"
  fi

  local model_entries=()
  local profile_entries=()
  local template_entries=()
  local entry

  if [[ "$SHOW_MODELS" == "true" ]]; then
    if [[ "$BACKEND" == "all" || "$BACKEND" == "mlx" ]]; then
      while IFS= read -r entry; do
        [[ -z "$entry" ]] && continue
        model_entries+=("$entry")
      done < <(collect_mlx_model_entries)
    fi

    if [[ "$BACKEND" == "all" || "$BACKEND" == "llama.cpp" ]] && [[ -d "$HF_HUB_DIR" ]]; then
      while IFS= read -r entry; do
        [[ -z "$entry" ]] && continue
        model_entries+=("$entry")
      done < <(collect_cached_model_entries)
    fi
    if [[ ${#model_entries[@]} -gt 0 ]]; then
      local _sorted=()
      while IFS= read -r entry; do
        _sorted+=("$entry")
      done < <(printf '%s\n' "${model_entries[@]}" | sort -f -t'|' -k1,1)
      model_entries=("${_sorted[@]}")
    fi
  fi

  if [[ "$SHOW_PROFILES" == "true" ]]; then
    while IFS= read -r entry; do
      [[ -z "$entry" ]] && continue
      profile_entries+=("$entry")
    done < <(collect_profile_entries)
    if [[ ${#profile_entries[@]} -gt 0 ]]; then
      local _sorted=()
      while IFS= read -r entry; do
        _sorted+=("$entry")
      done < <(printf '%s\n' "${profile_entries[@]}" | sort -f -t'|' -k1,1)
      profile_entries=("${_sorted[@]}")
    fi
  fi

  if [[ "$SHOW_TEMPLATES" == "true" ]]; then
    while IFS= read -r entry; do
      [[ -z "$entry" ]] && continue
      template_entries+=("$entry")
    done < <(collect_template_entries)
    if [[ ${#template_entries[@]} -gt 0 ]]; then
      local _sorted=()
      while IFS= read -r entry; do
        _sorted+=("$entry")
      done < <(printf '%s\n' "${template_entries[@]}" | sort -f -t'|' -k1,1)
      template_entries=("${_sorted[@]}")
    fi
  fi

  local model_count profile_count template_count
  model_count=${#model_entries[@]}
  profile_count=${#profile_entries[@]}
  template_count=${#template_entries[@]}

  if [[ "$model_count" -eq 0 && "$profile_count" -eq 0 && "$template_count" -eq 0 ]]; then
    if [[ "$SHOW_MODELS" == "true" && "$SHOW_PROFILES" == "true" && "$SHOW_TEMPLATES" == "true" ]]; then
      echo "No models, profiles, or templates found."
    elif [[ "$SHOW_MODELS" == "true" ]]; then
      echo "No models found."
    elif [[ "$SHOW_PROFILES" == "true" ]]; then
      echo "No profiles found."
    else
      echo "No templates found."
    fi
    return 0
  fi

  if [[ "$QUIET" == "true" ]]; then
    if [[ "$model_count" -gt 0 ]]; then
      local e
      for e in "${model_entries[@]}"; do
        local name quant
        name="${e%%|*}"
        local rest="${e#*|}"
        quant="${rest%%|*}"
        if [[ -n "$quant" ]]; then
          echo "${name}:${quant}"
        else
          echo "$name"
        fi
      done
    fi

    if [[ "$profile_count" -gt 0 ]]; then
      local e
      for e in "${profile_entries[@]}"; do
        local pname
        pname="${e%%|*}"
        echo "$pname"
      done
    fi

    if [[ "$template_count" -gt 0 ]]; then
      local e
      for e in "${template_entries[@]}"; do
        local tname
        tname="${e%%|*}"
        echo "$tname"
      done
    fi
  else
    if [[ "$model_count" -gt 0 ]]; then
      local color_model_sizes="false"
      stdout_supports_color && color_model_sizes="true"

      {
        local e
        for e in "${model_entries[@]}"; do
          local name quant size backend display_name
          name="${e%%|*}"
          local rest="${e#*|}"
          quant="${rest%%|*}"
          rest="${rest#*|}"
          size="${rest%%|*}"
          backend="${rest#*|}"
          if [[ -n "$quant" ]]; then
            display_name="${name}:${quant}"
          else
            display_name="$name"
          fi
          if [[ "$color_model_sizes" == "true" ]]; then
            size="$(wrap_color green "$size")"
          fi
          printf '%s\t%s\t%s\n' "$display_name" "$backend" "$size"
        done
      } | print_tsv_table 'lll' $'MODEL\tBACKEND\tSIZE'
    fi

    if [[ "$profile_count" -gt 0 ]]; then
      [[ "$model_count" -gt 0 ]] && echo
      {
        local e
        for e in "${profile_entries[@]}"; do
          local pname pmodel
          pname="${e%%|*}"
          pmodel="${e#*|}"
          printf '%s\t%s\n' "$pname" "$pmodel"
        done
      } | print_tsv_table 'll' $'PROFILE\tMODEL'
    fi

    if [[ "$template_count" -gt 0 ]]; then
      [[ "$model_count" -gt 0 || "$profile_count" -gt 0 ]] && echo
      {
        local e
        for e in "${template_entries[@]}"; do
          local tname ttype tmodel
          tname="${e%%|*}"
          local trest="${e#*|}"
          ttype="${trest%%|*}"
          tmodel="${trest#*|}"
          printf '%s\t%s\t%s\n' "$tname" "$ttype" "$tmodel"
        done
      } | print_tsv_table 'lll' $'TEMPLATE\tTYPE\tDEFAULT MODEL'
    fi
  fi
}

cmd_remove_usage() {
  cat <<EOF
Usage: $SCRIPT_NAME remove [--backend <mlx|llama.cpp>] <MODEL_NAME>[:<QUANT>] [--force]
  $SCRIPT_NAME rm [--backend <mlx|llama.cpp>] <MODEL_NAME>[:<QUANT>] [--force]
       $SCRIPT_NAME remove <PROFILE_NAME>
       $SCRIPT_NAME rm <PROFILE_NAME>

Arguments:
  MODEL_NAME    HuggingFace model identifier, e.g. unsloth/gemma-4-26B-A4B-it-GGUF
  QUANT         Optional quant tag to remove only a specific variant
                (e.g. Q4_K_M, UD-Q6_K). Without it, the entire model is removed.

Use '$SCRIPT_NAME list' to see available quant tags.

Passing a profile name removes that saved profile.

Deletes the locally cached model or quant variant. Refuses if the model is
currently in use by llama-cli or llama-server.

Model and quant removal applies to GGUF cache entries used by llama.cpp workflows.
With --backend mlx, quant suffixes are ignored and removal targets MLX model state.

Options:
  --backend <backend>
                Removal backend scope for model targets: mlx or llama.cpp (default: platform-detected).
  --force       Skip the confirmation prompt.
EOF
}

cmd_remove() {
  # Idiomatic help/no-args guard used throughout corral:
  # With no args: print usage to stderr and return 1 (error).
  # With -h/--help: print usage to stdout and return 0 (success).
  if [[ $# -eq 0 || "$1" == "-h" || "$1" == "--help" ]]; then
    cmd_remove_usage
    [[ $# -eq 0 ]] && return 1 || return 0
  fi

  if ! _parse_remove_args "$@"; then
    echo "$REPLY_REMOVE_ERROR" >&2
    cmd_remove_usage >&2
    return 1
  fi

  if [[ "$REPLY_REMOVE_SHOW_HELP" == "true" ]]; then
    cmd_remove_usage
    return 0
  fi

  local BACKEND_FLAG="$REPLY_REMOVE_BACKEND_FLAG"
  local target_spec="$REPLY_REMOVE_TARGET_SPEC"
  local force="$REPLY_REMOVE_FORCE"

  # If TARGET has no model slash/quant suffix and matches an existing profile,
  # treat this as profile deletion for parity with model removal.
  if _remove_existing_profile_target "$target_spec"; then
    return 0
  fi

  local BACKEND
  if [[ -n "$BACKEND_FLAG" ]]; then
    BACKEND="$(resolve_backend "$BACKEND_FLAG")"
  else
    BACKEND="$(_infer_remove_backend "$target_spec")"
  fi

  if [[ "$BACKEND" == "mlx" ]]; then
    _remove_mlx_target "$target_spec" "$force"
    return 0
  fi

  _remove_llama_target "$target_spec" "$force"
}

_remove_mlx_target() {
  local target_spec="$1"
  local force="$2"

  local model_name
  parse_model_spec "$target_spec"
  model_name="$REPLY_MODEL"

  if [[ -n "$REPLY_QUANT" ]]; then
    echo "Warning: MLX backend does not use quant specifiers; ignoring ':${REPLY_QUANT}'." >&2
  fi

  if [[ "$model_name" != */* ]]; then
    die "profiles are not supported with the MLX backend. Use a HuggingFace model id (USER/MODEL) or --backend llama.cpp."
  fi

  if mlx_model_is_in_use "$model_name"; then
    die "cannot remove '${model_name}': it is currently in use by mlx_lm.chat or mlx_lm.server."
  fi

  local cache_dir
  cache_dir="$(model_name_to_cache_dir "$model_name")"
  if [[ ! -d "$cache_dir" ]]; then
    die "model not found: ${model_name}"
  fi

  confirm_destructive_action "removing MLX model '${model_name}'" "$force" || return 1

  echo "Removing model cache: $cache_dir"
  rm -rf "$cache_dir"

  echo "Removed MLX model: $model_name"
}

_enable_list_scope() {
  local scope="$1"

  if [[ "$REPLY_LIST_SCOPE_SET" == "false" ]]; then
    REPLY_LIST_SHOW_MODELS="false"
    REPLY_LIST_SHOW_PROFILES="false"
    REPLY_LIST_SHOW_TEMPLATES="false"
    REPLY_LIST_SCOPE_SET="true"
  fi

  case "$scope" in
    models) REPLY_LIST_SHOW_MODELS="true" ;;
    profiles) REPLY_LIST_SHOW_PROFILES="true" ;;
    templates) REPLY_LIST_SHOW_TEMPLATES="true" ;;
  esac
}

_parse_list_args() {
  REPLY_LIST_BACKEND_FLAG=""
  REPLY_LIST_QUIET="false"
  REPLY_LIST_SHOW_MODELS="true"
  REPLY_LIST_SHOW_PROFILES="true"
  REPLY_LIST_SHOW_TEMPLATES="true"
  REPLY_LIST_SCOPE_SET="false"
  REPLY_LIST_SHOW_HELP="false"
  REPLY_LIST_ERROR=""

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --backend)
        option_value_present "$@" || {
          REPLY_LIST_ERROR="missing value for --backend"
          return 1
        }
        REPLY_LIST_BACKEND_FLAG="$2"
        validate_backend_flag "$REPLY_LIST_BACKEND_FLAG"
        shift 2
        ;;
      --quiet)
        REPLY_LIST_QUIET="true"
        shift
        ;;
      --models)
        _enable_list_scope models
        shift
        ;;
      --profiles)
        _enable_list_scope profiles
        shift
        ;;
      --templates)
        _enable_list_scope templates
        shift
        ;;
      -h|--help)
        REPLY_LIST_SHOW_HELP="true"
        return 0
        ;;
      *)
        REPLY_LIST_ERROR="Unknown argument: $1"
        return 1
        ;;
    esac
  done
}

_parse_remove_args() {
  REPLY_REMOVE_BACKEND_FLAG=""
  REPLY_REMOVE_TARGET_SPEC=""
  REPLY_REMOVE_FORCE="false"
  REPLY_REMOVE_SHOW_HELP="false"
  REPLY_REMOVE_ERROR=""

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --backend)
        option_value_present "$@" || {
          REPLY_REMOVE_ERROR="missing value for --backend"
          return 1
        }
        REPLY_REMOVE_BACKEND_FLAG="$2"
        validate_backend_flag "$REPLY_REMOVE_BACKEND_FLAG"
        shift 2
        ;;
      --force)
        REPLY_REMOVE_FORCE="true"
        shift
        ;;
      -h|--help)
        REPLY_REMOVE_SHOW_HELP="true"
        return 0
        ;;
      *)
        if [[ -z "$REPLY_REMOVE_TARGET_SPEC" ]]; then
          REPLY_REMOVE_TARGET_SPEC="$1"
          shift
        else
          REPLY_REMOVE_ERROR="Unknown argument: $1"
          return 1
        fi
        ;;
    esac
  done

  if [[ -z "$REPLY_REMOVE_TARGET_SPEC" && "$REPLY_REMOVE_SHOW_HELP" != "true" ]]; then
    REPLY_REMOVE_ERROR="missing model or profile target"
    return 1
  fi
}

_remove_existing_profile_target() {
  local target_spec="$1"

  if [[ "$target_spec" != */* && "$target_spec" != *:* ]]; then
    local profile_path
    profile_path="$(profile_path "$target_spec")"
    if [[ -f "$profile_path" ]]; then
      remove_profile_by_name "$target_spec"
      return 0
    fi
  fi

  return 1
}

_infer_remove_backend() {
  local target_spec="$1"
  local model_name quant

  parse_model_spec "$target_spec"
  model_name="$REPLY_MODEL"
  quant="$REPLY_QUANT"

  if [[ -n "$quant" ]]; then
    printf 'llama.cpp'
    return 0
  fi

  local cache_dir
  cache_dir="$(model_name_to_cache_dir "$model_name" 2>/dev/null || true)"
  if [[ -n "$cache_dir" && -d "$cache_dir" ]]; then
    local has_gguf="false"
    local has_mlx="false"

    cache_dir_has_gguf "$cache_dir" && has_gguf="true"
    cache_dir_has_mlx_weights "$cache_dir" && has_mlx="true"

    case "${has_gguf}:${has_mlx}" in
      true:false)
        printf 'llama.cpp'
        return 0
        ;;
      false:true)
        printf 'mlx'
        return 0
        ;;
      true:true)
        die "model '${model_name}' has both GGUF and MLX cache entries. Re-run with --backend llama.cpp or --backend mlx to choose what to remove."
        ;;
    esac
  fi

  resolve_backend ""
}

_remove_llama_target() {
  local target_spec="$1"
  local force="$2"

  local model_name quant
  parse_model_spec "$target_spec"
  model_name="$REPLY_MODEL"
  quant="$REPLY_QUANT"

  local cache_dir
  cache_dir="$(model_name_to_cache_dir "$model_name")"

  if [[ ! -d "$cache_dir" ]]; then
    die "model not found: ${model_name} (expected at ${cache_dir})"
  fi

  if [[ -n "$quant" ]]; then
    local matching_files
    matching_files="$(find_gguf_by_quant "$cache_dir" "$quant")"
    if [[ -z "$matching_files" ]]; then
      die "no cached files matching quant '${quant}' found for model '${model_name}'"
    fi

    quant_is_in_use "$cache_dir" "$model_name" "$quant"

    confirm_destructive_action "removing quant '${quant}' from '${model_name}'" "$force" || return 1

    echo "Removing quant: ${model_name}:${quant}"
    remove_quant_files "$cache_dir" "$quant"

    local remaining
    remaining="$(find_cached_gguf_files "$cache_dir")"
    if [[ -z "$remaining" ]]; then
      echo "No remaining quants. Removing model cache."
      rm -rf "$cache_dir"
    fi
    echo "Done."
    return 0
  fi

  if model_is_in_use "$cache_dir"; then
    die "cannot remove '${model_name}': it is currently in use by llama-cli or llama-server."
  fi

  local all_quants quant_list=()
  all_quants="$(find_cached_gguf_files "$cache_dir")"
  if [[ -n "$all_quants" ]]; then
    while IFS= read -r fname; do
      [[ -z "$fname" ]] && continue
      local tag
      tag="$(extract_quant_from_filename "$fname")"
      quant_list+=("$tag")
    done < <(printf '%s\n' "$all_quants" | sort -u)
  fi

  echo "The following quant variants will be removed:"
  if [[ ${#quant_list[@]} -gt 0 ]]; then
    local q
    for q in "${quant_list[@]}"; do
      printf '  %s:%s\n' "$model_name" "$q"
    done
  else
    printf '  %s  (no GGUF variants found)\n' "$model_name"
  fi
  echo

  confirm_destructive_action "removing cached model '${model_name}'" "$force" || return 1

  echo "Removing model: $model_name"
  rm -rf "$cache_dir"
  echo "Done."
}
