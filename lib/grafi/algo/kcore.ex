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
      neigh = Neighborhood.sets(g, self_loops: :drop)
      degree = Map.new(neigh, fn {v, ns} -> {v, MapSet.size(ns)} end)
      peel(neigh, degree)
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

  # Batagelj-Zaversnik peeling with bucket-by-degree.
  defp peel(neigh, degree) do
    max_d = degree |> Map.values() |> Enum.max(fn -> 0 end)

    # Bucket: index 0..max_d, each a MapSet of vertices at that current degree.
    buckets =
      Enum.reduce(degree, init_buckets(max_d + 1), fn {v, d}, b ->
        update_in_array(b, d, &MapSet.put(&1, v))
      end)

    do_peel(buckets, degree, neigh, %{}, 0)
  end

  defp do_peel(buckets, degree, neigh, cores, cursor) do
    case lowest_nonempty(buckets, cursor) do
      :done ->
        cores

      d ->
        bucket = elem(buckets, d)
        v = Enum.at(bucket, 0)
        buckets = update_in_array(buckets, d, &MapSet.delete(&1, v))
        cores = Map.put(cores, v, d)

        # Remove v from all its neighbors; decrement their degree.
        {buckets, degree} =
          Enum.reduce(Map.fetch!(neigh, v), {buckets, degree}, fn u, {b, deg} ->
            if not Map.has_key?(deg, u) do
              {b, deg}
            else
              du = Map.fetch!(deg, u)

              if du > d do
                b =
                  b
                  |> update_in_array(du, &MapSet.delete(&1, u))
                  |> update_in_array(du - 1, &MapSet.put(&1, u))

                {b, Map.put(deg, u, du - 1)}
              else
                # Already in a bucket <= d; it will be peeled at its own d.
                {b, deg}
              end
            end
          end)

        degree = Map.delete(degree, v)
        # Strip v from its neighbors' sets so we don't revisit it.
        neigh =
          Enum.reduce(Map.fetch!(neigh, v), neigh, fn u, acc ->
            case Map.fetch(acc, u) do
              {:ok, ns} -> Map.put(acc, u, MapSet.delete(ns, v))
              :error -> acc
            end
          end)
          |> Map.delete(v)

        # The next lowest non-empty bucket may be <= d (newly decremented
        # vertices), so start the next scan at d - 1 (clamped to 0). Otherwise
        # the algorithm would skip them and produce wrong core numbers.
        next_cursor = max(d - 1, 0)
        do_peel(buckets, degree, neigh, cores, next_cursor)
    end
  end

  defp init_buckets(n), do: Tuple.duplicate(MapSet.new(), n)

  defp update_in_array(t, i, fun), do: put_elem(t, i, fun.(elem(t, i)))

  defp lowest_nonempty(buckets, start) do
    size = tuple_size(buckets)
    scan_buckets(buckets, start, size)
  end

  defp scan_buckets(_b, i, size) when i >= size, do: :done

  defp scan_buckets(b, i, size) do
    if MapSet.size(elem(b, i)) > 0, do: i, else: scan_buckets(b, i + 1, size)
  end
end
