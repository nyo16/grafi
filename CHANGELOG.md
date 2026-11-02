# Changelog

All notable changes to Grafi are documented here, following
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/) and
[Semantic Versioning](https://semver.org/).

## [Unreleased]

> **v0.1.0 will be the first published release.** The entries below
> describe the hardening work happening on the way to that release.

### Breaking
- `Grafi.Algo.Centrality.betweenness/2` follows NetworkX: unweighted
  and normalized by default (`weighted: false`, `normalized: true`),
  each undirected pair counted once. The middle of an undirected P3 now
  scores `1.0` on both engines; the Elixir engine used to return `0.5`.
- `Grafi.Algo.Centrality.pagerank/2` uses edge weights and spreads the
  rank of dangling vertices uniformly, so ranks always sum to 1. The
  Elixir engine's convergence test is NetworkX's (L1 change < n · tolerance).
- `Grafi.Graph.to_csr/1` returns `row_offsets`, `col_indices` and
  `weights` as native-endian binaries (`signed-native-64` /
  `float-native-64`), adds a `:vertices` tuple, and lists each
  undirected edge once. `Grafi.NIF.validate_csr!/1` validates that
  format.
- `Grafi.Algo.Cycles.strongly_connected_components/2` returns a
  canonical order: members sorted, components ordered by their smallest
  member. `Grafi.DAG.topological_sort/2` ties are broken by vertex term
  order.
- Isomorphism functions no longer fall back to Elixir silently when
  the NIF fails. `isomorphism/3`, `subgraph_isomorphism/3` and
  `count_subgraph_isomorphisms/3` return `{:error, {:igraph, message}}`.
  `isomorphic?/3` and `subgraph_isomorphic?/3` always return a boolean:
  they raise `Grafi.TimeoutError` on timeout and `Grafi.NIFError` on a
  NIF failure or `engine: :nif` without the NIF.
- `Grafi.Algo.Centrality.closeness/2` and `betweenness(weighted: true)`
  require positive edge weights: a zero weight now raises
  `ArgumentError` on both engines (the raw NIFs return
  `{:error, :non_positive_weight}`). PageRank and Dijkstra still accept
  zero weights.
- `GRAFI_NIF_ENABLED=false` / `nif_enabled: false` now also disables
  community detection, which returns `{:error, :nif_not_available}`.
- The raw `Grafi.NIF.nif_*` functions are no longer documented, and
  their arities changed (betweenness/3, leiden/3, VF2 functions/3).
- `Grafi.Graph.edges/1` on undirected graphs returns every parallel
  edge and orients each edge `from <= to`. Serializer output changes
  for undirected multigraphs, and the endpoint order of an exported
  edge can change for any undirected graph. Undirected
  `Grafi.Algo.ShortestPath.bellman_ford/2` returns
  `{:error, :negative_cycle}` for a negative edge reachable from
  `source`. See Fixed below.
- **Edge weights must be numbers.** `Grafi.Graph.add_edge/4` raises
  `ArgumentError` for any other `:weight`. Decoders return
  `{:error, {:invalid_weight, value}}` instead of silently using 1.0.
- **Decoders enforce input limits:**
  - every `from_*` decoder takes `:max_bytes`, default 64 MiB
    (`:infinity` allowed), and returns `{:error, {:too_large, size, max}}`;
    the GraphML/GEXF `{:error, :input_too_large}` is gone;
  - MatrixMarket takes `:max_vertices`, default 10_000_000, and checks it
    before allocating anything.

  The `Grafi.from_*` facade functions pass options through.
- **`vertices_as_atoms: true` never creates atoms.** In the edge list and
  adjacency list decoders it uses existing atoms only; other tokens stay
  strings.
- **Stricter decoder errors:**
  - Pajek rejects unknown sections (`{:unsupported_section, line}`) and
    malformed or duplicate vertex lines;
  - MatrixMarket reports `{:index_out_of_range, i}`,
    `{:nnz_mismatch, declared, seen}` and negative sizes;
  - GraphML/GEXF report `{:unclosed_element, tag}`;
  - decoders no longer catch arbitrary exceptions and turn them into
    error strings.
- **Pajek semantics:** a file mixing `*Arcs` and `*Edges` decodes to a
  directed graph with `*Edges` as arcs in both directions. Vertices that
  share a label become `{label, index}` ids.
- **Mermaid label escaping:** newlines become `#10;`, backticks `#96;`,
  `|` `#124;`, `"` `#quot;` and `#` `#35;`. Edge-label pipes used to be
  `\|`, and newlines used to become spaces.
- **DOT quoting:** a `:name` that is not a plain identifier, and DOT
  keywords used as ids, are quoted.
- **`Grafi.Viz`:**
  - `graphviz_available?/0` becomes `graphviz_available?/1` (default
    `:dot`) and checks that engine's own executable;
  - `render/3` takes `:timeout` (default 30 s) and returns
    `{:error, :timeout}`;
  - `{:graphviz_failed, output, code}` carries Graphviz's real output.

### Added (NIF safety)
- `engine: :auto | :nif | :elixir` option on every NIF-capable
  function (PageRank, betweenness, closeness, Dijkstra, Louvain,
  Leiden, label propagation, SCC, topological sort, all isomorphism
  functions), backed by `Grafi.NIF.engine/3`.
- `Grafi.NIFError`, raised when the NIF fails in a function that has no
  error return.
- `timeout:` option for every isomorphism function on both engines
  (integer milliseconds up to `0xFFFFFFFF`, or `:infinity`).
  `isomorphism/3`, `subgraph_isomorphism/3` and
  `count_subgraph_isomorphisms/3` return `{:error, :timeout}`; the `?`
  predicates raise `Grafi.TimeoutError`.
- `config :grafi, vf2_timeout` (default `:infinity`): the isomorphism
  timeout when no `:timeout` option is given. Set a finite value when
  matching graphs from untrusted input.
- `Grafi.TimeoutError`, raised by the isomorphism `?` predicates when
  the search runs out of time.
- `objective: :modularity | :cpm` for Leiden. The reported modularity
  is now comparable to Louvain's.
- NIF defaults (`nif_threshold: 500`, `nif_enabled: true`) live in the
  application env, so they apply when grafi is a dependency.
- CI runs the suite in three engine modes and merges coverage.

### Fixed (NIF safety)
- Directed `Community.louvain/1` aborted the whole VM (exit 134): igraph's
  error handlers are thread-local and were only installed on the
  loading thread. Every NIF thread now installs non-aborting handlers.
  Louvain and Leiden return `{:error, :directed_unsupported}` on
  directed graphs.
- igraph silently accepted negative weights in PageRank and Leiden.
  Weighted centralities now raise `ArgumentError`; Dijkstra and
  community detection return `{:error, :negative_weight}` on both
  engines.
- Invalid options (`damping`, `iterations`, `tolerance`, `resolution`,
  `engine`, `timeout`) raise `ArgumentError` before dispatch; integer
  `resolution` is accepted.
- Non-finite NIF results (e.g. igraph's NaN closeness for a vertex that
  reaches nothing) are returned as `0.0`, matching the Elixir engine.
- Dijkstra NIF distances on multigraphs sum the weights of the edges
  actually used.
- `nif_is_acyclic` ran on a normal scheduler; every CSR-consuming NIF
  is now dirty.
- NIF error messages are binaries, not charlists.
- `Grafi.Graph.to_csr/1` sent igraph the wrong undirected self-loops
  when a vertex had two or more: the newest loop was kept twice and the
  older ones dropped, so PageRank, closeness, betweenness and Dijkstra
  on the NIF engine disagreed with the Elixir engine. PageRank on both
  engines counts an undirected self-loop twice (igraph's convention;
  NetworkX counts it once).
- An invalid `:engine` now raises `ArgumentError` on every input,
  including early-return paths (e.g. closeness of a one-vertex graph).
- A VF2 `timeout:` too large for the native clock overflowed into an
  already-expired deadline, and `timeout: 2**63` returned
  `{:error, :badarg_timeout}`. Such values now raise `ArgumentError`;
  the raw NIF treats any int64 above `0xFFFFFFFF` as no deadline.
- `Grafi.NIF.available?/0` raised when the `:grafi` application env
  was not loaded; the NIF settings now fall back to their defaults.

### Added (packaging)
- Precompiled NIF pipeline (`.github/workflows/release.yml`) with
  static igraph 1.0.1, NIF 2.17 (OTP 26-29):
  - targets: x86_64/aarch64 Linux, built in manylinux_2_28 (glibc
    >= 2.28: RHEL 8+, Debian 11+, Ubuntu 20.04+), and macOS (11+ on
    Apple Silicon, 10.15+ on Intel);
  - each artefact is checksum-verified on download, checked to export
    only `nif_init` and to meet its platform floor, and smoke-tested
    in a consumer app without igraph;
  - releases carry `checksum.exs` (generated from the build outputs),
    build provenance attestations, `NOTICE`, the igraph source and the
    licence texts, and are published only from a `v*` tag matching
    `@version`, through a protected environment, without ever
    replacing assets;
  - a post-release job downloads the published artefact on OTP 26, 28
    and 29.

  Uploads stay disabled until the licence review signs off (see
  `RELEASING.md`). Precompiled artefacts statically link igraph and are
  distributed under **GPL-3.0-or-later** (Apache-2.0 + GPL; pending
  legal review); the source package stays Apache-2.0. See `NOTICE` and
  the README "Third-party licenses" section, including how to build
  without any GPL code.
- igraph is optional at build time. Without a usable igraph (>= 1.0,
  thread-safe, headers and library) the build prints a notice and Grafi
  runs in pure Elixir; `GRAFI_REQUIRE_NIF=1` makes that a build error,
  and `IGRAPH_DIR=/prefix` selects one igraph install exclusively.
- CI:
  - Elixir/OTP matrix 1.18/26, 1.18/27, 1.19/28, 1.20/29;
  - jobs for a build without igraph, a consumer (path dependency) source
    build, macOS with Homebrew igraph, and graphviz for the Viz tests;
  - `mix deps.audit`, `mix hex.audit` and `mix deps.unlock --check-unused`;
  - actions pinned by commit SHA, with Dependabot (7-day cooldown) for
    Mix and GitHub Actions.

### Fixed (parser hardening)
- Pajek no longer loops forever on `*Matrix`, `*Arcslist` or
  `*Edgeslist` (V6). Section switching is honoured.
- Quoted Pajek labels escape `\\`, `"`, `\n` and `\r` symmetrically, so a
  label can no longer inject a section or an edge.
- A MatrixMarket header declaring huge dimensions no longer allocates
  them (Sec H1).
- GraphML and GEXF use a linear tokenizer:
  - a 10k-vertex/50k-edge round-trip takes under a second (GEXF used to
    be quadratic: over 15 minutes);
  - an attribute value containing `id=` is no longer read as the id;
  - a self-closed node no longer takes the next node's label;
  - single-quoted attributes and numeric character references are
    decoded;
  - GraphML labels with leading or trailing whitespace round-trip.
- The edge list decoder honours `:separator` and detects weights per
  line; the adjacency list decoder accepts `:separator`.
- Numbers in input never raise: overflowing or 400-digit values are
  rejected as invalid weights.
- DOT `:name` and labels, and Mermaid/Kino labels, can no longer inject
  statements or close the enclosing code fence.
- `Grafi.Viz` creates private (0600), exclusive temp files and runs
  Graphviz through a port with a timeout that kills the OS process.

### Fixed (packaging)
- Using grafi as a dependency failed to compile: `cc_precompiler` was an
  optional dependency (`current_target/0` undefined) and the
  Makefile could not find fine's headers (`'fine.hpp' file not found`).
- The precompiled-artefact filename did not match the NIF, so every build
  tried, and failed, to download an artefact before compiling.
- igraph detection works without pkg-config: the version comes from
  `igraph_version.h`, Homebrew's prefix is found on Apple Silicon, and a
  missing library or an igraph without thread safety skips the NIF instead
  of breaking the build. Compile-time `#error`s act as a backstop.
- The NIF exports only `nif_init`: a statically linked igraph and C++
  template instantiations no longer leak (Linux version script). Linux
  builds use full RELRO and `-fstack-protector-strong`, and macOS builds
  drop `-flat_namespace`.
- Source builds rebuild when the igraph install, the link mode or the OTP
  headers change, and `mix clean` removes the NIF.
- The package lists `checksum.exs`, `NOTICE`, `LICENSES/` and
  `CHANGELOG.md`; the source URL points at `nyo16/grafi`.

### Added
- README sections covering pre-Hex install instructions, benchmarks
  scaffolding, a "When to use Grafi" decision guide, and a
  troubleshooting guide (NIF availability, pure-Elixir fallback,
  igraph install / linker errors).
- README architecture notes explaining CSR (Compressed Sparse Row),
  the configurable `:nif_threshold` (default 500), and the
  `ERL_NIF_DIRTY_JOB_CPU_BOUND` scheduler guarantee.
- `examples/` directory with 8 runnable `.exs` scripts:
  `shortest_path`, `pagerank`, `community_detection`,
  `dag_critical_path`, `cycle_detection`, `graph_export`,
  `nif_availability`, `large_graph_benchmark`.
- `CONTRIBUTING.md` covering setup, tests (including pure-Elixir
  fallback testing via `GRAFI_NIF_ENABLED=false`), benchmarks,
  code style, NIF development workflow, and contribution policy.
- Top-10 doctests for the most-used public functions
  (`Grafi.Graph.new`, `add_edge`, `shortest_path`, `pagerank`,
  `has_cycle?`, `DAG.add_edge`, `topological_sort`, `critical_path`,
  `to_dot`, `bfs`) — they run as part of `mix test` and prevent
  README/doc drift.
- **`Grafi.Algo.Metrics`** — triangle count, per-vertex triangles,
  clustering coefficient (local + average), transitivity, density,
  diameter, radius, eccentricity, eccentricities, center, periphery.
- **`Grafi.Generators`** — `complete`, `cycle`, `path`, `grid`,
  `erdos_renyi`, `barabasi_albert`, `watts_strogatz`,
  `random_regular`. Seeded for reproducibility.
- **`Grafi.UnionFind`** — persistent disjoint-set primitive with
  path compression and union-by-rank.
- **`Grafi.Algo.MST`** — Kruskal and Prim minimum spanning tree /
  forest; `Grafi.DisconnectedError` for the strict `kruskal!/1`.
- **`Grafi.Algo.APSP`** — Floyd–Warshall and Johnson's all-pairs
  shortest path with path reconstruction; transitive closure.
- **`Grafi.Algo.Bipartite`** — `bipartite?`, `coloring`, `sets`,
  `project` (bipartite projection with shared-neighbor weights).
- **`Grafi.Algo.KCore`** — Batagelj–Zaversnik core-number peeling,
  `k_core/2` subgraph extraction, `degeneracy/1`.
- **`Grafi.Algo.Cliques`** — Bron–Kerbosch with Tomita pivot:
  `maximal_cliques`, `maximum_clique`, `clique_number`,
  `count_cliques`.
- **`Grafi.Algo.Connectivity`** — bridges, articulation points,
  biconnected components, `is_biconnected?` via single Tarjan
  DFS pass (handles multi-edges and self-loops).
- **`Grafi.Algo.Centrality` extras** — HITS (hubs + authorities),
  Katz, eigenvector, harmonic centrality.
- **`Grafi.Algo.LinkPrediction`** — Jaccard, Adamic–Adar,
  resource-allocation, preferential-attachment scores with a
  `top_k/2` helper.
- **`Grafi.Algo.MaxFlow`** — Edmonds–Karp, Dinic's, and `min_cut/4`
  with full source/sink partition.
- **`Grafi.Algo.Matching`** — Hopcroft–Karp maximum-cardinality
  bipartite matching; Hungarian (Jonker–Volgenant) assignment;
  `weighted_bipartite_matching/3` convenience wrapper.
- **`Grafi.Algo.KShortestPath`** — Yen's K loopless shortest paths.
- **`Grafi.Algo.Bidirectional`** — bidirectional Dijkstra.
- **Serialization formats** (encoder + decoder, round-trip tested):
  GraphML, GEXF, Pajek, edge-list, adjacency-list, Matrix Market.
  No new dependencies — pure Elixir + stdlib.
- **Performance**: `out_degree/2` and `in_degree/2` on
  `Grafi.Graph` are now O(log n) via cached degree maps maintained
  on every add/remove; CSR build no longer reverses per-vertex.
- **`Grafi.Algo.Isomorphism`** — VF2 / sub-isomorphism via 5 new
  igraph NIFs (`nif_isomorphic_vf2`, `nif_subisomorphic_vf2`,
  `nif_isomorphism_vf2`, `nif_subgraph_isomorphism_vf2`,
  `nif_count_subisomorphisms_vf2`) with a pure-Elixir VF2-style
  backtracking fallback for when the NIF is unavailable.
- **`Grafi.Serialize.Mermaid`** — emit Mermaid `flowchart`/`graph`
  syntax for Markdown / Livebook docs. Direction, edge weights/labels,
  custom vertex labels all configurable.
- **`Grafi.Kino`** — produces Markdown-wrapped Mermaid blocks ready
  for `Kino.Markdown.new/1` in Livebook. **No new dependency** —
  `kino` is not added to `mix.exs`; users bring their own.
- **`Grafi.Layout`** — `sugiyama/2` (layered DAG layout with
  longest-path layering + barycenter crossing reduction) and
  `levels/1`. Returns `%{vertex => {x, y}}`.
- **`Grafi.Viz`** — Graphviz shelling helper: `render/3` /
  `render!/3` / `render_to_file/3` / `graphviz_available?/0`.
  Supports `:svg`, `:png`, `:pdf`, `:dot`, `:json`, `:eps` formats
  and `:dot`/`:neato`/`:circo`/`:twopi`/`:fdp`/`:sfdp` engines.
- **Top-level `Grafi.*` delegations** for the most-used new
  functions: `triangle_count`, `clustering_coefficient`,
  `transitivity`, `density`, `diameter`, `radius`, `eccentricity`,
  `kruskal`, `prim`, `floyd_warshall`, `johnson`,
  `transitive_closure`, `bidirectional_dijkstra`,
  `k_shortest_paths`, `bridges`, `articulation_points`,
  `biconnected_components`, `bipartite?`, `core_numbers`, `k_core`,
  `maximal_cliques`, `maximum_clique`, `hits`, `katz`,
  `eigenvector_centrality`, `harmonic_centrality`, `max_flow`,
  `min_cut`, `bipartite_matching`, `weighted_bipartite_matching`,
  `isomorphic?`, `subgraph_isomorphic?`, and `to_mermaid` +
  `to_/from_` wrappers for every new serialization format.

### Changed
- License declaration in `mix.exs` corrected to `Apache-2.0` to match
  the project `LICENSE` file (was previously declared as `MIT`).
- README License section updated to reference Apache 2.0 with a link
  to the `LICENSE` file.
- PageRank example in the README no longer prints stale numeric output
  — values depend on damping factor and iteration count.

### Fixed
- `Grafi.Graph.delete_vertex/2` miscounted `num_edges` when the vertex
  had self-loops; the count could go negative.
- `Grafi.Graph.subgraph/2` doubled undirected edges and self-loops,
  doubled edges again for every repeated id in `keep`, and reversed the
  order of parallel edges (so a later `delete_edge/3` removed the
  oldest copy instead of the newest).
- `Grafi.Graph.edges/1` collapsed undirected parallel edges that shared
  a label (including unlabelled ones) and oriented undirected edges
  arbitrarily. It now returns every edge exactly once, so
  `length(edges(g)) == num_edges(g)`, with undirected edges oriented
  `from <= to` in term order. An undirected edge between ids that
  compare equal but differ (`1` and `1.0`) is listed once instead of
  twice. The serializers now emit every parallel edge, and
  MatrixMarket sums all of them.
- `Grafi.Algo.ShortestPath.bellman_ford/2` relaxed undirected edges in
  one direction only, so vertices reachable only "backwards" were
  missing. A negative undirected edge reachable from `source` is now
  reported as `{:error, :negative_cycle}`.
- igraph 1.0.x and OTP 28 compatibility in the C++ NIF.
- Replaced throw-for-flow-control with explicit conditionals in the
  pure-Elixir algorithms.
- Replaced O(n²) list appends with `:queue` and prepend+reverse in the
  hot paths.
- `Grafi.Algo.ShortestPath` vertex-existence handling: looking up a
  source or target that is not in the graph now returns an explicit
  `{:error, :no_such_vertex}` instead of silently passing `nil` to
  the NIF.
- `Grafi.Serialize.JSON.from_json/1` now returns `{:error, :malformed}`
  on missing `"vertices"` / `"edges"` keys instead of crashing with a
  confusing `Enum.reduce(nil, ...)` error.
- `Grafi.Serialize.DOT` escapes `"` and special characters inside
  vertex names so identifiers like `a"b` produce valid DOT.
- `Grafi.DAG.add_edge/4` runs the reachability / cycle check *after*
  any auto-inserted vertices, closing a corner case where a cycle
  could be created via two simultaneously-new endpoints.

### Security
- C++ NIF hardening: bounds-checked `source` / `target` indices in
  `nif_dijkstra` (and all path-finding NIFs); `enif_get_*` return
  values are now validated in every decoder; structural CSR
  invariants (`row_offsets[0] == 0`, monotonic non-decreasing,
  `row_offsets[n] == |col_indices|`, `col_indices[j] < n_vertices`)
  are enforced before any igraph call.
- Reject negative weights in the Dijkstra wrapper with
  `{:error, :negative_weight}` instead of silently producing
  undefined behaviour.
- RAII / scope-guard every igraph allocation (`igraph_t`,
  `igraph_vector_*`, `igraph_vector_int_list_t`) so a thrown
  exception between `init` and `destroy` no longer leaks.
- Parameter validation: PageRank `damping ∈ (0, 1)` and `max_iter > 0`;
  Leiden `resolution > 0`; reject `NaN` / `Inf` weights.
- Replaced the 16-byte atom buffer in `decode_csr` with a 64-byte
  buffer and checked the `enif_get_atom` return value.

## v0.1.0

- Initial release (pre-Hex; not yet published).
- Core graph struct (directed, undirected, weighted, labelled).
- DAG with cycle prevention, topological sort, layers, critical path.
- Traversals: BFS, DFS as lazy streams.
- Shortest path: Dijkstra, Bellman-Ford, A*.
- Centrality: PageRank, betweenness (Brandes), closeness, degree.
- Cycles: detection, finding, SCC (Tarjan), condensation.
- Community detection: Louvain, Leiden, label propagation (via igraph NIF).
- Serialization: DOT, JSON.
- igraph C++ NIF engine via fine with graceful fallback to pure
  Elixir when igraph is not installed.
- Runtime-configurable NIF threshold via `Application` config and
  `GRAFI_NIF_THRESHOLD` / `GRAFI_NIF_ENABLED` env vars.
- Credo, Dialyzer, and GitHub Actions CI.
- Expanded test suite with edge cases, JSON round-trip, and
  property-based tests (via `stream_data`).
- `@doc` annotations on all public functions.
