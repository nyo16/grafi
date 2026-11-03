defmodule Grafi.Algo.Metrics do
  @moduledoc """
  Cheap graph metrics: triangle counts, clustering coefficients,
  transitivity, density, and the distance-based metrics — eccentricity,
  radius, diameter, center and periphery.

  Triangle-based metrics treat the underlying graph as undirected: an
  edge `(u, v)` is considered present whenever `v` is in the union of
  the in- and out-neighbors of `u`. Density honours the graph's
  declared `:type`.

  Diameter, radius and eccentricity default to unweighted shortest-path
  distances (BFS). Pass `weighted: true` to dispatch to Dijkstra, which
  raises `ArgumentError` on a negative edge weight. For
  disconnected graphs, the diameter and radius default to `:infinity`
  (matching NetworkX). With `connected: :ignore` only finite pairs are
  considered.
  """

  alias Grafi.Algo.Distances
  alias Grafi.Algo.Neighborhood
  alias Grafi.Args
  alias Grafi.Graph

  # ── Triangle counts ──────────────────────────────────────────────────

  @doc """
  Total number of triangles in the graph, treating it as undirected.

  Each triangle (unordered triple) is counted exactly once. Runs in
  O(E^1.5) (see `triangles_per_vertex/1`).

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

  Uses the degree-ordered forward algorithm: vertices are ranked by
  (degree, id), each edge is oriented towards the higher rank, and every
  triangle is found once, from its lowest-ranked corner, by intersecting
  two forward neighbourhoods. Each forward neighbourhood has at most
  `√(2E)` vertices, so the whole pass is O(E^1.5).

  ## Examples

      iex> g = Grafi.new(type: :undirected)
      ...>     |> Grafi.add_edges([{:a, :b}, {:b, :c}, {:c, :a}])
      iex> Grafi.Algo.Metrics.triangles_per_vertex(g)
      %{a: 1, b: 1, c: 1}
  """
  @spec triangles_per_vertex(Graph.t()) :: %{any() => non_neg_integer()}
  def triangles_per_vertex(%Graph{} = g), do: g |> triangle_pass() |> elem(1)

  # One pass shared by the triangle-based metrics. Returns the undirected
  # neighbour sets (self-loops dropped) and the per-vertex triangle counts.
  defp triangle_pass(g) do
    nbrs = Neighborhood.sets(g, self_loops: :drop)

    rank =
      nbrs
      |> Enum.sort_by(fn {v, ns} -> {MapSet.size(ns), v} end)
      |> Enum.with_index(fn {v, _ns}, i -> {v, i} end)
      |> Map.new()

    forward =
      Map.new(nbrs, fn {v, ns} ->
        r = Map.fetch!(rank, v)
        {v, MapSet.filter(ns, &(Map.fetch!(rank, &1) > r))}
      end)

    counts =
      Enum.reduce(forward, Map.new(nbrs, fn {v, _} -> {v, 0} end), fn {v, fv}, acc ->
        Enum.reduce(fv, acc, fn u, acc ->
          common = MapSet.intersection(fv, Map.fetch!(forward, u))

          case MapSet.size(common) do
            0 ->
              acc

            n ->
              acc = acc |> Map.update!(v, &(&1 + n)) |> Map.update!(u, &(&1 + n))
              Enum.reduce(common, acc, fn w, acc -> Map.update!(acc, w, &(&1 + 1)) end)
          end
        end)
      end)

    {nbrs, counts}
  end

  # ── Clustering coefficient ───────────────────────────────────────────

  @doc """
  Local clustering coefficient for `vertex`: the fraction of pairs of
  the vertex's neighbors that are themselves connected. Returns `0.0`
  for vertices with fewer than two neighbors. Raises `ArgumentError` if
  `vertex` is not in the graph.

  ## Examples

      iex> g = Grafi.new(type: :undirected)
      ...>     |> Grafi.add_edges([{:a, :b}, {:b, :c}, {:c, :a}])
      iex> Grafi.Algo.Metrics.clustering_coefficient(g, :a)
      1.0
  """
  @spec clustering_coefficient(Graph.t(), any()) :: float()
  def clustering_coefficient(%Graph{} = g, vertex) do
    ensure_vertex!(g, vertex)
    nbrs = MapSet.new(Neighborhood.neighbors(g, vertex, self_loops: :drop))
    k = MapSet.size(nbrs)

    if k < 2 do
      0.0
    else
      # Each neighbour-neighbour edge is seen from both ends.
      links =
        Enum.reduce(nbrs, 0, fn u, acc ->
          acc +
            Enum.count(Neighborhood.neighbors(g, u, self_loops: :drop), &MapSet.member?(nbrs, &1))
        end)

      links / (k * (k - 1))
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
    {nbrs, tri} = triangle_pass(g)

    {sum, count} =
      Enum.reduce(nbrs, {0.0, 0}, fn {v, ns}, {sum, count} ->
        case MapSet.size(ns) do
          k when k >= 2 -> {sum + 2.0 * Map.fetch!(tri, v) / (k * (k - 1)), count + 1}
          _ -> {sum, count}
        end
      end)

    if count == 0, do: 0.0, else: sum / count
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
    {nbrs, tri} = triangle_pass(g)

    {triples, corners} =
      Enum.reduce(nbrs, {0, 0}, fn {v, ns}, {triples, corners} ->
        k = MapSet.size(ns)
        {triples + div(k * (k - 1), 2), corners + Map.fetch!(tri, v)}
      end)

    # `corners` counts each triangle once per corner, i.e. 3 × triangles.
    if triples == 0, do: 0.0, else: corners / triples
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

  Raises `ArgumentError` if `vertex` is not in the graph, an option is
  unknown or invalid, or `weighted: true` and an edge weight is negative.

  ## Options
    * `:weighted` — `true` to use Dijkstra (default `false`, BFS)
    * `:connected` — `:strict` to return `:infinity` when some other
      vertex is unreachable, or `:ignore` (default)

  ## Examples

      iex> g = Grafi.new(type: :undirected)
      ...>     |> Grafi.add_edges([{:a, :b}, {:b, :c}])
      iex> Grafi.Algo.Metrics.eccentricity(g, :b)
      1
  """
  @spec eccentricity(Graph.t(), any(), keyword()) :: number() | :infinity
  def eccentricity(%Graph{} = g, vertex, opts \\ []) do
    opts = Keyword.validate!(opts, weighted: false, connected: :ignore)
    {weighted?, strict?} = distance_opts!(g, opts)
    ensure_vertex!(g, vertex)
    vertex_eccentricity(g, vertex, weighted?, strict?)
  end

  defp vertex_eccentricity(g, vertex, weighted?, strict?) do
    dists = Distances.single_source(g, vertex, weighted: weighted?, source: :exclude)

    cond do
      # `dists` excludes the source itself, so a fully-connected graph
      # of size n yields map_size == n - 1.
      strict? and map_size(dists) < Graph.num_vertices(g) - 1 -> :infinity
      map_size(dists) == 0 -> 0
      true -> dists |> Map.values() |> Enum.max()
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
    opts = Keyword.validate!(opts, weighted: false, connected: :ignore)
    all_eccentricities(g, opts)
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
    opts = Keyword.validate!(opts, weighted: false, connected: :strict)
    g |> all_eccentricities(opts) |> aggregate_extrema(&Enum.max/1, :infinity)
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
    opts = Keyword.validate!(opts, weighted: false, connected: :strict)
    g |> all_eccentricities(opts) |> aggregate_extrema(&Enum.min/1, :infinity)
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
    opts = Keyword.validate!(opts, weighted: false, connected: :strict)
    ecc = all_eccentricities(g, opts)
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
    opts = Keyword.validate!(opts, weighted: false, connected: :strict)
    ecc = all_eccentricities(g, opts)
    d = aggregate_extrema(ecc, &Enum.max/1, :infinity)
    for {v, e} <- ecc, e == d, do: v
  end

  # ── Internal helpers ─────────────────────────────────────────────────

  defp all_eccentricities(g, opts) do
    {weighted?, strict?} = distance_opts!(g, opts)
    Map.new(Graph.vertices(g), &{&1, vertex_eccentricity(g, &1, weighted?, strict?)})
  end

  # Typed checks for the validated distance options. Weighted distances run
  # Dijkstra from every source, so the weights are checked here, once.
  defp distance_opts!(g, opts) do
    weighted? = Args.boolean!(opts, :weighted, false)

    case Keyword.fetch!(opts, :connected) do
      connected when connected in [:strict, :ignore] ->
        if weighted?, do: Args.non_negative_weights!(g)
        {weighted?, connected == :strict}

      other ->
        raise ArgumentError,
              "expected :connected to be :strict or :ignore, got: #{inspect(other)}"
    end
  end

  defp ensure_vertex!(g, v) do
    if not Graph.has_vertex?(g, v),
      do: raise(ArgumentError, "vertex #{inspect(v)} is not in the graph")
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
