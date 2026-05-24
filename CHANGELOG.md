# Changelog

All notable changes to Grafi are documented here, following
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/) and
[Semantic Versioning](https://semver.org/).

## [Unreleased]

> **v0.1.0 will be the first published release.** The entries below
> describe the hardening work happening on the way to that release.

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
