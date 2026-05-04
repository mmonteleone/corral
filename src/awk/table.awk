# Awk program for TSV-to-padded-columns table formatter with ANSI color support.
# Used by print_tsv_table() in src/lib/corral-helpers.sh.
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
