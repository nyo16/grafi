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

  ## Conventions

  Every public function follows these rules:

  | Area | Convention |
  |---|---|
  | Fallible operations | `{:ok, value}` or `{:error, reason}`; error tuples always have two elements, e.g. `{:error, {:not_bipartite, {u, v}}}` |
  | Raising variants | a `!` function raises instead of returning `{:error, _}` where one is provided (`from_json!/2` and the other deserializers, `MST.kruskal!/1`, `DAG.from_graph!/1`) |
  | Deserializers | `from_x/2` returns `{:ok, graph}` or `{:error, reason}`; `from_x!/2` raises |
  | No path | `{:error, :no_path}` |
  | No cycle | `{:error, :no_cycle}` (`find_cycle/1`) |
  | Missing endpoint | functions returning `{:ok, _}` / `{:error, _}` return `{:error, :no_such_vertex}`; functions returning a plain value (`bfs/2`, `dfs/2`, `reachable?/3`, `eccentricity/3`, `prim/2`) raise `ArgumentError` |
  | Invalid options | `ArgumentError`, including unknown option keys (`Keyword.validate!/2`) |
  | Iteration knobs | `:max_iter` and `:tol` |
  | Directedness | `type: :directed \| :undirected`, default `:directed` (`Grafi.Graph.new/1`, `Grafi.Generators`, the edge-list and adjacency-list readers) |
  | Engine | NIF-capable functions take `engine: :auto \| :nif \| :elixir` |

  NIF-only algorithms (`Grafi.Algo.Community.louvain/2`, `leiden/2`,
  `label_propagation/2`) return `{:error, :nif_not_available}` without the
  NIF; every other algorithm falls back to pure Elixir. Use
  `Grafi.nif_available?/0` to check up front, or
  `Grafi.Algo.Community.label_propagation_simple/2` for a pure-Elixir
  alternative.

  ## Facade names

  Facade functions carry the name of the module function they call. The
  exceptions are names that would be ambiguous at the `Grafi` level:

  | Facade | Calls |
  |---|---|
  | `bidirectional_dijkstra/4` | `Grafi.Algo.Bidirectional.dijkstra/4` |
  | `eigenvector_centrality/2` | `Grafi.Algo.Centrality.eigenvector/2` |
  | `harmonic_centrality/2` | `Grafi.Algo.Centrality.harmonic/2` |
  | `bipartite_coloring/1` | `Grafi.Algo.Bipartite.coloring/1` |
  | `bipartite_sets/1` | `Grafi.Algo.Bipartite.sets/1` |
  | `bipartite_projection/2` | `Grafi.Algo.Bipartite.project/2` |
  | `top_k_links/2` | `Grafi.Algo.LinkPrediction.top_k/2` |
  | `complete_graph/2`, `cycle_graph/2`, `path_graph/2`, `grid_graph/3` | `Grafi.Generators.complete/2`, `cycle/2`, `path/2`, `grid/3` |

  Modules with an API of their own (`Grafi.DAG`, `Grafi.Layout`,
  `Grafi.Viz`) are used directly.

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
      Grafi.dijkstra(g, :athens, :olympia)
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

  alias Grafi.{Edge, Graph}
  alias Grafi.Algo.{APSP, Community, Connectivity, Isomorphism, LinkPrediction, MaxFlow}

  @typep vertex :: Graph.vertex_id()
  @typep path_result :: {:ok, {[vertex()], number()}} | {:error, term()}
  @typep scores :: %{vertex() => float()}

  @doc """
  Returns `true` if the igraph NIF engine is loaded and available.

  When `false`, NIF-only algorithms (e.g. `Grafi.Algo.Community.louvain/2`)
  return `{:error, :nif_not_available}`; algorithms with a pure-Elixir
  fallback are unaffected.
  """
  @spec nif_available?() :: boolean()
  defdelegate nif_available?(), to: Grafi.NIF, as: :available?

  # ── Construction ──────────────────────────────────────────────────────

  @spec new(keyword()) :: Graph.t()
  defdelegate new(opts \\ []), to: Graph
  @spec add_vertex(Graph.t(), vertex(), keyword()) :: Graph.t()
  defdelegate add_vertex(g, v, opts \\ []), to: Graph
  @spec add_vertices(Graph.t(), [vertex() | {vertex(), keyword()}]) :: Graph.t()
  defdelegate add_vertices(g, vs), to: Graph
  @spec add_edge(Graph.t(), vertex(), vertex(), keyword()) :: Graph.t()
  defdelegate add_edge(g, v1, v2, opts \\ []), to: Graph

  @spec add_edges(Graph.t(), [{vertex(), vertex()} | {vertex(), vertex(), keyword()}]) ::
          Graph.t()
  defdelegate add_edges(g, edges), to: Graph
  @spec delete_vertex(Graph.t(), vertex()) :: Graph.t()
  defdelegate delete_vertex(g, v), to: Graph
  @spec delete_edge(Graph.t(), vertex(), vertex()) :: Graph.t()
  defdelegate delete_edge(g, v1, v2), to: Graph

  # ── Queries ───────────────────────────────────────────────────────────

  @spec vertices(Graph.t()) :: [vertex()]
  defdelegate vertices(g), to: Graph
  @spec edges(Graph.t()) :: [Edge.t()]
  defdelegate edges(g), to: Graph
  @spec edges_between(Graph.t(), vertex(), vertex()) :: [Edge.t()]
  defdelegate edges_between(g, v1, v2), to: Graph
  @spec has_vertex?(Graph.t(), vertex()) :: boolean()
  defdelegate has_vertex?(g, v), to: Graph
  @spec has_edge?(Graph.t(), vertex(), vertex()) :: boolean()
  defdelegate has_edge?(g, v1, v2), to: Graph
  @spec label(Graph.t(), vertex()) :: any()
  defdelegate label(g, v), to: Graph
  @spec neighbors(Graph.t(), vertex()) :: [vertex()]
  defdelegate neighbors(g, v), to: Graph
  @spec out_neighbors(Graph.t(), vertex()) :: [vertex()]
  defdelegate out_neighbors(g, v), to: Graph
  @spec in_neighbors(Graph.t(), vertex()) :: [vertex()]
  defdelegate in_neighbors(g, v), to: Graph
  @spec degree(Graph.t(), vertex()) :: non_neg_integer()
  defdelegate degree(g, v), to: Graph
  @spec out_degree(Graph.t(), vertex()) :: non_neg_integer()
  defdelegate out_degree(g, v), to: Graph
  @spec in_degree(Graph.t(), vertex()) :: non_neg_integer()
  defdelegate in_degree(g, v), to: Graph
  @spec num_vertices(Graph.t()) :: non_neg_integer()
  defdelegate num_vertices(g), to: Graph
  @spec num_edges(Graph.t()) :: non_neg_integer()
  defdelegate num_edges(g), to: Graph
  @spec empty?(Graph.t()) :: boolean()
  defdelegate empty?(g), to: Graph
  @spec subgraph(Graph.t(), [vertex()]) :: Graph.t()
  defdelegate subgraph(g, vs), to: Graph
  @spec transpose(Graph.t()) :: Graph.t()
  defdelegate transpose(g), to: Graph

  # ── Generators ────────────────────────────────────────────────────────

  @spec complete_graph(non_neg_integer(), keyword()) :: Graph.t()
  defdelegate complete_graph(n, opts \\ []), to: Grafi.Generators, as: :complete
  @spec cycle_graph(non_neg_integer(), keyword()) :: Graph.t()
  defdelegate cycle_graph(n, opts \\ []), to: Grafi.Generators, as: :cycle
  @spec path_graph(non_neg_integer(), keyword()) :: Graph.t()
  defdelegate path_graph(n, opts \\ []), to: Grafi.Generators, as: :path
  @spec grid_graph(non_neg_integer(), non_neg_integer(), keyword()) :: Graph.t()
  defdelegate grid_graph(m, n, opts \\ []), to: Grafi.Generators, as: :grid
  @spec erdos_renyi(non_neg_integer(), float(), keyword()) :: Graph.t()
  defdelegate erdos_renyi(n, p, opts \\ []), to: Grafi.Generators
  @spec barabasi_albert(pos_integer(), pos_integer(), keyword()) :: Graph.t()
  defdelegate barabasi_albert(n, m, opts \\ []), to: Grafi.Generators
  @spec watts_strogatz(pos_integer(), pos_integer(), float(), keyword()) :: Graph.t()
  defdelegate watts_strogatz(n, k, p, opts \\ []), to: Grafi.Generators
  @spec random_regular(pos_integer(), non_neg_integer(), keyword()) :: Graph.t()
  defdelegate random_regular(n, d, opts \\ []), to: Grafi.Generators

  # ── Shortest paths ────────────────────────────────────────────────────

  @doc """
  Shortest weighted path via Dijkstra. Returns `{:ok, {path, distance}}`,
  `{:error, :no_path}`, or `{:error, :no_such_vertex}`. See
  `Grafi.Algo.ShortestPath.dijkstra/4` for the options and other errors.

  ## Examples

      iex> g = Grafi.new() |> Grafi.add_edges([
      ...>   {:a, :b, weight: 1.0},
      ...>   {:b, :c, weight: 2.0},
      ...>   {:a, :c, weight: 5.0}
      ...> ])
      iex> Grafi.dijkstra(g, :a, :c)
      {:ok, {[:a, :b, :c], 3.0}}

      iex> g = Grafi.new() |> Grafi.add_vertices([:a, :b])
      iex> Grafi.dijkstra(g, :a, :b)
      {:error, :no_path}
  """
  @spec dijkstra(Graph.t(), vertex(), vertex(), keyword()) :: path_result()
  defdelegate dijkstra(g, from, to, opts \\ []), to: Grafi.Algo.ShortestPath

  @spec dijkstra_all(Graph.t(), vertex(), (Edge.t() -> number())) :: %{vertex() => number()}
  defdelegate dijkstra_all(g, source, weight_fn \\ & &1.weight), to: Grafi.Algo.ShortestPath

  @doc """
  A* shortest path with a heuristic function. Returns `{:ok, {path, cost}}`,
  `{:error, :no_path}`, or `{:error, :no_such_vertex}`.
  """
  @spec a_star(Graph.t(), vertex(), vertex(), (vertex() -> number())) ::
          {:ok, {[vertex()], number()}} | {:error, :no_path | :no_such_vertex}
  defdelegate a_star(g, from, to, heuristic), to: Grafi.Algo.ShortestPath

  @spec bellman_ford(Graph.t(), vertex()) ::
          {:ok, %{vertex() => number()}} | {:error, :negative_cycle | :no_such_vertex}
  defdelegate bellman_ford(g, source), to: Grafi.Algo.ShortestPath

  @spec bidirectional_dijkstra(Graph.t(), vertex(), vertex(), keyword()) ::
          {:ok, {[vertex()], number()}} | {:error, :no_path | :no_such_vertex}
  defdelegate bidirectional_dijkstra(g, source, target, opts \\ []),
    to: Grafi.Algo.Bidirectional,
    as: :dijkstra

  @spec yen(Graph.t(), vertex(), vertex(), pos_integer(), keyword()) ::
          {:ok, [{[vertex()], number()}]}
          | {:error, :no_such_vertex | :no_path | :negative_weight}
  defdelegate yen(g, source, target, k, opts \\ []), to: Grafi.Algo.KShortestPath

  @spec floyd_warshall(Graph.t()) :: {:ok, APSP.dist_matrix()} | {:error, :negative_cycle}
  defdelegate floyd_warshall(g), to: APSP

  @spec floyd_warshall_with_paths(Graph.t()) ::
          {:ok, APSP.dist_matrix(), APSP.pred_matrix()} | {:error, :negative_cycle}
  defdelegate floyd_warshall_with_paths(g), to: APSP

  @spec reconstruct_path(APSP.pred_matrix(), vertex(), vertex()) ::
          {:ok, [vertex()]} | {:error, :no_path | :no_such_vertex}
  defdelegate reconstruct_path(preds, from, to), to: APSP

  @spec johnson(Graph.t()) :: {:ok, APSP.dist_matrix()} | {:error, :negative_cycle}
  defdelegate johnson(g), to: APSP

  @spec transitive_closure(Graph.t()) :: %{vertex() => MapSet.t()}
  defdelegate transitive_closure(g), to: APSP

  # ── Spanning trees ────────────────────────────────────────────────────

  @spec kruskal(Graph.t()) :: {[Edge.t()], number()}
  defdelegate kruskal(g), to: Grafi.Algo.MST
  @spec kruskal_tree(Graph.t()) :: {:ok, {[Edge.t()], number()}} | {:error, :disconnected}
  defdelegate kruskal_tree(g), to: Grafi.Algo.MST
  @spec kruskal!(Graph.t()) :: {[Edge.t()], number()}
  defdelegate kruskal!(g), to: Grafi.Algo.MST
  @spec prim(Graph.t(), vertex() | nil) :: {[Edge.t()], number()}
  defdelegate prim(g, start \\ nil), to: Grafi.Algo.MST
  @spec total_weight([Edge.t()]) :: number()
  defdelegate total_weight(edges), to: Grafi.Algo.MST

  # ── Traversal ─────────────────────────────────────────────────────────

  @doc """
  BFS stream from a start vertex. Lazy; safe to pipe into `Enum.take/2`.
  Sibling order at a given depth is map-iteration order, so don't rely on
  it; depth order is guaranteed. Raises `ArgumentError` if `start` is not in
  the graph.

  ## Examples

      iex> order =
      ...>   Grafi.new()
      ...>   |> Grafi.add_edges([{:a, :b}, {:a, :c}, {:b, :d}, {:c, :d}])
      ...>   |> Grafi.bfs(:a)
      ...>   |> Enum.to_list()
      iex> {hd(order), Enum.sort(order)}
      {:a, [:a, :b, :c, :d]}
  """
  @spec bfs(Graph.t(), vertex()) :: Enumerable.t()
  defdelegate bfs(g, start), to: Grafi.Algo.Traversal

  @doc "DFS stream from a start vertex. Raises `ArgumentError` if `start` is not in the graph."
  @spec dfs(Graph.t(), vertex()) :: Enumerable.t()
  defdelegate dfs(g, start), to: Grafi.Algo.Traversal

  @spec dfs_post(Graph.t(), vertex()) :: [vertex()]
  defdelegate dfs_post(g, start), to: Grafi.Algo.Traversal
  @spec reachable?(Graph.t(), vertex(), vertex()) :: boolean()
  defdelegate reachable?(g, source, target), to: Grafi.Algo.Traversal
  @spec reachable_from(Graph.t(), vertex()) :: MapSet.t()
  defdelegate reachable_from(g, source), to: Grafi.Algo.Traversal

  @doc """
  Topological order of a directed graph (Kahn, ties broken by vertex term
  order): `{:ok, order}` or `{:error, :has_cycle}`.
  """
  @spec topological_sort(Graph.t()) :: {:ok, [vertex()]} | {:error, :has_cycle}
  defdelegate topological_sort(g), to: Grafi.Algo.Traversal

  # ── Cycles and components ─────────────────────────────────────────────

  @doc """
  Returns true if the graph contains at least one cycle: a directed cycle in
  a directed graph; in an undirected graph, any cycle other than walking a
  single edge back (so a self-loop, a parallel pair or a triangle counts,
  a lone edge does not). See `Grafi.Algo.Cycles.has_cycle?/1`.

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
  @spec has_cycle?(Graph.t()) :: boolean()
  defdelegate has_cycle?(g), to: Grafi.Algo.Cycles

  @doc "Finds one cycle as a closed walk: `{:ok, [v0, ..., v0]}` or `{:error, :no_cycle}`."
  @spec find_cycle(Graph.t()) :: {:ok, [vertex()]} | {:error, :no_cycle}
  defdelegate find_cycle(g), to: Grafi.Algo.Cycles

  @doc "Strongly connected components (canonical order; see `Grafi.Algo.Cycles`)."
  @spec strongly_connected_components(Graph.t(), keyword()) :: [[vertex()]]
  defdelegate strongly_connected_components(g, opts \\ []), to: Grafi.Algo.Cycles

  @doc "Connected components (weak for directed graphs), in canonical order."
  @spec connected_components(Graph.t()) :: [[vertex()]]
  defdelegate connected_components(g), to: Grafi.Algo.Cycles

  @doc """
  Condensation DAG: each SCC becomes one integer vertex (its index in
  `strongly_connected_components/2` order), labelled with its sorted member
  list.
  """
  @spec condensation(Graph.t()) :: Graph.t()
  defdelegate condensation(g), to: Grafi.Algo.Cycles

  # ── Centrality ────────────────────────────────────────────────────────

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
  @spec pagerank(Graph.t(), keyword()) :: scores()
  defdelegate pagerank(g, opts \\ []), to: Grafi.Algo.Centrality

  @doc "Betweenness centrality for all vertices."
  @spec betweenness(Graph.t(), keyword()) :: scores()
  defdelegate betweenness(g, opts \\ []), to: Grafi.Algo.Centrality

  @doc "Closeness centrality for all vertices."
  @spec closeness(Graph.t(), keyword()) :: scores()
  defdelegate closeness(g, opts \\ []), to: Grafi.Algo.Centrality

  @spec degree_centrality(Graph.t()) :: scores()
  defdelegate degree_centrality(g), to: Grafi.Algo.Centrality
  @spec hits(Graph.t(), keyword()) :: %{hubs: scores(), authorities: scores()}
  defdelegate hits(g, opts \\ []), to: Grafi.Algo.Centrality
  @spec katz(Graph.t(), keyword()) :: scores()
  defdelegate katz(g, opts \\ []), to: Grafi.Algo.Centrality
  @spec eigenvector_centrality(Graph.t(), keyword()) :: scores()
  defdelegate eigenvector_centrality(g, opts \\ []), to: Grafi.Algo.Centrality, as: :eigenvector
  @spec harmonic_centrality(Graph.t(), keyword()) :: scores()
  defdelegate harmonic_centrality(g, opts \\ []), to: Grafi.Algo.Centrality, as: :harmonic

  # ── Community detection ───────────────────────────────────────────────

  @doc "Community detection via Louvain (requires NIF)."
  @spec louvain(Graph.t(), keyword()) :: {:ok, Community.community_result()} | Community.error()
  defdelegate louvain(g, opts \\ []), to: Community

  @doc "Community detection via Leiden (requires NIF)."
  @spec leiden(Graph.t(), keyword()) :: {:ok, Community.community_result()} | Community.error()
  defdelegate leiden(g, opts \\ []), to: Community

  @doc "Community detection via label propagation (requires NIF)."
  @spec label_propagation(Graph.t(), keyword()) ::
          {:ok, Community.community_result()} | Community.error()
  defdelegate label_propagation(g, opts \\ []), to: Community

  @doc "Pure-Elixir label propagation."
  @spec label_propagation_simple(Graph.t(), keyword()) :: Community.community_result()
  defdelegate label_propagation_simple(g, opts \\ []), to: Community

  # ── Metrics ───────────────────────────────────────────────────────────

  @spec triangle_count(Graph.t()) :: non_neg_integer()
  defdelegate triangle_count(g), to: Grafi.Algo.Metrics
  @spec triangles_per_vertex(Graph.t()) :: %{vertex() => non_neg_integer()}
  defdelegate triangles_per_vertex(g), to: Grafi.Algo.Metrics
  @spec clustering_coefficient(Graph.t()) :: float()
  defdelegate clustering_coefficient(g), to: Grafi.Algo.Metrics
  @spec clustering_coefficient(Graph.t(), vertex()) :: float()
  defdelegate clustering_coefficient(g, vertex), to: Grafi.Algo.Metrics
  @spec transitivity(Graph.t()) :: float()
  defdelegate transitivity(g), to: Grafi.Algo.Metrics
  @spec density(Graph.t()) :: float()
  defdelegate density(g), to: Grafi.Algo.Metrics
  @spec eccentricity(Graph.t(), vertex(), keyword()) :: number() | :infinity
  defdelegate eccentricity(g, vertex, opts \\ []), to: Grafi.Algo.Metrics
  @spec eccentricities(Graph.t(), keyword()) :: %{vertex() => number() | :infinity}
  defdelegate eccentricities(g, opts \\ []), to: Grafi.Algo.Metrics
  @spec diameter(Graph.t(), keyword()) :: number() | :infinity
  defdelegate diameter(g, opts \\ []), to: Grafi.Algo.Metrics
  @spec radius(Graph.t(), keyword()) :: number() | :infinity
  defdelegate radius(g, opts \\ []), to: Grafi.Algo.Metrics
  @spec center(Graph.t(), keyword()) :: [vertex()]
  defdelegate center(g, opts \\ []), to: Grafi.Algo.Metrics
  @spec periphery(Graph.t(), keyword()) :: [vertex()]
  defdelegate periphery(g, opts \\ []), to: Grafi.Algo.Metrics

  # ── Connectivity ──────────────────────────────────────────────────────

  @spec bridges(Graph.t()) :: [Connectivity.edge()]
  defdelegate bridges(g), to: Connectivity
  @spec articulation_points(Graph.t()) :: MapSet.t(Connectivity.vertex())
  defdelegate articulation_points(g), to: Connectivity
  @spec biconnected_components(Graph.t()) :: [MapSet.t(Connectivity.edge())]
  defdelegate biconnected_components(g), to: Connectivity
  @spec biconnected?(Graph.t()) :: boolean()
  defdelegate biconnected?(g), to: Connectivity

  # ── Bipartite, k-core, cliques ────────────────────────────────────────

  @spec bipartite?(Graph.t()) :: boolean()
  defdelegate bipartite?(g), to: Grafi.Algo.Bipartite

  @spec bipartite_coloring(Graph.t()) ::
          {:ok, %{vertex() => 0 | 1}} | {:error, {:not_bipartite, {vertex(), vertex()}}}
  defdelegate bipartite_coloring(g), to: Grafi.Algo.Bipartite, as: :coloring

  @spec bipartite_sets(Graph.t()) :: {:ok, {MapSet.t(), MapSet.t()}} | {:error, :not_bipartite}
  defdelegate bipartite_sets(g), to: Grafi.Algo.Bipartite, as: :sets

  @spec bipartite_projection(Graph.t(), [vertex()] | MapSet.t()) :: Graph.t()
  defdelegate bipartite_projection(g, side), to: Grafi.Algo.Bipartite, as: :project

  @spec core_numbers(Graph.t()) :: %{vertex() => non_neg_integer()}
  defdelegate core_numbers(g), to: Grafi.Algo.KCore
  @spec k_core(Graph.t(), non_neg_integer()) :: Graph.t()
  defdelegate k_core(g, k), to: Grafi.Algo.KCore
  @spec degeneracy(Graph.t()) :: non_neg_integer()
  defdelegate degeneracy(g), to: Grafi.Algo.KCore

  @spec maximal_cliques(Graph.t(), keyword()) :: [MapSet.t()]
  defdelegate maximal_cliques(g, opts \\ []), to: Grafi.Algo.Cliques
  @spec maximum_clique(Graph.t()) :: MapSet.t()
  defdelegate maximum_clique(g), to: Grafi.Algo.Cliques
  @spec clique_number(Graph.t()) :: non_neg_integer()
  defdelegate clique_number(g), to: Grafi.Algo.Cliques
  @spec count_cliques(Graph.t()) :: non_neg_integer()
  defdelegate count_cliques(g), to: Grafi.Algo.Cliques

  # ── Link prediction ───────────────────────────────────────────────────

  @spec jaccard(Graph.t(), [LinkPrediction.pair()] | nil) :: LinkPrediction.scores()
  defdelegate jaccard(g, candidates \\ nil), to: LinkPrediction
  @spec adamic_adar(Graph.t(), [LinkPrediction.pair()] | nil) :: LinkPrediction.scores()
  defdelegate adamic_adar(g, candidates \\ nil), to: LinkPrediction
  @spec resource_allocation(Graph.t(), [LinkPrediction.pair()] | nil) :: LinkPrediction.scores()
  defdelegate resource_allocation(g, candidates \\ nil), to: LinkPrediction

  @spec preferential_attachment(Graph.t(), [LinkPrediction.pair()] | nil) ::
          LinkPrediction.scores()
  defdelegate preferential_attachment(g, candidates \\ nil), to: LinkPrediction

  @spec top_k_links(LinkPrediction.scores(), non_neg_integer()) ::
          [{LinkPrediction.pair(), float()}]
  defdelegate top_k_links(scores, k), to: LinkPrediction, as: :top_k

  # ── Flow and matching ─────────────────────────────────────────────────

  @doc """
  Maximum s–t flow: Dinic's algorithm by default, or `algo: :edmonds_karp`.
  See `Grafi.Algo.MaxFlow.max_flow/4`.
  """
  @spec max_flow(Graph.t(), vertex(), vertex(), keyword()) ::
          {:ok, MaxFlow.result()} | {:error, :no_such_vertex | :negative_capacity}
  defdelegate max_flow(g, source, sink, opts \\ []), to: MaxFlow

  @spec edmonds_karp(Graph.t(), vertex(), vertex(), keyword()) ::
          {:ok, MaxFlow.result()} | {:error, :no_such_vertex | :negative_capacity}
  defdelegate edmonds_karp(g, source, sink, opts \\ []), to: MaxFlow

  @spec dinic(Graph.t(), vertex(), vertex(), keyword()) ::
          {:ok, MaxFlow.result()} | {:error, :no_such_vertex | :negative_capacity}
  defdelegate dinic(g, source, sink, opts \\ []), to: MaxFlow

  @spec min_cut(Graph.t(), vertex(), vertex(), keyword()) ::
          {:ok,
           %{
             cut_value: number(),
             source_side: MapSet.t(),
             sink_side: MapSet.t(),
             cut_edges: [{vertex(), vertex()}]
           }}
          | {:error, :no_such_vertex | :negative_capacity}
  defdelegate min_cut(g, source, sink, opts \\ []), to: MaxFlow

  @spec hopcroft_karp(Graph.t(), [vertex()] | MapSet.t(), keyword()) ::
          {:ok, %{matching: %{vertex() => vertex()}, size: non_neg_integer()}}
          | {:error, :not_bipartite}
  defdelegate hopcroft_karp(g, left_side, opts \\ []), to: Grafi.Algo.Matching

  @spec hungarian([[number()]], keyword()) ::
          {:ok, %{assignment: [non_neg_integer() | nil], cost: number(), unmatched: [integer()]}}
  defdelegate hungarian(cost_matrix, opts \\ []), to: Grafi.Algo.Matching

  @spec weighted_bipartite_matching(Graph.t(), [vertex()] | MapSet.t(), keyword()) ::
          {:ok, %{matching: %{vertex() => vertex()}, weight: number()}}
          | {:error, :not_bipartite}
  defdelegate weighted_bipartite_matching(g, left_side, opts \\ []), to: Grafi.Algo.Matching

  # ── Isomorphism ───────────────────────────────────────────────────────

  @doc """
  Returns `true` if `g1` and `g2` are isomorphic. Always a boolean: raises
  `Grafi.TimeoutError` on timeout and `Grafi.NIFError` on a NIF failure.
  See `Grafi.Algo.Isomorphism.isomorphic?/3`.
  """
  @spec isomorphic?(Graph.t(), Graph.t(), keyword()) :: boolean()
  defdelegate isomorphic?(g1, g2, opts \\ []), to: Isomorphism

  @doc """
  Returns `true` if `pattern` is sub-isomorphic to `g`. Always a boolean:
  raises `Grafi.TimeoutError` on timeout and `Grafi.NIFError` on a NIF
  failure. See `Grafi.Algo.Isomorphism.subgraph_isomorphic?/3`.
  """
  @spec subgraph_isomorphic?(Graph.t(), Graph.t(), keyword()) :: boolean()
  defdelegate subgraph_isomorphic?(g, pattern, opts \\ []), to: Isomorphism

  @spec isomorphism(Graph.t(), Graph.t(), keyword()) ::
          {:ok, Isomorphism.mapping()} | {:error, :no_isomorphism} | Isomorphism.error()
  defdelegate isomorphism(g1, g2, opts \\ []), to: Isomorphism

  @spec subgraph_isomorphism(Graph.t(), Graph.t(), keyword()) ::
          {:ok, Isomorphism.mapping()} | {:error, :no_isomorphism} | Isomorphism.error()
  defdelegate subgraph_isomorphism(g, pattern, opts \\ []), to: Isomorphism

  @spec count_subgraph_isomorphisms(Graph.t(), Graph.t(), keyword()) ::
          {:ok, non_neg_integer()} | Isomorphism.error()
  defdelegate count_subgraph_isomorphisms(g, pattern, opts \\ []), to: Isomorphism

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
  @spec to_dot(Graph.t(), keyword()) :: String.t()
  defdelegate to_dot(g, opts \\ []), to: Grafi.Serialize.DOT

  @doc "Export to JSON (uses the built-in `JSON` module)."
  @spec to_json(Graph.t()) :: String.t()
  defdelegate to_json(g), to: Grafi.Serialize.JSON

  @doc """
  Import from a JSON string: `{:ok, graph}` or `{:error, reason}`. Options
  are passed to `Grafi.Serialize.JSON.from_json/2` (e.g. `:max_bytes`).
  """
  @spec from_json(String.t(), keyword()) :: {:ok, Graph.t()} | {:error, term()}
  defdelegate from_json(json, opts \\ []), to: Grafi.Serialize.JSON

  @spec from_json!(String.t(), keyword()) :: Graph.t()
  defdelegate from_json!(json, opts \\ []), to: Grafi.Serialize.JSON
  @spec to_mermaid(Graph.t(), keyword()) :: String.t()
  defdelegate to_mermaid(g, opts \\ []), to: Grafi.Serialize.Mermaid
  @spec to_markdown(Graph.t(), keyword()) :: String.t()
  defdelegate to_markdown(g, opts \\ []), to: Grafi.Serialize.Mermaid
  @spec to_graphml(Graph.t(), keyword()) :: String.t()
  defdelegate to_graphml(g, opts \\ []), to: Grafi.Serialize.GraphML
  @spec from_graphml(String.t(), keyword()) :: {:ok, Graph.t()} | {:error, term()}
  defdelegate from_graphml(xml, opts \\ []), to: Grafi.Serialize.GraphML
  @spec from_graphml!(String.t(), keyword()) :: Graph.t()
  defdelegate from_graphml!(xml, opts \\ []), to: Grafi.Serialize.GraphML
  @spec to_gexf(Graph.t(), keyword()) :: String.t()
  defdelegate to_gexf(g, opts \\ []), to: Grafi.Serialize.GEXF
  @spec from_gexf(String.t(), keyword()) :: {:ok, Graph.t()} | {:error, term()}
  defdelegate from_gexf(xml, opts \\ []), to: Grafi.Serialize.GEXF
  @spec from_gexf!(String.t(), keyword()) :: Graph.t()
  defdelegate from_gexf!(xml, opts \\ []), to: Grafi.Serialize.GEXF
  @spec to_pajek(Graph.t(), keyword()) :: String.t()
  defdelegate to_pajek(g, opts \\ []), to: Grafi.Serialize.Pajek
  @spec from_pajek(String.t(), keyword()) :: {:ok, Graph.t()} | {:error, term()}
  defdelegate from_pajek(text, opts \\ []), to: Grafi.Serialize.Pajek
  @spec from_pajek!(String.t(), keyword()) :: Graph.t()
  defdelegate from_pajek!(text, opts \\ []), to: Grafi.Serialize.Pajek
  @spec to_edge_list(Graph.t(), keyword()) :: String.t()
  defdelegate to_edge_list(g, opts \\ []), to: Grafi.Serialize.EdgeList
  @spec from_edge_list(String.t(), keyword()) :: {:ok, Graph.t()} | {:error, term()}
  defdelegate from_edge_list(text, opts \\ []), to: Grafi.Serialize.EdgeList
  @spec from_edge_list!(String.t(), keyword()) :: Graph.t()
  defdelegate from_edge_list!(text, opts \\ []), to: Grafi.Serialize.EdgeList
  @spec to_adjacency_list(Graph.t(), keyword()) :: String.t()
  defdelegate to_adjacency_list(g, opts \\ []), to: Grafi.Serialize.AdjacencyList
  @spec from_adjacency_list(String.t(), keyword()) :: {:ok, Graph.t()} | {:error, term()}
  defdelegate from_adjacency_list(text, opts \\ []), to: Grafi.Serialize.AdjacencyList
  @spec from_adjacency_list!(String.t(), keyword()) :: Graph.t()
  defdelegate from_adjacency_list!(text, opts \\ []), to: Grafi.Serialize.AdjacencyList
  @spec to_matrix_market(Graph.t(), keyword()) :: String.t()
  defdelegate to_matrix_market(g, opts \\ []), to: Grafi.Serialize.MatrixMarket
  @spec from_matrix_market(String.t(), keyword()) :: {:ok, Graph.t()} | {:error, term()}
  defdelegate from_matrix_market(text, opts \\ []), to: Grafi.Serialize.MatrixMarket
  @spec from_matrix_market!(String.t(), keyword()) :: Graph.t()
  defdelegate from_matrix_market!(text, opts \\ []), to: Grafi.Serialize.MatrixMarket
end
