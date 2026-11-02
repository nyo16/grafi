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
    score_pairs(g, candidates, fn _g, _u, _v, n_u, n_v ->
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
    score_pairs(g, candidates, fn g, _u, _v, n_u, n_v ->
      MapSet.intersection(n_u, n_v)
      |> Enum.reduce(0.0, fn z, acc ->
        d = undirected_degree(g, z)
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
    score_pairs(g, candidates, fn g, _u, _v, n_u, n_v ->
      MapSet.intersection(n_u, n_v)
      |> Enum.reduce(0.0, fn z, acc ->
        d = undirected_degree(g, z)
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
    score_pairs(g, candidates, fn g, u, v, _n_u, _n_v ->
      undirected_degree(g, u) * undirected_degree(g, v) * 1.0
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

  defp score_pairs(g, candidates, score_fun) do
    pairs = candidates || default_candidates(g)

    Map.new(pairs, fn {u, v} ->
      n_u = neighbor_set(g, u)
      n_v = neighbor_set(g, v)
      {{u, v}, score_fun.(g, u, v, n_u, n_v)}
    end)
  end

  defp default_candidates(%Graph{} = g) do
    vs = Graph.vertices(g) |> Enum.sort()

    for u <- vs,
        v <- vs,
        u < v,
        not adjacent?(g, u, v),
        do: {u, v}
  end

  defp adjacent?(g, u, v) do
    Graph.has_edge?(g, u, v) or Graph.has_edge?(g, v, u)
  end

  defp neighbor_set(g, v), do: MapSet.new(Neighborhood.neighbors(g, v, self_loops: :drop))

  defp undirected_degree(g, v), do: length(Neighborhood.neighbors(g, v, self_loops: :drop))
end
