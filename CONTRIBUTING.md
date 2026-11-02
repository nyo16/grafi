# Contributing to Grafi

Thanks for your interest. Grafi aims to be a small, sharp, well-tested
graph library. Contributions are welcome — bug reports, performance
patches, new algorithms, and documentation are all fair game.

## Setup

Prerequisites:

- Elixir 1.18+ and Erlang/OTP 26+
- A C++17 toolchain (`clang++` or `g++`) — only if you want to build
  the NIF
- [igraph](https://igraph.org) >= 1.0 C library (optional, for NIF
  acceleration)

```bash
# macOS
brew install igraph

# Linux: build the 1.0.1 release; distro packages are often 0.10
# (see README "Installation")
```

Clone and build:

```bash
git clone https://github.com/nyo16/grafi.git
cd grafi
mix deps.get
mix compile
```

In a git checkout the NIF is always built from source (never downloaded).
If igraph >= 1.0 is not found, the build prints
`grafi: igraph >= 1.0 not found; building without NIF (pure Elixir)` and
succeeds; set `GRAFI_REQUIRE_NIF=1` to make that an error, or
`IGRAPH_DIR=/prefix` to pick a specific igraph install.

## Running tests

```bash
mix test                                  # default suite
GRAFI_NIF_THRESHOLD=0 mix test            # NIF for every graph size
GRAFI_NIF_ENABLED=false mix test          # force pure-Elixir paths
```

`:nif` tests run automatically when the NIF is loaded; `:no_nif` tests
run only without it (e.g. under `GRAFI_NIF_ENABLED=false`). No
`--include` flag is needed.

CI runs all three modes and merges their coverage. To reproduce it:

```bash
mix test --cover --export-coverage default
GRAFI_NIF_THRESHOLD=0 mix test --cover --export-coverage nif
GRAFI_NIF_ENABLED=false mix test --cover --export-coverage elixir
mix test.coverage
```

The 85% coverage floor applies to the merged report, not to a single
mode.

Property tests use `stream_data` and run as part of the default
suite. Please add tests for any new algorithm or bug fix — see
"Testing requirements" below.

## Benchmarks

```bash
mix bench
```

This runs `bench/run.exs` with Benchee and compares Grafi (Elixir),
Grafi (NIF, if available), and `:digraph` where applicable.

## Examples

Eight runnable scripts live under `examples/`:

```bash
mix run examples/shortest_path.exs
mix run examples/pagerank.exs
mix run examples/community_detection.exs
mix run examples/dag_critical_path.exs
mix run examples/cycle_detection.exs
mix run examples/graph_export.exs
mix run examples/nif_availability.exs
mix run examples/large_graph_benchmark.exs
```

## Code style

Run all three before sending a PR:

```bash
mix format
mix credo --strict
mix dialyzer
```

Public functions get `@spec` and a one-line `@doc`. Match the terse
existing style — no marketing copy in docs.

## NIF development

The C++ side lives in `c_src/`:

- `c_src/grafi_nif.h` — declarations and the fine bindings layer
- `c_src/grafi_nif.cpp` — implementations that call into igraph

To rebuild after a change:

```bash
make clean && mix compile
```

igraph reference: https://igraph.org/c/doc/

### Adding a new NIF

1. Declare the function in `c_src/grafi_nif.h`.
2. Implement it in `c_src/grafi_nif.cpp`, wrap the body in `run_nif`
   (which installs igraph's thread-local handlers), and register it in
   the `nif_funcs` table with `ERL_NIF_DIRTY_JOB_CPU_BOUND`.
3. Add a `@doc false` Elixir stub in `lib/grafi/nif.ex` that raises
   `:nif_not_loaded` (the `@on_load` hook handles the rest).
4. Add a pure-Elixir implementation in the appropriate `lib/grafi/algo/`
   module. Validate options with the helpers in `lib/grafi/args.ex` before dispatch, pick the
   engine with `Grafi.NIF.engine/3`, and normalize the NIF result with
   `Grafi.NIF.call/1` (or `call!/1` for functions without an error
   return).
5. Add a parity test to `test/grafi/nif_parity_test.exs` that runs both
   engines via `engine:`, and tag NIF-only tests `@tag :nif`.

### Pure-Elixir fallback policy

Every NIF must have a pure-Elixir fallback **except**:

- Louvain and Leiden community detection — too complex to reimplement
  faithfully; they return `{:error, :nif_not_available}` if the NIF
  is missing.

For everything else, the Elixir path is the spec; the NIF is an
optimization for large graphs (default threshold: 500 vertices,
configurable via `:nif_threshold`).

## Pull requests

- Branch from `master`. Use `feature/<short-name>` or
  `fix/<short-name>`.
- One logical change per PR. Keep them small.
- Commit messages: short imperative subject line (under 72
  characters), no trailing period. Match the existing log style
  (e.g. "Replace sorted-list PQ with pairing heap in Dijkstra and
  A*").
- We squash on merge — feel free to keep your branch history messy
  while iterating.
- Reference the issue in the PR description if one exists.

## Testing requirements

New algorithms need:

- **Unit tests** in `test/grafi/algo_test.exs` (or a new file) with
  hand-built fixtures covering the obvious cases (empty graph, single
  vertex, disconnected, self-loops, etc.).
- **Property tests** in `test/grafi/property_test.exs` exercising the
  algorithm against generated graphs. `stream_data` is already a test
  dependency.
- **NIF-vs-Elixir cross-check** if both paths exist — both should
  produce equivalent results on the same input.

Bug fixes need a regression test that fails before the fix and
passes after.

## License

Grafi is Apache-2.0 licensed. By contributing you agree your
contribution is licensed under the same terms. No CLA required.

## Code of conduct

Be kind. Assume good faith. We follow the spirit of the
[Contributor Covenant](https://www.contributor-covenant.org/).
