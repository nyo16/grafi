defmodule Grafi.Algo.Metrics do
  @dialyzer :no_opaque

  @moduledoc """
  Cheap graph metrics: triangle counts, clustering coefficients,
  transitivity, density, and the distance-based metrics — eccentricity,
  radius, diameter, center and periphery.

  Triangle-based metrics treat the underlying graph as undirected: an
  edge `(u, v)` is considered present whenever `v` is in the union of
  the in- and out-neighbors of `u`. Density honours the graph's
  declared `:type`.

  Diameter, radius and eccentricity default to unweighted shortest-path
  distances (BFS). Pass `weighted: true` to dispatch to Dijkstra. For
  disconnected graphs, the diameter and radius default to `:infinity`
  (matching NetworkX). With `connected: :ignore` only finite pairs are
  considered.
  """

  alias Grafi.Algo.Distances
  alias Grafi.Algo.Neighborhood
  alias Grafi.Graph

  # ── Triangle counts ──────────────────────────────────────────────────

  @doc """
  Total number of triangles in the graph, treating it as undirected.

  Each triangle (unordered triple) is counted exactly once. Naive
  O(V · deg^2) implementation; intended for the small-graph case.

  ## Examples

      iex> g = Grafi.new(type: :undirected)
      ...>     |> Grafi.add_edges([{:a, :b}, {:b, :c}, {:c, :a}])
      iex> Grafi.Algo.Metrics.triangle_count(g)
      1
  """
  @spec triangle_count(Graph.t()) :: non_neg_integer()
  def triangle_count(%Graph{} = g) do
    triangles_per_vertex(g)
    |> Map.values()
    |> Enum.sum()
    |> div(3)
  end

  @doc """
  Returns a map `vertex => number_of_triangles_through_vertex` for the
  whole graph.

  ## Examples

      iex> g = Grafi.new(type: :undirected)
      ...>     |> Grafi.add_edges([{:a, :b}, {:b, :c}, {:c, :a}])
      iex> Grafi.Algo.Metrics.triangles_per_vertex(g)
      %{a: 1, b: 1, c: 1}
  """
  @spec triangles_per_vertex(Graph.t()) :: %{any() => non_neg_integer()}
  def triangles_per_vertex(%Graph{} = g) do
    Graph.vertices(g)
    |> Map.new(fn v -> {v, count_triangles_through(g, v)} end)
  end

  defp count_triangles_through(g, v) do
    nbrs = undirected_neighbors(g, v)
    nbr_set = MapSet.new(nbrs)

    pairs =
      Enum.reduce(nbrs, 0, fn u, acc ->
        u_nbrs = undirected_neighbors(g, u)

        common =
          Enum.count(u_nbrs, fn w ->
            w != v and w != u and MapSet.member?(nbr_set, w)
          end)

        acc + common
      end)

    div(pairs, 2)
  end

  defp undirected_neighbors(%Graph{} = g, v), do: Neighborhood.neighbors(g, v, self_loops: :drop)

  # ── Clustering coefficient ───────────────────────────────────────────

  @doc """
  Local clustering coefficient for `vertex`: the fraction of pairs of
  the vertex's neighbors that are themselves connected. Returns `0.0`
  for vertices with fewer than two neighbors.

  ## Examples

      iex> g = Grafi.new(type: :undirected)
      ...>     |> Grafi.add_edges([{:a, :b}, {:b, :c}, {:c, :a}])
      iex> Grafi.Algo.Metrics.clustering_coefficient(g, :a)
      1.0
  """
  @spec clustering_coefficient(Graph.t(), any()) :: float()
  def clustering_coefficient(%Graph{} = g, vertex) do
    nbrs = undirected_neighbors(g, vertex)
    k = length(nbrs)

    if k < 2 do
      0.0
    else
      t = count_triangles_through(g, vertex)
      2.0 * t / (k * (k - 1))
    end
  end

  @doc """
  Average local clustering coefficient over all non-isolated vertices
  (vertices with at least two neighbors). Returns `0.0` if no such
  vertex exists.

  ## Examples

      iex> g = Grafi.new(type: :undirected)
      ...>     |> Grafi.add_edges([{:a, :b}, {:b, :c}, {:c, :a}])
      iex> Grafi.Algo.Metrics.clustering_coefficient(g)
      1.0
  """
  @spec clustering_coefficient(Graph.t()) :: float()
  def clustering_coefficient(%Graph{} = g) do
    contributing =
      Graph.vertices(g)
      |> Enum.filter(&(length(undirected_neighbors(g, &1)) >= 2))

    case contributing do
      [] ->
        0.0

      vs ->
        sum = Enum.reduce(vs, 0.0, &(&2 + clustering_coefficient(g, &1)))
        sum / length(vs)
    end
  end

  # ── Transitivity ─────────────────────────────────────────────────────

  @doc """
  Global transitivity: `3 × triangles / connected_triples`, where a
  connected triple is an ordered pair of edges sharing a common vertex.
  Returns `0.0` when no connected triple exists.

  ## Examples

      iex> g = Grafi.new(type: :undirected)
      ...>     |> Grafi.add_edges([{:a, :b}, {:b, :c}, {:c, :a}])
      iex> Grafi.Algo.Metrics.transitivity(g)
      1.0
  """
  @spec transitivity(Graph.t()) :: float()
  def transitivity(%Graph{} = g) do
    triples =
      Graph.vertices(g)
      |> Enum.reduce(0, fn v, acc ->
        k = length(undirected_neighbors(g, v))
        acc + div(k * (k - 1), 2)
      end)

    if triples == 0, do: 0.0, else: 3.0 * triangle_count(g) / triples
  end

  # ── Density ──────────────────────────────────────────────────────────

  @doc """
  Edge density. For directed graphs `E / (V · (V - 1))`; for undirected
  graphs `2E / (V · (V - 1))`. Returns `0.0` if `V < 2`.

  ## Examples

      iex> g = Grafi.new(type: :undirected)
      ...>     |> Grafi.add_edges([{:a, :b}, {:b, :c}, {:c, :a}])
      iex> Grafi.Algo.Metrics.density(g)
      1.0
  """
  @spec density(Graph.t()) :: float()
  def density(%Graph{} = g) do
    n = Graph.num_vertices(g)

    if n < 2 do
      0.0
    else
      e = Graph.num_edges(g)
      max = n * (n - 1)
      if g.type == :undirected, do: 2.0 * e / max, else: e * 1.0 / max
    end
  end

  # ── Eccentricity, radius, diameter ──────────────────────────────────

  @doc """
  Eccentricity of `vertex`: the maximum shortest-path distance from
  `vertex` to any reachable vertex. Returns `:infinity` if the graph
  has unreachable vertices and `connected: :strict` is set; otherwise
  the maximum over finite distances. Returns `0` for an isolated
  vertex.

  ## Options
    * `:weighted` — `true` to use Dijkstra (default `false`, BFS)
    * `:connected` — `:strict` to return `:infinity` when some other
      vertex is unreachable (default `:ignore`)

  ## Examples

      iex> g = Grafi.new(type: :undirected)
      ...>     |> Grafi.add_edges([{:a, :b}, {:b, :c}])
      iex> Grafi.Algo.Metrics.eccentricity(g, :b)
      1
  """
  @spec eccentricity(Graph.t(), any(), keyword()) :: number() | :infinity
  def eccentricity(%Graph{} = g, vertex, opts \\ []) do
    if not Graph.has_vertex?(g, vertex) do
      0
    else
      dists = single_source_distances(g, vertex, opts)
      n = Graph.num_vertices(g)
      strict? = Keyword.get(opts, :connected) == :strict

      cond do
        # `dists` excludes the source itself, so a fully-connected graph
        # of size n yields map_size == n - 1.
        strict? and map_size(dists) < n - 1 ->
          :infinity

        map_size(dists) == 0 ->
          0

        true ->
          dists |> Map.values() |> Enum.max()
      end
    end
  end

  @doc """
  Returns `%{vertex => eccentricity}` for every vertex of the graph.

  ## Options — same as `eccentricity/3`.

  ## Examples

      iex> g = Grafi.new(type: :undirected)
      ...>     |> Grafi.add_edges([{:a, :b}, {:b, :c}])
      iex> ecc = Grafi.Algo.Metrics.eccentricities(g)
      iex> {ecc[:a], ecc[:b], ecc[:c]}
      {2, 1, 2}
  """
  @spec eccentricities(Graph.t(), keyword()) :: %{any() => number() | :infinity}
  def eccentricities(%Graph{} = g, opts \\ []) do
    Graph.vertices(g)
    |> Map.new(&{&1, eccentricity(g, &1, opts)})
  end

  @doc """
  Diameter of the graph — maximum eccentricity over all vertices.
  Returns `:infinity` for disconnected graphs by default (matching
  NetworkX). Pass `connected: :ignore` to take the max over the
  finite values only.

  ## Options — same as `eccentricity/3`. Default `:connected` is
  `:strict`.

  ## Examples

      iex> g = Grafi.new(type: :undirected)
      ...>     |> Grafi.add_edges([{:a, :b}, {:b, :c}])
      iex> Grafi.Algo.Metrics.diameter(g)
      2
  """
  @spec diameter(Graph.t(), keyword()) :: number() | :infinity
  def diameter(%Graph{} = g, opts \\ []) do
    opts = Keyword.put_new(opts, :connected, :strict)
    ecc = eccentricities(g, opts)
    aggregate_extrema(ecc, &Enum.max/1, :infinity)
  end

  @doc """
  Radius of the graph — minimum eccentricity over all vertices.
  Returns `:infinity` for disconnected graphs by default.

  ## Options — same as `diameter/2`.

  ## Examples

      iex> g = Grafi.new(type: :undirected)
      ...>     |> Grafi.add_edges([{:a, :b}, {:b, :c}])
      iex> Grafi.Algo.Metrics.radius(g)
      1
  """
  @spec radius(Graph.t(), keyword()) :: number() | :infinity
  def radius(%Graph{} = g, opts \\ []) do
    opts = Keyword.put_new(opts, :connected, :strict)
    ecc = eccentricities(g, opts)
    aggregate_extrema(ecc, &Enum.min/1, :infinity)
  end

  @doc """
  Center of the graph — the list of vertices whose eccentricity equals
  the graph radius.

  ## Options — same as `radius/2`.

  ## Examples

      iex> g = Grafi.new(type: :undirected)
      ...>     |> Grafi.add_edges([{:a, :b}, {:b, :c}])
      iex> Grafi.Algo.Metrics.center(g)
      [:b]
  """
  @spec center(Graph.t(), keyword()) :: [any()]
  def center(%Graph{} = g, opts \\ []) do
    opts = Keyword.put_new(opts, :connected, :strict)
    ecc = eccentricities(g, opts)
    r = aggregate_extrema(ecc, &Enum.min/1, :infinity)
    for {v, e} <- ecc, e == r, do: v
  end

  @doc """
  Periphery — the list of vertices whose eccentricity equals the
  diameter.

  ## Options — same as `diameter/2`.

  ## Examples

      iex> g = Grafi.new(type: :undirected)
      ...>     |> Grafi.add_edges([{:a, :b}, {:b, :c}])
      iex> Enum.sort(Grafi.Algo.Metrics.periphery(g))
      [:a, :c]
  """
  @spec periphery(Graph.t(), keyword()) :: [any()]
  def periphery(%Graph{} = g, opts \\ []) do
    opts = Keyword.put_new(opts, :connected, :strict)
    ecc = eccentricities(g, opts)
    d = aggregate_extrema(ecc, &Enum.max/1, :infinity)
    for {v, e} <- ecc, e == d, do: v
  end

  # ── Internal helpers ─────────────────────────────────────────────────

  defp single_source_distances(g, v, opts) do
    Distances.single_source(g, v,
      weighted: Keyword.get(opts, :weighted, false),
      source: :exclude
    )
  end

  defp aggregate_extrema(ecc, fun, default) do
    case Map.values(ecc) do
      [] ->
        default

      vals ->
        if Enum.any?(vals, &(&1 == :infinity)),
          do: :infinity,
          else: fun.(vals)
    end
  end
end
