# Awk program that strips // and /* */ comments and trailing commas from JSONC input.
# Used by _strip_jsonc() in src/lib/corral-launch.sh.
{
  text = text $0 ORS
}

END {
  out = ""
  i = 1
  in_string = 0
  escape = 0
  while (i <= length(text)) {
    ch = substr(text, i, 1)

    if (in_string) {
      out = out ch
      if (escape) {
        escape = 0
      } else if (ch == "\\") {
        escape = 1
      } else if (ch == "\"") {
        in_string = 0
      }
      i += 1
      continue
    }

    if (ch == "\"") {
      in_string = 1
      out = out ch
      i += 1
      continue
    }

    if (ch == "/" && i < length(text)) {
      nxt = substr(text, i + 1, 1)
      if (nxt == "/") {
        i += 2
        while (i <= length(text)) {
          line_ch = substr(text, i, 1)
          if (line_ch == "\r" || line_ch == "\n") {
            break
          }
          i += 1
        }
        continue
      }
      if (nxt == "*") {
        i += 2
        while (i < length(text) && !(substr(text, i, 1) == "*" && substr(text, i + 1, 1) == "/")) {
          i += 1
        }
        i += 2
        continue
      }
    }

    out = out ch
    i += 1
  }

  text = out
  out = ""
  i = 1
  in_string = 0
  escape = 0
  while (i <= length(text)) {
    ch = substr(text, i, 1)

    if (in_string) {
      out = out ch
      if (escape) {
        escape = 0
      } else if (ch == "\\") {
        escape = 1
      } else if (ch == "\"") {
        in_string = 0
      }
      i += 1
      continue
    }

    if (ch == "\"") {
      in_string = 1
      out = out ch
      i += 1
      continue
    }

    if (ch == ",") {
      j = i + 1
      while (j <= length(text) && substr(text, j, 1) ~ /[[:space:]]/) {
        j += 1
      }
      if (j <= length(text)) {
        nxt = substr(text, j, 1)
        if (nxt == "]" || nxt == "}") {
          i += 1
          continue
        }
      }
    }

    out = out ch
    i += 1
  }

  printf "%s", out
}
