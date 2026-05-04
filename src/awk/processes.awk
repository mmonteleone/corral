# Awk program for parse ps output to find llama.cpp and MLX processes.
# Used by emit_runtime_process_rows() in src/lib/corral-processes.sh.
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
  context_window = "-"
  max_tokens = "-"

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
    } else if (($i == "--ctx-size" || $i == "-c") && i < NF) {
      context_window = $(i + 1)
    } else if ($i ~ /^--ctx-size=/) {
      split($i, parts, "=")
      context_window = parts[2]
    } else if ($i ~ /^-c[0-9]+$/) {
      context_window = substr($i, 3)
    } else if (($i == "--n-predict" || $i == "-n") && i < NF) {
      max_tokens = $(i + 1)
    } else if ($i ~ /^--n-predict=/) {
      split($i, parts, "=")
      max_tokens = parts[2]
    } else if ($i ~ /^-n[0-9]+$/) {
      max_tokens = substr($i, 3)
    } else if (($i == "--max-tokens" || $i == "-m") && i < NF) {
      max_tokens = $(i + 1)
    } else if ($i ~ /^--max-tokens=/) {
      split($i, parts, "=")
      max_tokens = parts[2]
    } else if ($i ~ /^-m[0-9]+$/) {
      max_tokens = substr($i, 3)
    }
  }

  sub(/^.*\//, "", proc)
  if (proc != "llama-server" && proc != "mlx_lm.server") {
    port = "-"
  } else if (port == "-") {
    # llama-server and mlx_lm.server default to port 8080 when --port is not explicitly given.
    port = "8080"
  }

  printf "%s\t%s\t%s\t%s\t%s\t%s\n", pid, proc, port, model, context_window, max_tokens
}
