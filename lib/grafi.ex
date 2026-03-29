defmodule Grafi do
  @moduledoc """
  # Grafi — γραφή

  A high-performance graph library for Elixir with igraph NIF acceleration.

  Grafi provides an immutable, pipeable graph data structure with
  comprehensive algorithms for pathfinding, centrality, community
  detection, cycle analysis, and DAG operations.

  ## Architecture

  - **Pure Elixir core** — `Grafi.Graph` and `Grafi.DAG` for construction,
    mutation, traversal, and small-graph algorithms.
  - **igraph C++ NIFs** — via `fine`, heavy algorithms (PageRank,
    betweenness, Louvain, Leiden) dispatch to the battle-tested igraph
    C library on dirty CPU schedulers.
  - **Graceful fallback** — if igraph is not installed, every algorithm
    has a pure Elixir implementation (except community detection).

  ## Quick start

      # Build a graph
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
      #=> %{athens: 0.18, sparta: 0.27, corinth: 0.28, olympia: 0.27}

      # Cycle detection
      Grafi.has_cycle?(g)
      #=> true

      # DAG enforcement
      dag = Grafi.DAG.new()
        |> Grafi.DAG.add_edge(:parse, :compile)
        |> Grafi.DAG.add_edge(:compile, :link)
      Grafi.DAG.topological_sort(dag)
      #=> {:ok, [:parse, :compile, :link]}

  ## Serialization

      Grafi.to_dot(g)    # Graphviz DOT
      Grafi.to_json(g)   # JSON adjacency list
  """

  alias Grafi.Graph

  # ── Construction (delegated) ──────────────────────────────────────────

  defdelegate new(opts \\ []), to: Graph
  defdelegate add_vertex(g, v, opts \\ []), to: Graph
  defdelegate add_vertices(g, vs), to: Graph
  defdelegate add_edge(g, v1, v2, opts \\ []), to: Graph
  defdelegate add_edges(g, edges), to: Graph
  defdelegate delete_vertex(g, v), to: Graph
  defdelegate delete_edge(g, v1, v2), to: Graph

  # ── Queries (delegated) ──────────────────────────────────────────────

  defdelegate vertices(g), to: Graph
  defdelegate edges(g), to: Graph
  defdelegate has_vertex?(g, v), to: Graph
  defdelegate has_edge?(g, v1, v2), to: Graph
  defdelegate neighbors(g, v), to: Graph
  defdelegate out_neighbors(g, v), to: Graph
  defdelegate in_neighbors(g, v), to: Graph
  defdelegate degree(g, v), to: Graph
  defdelegate num_vertices(g), to: Graph
  defdelegate num_edges(g), to: Graph
  defdelegate subgraph(g, vs), to: Graph
  defdelegate transpose(g), to: Graph

  # ── Algorithms (convenience wrappers) ─────────────────────────────────

  @doc "Shortest path via Dijkstra. Returns `{:ok, {path, distance}}` or `:no_path`."
  def shortest_path(g, from, to, opts \\ []),
    do: Grafi.Algo.ShortestPath.dijkstra(g, from, to, opts)

  @doc "A* shortest path with heuristic function."
  def a_star(g, from, to, heuristic),
    do: Grafi.Algo.ShortestPath.a_star(g, from, to, heuristic)

  @doc "PageRank scores for all vertices."
  def pagerank(g, opts \\ []),
    do: Grafi.Algo.Centrality.pagerank(g, opts)

  @doc "Betweenness centrality for all vertices."
  def betweenness(g),
    do: Grafi.Algo.Centrality.betweenness(g)

  @doc "Closeness centrality for all vertices."
  def closeness(g),
    do: Grafi.Algo.Centrality.closeness(g)

  @doc "Returns true if the graph contains a cycle."
  def has_cycle?(g),
    do: Grafi.Algo.Cycles.has_cycle?(g)

  @doc "Find one cycle in the graph, if any."
  def find_cycle(g),
    do: Grafi.Algo.Cycles.find_cycle(g)

  @doc "Strongly connected components (Tarjan)."
  def scc(g),
    do: Grafi.Algo.Cycles.strongly_connected_components(g)

  @doc "Connected components."
  def components(g),
    do: Grafi.Algo.Cycles.connected_components(g)

  @doc "Condensation DAG (contract each SCC into one vertex)."
  def condensation(g),
    do: Grafi.Algo.Cycles.condensation(g)

  @doc "Community detection via Louvain (requires NIF)."
  def louvain(g),
    do: Grafi.Algo.Community.louvain(g)

  @doc "Community detection via Leiden (requires NIF)."
  def leiden(g, opts \\ []),
    do: Grafi.Algo.Community.leiden(g, opts)

  @doc "BFS stream from a start vertex."
  def bfs(g, start),
    do: Grafi.Algo.Traversal.bfs(g, start)

  @doc "DFS stream from a start vertex."
  def dfs(g, start),
    do: Grafi.Algo.Traversal.dfs(g, start)

  # ── Serialization ─────────────────────────────────────────────────────

  @doc "Export to Graphviz DOT format."
  def to_dot(g, opts \\ []),
    do: Grafi.Serialize.DOT.to_dot(g, opts)

  @doc "Export to JSON (requires `:jason`)."
  def to_json(g),
    do: Grafi.Serialize.JSON.to_json(g)

  @doc "Import from JSON string."
  def from_json(json),
    do: Grafi.Serialize.JSON.from_json(json)
end
