# Grafi — γραφή

[![Hex.pm](https://img.shields.io/hexpm/v/grafi.svg)](https://hex.pm/packages/grafi)
[![Docs](https://img.shields.io/badge/docs-hexdocs-blue.svg)](https://hexdocs.pm/grafi)

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
- **Serialization** — DOT (Graphviz), JSON, with more formats planned

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

## Installation

Add `grafi` to your `mix.exs`:

```elixir
def deps do
  [{:grafi, "~> 0.1.0"}]
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

# PageRank
Grafi.pagerank(g)
#=> %{athens: 0.15, corinth: 0.28, sparta: 0.30, olympia: 0.27}

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

The NIF threshold is 500 vertices — below that, pure Elixir runs.
Above that, graphs are converted to CSR (Compressed Sparse Row) format
and dispatched to igraph. All NIFs run on dirty CPU schedulers so they
never block the BEAM.

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

## License

MIT
