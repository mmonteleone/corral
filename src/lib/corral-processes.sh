# Runtime process inspection helpers for corral.
#
# Detects running llama.cpp and MLX processes and exposes:
#   - Public helpers: emit_runtime_process_rows(), model_is_in_use(),
#     mlx_model_is_in_use(), quant_is_in_use(), cmd_ps()
#   - emit_runtime_process_rows() — PID/process/port/model rows
#   - cmd_ps() — user-facing process table
#   - model_is_in_use(), mlx_model_is_in_use(), quant_is_in_use() — guards for removal
# shellcheck shell=bash

emit_runtime_process_rows() {
  # Try GNU/Linux ps format first (-eo); fall back to BSD/macOS (-ax -o).
  # Detect target processes from the command name or early executable/script
  # tokens in args. Limiting fallback to the first command-like fields avoids
  # self-matching awk script text that may mention llama/port flags.
  { ps -eo pid=,comm=,args= -ww 2>/dev/null || ps -ax -o pid=,comm=,args= -ww 2>/dev/null; } | awk '
    {
      pid = $1
      proc = $2
      matched = ""

      if (proc ~ /^llama-(cli|server)$/ || proc == "mlx_lm.server" || proc == "mlx_lm.chat") {
        matched = proc
      } else {
        for (i = 3; i <= NF && i <= 4; i++) {
          if ($i ~ /^-/) {
            break
          }

          token = $i
          sub(/^.*\//, "", token)

          if (token ~ /^llama-(cli|server)$/ || token == "mlx_lm.server" || token == "mlx_lm.chat") {
            matched = token
            break
          }
        }
      }

      if (matched == "") {
        next
      }

      proc = matched

      model = "(unknown)"
      port = "-"

      for (i = 3; i <= NF; i++) {
        if (($i == "-hf" || $i == "--hf" || $i == "--model") && i < NF) {
          model = $(i + 1)
        } else if (($i == "-p" || $i == "--port") && i < NF) {
          port = $(i + 1)
        } else if ($i ~ /^--port=/) {
          split($i, parts, "=")
          port = parts[2]
        } else if ($i ~ /^-p[0-9]+$/) {
          port = substr($i, 3)
        }
      }

      sub(/^.*\//, "", proc)
      if (proc != "llama-server" && proc != "mlx_lm.server") {
        port = "-"
      } else if (port == "-") {
        # llama-server and mlx_lm.server default to port 8080 when --port is not explicitly given.
        port = "8080"
      }

      printf "%s\t%s\t%s\t%s\n", pid, proc, port, model
    }
  '
}

# Check whether any running llama-cli or llama-server process has open files
# inside cache_dir. Uses lsof where available (e.g. macOS, most Linux distros);
# falls back to /proc/PID/maps on systems where lsof is absent.
model_is_in_use() {
  local cache_dir="$1"
  local pids
  # Find PIDs of running llama-cli and llama-server processes.
  # 'ps -eo pid=,comm=': list all processes with just PID and command name
  # (the trailing '=' suppresses the header line).
  pids="$(ps -eo pid=,comm= 2>/dev/null | awk '$2 ~ /llama-(cli|server)$/ || $2 == "mlx_lm.server" {print $1}')"
  [[ -z "$pids" ]] && return 1

  if command -v lsof >/dev/null 2>&1; then
    local pid_list
    # lsof -p needs a comma-separated PID list; join newlines with tr and
    # strip the trailing comma with sed.
    pid_list="$(printf '%s' "$pids" | tr '\n' ',' | sed 's/,$//')"
    # grep -qF: -q quiet (just set exit code), -F fixed-string (no regex).
    lsof -p "$pid_list" 2>/dev/null | grep -qF "$cache_dir"
  else
    local pid
    while IFS= read -r pid; do
      [[ -z "$pid" ]] && continue
      grep -qF "$cache_dir" "/proc/${pid}/maps" 2>/dev/null && return 0
    done <<< "$pids"
    return 1
  fi
}

mlx_model_is_in_use() {
  local model_name="$1"
  ps -eo comm=,args= -ww 2>/dev/null | awk -v model="$model_name" '
    {
      proc = $1
      is_mlx_proc = 0

      if (proc == "mlx_lm.server" || proc == "mlx_lm.chat") {
        is_mlx_proc = 1
      } else {
        for (i = 2; i <= NF; i++) {
          if ($i ~ /^-/) {
            break
          }

          token = $i
          sub(/^.*\//, "", token)
          if (token == "mlx_lm.server" || token == "mlx_lm.chat") {
            is_mlx_proc = 1
            break
          }
        }
      }

      if (!is_mlx_proc) {
        next
      }

      for (i = 2; i <= NF; i++) {
        if (($i == "--model" && i < NF && $(i + 1) == model) || $i == ("--model=" model)) {
          found = 1
          break
        }
      }
    }
    END { exit found ? 0 : 1 }
  '
}

# Safety check before removing a specific quant: verify none of its files
# are open by a running llama process. Checks both the symlink path in
# snapshots/ and the resolved blob path, since the process may have opened
# either one.
quant_is_in_use() {
  local cache_dir="$1"
  local model_name="$2"
  local quant="$3"
  local qf qblob
  while IFS= read -r qf; do
    [[ -z "$qf" ]] && continue
    if model_is_in_use "$qf"; then
      die "cannot remove '${model_name}:${quant}': it is currently in use by llama-cli or llama-server."
    fi
    if [[ -L "$qf" ]]; then
      qblob="$(resolve_link "$qf")"
      if [[ -n "$qblob" ]] && model_is_in_use "$qblob"; then
        die "cannot remove '${model_name}:${quant}': it is currently in use by llama-cli or llama-server."
      fi
    fi
  done < <(find_cached_gguf_paths_by_quant "$cache_dir" "$quant")
}

cmd_ps() {
  local ps_output
  ps_output="$(emit_runtime_process_rows)"

  if [[ -z "$ps_output" ]]; then
    echo "No llama-cli, llama-server, mlx_lm.chat, or mlx_lm.server processes running."
    return 0
  fi

  print_tsv_table 'llll' $'PID\tPROCESS\tPORT\tMODEL' <<< "$ps_output"
}
