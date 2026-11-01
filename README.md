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
- **Graceful fallback** — every NIF-accelerated algorithm has a pure Elixir
  implementation that kicks in if igraph is not installed
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
    # {:grafi, git: "https://github.com/nmaroulis/grafi"}
  ]
end
```

### Optional: igraph NIF acceleration

For NIF-accelerated algorithms, install igraph system-wide:

```bash
# macOS
brew install igraph

# Ubuntu / Debian
sudo apt install libigraph-dev

# From source
git clone https://github.com/igraph/igraph.git
cd igraph && mkdir build && cd build
cmake .. && make && sudo make install
```

The NIF compiles automatically during `mix compile`. If igraph is not found,
Grafi falls back to pure Elixir — no build errors.

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

The threshold is configurable at runtime:

```elixir
# In runtime.exs, or anywhere during boot:
Application.put_env(:grafi, :nif_threshold, 1_000)

# Or via env var (read by config/runtime.exs):
# GRAFI_NIF_THRESHOLD=1000
```

You can also disable NIF dispatch entirely (forces pure-Elixir paths
on every algorithm) with `GRAFI_NIF_ENABLED=false`, which is what CI
uses to exercise the fallback codepath.

Isomorphism searches are unbounded by default. Set
`config :grafi, vf2_timeout: 5_000` (milliseconds) to cap every VF2 search
that has no explicit `:timeout`; use a finite value for untrusted input.

All NIFs are registered as `ERL_NIF_DIRTY_JOB_CPU_BOUND`, so even
multi-second runs (e.g. Louvain on a 100k-vertex graph) execute on a
dirty CPU scheduler and never stall the BEAM's normal schedulers.

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
| Serialization | DOT only | DOT, JSON, more planned |
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

- **Force pure-Elixir mode** (skip NIF dispatch on every algorithm),
  useful for CI matrices and for verifying the fallback path:

  ```bash
  GRAFI_NIF_ENABLED=false mix test
  ```

  Or set it permanently in `config/runtime.exs`:

  ```elixir
  config :grafi, nif_enabled: false
  ```

- **`igraph` not found at compile time** — install the development
  headers, then recompile:

  ```bash
  # macOS
  brew install igraph

  # Ubuntu / Debian
  sudo apt install libigraph-dev
  ```

- **Linker can't find `libigraph` at runtime** — on Linux, the loader
  may not look in `/usr/local/lib` by default. Either set
  `LD_LIBRARY_PATH=/usr/local/lib`, add the path to `/etc/ld.so.conf.d/`
  and run `ldconfig`, or reinstall igraph through your package manager
  so it lands in a default search path. After fixing, rebuild Grafi
  with `mix deps.compile grafi --force`.

## License

[Apache 2.0](LICENSE)
