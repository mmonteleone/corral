# Contributing to Corral

## Development

Source entry point is [src/corral.sh](src/corral.sh) with modules in [src/lib/](src/lib/). The standalone distributable is built by [tools/build.sh](tools/build.sh), which inlines modules and stamps the version from the current git tag.

Current module split is feature-oriented: helpers, cache, profiles, shell integration, runtime lifecycle, process discovery, inventory/removal, launch, search, and completions.

Within that split, public cross-module helpers are named without a leading underscore; underscore-prefixed helpers are intended to stay private to their defining module.

```sh
bash tools/build.sh              # build standalone artifact
shellcheck src/corral.sh src/lib/*.sh   # lint
bash tests/unit.sh               # full unit suite
bash tests/smoke.sh              # full smoke suite
```

```sh
bash tests/unit.sh test_parse_model_spec_without_quant  # single unit test
bash tests/smoke.sh test_search_returns_results         # single smoke test
```

`dist/corral` is generated output. Edit `src/corral.sh`, `src/lib/*.sh`, `src/templates/*.conf`, `src/launch/*.tmpl`, or `src/jq/search-quants.jq`, then rebuild.

## Repository Conventions

For full architecture details, module descriptions, and coding conventions, see [AGENTS.md](AGENTS.md).
