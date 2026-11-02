# Grafi — γραφή

[![Hex.pm](https://img.shields.io/hexpm/v/grafi.svg)](https://hex.pm/packages/grafi)
[![Docs](https://img.shields.io/badge/docs-hexdocs-blue.svg)](https://hexdocs.pm/grafi)

*Hex and HexDocs links activate once v0.1.0 is published.*

A high-performance graph library for Elixir with igraph NIF acceleration.

The name comes from ancient Greek **γραφή** (*graphē*) — "to write, to draw, to describe" —
the etymological ancestor of the English word "graph." Returning the word to its origin.

## Features

- **Immutable, pipeable API** — build graphs in a single pipeline
- **Directed & undirected** graphs with weighted, labelled, multi-edges
- **DAG enforcement** — `Grafi.DAG` prevents cycles at insertion time
- **igraph C++ NIFs** — PageRank (PRPACK), Dijkstra, betweenness, community detection
  dispatch to the battle-tested [igraph](https://igraph.org) C library via
  [fine](https://github.com/elixir-nx/fine) on dirty CPU schedulers
- **Graceful fallback** — without igraph, every algorithm except community
  detection (Louvain, Leiden, label propagation) runs in pure Elixir;
  those three return `{:error, :nif_not_available}`
- **Serialization** — DOT, JSON, GraphML, GEXF, Pajek, edge-list,
  adjacency-list, Matrix Market, and Mermaid (with Livebook/Kino glue)
- **Layout & viz** — Sugiyama DAG layout and a Graphviz shelling
  helper for direct SVG/PNG/PDF rendering

## Algorithms

| Category | Algorithm | Elixir | igraph NIF |
|---|---|---|---|
| **Traversal** | BFS, DFS (lazy streams) | ✅ | — |
| **Shortest path** | Dijkstra, Bellman-Ford, A* | ✅ | ✅ (large graphs) |
| **Centrality** | PageRank | ✅ | ✅ (PRPACK) |
| | Betweenness (Brandes) | ✅ | ✅ |
| | Closeness | ✅ | ✅ |
| | Degree centrality | ✅ | — |
| **Community** | Louvain (multi-level) | — | ✅ |
| | Leiden | — | ✅ |
| | Label propagation | ✅ (simple) | ✅ |
| **Cycles** | Cycle detection | ✅ | ✅ |
| | Cycle finding | ✅ | — |
| | SCC (Tarjan) | ✅ | ✅ |
| | Connected components | ✅ | — |
| | Condensation | ✅ | — |
| **DAG** | Topological sort (Kahn) | ✅ | ✅ |
| | Layer assignment | ✅ | — |
| | Critical path | ✅ | — |
| | Cycle prevention | ✅ | — |
| **Metrics** | Triangle count, clustering coefficient, transitivity, density | ✅ | — |
| | Diameter, radius, eccentricity, center, periphery | ✅ | — |
| **Connectivity** | Bridges, articulation points, biconnected components | ✅ | — |
| | Bipartite detection, 2-coloring, bipartite projection | ✅ | — |
| | k-core decomposition, degeneracy | ✅ | — |
| | Maximal cliques (Bron–Kerbosch with Tomita pivot) | ✅ | — |
| **MST** | Kruskal, Prim (with `Grafi.UnionFind` primitive) | ✅ | — |
| **All-pairs SP** | Floyd–Warshall, Johnson, transitive closure | ✅ | — |
| **K-shortest** | Yen's algorithm, bidirectional Dijkstra | ✅ | — |
| **Centrality extras** | HITS, Katz, eigenvector, harmonic | ✅ | — |
| **Link prediction** | Jaccard, Adamic–Adar, resource allocation, preferential attachment | ✅ | — |
| **Flows & matching** | Max-flow: Edmonds–Karp, Dinic; min s–t cut | ✅ | — |
| | Hopcroft–Karp bipartite matching | ✅ | — |
| | Hungarian (Jonker–Volgenant) assignment | ✅ | — |
| **Isomorphism** | VF2 / sub-isomorphism, count subisomorphisms | ✅ (backtracking) | ✅ (igraph VF2) |
| **Generators** | Erdős–Rényi, Barabási–Albert, Watts–Strogatz, random-regular, complete, cycle, path, grid | ✅ | — |
| **Layout** | Sugiyama (layered DAG, barycenter crossing reduction) | ✅ | — |
| **Viz** | Graphviz `dot`/`neato`/`circo`/`twopi`/`fdp`/`sfdp` shelling | ✅ (System.cmd) | — |

## Installation

> **Pre-release notice**: v0.1.0 is not yet on Hex. Use the `git:` dep form
> until the first published release.

Add `grafi` to your `mix.exs`:

```elixir
def deps do
  [
    # Once published:
    {:grafi, "~> 0.1.0"}

    # Until then:
    # {:grafi, git: "https://github.com/nyo16/grafi"}
  ]
end
```

### The igraph NIF (optional)

Grafi works without any native code. The NIF adds speed on large graphs and
is required for community detection (Louvain, Leiden, label propagation).
`mix compile` picks one of three paths:

1. **Precompiled NIF** (from the first Hex release, once the licence review
   in [RELEASING.md](https://github.com/nyo16/grafi/blob/master/RELEASING.md) is signed off): downloaded and
   checksum-verified for x86_64/aarch64 Linux (glibc >= 2.28: RHEL 8+,
   Debian 11+, Ubuntu 20.04+) and macOS (11+ on Apple Silicon, 10.15+ on
   Intel) on OTP 26-29. It has igraph built in; on Linux it needs only the
   system C++ runtime (`libstdc++.so.6`, present on standard distros; slim
   or distroless images may need it installed, e.g. `libstdc++6`).
   **It is GPL-3.0-or-later** — see [Third-party licenses](#third-party-licenses).
2. **Built from source** on other targets, for `git:`/`path:` deps, or when
   you force it with `config :elixir_make, :force_build, grafi: true`. This
   needs igraph >= 1.0 (built with thread safety, the default), `make` and a
   C++17 compiler.
3. **Pure Elixir** when no igraph is found. The build prints
   `grafi: igraph >= 1.0 not found; building without NIF (pure Elixir)` and
   succeeds. This still runs `make`, so `make` must be installed even then;
   a cross build (Nerves, a `MIX_TARGET` other than `host`) only uses an
   igraph given with `IGRAPH_DIR` and otherwise falls back to pure Elixir.

To ship **no GPL code** (no precompiled artefact, no igraph), force the
source build in your app's `config/config.exs` and don't install igraph:

```elixir
config :elixir_make, :force_build, grafi: true
```

Windows is not supported: there is no precompiled artefact, and elixir_make
runs `nmake /F Makefile.win`, which Grafi doesn't ship, so `mix compile`
fails rather than falling back to pure Elixir.

Installing igraph >= 1.0 for source builds:

```bash
# macOS
brew install igraph

# Linux: build the 1.0.1 release (distro packages such as Ubuntu's
# libigraph-dev are often 0.10, which is not supported)
curl -LO https://github.com/igraph/igraph/releases/download/1.0.1/igraph-1.0.1.tar.gz
tar xzf igraph-1.0.1.tar.gz && cd igraph-1.0.1
cmake -S . -B build -DCMAKE_BUILD_TYPE=Release -DBUILD_SHARED_LIBS=ON
cmake --build build --parallel && sudo cmake --install build
```

Build knobs (environment variables at `mix compile` time):

| Variable | Effect |
|---|---|
| `IGRAPH_DIR=/prefix` | Use only this igraph install (`include/`, `lib/`) |
| `GRAFI_REQUIRE_NIF=1` | Fail the build instead of falling back to pure Elixir |

## Quick start

```elixir
# Build a graph of Greek cities
g = Grafi.new()
  |> Grafi.add_edges([
    {:athens, :sparta, weight: 210.0},
    {:athens, :corinth, weight: 80.0},
    {:corinth, :sparta, weight: 130.0},
    {:corinth, :olympia, weight: 150.0},
    {:sparta, :olympia, weight: 100.0}
  ])

# Shortest path
Grafi.shortest_path(g, :athens, :olympia)
#=> {:ok, {[:athens, :corinth, :olympia], 230.0}}

# PageRank — exact values depend on damping factor and iteration count
Grafi.pagerank(g)
#=> %{athens: _, corinth: _, sparta: _, olympia: _}

# Cycle detection
Grafi.has_cycle?(g)
#=> true

# Community detection (requires igraph NIF)
Grafi.louvain(g)
#=> {:ok, %{membership: %{...}, modularity: 0.42, n_communities: 2, ...}}

# Export to Graphviz
Grafi.to_dot(g) |> File.write!("cities.dot")
```

## DAG (Directed Acyclic Graph)

```elixir
alias Grafi.DAG

dag = DAG.new()
  |> DAG.add_edges([
    {:parse, :compile, weight: 2.0},
    {:compile, :link, weight: 3.0},
    {:compile, :optimize, weight: 5.0},
    {:optimize, :link, weight: 1.0}
  ])

DAG.topological_sort(dag)
#=> {:ok, [:parse, :compile, :optimize, :link]}

DAG.critical_path(dag)
#=> {[:parse, :compile, :optimize, :link], 8.0}

DAG.layers(dag)
#=> %{0 => [:parse], 1 => [:compile], 2 => [:optimize], 3 => [:link]}

# Cycle prevention
DAG.add_edge(dag, :link, :parse)
#=> ** (Grafi.CycleError) :link -> :parse would create a cycle
```

## Architecture

```
┌─────────────────────────────────────────────────┐
│            Grafi — Elixir public API             │
│  Grafi.Graph · Grafi.DAG · Grafi.Algo · ...      │
└────────────────┬────────────────┬────────────────┘
                 │                │
         simple ops          heavy compute
                 │                │
    ┌────────────▼──┐    ┌───────▼────────────┐
    │  Elixir core  │    │  C++ NIF (igraph)  │
    │  Maps-based   │    │  fine + igraph.h   │
    │  graph struct │    │  dirty CPU sched.  │
    └───────────────┘    └────────────────────┘
```

Heavy compute paths (PageRank, betweenness, closeness, Dijkstra on
large graphs, Louvain, Leiden, label propagation, SCC, topological sort)
dispatch to igraph through the NIF; everything else runs in pure
Elixir on the immutable graph struct.

The default NIF threshold is **500 vertices** — below that, pure Elixir
runs even when the NIF is loaded. Above that, the graph is converted
to **CSR (Compressed Sparse Row)** — a compact two-array adjacency
representation (`row_offsets` + `col_indices`) that igraph consumes
directly without re-copying — and handed to the NIF.

The threshold and the other runtime settings live in the `:grafi`
application environment; set them in your app's config:

```elixir
# config/config.exs or config/runtime.exs of your application
config :grafi,
  nif_threshold: 1_000,     # :auto uses the NIF above this many vertices
  nif_enabled: true,        # false forces pure Elixir everywhere
  vf2_timeout: :infinity    # isomorphism budget in ms; set finite for untrusted input
```

Every NIF-capable function also takes `engine: :auto | :nif | :elixir` per
call. Isomorphism searches are unbounded by default: `vf2_timeout` caps every
VF2 search that has no explicit `:timeout`.

Every NIF except the O(1) load probe runs on a dirty CPU scheduler
(`ERL_NIF_DIRTY_JOB_CPU_BOUND`), so even multi-second runs (e.g. Louvain on
a 100k-vertex graph) never stall the BEAM's normal schedulers.

## Benchmarks

Grafi includes a `mix bench` task (aliased to `run bench/run.exs`) that
exercises the major algorithms across pure-Elixir, NIF, and `:digraph`
backends. Sample numbers on Apple M1 / Linux x86 are below — your
results will vary with graph topology, edge count, and hardware.

| Algorithm | Graph size | Grafi (Elixir) | Grafi (NIF) | `:digraph` |
|---|---|---|---|---|
| Dijkstra single-pair | 1k vertices / 3k edges | TBD | TBD | TBD |
| Dijkstra single-pair | 10k vertices / 30k edges | TBD | TBD | TBD |
| PageRank (100 iter)   | 1k vertices / 3k edges | TBD | TBD | — |
| PageRank (100 iter)   | 10k vertices / 30k edges | TBD | TBD | — |
| Betweenness           | 1k vertices / 3k edges | TBD | TBD | — |
| Louvain               | 10k vertices / 30k edges | — | TBD | — |

> Real numbers will be filled in once `mix bench` has been run in a
> clean environment. Run it locally with `mix bench` to compare against
> your hardware.

## Comparison with libgraph

| | libgraph | Grafi |
|---|---|---|
| Data structure | Elixir maps | Elixir maps + CSR for NIF |
| ETS usage | k-core only | None |
| PageRank | ❌ | ✅ (PRPACK via igraph) |
| Community detection | ❌ | ✅ (Louvain, Leiden, LP) |
| Betweenness centrality | ❌ | ✅ (Brandes + igraph) |
| DAG type | ❌ | ✅ with cycle prevention |
| Cycle enumeration | ❌ | ✅ |
| Extensible traversals | Partial | ✅ (lazy streams) |
| Serialization | DOT only | DOT, JSON, GraphML, GEXF, Pajek, edge list, adjacency list, Matrix Market, Mermaid |
| Large graph perf | Pure Elixir | igraph NIF (C, optimized) |

## When to use Grafi

- **Use Grafi** if you need PageRank, betweenness, closeness, community
  detection (Louvain / Leiden / label propagation), DAG cycle prevention,
  or igraph-backed performance on graphs above a few hundred vertices.
- **Use Erlang's [`:digraph`](https://www.erlang.org/doc/man/digraph.html)**
  if you need a *mutable* graph stored in ETS and only basic traversal,
  reachability, or topological sort — and you don't want a NIF dependency.
- **Use [libgraph](https://hex.pm/packages/libgraph)** if you need a stable,
  battle-tested, pure-Elixir map-based graph with the basic algorithms
  (shortest path, MST, components) and you specifically *don't* want
  C extensions in your build.

## Troubleshooting

- **Check NIF availability** from IEx:

  ```elixir
  iex> Grafi.NIF.available?()
  true
  ```

- **Force pure-Elixir mode** (skip NIF dispatch on every algorithm) in your
  app's config:

  ```elixir
  config :grafi, nif_enabled: false
  ```

  When working on grafi itself, its `config/runtime.exs` also reads the
  `GRAFI_NIF_ENABLED` and `GRAFI_NIF_THRESHOLD` environment variables, e.g.
  `GRAFI_NIF_ENABLED=false mix test`.

- **`grafi: igraph >= 1.0 not found; building without NIF`** — install
  igraph >= 1.0 (see [Installation](#the-igraph-nif-optional)), or point the
  build at it with `IGRAPH_DIR=/prefix`, then rebuild with
  `mix deps.compile grafi --force`. An older igraph (e.g. 0.10 from a distro
  package) is reported as `igraph 0.10.x found …, but >= 1.0 is required`.

- **Linker can't find `libigraph` at runtime** — source builds embed an
  rpath to the igraph `lib/` directory they were linked against, so this
  usually means igraph was moved or uninstalled after the build. Reinstall
  it, or rebuild with `mix deps.compile grafi --force`.

## License

Grafi's source code is licensed under [Apache 2.0](LICENSE).

### Third-party licenses

The optional NIF bridges to [igraph](https://igraph.org), which is
GPL-2.0-or-later and is not included in the Hex package:

- **Built from source** (igraph installed on your machine): the NIF links
  your igraph dynamically.
- **Precompiled artefacts** (downloaded by default from the GitHub releases
  page on supported platforms) statically link igraph 1.0.1. They combine
  Apache-2.0 and GPL code, so each artefact is distributed under the
  **GPL-3.0-or-later** (pending legal review). If you distribute an
  application that includes one (e.g. a `mix release`), that licence applies
  to it; see above for building without any GPL code.

[NOTICE](NOTICE) has the details and the corresponding-source pointers; each
GitHub release also carries the igraph source and the licence texts.
