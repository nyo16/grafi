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

  @doc """
  Shortest weighted path via Dijkstra. Returns `{:ok, {path, distance}}`,
  `:no_path`, or `{:error, :no_such_vertex}`.

  ## Examples

      iex> g = Grafi.new() |> Grafi.add_edges([
      ...>   {:a, :b, weight: 1.0},
      ...>   {:b, :c, weight: 2.0},
      ...>   {:a, :c, weight: 5.0}
      ...> ])
      iex> Grafi.shortest_path(g, :a, :c)
      {:ok, {[:a, :b, :c], 3.0}}

      iex> g = Grafi.new() |> Grafi.add_vertices([:a, :b])
      iex> Grafi.shortest_path(g, :a, :b)
      :no_path
  """
  def shortest_path(g, from, to, opts \\ []),
    do: Grafi.Algo.ShortestPath.dijkstra(g, from, to, opts)

  @doc "A* shortest path with heuristic function."
  def a_star(g, from, to, heuristic),
    do: Grafi.Algo.ShortestPath.a_star(g, from, to, heuristic)

  @doc """
  PageRank scores for all vertices. Returns a map of `vertex => score`,
  with scores summing to ~1.0.

  ## Examples

      iex> g = Grafi.new() |> Grafi.add_edges([{:a, :b}, {:b, :c}, {:c, :a}])
      iex> ranks = Grafi.pagerank(g)
      iex> Enum.sort(Map.keys(ranks))
      [:a, :b, :c]
      iex> Float.round(Enum.sum(Map.values(ranks)), 2)
      1.0
  """
  def pagerank(g, opts \\ []),
    do: Grafi.Algo.Centrality.pagerank(g, opts)

  @doc "Betweenness centrality for all vertices."
  def betweenness(g),
    do: Grafi.Algo.Centrality.betweenness(g)

  @doc "Closeness centrality for all vertices."
  def closeness(g),
    do: Grafi.Algo.Centrality.closeness(g)

  @doc """
  Returns true if the graph contains at least one directed cycle.

  ## Examples

      iex> Grafi.new()
      ...> |> Grafi.add_edges([{:a, :b}, {:b, :c}, {:c, :a}])
      ...> |> Grafi.has_cycle?()
      true

      iex> Grafi.new()
      ...> |> Grafi.add_edges([{:a, :b}, {:b, :c}])
      ...> |> Grafi.has_cycle?()
      false
  """
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

  @doc """
  BFS stream from a start vertex. Lazy; safe to pipe into `Enum.take/2`.
  Sibling order at a given depth is map-iteration order, so don't rely on
  it; depth order is guaranteed.

  ## Examples

      iex> order =
      ...>   Grafi.new()
      ...>   |> Grafi.add_edges([{:a, :b}, {:a, :c}, {:b, :d}, {:c, :d}])
      ...>   |> Grafi.bfs(:a)
      ...>   |> Enum.to_list()
      iex> {hd(order), Enum.sort(order)}
      {:a, [:a, :b, :c, :d]}
  """
  def bfs(g, start),
    do: Grafi.Algo.Traversal.bfs(g, start)

  @doc "DFS stream from a start vertex."
  def dfs(g, start),
    do: Grafi.Algo.Traversal.dfs(g, start)

  # ── Metrics ───────────────────────────────────────────────────────────

  defdelegate triangle_count(g), to: Grafi.Algo.Metrics
  defdelegate clustering_coefficient(g), to: Grafi.Algo.Metrics
  defdelegate clustering_coefficient(g, vertex), to: Grafi.Algo.Metrics
  defdelegate transitivity(g), to: Grafi.Algo.Metrics
  defdelegate density(g), to: Grafi.Algo.Metrics
  defdelegate diameter(g, opts \\ []), to: Grafi.Algo.Metrics
  defdelegate radius(g, opts \\ []), to: Grafi.Algo.Metrics
  defdelegate eccentricity(g, vertex, opts \\ []), to: Grafi.Algo.Metrics

  # ── Spanning trees ────────────────────────────────────────────────────

  defdelegate kruskal(g), to: Grafi.Algo.MST
  defdelegate prim(g, start \\ nil), to: Grafi.Algo.MST

  # ── All-pairs shortest path ───────────────────────────────────────────

  defdelegate floyd_warshall(g), to: Grafi.Algo.APSP
  defdelegate johnson(g), to: Grafi.Algo.APSP
  defdelegate transitive_closure(g), to: Grafi.Algo.APSP

  # ── Bidirectional / k-shortest ────────────────────────────────────────

  defdelegate bidirectional_dijkstra(g, source, target, opts \\ []),
    to: Grafi.Algo.Bidirectional,
    as: :dijkstra

  defdelegate k_shortest_paths(g, source, target, k, opts \\ []),
    to: Grafi.Algo.KShortestPath,
    as: :yen

  # ── Connectivity ──────────────────────────────────────────────────────

  defdelegate bridges(g), to: Grafi.Algo.Connectivity
  defdelegate articulation_points(g), to: Grafi.Algo.Connectivity
  defdelegate biconnected_components(g), to: Grafi.Algo.Connectivity

  # ── Bipartite / k-core / cliques ──────────────────────────────────────

  defdelegate bipartite?(g), to: Grafi.Algo.Bipartite
  defdelegate core_numbers(g), to: Grafi.Algo.KCore
  defdelegate k_core(g, k), to: Grafi.Algo.KCore
  defdelegate maximal_cliques(g), to: Grafi.Algo.Cliques
  defdelegate maximum_clique(g), to: Grafi.Algo.Cliques

  # ── Extra centralities ────────────────────────────────────────────────

  defdelegate hits(g, opts \\ []), to: Grafi.Algo.Centrality
  defdelegate katz(g, opts \\ []), to: Grafi.Algo.Centrality

  defdelegate eigenvector_centrality(g, opts \\ []),
    to: Grafi.Algo.Centrality,
    as: :eigenvector

  defdelegate harmonic_centrality(g, opts \\ []),
    to: Grafi.Algo.Centrality,
    as: :harmonic

  # ── Max-flow / matching ───────────────────────────────────────────────

  @doc """
  Maximum s–t flow. Dispatches to Dinic's algorithm by default; pass
  `algo: :edmonds_karp` for the simpler BFS-based variant.
  """
  def max_flow(g, source, sink, opts \\ []) do
    case Keyword.get(opts, :algo, :dinic) do
      :dinic -> Grafi.Algo.MaxFlow.dinic(g, source, sink, opts)
      :edmonds_karp -> Grafi.Algo.MaxFlow.edmonds_karp(g, source, sink, opts)
    end
  end

  defdelegate min_cut(g, source, sink, opts \\ []), to: Grafi.Algo.MaxFlow

  defdelegate bipartite_matching(g, left_side, opts \\ []),
    to: Grafi.Algo.Matching,
    as: :hopcroft_karp

  defdelegate weighted_bipartite_matching(g, left_side, opts \\ []),
    to: Grafi.Algo.Matching

  # ── Isomorphism ───────────────────────────────────────────────────────

  defdelegate isomorphic?(g1, g2), to: Grafi.Algo.Isomorphism
  defdelegate subgraph_isomorphic?(g, pattern), to: Grafi.Algo.Isomorphism

  # ── Serialization ─────────────────────────────────────────────────────

  @doc """
  Export to Graphviz DOT format. See `Grafi.Serialize.DOT.to_dot/2` for
  options.

  ## Examples

      iex> dot = Grafi.new() |> Grafi.add_edge(:a, :b) |> Grafi.to_dot()
      iex> String.starts_with?(dot, "digraph G {") and
      ...>   dot =~ "a -> b" and dot =~ "a;" and dot =~ "b;"
      true
  """
  def to_dot(g, opts \\ []),
    do: Grafi.Serialize.DOT.to_dot(g, opts)

  @doc "Export to JSON (requires `:jason`)."
  def to_json(g),
    do: Grafi.Serialize.JSON.to_json(g)

  @doc "Import from JSON string."
  def from_json(json),
    do: Grafi.Serialize.JSON.from_json(json)

  defdelegate to_mermaid(g, opts \\ []), to: Grafi.Serialize.Mermaid
  defdelegate to_graphml(g, opts \\ []), to: Grafi.Serialize.GraphML
  defdelegate from_graphml(xml), to: Grafi.Serialize.GraphML
  defdelegate to_gexf(g, opts \\ []), to: Grafi.Serialize.GEXF
  defdelegate from_gexf(xml), to: Grafi.Serialize.GEXF
  defdelegate to_pajek(g, opts \\ []), to: Grafi.Serialize.Pajek
  defdelegate from_pajek(text), to: Grafi.Serialize.Pajek
  defdelegate to_edge_list(g, opts \\ []), to: Grafi.Serialize.EdgeList
  defdelegate from_edge_list(text, opts \\ []), to: Grafi.Serialize.EdgeList
  defdelegate to_adjacency_list(g, opts \\ []), to: Grafi.Serialize.AdjacencyList
  defdelegate from_adjacency_list(text, opts \\ []), to: Grafi.Serialize.AdjacencyList
  defdelegate to_matrix_market(g, opts \\ []), to: Grafi.Serialize.MatrixMarket
  defdelegate from_matrix_market(text), to: Grafi.Serialize.MatrixMarket
end
