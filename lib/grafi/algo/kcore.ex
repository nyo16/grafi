defmodule Grafi.Algo.KCore do
  @moduledoc """
  k-core decomposition via the Batagelj-Zaversnik peeling algorithm.

  The **k-core** of a graph is its maximal subgraph in which every vertex has
  degree at least `k`. The **core number** of a vertex is the largest `k`
  such that it belongs to the k-core; the **degeneracy** of the graph is the
  largest core number across all vertices.

  Runs in O(V + E) using bucket-sort by current degree.

  For directed graphs the underlying undirected graph is used, with degree
  defined as the number of distinct neighbors (in ∪ out).
  """

  alias Grafi.Algo.Neighborhood
  alias Grafi.Graph

  @doc """
  Returns a map `%{vertex => core_number}`.

  An isolated vertex has core number `0`. The empty graph returns `%{}`.

  ## Examples

      iex> Grafi.Graph.new(type: :undirected)
      ...> |> Grafi.Graph.add_edges([{:a, :b}, {:b, :c}, {:c, :a}])
      ...> |> Grafi.Algo.KCore.core_numbers()
      %{a: 2, b: 2, c: 2}
  """
  @spec core_numbers(Graph.t()) :: %{any() => non_neg_integer()}
  def core_numbers(%Graph{} = g) do
    vs = Graph.vertices(g)

    if vs == [] do
      %{}
    else
      neigh = Neighborhood.lists(g, self_loops: :drop)
      degree = Map.new(neigh, fn {v, ns} -> {v, length(ns)} end)
      buckets = Enum.group_by(vs, &Map.fetch!(degree, &1))
      max_d = degree |> Map.values() |> Enum.max()
      peel(0, max_d, buckets, degree, neigh, %{})
    end
  end

  @doc """
  Returns the induced subgraph of all vertices with core number `>= k`.

  The returned graph has the same `:type` as the input.

  ## Examples

      iex> g = Grafi.Graph.new(type: :undirected)
      ...>     |> Grafi.Graph.add_edges([{:a, :b}, {:b, :c}, {:c, :a}, {:c, :d}])
      iex> sub = Grafi.Algo.KCore.k_core(g, 2)
      iex> Enum.sort(Grafi.Graph.vertices(sub))
      [:a, :b, :c]
  """
  @spec k_core(Graph.t(), non_neg_integer()) :: Graph.t()
  def k_core(%Graph{} = g, k) when is_integer(k) and k >= 0 do
    cores = core_numbers(g)
    keep = for {v, c} <- cores, c >= k, do: v
    Graph.subgraph(g, keep)
  end

  @doc """
  Returns the **degeneracy** of the graph: the maximum core number.

  Returns `0` for an empty graph.

  ## Examples

      iex> g = Grafi.Graph.new(type: :undirected)
      ...>     |> Grafi.Graph.add_edges(for(i <- 1..4, j <- (i + 1)..5, do: {i, j}))
      iex> Grafi.Algo.KCore.degeneracy(g)
      4
  """
  @spec degeneracy(Graph.t()) :: non_neg_integer()
  def degeneracy(%Graph{} = g) do
    case core_numbers(g) do
      empty when empty == %{} -> 0
      cores -> cores |> Map.values() |> Enum.max()
    end
  end

  # ── Internals ─────────────────────────────────────────────────────────

  # Batagelj–Zaversnik peeling over `%{degree => [vertex]}` buckets, scanned
  # in increasing degree. Lazy deletion: decrementing a vertex's degree
  # pushes it onto the lower bucket without removing it from the old one,
  # so a popped entry is stale when the vertex is already peeled or its
  # degree has dropped since; stale entries are skipped. A neighbour whose
  # degree exceeds the current level `d` drops to at least `d`, so it never
  # lands below the scan. Each edge causes at most one push: O(V + E).
  defp peel(d, max_d, _buckets, _degree, _neigh, cores) when d > max_d, do: cores

  defp peel(d, max_d, buckets, degree, neigh, cores) do
    case Map.get(buckets, d, []) do
      [] ->
        peel(d + 1, max_d, Map.delete(buckets, d), degree, neigh, cores)

      [v | rest] ->
        buckets = Map.put(buckets, d, rest)

        # A vertex enters bucket k at most once (degrees only fall), so an
        # entry is current iff the vertex still has degree d; once peeled,
        # its degree stays at its core number and no bucket d entry remains.
        if Map.fetch!(degree, v) != d do
          peel(d, max_d, buckets, degree, neigh, cores)
        else
          {buckets, degree} =
            Enum.reduce(Map.fetch!(neigh, v), {buckets, degree}, &decrement(&1, &2, d))

          peel(d, max_d, buckets, degree, neigh, Map.put(cores, v, d))
        end
    end
  end

  # A peeled neighbour has degree == its core <= d, so `du > d` also skips it.
  defp decrement(u, {buckets, degree}, d) do
    case Map.fetch!(degree, u) do
      du when du > d ->
        {Map.update(buckets, du - 1, [u], &[u | &1]), Map.put(degree, u, du - 1)}

      _ ->
        {buckets, degree}
    end
  end
end
