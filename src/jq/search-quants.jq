def quant_rank:
  if test("^F32$") then
    -32
  elif test("^(BF16|F16)$") then
    -16
  elif test("^(?:[A-Z]{2}[-_])?I?Q[0-9]+") then
    (capture("^(?:[A-Z]{2}[-_])?I?Q(?<n>[0-9]+)") | .n | tonumber | -.)
  else
    0
  end;

def gguf_files:
  [.siblings[]? | .rfilename | select(type == "string" and test("[.]gguf$"; "i"))];

def has_gguf_tag:
  (((.tags // []) | map(ascii_downcase) | index("gguf")) != null);

def has_gguf:
  ((gguf_files | length > 0)
   or ((.library_name // "" | ascii_downcase) == "gguf")
   or has_gguf_tag);

def quants:
  [gguf_files[]
   | split("/")
   | last
   | gsub("[.]gguf$"; "")
   | gsub("-[0-9]+-of-[0-9]+$"; "")
   | (capture("[-._](?<q>(?:[A-Z]{2}[-_])?(?:I?Q[0-9]+(?:_[A-Z0-9]+)*|F16|BF16|F32))$")? | .q)
   | select(type == "string")]
  | unique
  | sort_by(quant_rank);

def default_quant:
  gguf_files as $files
  | ((([$files[] | select(test("Q4_K_M[.-]"; "i"))] | sort | .[0])
      // ([$files[] | select(test("Q4_0[.-]"; "i"))] | sort | .[0])
      // ($files | sort | .[0])) as $f
     | if $f != null then
         (($f
           | split("/")
           | last
           | gsub("[.]gguf$"; "")
           | gsub("-[0-9]+-of-[0-9]+$"; "")) as $stem
          | (($stem
              | capture("[-._](?<q>(?:[A-Z]{2}[-_])?(?:I?Q[0-9]+(?:_[A-Z0-9]+)*|F16|BF16|F32))$")?
              | .q) // $stem))
       else
         null
       end);
