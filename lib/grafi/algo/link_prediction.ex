defmodule Grafi.Algo.LinkPrediction do
  @moduledoc """
  Local-similarity link-prediction scores: Jaccard, Adamic-Adar,
  resource allocation, and preferential attachment.

  Each scorer takes a graph and an optional list of candidate vertex
  pairs `[{u, v}, ...]`. With `candidates = nil` (the default), all
  unordered pairs of distinct non-adjacent vertices are scored — this
  is `O(V²)`. Pass an explicit candidate list when the graph is large.

  All scorers operate on an *undirected view* of the graph: the
  neighborhood `N(v)` is taken via `Graph.neighbors/2`, which unions
  in- and out-neighbors. The returned map is keyed by `{u, v}` in the
  same order the pair was supplied; for default-generated candidates
  the canonical order matches `Enum.sort([u, v])`.

  Every scorer raises `ArgumentError` if a candidate pair names a vertex
  that is not in the graph.
  """

  alias Grafi.Algo.Neighborhood
  alias Grafi.Graph

  @type pair :: {any(), any()}
  @type scores :: %{pair() => float()}

  # ── Jaccard ───────────────────────────────────────────────────────────

  @doc """
  Jaccard coefficient: `|N(u) ∩ N(v)| / |N(u) ∪ N(v)|`. Returns `0.0`
  for pairs with no neighbors on either side. Scores live in `[0, 1]`.

  See the module doc for how default candidates are generated.
  """
  @spec jaccard(Graph.t(), [pair()] | nil) :: scores()
  def jaccard(%Graph{} = g, candidates \\ nil) do
    score_pairs(g, candidates, :endpoints, fn n_u, n_v, _sets ->
      union = MapSet.union(n_u, n_v) |> MapSet.size()

      if union == 0,
        do: 0.0,
        else: MapSet.intersection(n_u, n_v) |> MapSet.size() |> Kernel./(union)
    end)
  end

  # ── Adamic-Adar ───────────────────────────────────────────────────────

  @doc """
  Adamic-Adar index:
  `Σ_{z ∈ N(u) ∩ N(v)} 1 / log(degree(z))`.

  Common neighbors with degree `≤ 1` are skipped (the logarithm is
  zero or undefined there). Returns `0.0` when no common neighbor
  qualifies.
  """
  @spec adamic_adar(Graph.t(), [pair()] | nil) :: scores()
  def adamic_adar(%Graph{} = g, candidates \\ nil) do
    score_pairs(g, candidates, :with_neighbors, fn n_u, n_v, sets ->
      MapSet.intersection(n_u, n_v)
      |> Enum.reduce(0.0, fn z, acc ->
        d = degree(sets, z)
        if d > 1, do: acc + 1.0 / :math.log(d), else: acc
      end)
    end)
  end

  # ── Resource allocation ──────────────────────────────────────────────

  @doc """
  Resource-allocation index:
  `Σ_{z ∈ N(u) ∩ N(v)} 1 / degree(z)`.

  Common neighbors with degree `0` are skipped (shouldn't happen for
  genuine common neighbors, but defended for safety).
  """
  @spec resource_allocation(Graph.t(), [pair()] | nil) :: scores()
  def resource_allocation(%Graph{} = g, candidates \\ nil) do
    score_pairs(g, candidates, :with_neighbors, fn n_u, n_v, sets ->
      MapSet.intersection(n_u, n_v)
      |> Enum.reduce(0.0, fn z, acc ->
        d = degree(sets, z)
        if d > 0, do: acc + 1.0 / d, else: acc
      end)
    end)
  end

  # ── Preferential attachment ──────────────────────────────────────────

  @doc """
  Preferential-attachment score: `degree(u) × degree(v)` (using the
  undirected neighborhood-size as the degree).
  """
  @spec preferential_attachment(Graph.t(), [pair()] | nil) :: scores()
  def preferential_attachment(%Graph{} = g, candidates \\ nil) do
    score_pairs(g, candidates, :endpoints, fn n_u, n_v, _sets ->
      MapSet.size(n_u) * MapSet.size(n_v) * 1.0
    end)
  end

  # ── Top-k convenience ─────────────────────────────────────────────────

  @doc """
  Returns the top-`k` highest-scoring pairs from a `%{{u, v} => score}`
  map, sorted descending by score. Ties broken by the natural ordering
  of the pair tuples.
  """
  @spec top_k(scores(), non_neg_integer()) :: [{pair(), float()}]
  def top_k(scores, k) when is_map(scores) and is_integer(k) and k >= 0 do
    scores
    |> Enum.sort_by(fn {pair, score} -> {-score, pair} end)
    |> Enum.take(k)
  end

  # ── Internals ─────────────────────────────────────────────────────────

  # Neighbour sets (self-loops dropped) are built once per call, so each
  # pair costs one set operation instead of two neighbourhood rebuilds plus
  # one per common neighbour. Without candidates every vertex is scored, so
  # every set is built; with candidates only the endpoints' sets are, plus
  # their neighbours' when the score needs common-neighbour degrees
  # (`:with_neighbors`).
  defp score_pairs(g, nil, _scope, score_fun) do
    sets = Neighborhood.sets(g, self_loops: :drop)
    score_with(sets, default_candidates(sets), score_fun)
  end

  defp score_pairs(g, candidates, scope, score_fun) do
    endpoints = Enum.flat_map(candidates, fn {u, v} -> [u, v] end)

    case Enum.reject(endpoints, &Graph.has_vertex?(g, &1)) do
      [] -> :ok
      [v | _] -> raise ArgumentError, "vertex #{inspect(v)} is not in the graph"
    end

    sets = add_sets(%{}, g, endpoints)

    sets =
      case scope do
        :endpoints -> sets
        :with_neighbors -> add_sets(sets, g, Enum.flat_map(sets, fn {_v, ns} -> ns end))
      end

    score_with(sets, candidates, score_fun)
  end

  defp score_with(sets, pairs, score_fun) do
    Map.new(pairs, fn {u, v} ->
      {{u, v}, score_fun.(neighbors(sets, u), neighbors(sets, v), sets)}
    end)
  end

  defp add_sets(sets, g, vertices) do
    Enum.reduce(vertices, sets, fn v, acc ->
      if Map.has_key?(acc, v),
        do: acc,
        else: Map.put(acc, v, MapSet.new(Neighborhood.neighbors(g, v, self_loops: :drop)))
    end)
  end

  # Unordered pairs by position in the sorted vertex list, not by `<`,
  # which would drop a pair of distinct but equal-comparing ids (`1`, `1.0`).
  defp default_candidates(sets) do
    indexed = sets |> Map.keys() |> Enum.sort() |> Enum.with_index()

    for {u, i} <- indexed,
        n_u = Map.fetch!(sets, u),
        {v, j} <- indexed,
        i < j,
        not MapSet.member?(n_u, v),
        do: {u, v}
  end

  defp neighbors(sets, v), do: Map.get(sets, v, MapSet.new())

  defp degree(sets, v), do: sets |> neighbors(v) |> MapSet.size()
end
