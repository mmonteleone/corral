# Working in Corral

## What Corral is

Corral is a single Bash CLI for running and managing local LLMs with an Ollama-shaped UX on top of official `llama.cpp` and MLX releases.

- The distributable is `dist/corral`, a generated standalone shell script.
- Source lives under `src/`; do not edit `dist/corral` directly.
- Corral uses the standard Hugging Face cache at `~/.cache/huggingface/hub`.
- Corral does **not** keep its own model database or registry.
- Backends:
  - `llama.cpp`: GGUF models on macOS and Linux
  - `mlx`: MLX models on macOS Apple Silicon only

## Working tree map

```text
src/
  corral.sh                  Entry point and command dispatch
  lib/
    corral-helpers.sh        Shared helpers, error handling, tables, backend resolution
    corral-cache.sh          HF cache discovery and quant handling
    corral-profiles.sh       Profiles and templates
    corral-shell.sh          Shell profile and completion installation
    corral-runtime.sh        install/update/uninstall/pull/run/serve/status/prune
    corral-processes.sh      Runtime process discovery and ps output
    corral-inventory.sh      list/remove inventory across models, profiles, templates
    corral-launch.sh         launch integrations for pi and opencode
    corral-search.sh         Hugging Face search and browse
    corral-completions.sh    fish/zsh/bash completion generators
  templates/                 Built-in profile templates
  launch/          Built-in launcher config templates
  jq/                        jq helpers used by the CLI
dist/
  corral                     Generated output
tools/
  build.sh                   Regenerates dist/corral
tests/
  unit.sh                    Unit tests for sourced helpers
  smoke.sh                   End-to-end CLI tests with mocked tools
  test-helpers.sh            Shared test harness
```

## Build, lint, and test

Run these after code changes:

```sh
bash tools/build.sh
shellcheck src/corral.sh src/lib/*.sh
bash tests/unit.sh
bash tests/smoke.sh
```

Run a single test by passing its function name:

```sh
bash tests/unit.sh test_parse_model_spec_without_quant
bash tests/smoke.sh test_search_returns_results
```

What they do:

- `tools/build.sh` rebuilds `dist/corral` by inlining modules, built-in templates, launch templates, and jq assets, then stamping `@VERSION@`.
- `tests/unit.sh` sources library files directly and tests helpers without subprocesses.
- `tests/smoke.sh` runs `src/corral.sh` as a subprocess against mocked external tools and APIs.

## Architecture

### Entry point

- `src/corral.sh` sets global defaults, sources all modules, and dispatches top-level commands.
- Top-level help and the command dispatch table live here.

### Core modules

- `corral-helpers.sh`: shared foundation for all modules. Includes `die`, prompt helpers, command checks, path normalization, color/table output, and backend resolution.
- `corral-cache.sh`: source of truth for local model discovery. Reads the Hugging Face cache directly, maps cache paths to model IDs, and extracts GGUF quant tags.
- `corral-profiles.sh`: manages plain-text profiles and templates under `~/.config/corral/`.
- `corral-shell.sh`: manages PATH and completion installation across fish, zsh, and bash.
- `corral-runtime.sh`: backend lifecycle plus `pull`, `run`, and `serve`.
- `corral-processes.sh`: detects running llama.cpp and MLX processes and powers `ps` plus in-use guards.
- `corral-inventory.sh`: owns `list` and `remove`, combining cache, profiles, and templates into a single user-facing inventory.
- `corral-launch.sh`: configures supported coding harnesses from a running `corral serve` instance.
- `corral-search.sh`: Hugging Face search/browse behavior.
- `corral-completions.sh`: emits completion scripts for fish, zsh, and bash.

## Key repository conventions

### Public vs private helpers

- Functions intended for use across sourced modules should not use a leading underscore.
- Module-local helpers should use a leading underscore.
- When extracting shared behavior, prefer making the public surface explicit rather than reaching across modules to underscore-prefixed helpers.
- Within each module, keep public functions grouped first and move underscore-prefixed helpers to the bottom of the file.
- If a helper is used outside its defining module, rename it to a public non-underscored name instead of treating that module as an exception.

### `dist/corral` is generated

Always make source edits in `src/` or other source assets, then rebuild with:

```sh
bash tools/build.sh
```

Do not hand-edit the generated script.

### Structured helper outputs use `REPLY_*`

Many helpers return structured data by setting `REPLY_*` globals instead of printing to stdout. Common examples include model parsing, profile loading, launch resolution, and command argument parsing.

When changing or calling these helpers, preserve their `REPLY_*` contract.

### Corral infers state from the Hugging Face cache

Corral does not maintain a sidecar registry of installed models. Cached model visibility comes from the HF hub layout under `~/.cache/huggingface/hub`, including:

- GGUF files and symlinks in `snapshots/*`
- MLX weight files such as `.safetensors`, `.bin`, and `.pt`

Changes to model discovery, listing, or removal should stay consistent with that cache-first design.

### Backend inference is intentional and asymmetric

Backend inference differs between `pull` and `run`/`serve`:

- `run` and `serve` prefer local GGUF cache evidence first.
- `pull` may use remote Hugging Face metadata.
- Explicit `:QUANT` or `-GGUF` naming should continue to force `llama.cpp`.

Be careful when touching backend selection logic. Small changes can affect multiple commands.

### Profiles are plain text and resolution is two-pass

Profiles and templates are plain text files with a `model=` line and optional scoped sections such as:

- `[run]`, `[serve]`
- `[mlx]`, `[llama.cpp]`
- `[mlx.run]`, `[llama.cpp.serve]`

`run` and `serve` treat any argument without a slash as a profile name. Resolution is intentionally two-pass:

1. Load unscoped profile data to determine the real model and backend.
2. Reload with backend/command scope applied to collect the effective flags.

Preserve that behavior when modifying profiles logic.

### Launch integrations should stay generic

`corral launch` should keep a shared flow for:

- discovering the target server via `cmd_ps`
- rendering a built-in template
- deep-merging config where needed
- writing backups when a config changes

Keep harness-specific behavior in launch templates or narrowly scoped helpers. Existing config files should retain unrelated keys, and changed files should produce `.bak.TIMESTAMP` backups.

### Shell completions depend on `ls --quiet`

Dynamic completions shell out to:

- `corral ls --quiet --models`
- `corral ls --quiet --profiles`
- `corral ls --quiet --templates`

Do not casually change the quiet output format. Completion behavior and tests depend on it being sentinel-free and easy to parse.

## Testing guidance

### Unit tests

- `tests/unit.sh` sources the library modules directly.
- Use it for pure helpers and parsing logic.
- Tests assert on stdout or `REPLY_*` globals.

### Smoke tests

- `tests/smoke.sh` exercises the CLI end-to-end.
- It uses mocked `curl`, `llama.cpp`, `mlx_lm`, and related executables.
- Each smoke test resets its environment so tests stay isolated.

### When to add or update tests

- Add or update a unit test for helper behavior, parsing, cache discovery, or profile resolution.
- Add or update a smoke test for command behavior, CLI output, process handling, shell profile/completion installation, or launch/search flows.
- If you change `cmd_list`, backend inference, profile resolution, completion behavior, or launch config writing, expect both unit and smoke coverage to matter.

## Common change patterns

### Adding a new command

1. Add the command implementation in the most relevant `src/lib/` module.
2. Wire it into the dispatch table and help text in `src/corral.sh`.
3. Update shell completions in `src/lib/corral-completions.sh`.
4. Add tests.
5. Rebuild `dist/corral`.

### Adding a built-in template

1. Add a file under `src/templates/`.
2. Rebuild so `tools/build.sh` inlines it.
3. Update any help or tests that enumerate built-ins.

### Adding a new launch harness

1. Add a template under `src/launch/`.
2. Add the harness-specific wiring in `src/lib/corral-launch.sh`.
3. Update launch help and completions.
4. Add tests.
5. Rebuild.

## Shell and coding style

- Target portable Bash; avoid assuming newer Bash features unless the repo already does.
- Prefer existing helper patterns over ad hoc replacements.
- Use `die` for fatal errors instead of inconsistent manual stderr handling.
- Keep destructive operations explicit and consistent with existing confirmation behavior.
- Preserve table and quiet-output formats unless the change intentionally updates all callers and tests.

## User-facing environment variables

- `CORRAL_INSTALL_ROOT`: override llama.cpp install directory
- `CORRAL_PROFILES_DIR`: override profiles directory
- `CORRAL_TEMPLATES_DIR`: override templates directory
- `HF_TOKEN`, `HF_HUB_TOKEN`, `HUGGING_FACE_HUB_TOKEN`: Hugging Face auth tokens
