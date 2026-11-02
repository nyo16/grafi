defmodule Grafi.Algo.Traversal do
  @dialyzer :no_opaque
  @moduledoc """
  BFS, DFS, reachability and topological sorting.

  `bfs/2`, `dfs/2` and `weak_bfs/2` are lazy (`Stream`). Every function that
  takes a start, source or target vertex raises `ArgumentError` if that
  vertex is not in the graph.
  """

  alias Grafi.Graph

  @doc """
  Returns a lazy `Stream` of vertices in breadth-first order starting from
  `start`. The start vertex is emitted first; unreachable vertices are
  never emitted.

  Raises `ArgumentError` if `start` is not in the graph.
  """
  @spec bfs(Graph.t(), any()) :: Enumerable.t()
  def bfs(%Graph{} = g, start) do
    vertex!(g, start)
    bfs_stream(start, &Graph.out_neighbors(g, &1))
  end

  @doc """
  Like `bfs/2`, but follows edges in both directions (out ∪ in), so it
  enumerates the weakly connected component of `start` in a directed
  graph. On an undirected graph it is the same as `bfs/2`.

  Raises `ArgumentError` if `start` is not in the graph.
  """
  @spec weak_bfs(Graph.t(), any()) :: Enumerable.t()
  def weak_bfs(%Graph{type: :undirected} = g, start), do: bfs(g, start)

  def weak_bfs(%Graph{} = g, start) do
    vertex!(g, start)
    bfs_stream(start, &(Graph.out_neighbors(g, &1) ++ Graph.in_neighbors(g, &1)))
  end

  defp bfs_stream(start, next) do
    Stream.resource(
      fn -> {:queue.from_list([start]), MapSet.new([start])} end,
      fn
        {q, vis} ->
          case :queue.out(q) do
            {:empty, _} ->
              {:halt, nil}

            {{:value, v}, q2} ->
              {q3, vis} =
                Enum.reduce(next.(v), {q2, vis}, fn n, {q, vis} ->
                  if MapSet.member?(vis, n),
                    do: {q, vis},
                    else: {:queue.in(n, q), MapSet.put(vis, n)}
                end)

              {[v], {q3, vis}}
          end
      end,
      fn _ -> :ok end
    )
  end

  @doc """
  Returns a lazy `Stream` of vertices in depth-first pre-order from `start`.
  Each vertex is emitted at most once.

  Raises `ArgumentError` if `start` is not in the graph.
  """
  @spec dfs(Graph.t(), any()) :: Enumerable.t()
  def dfs(%Graph{} = g, start) do
    vertex!(g, start)

    Stream.resource(
      fn -> {[start], MapSet.new()} end,
      fn
        {[], _} ->
          {:halt, nil}

        {[v | rest], vis} ->
          if MapSet.member?(vis, v) do
            {[], {rest, vis}}
          else
            vis = MapSet.put(vis, v)
            {[v], {Graph.out_neighbors(g, v) ++ rest, vis}}
          end
      end,
      fn _ -> :ok end
    )
  end

  @doc """
  Returns the vertices reachable from `start` in DFS **reverse post-order**:
  a vertex always precedes its descendants, so for a DAG the result is a
  topological ordering of the vertices reachable from `start`.

  For example, `a -> b -> c -> d` yields `[:a, :b, :c, :d]`.

  Raises `ArgumentError` if `start` is not in the graph.
  """
  @spec dfs_post(Graph.t(), any()) :: [any()]
  def dfs_post(%Graph{} = g, start) do
    vertex!(g, start)
    {r, _} = do_post(g, start, MapSet.new(), [])
    r
  end

  @doc """
  Returns `true` if there is a directed path from `source` to `target`,
  `false` otherwise. Implemented as a lazy BFS that halts on the first hit.

  Raises `ArgumentError` if `source` or `target` is not in the graph.
  """
  @spec reachable?(Graph.t(), any(), any()) :: boolean()
  def reachable?(%Graph{} = g, source, target) do
    vertex!(g, target)
    g |> bfs(source) |> Enum.any?(&(&1 == target))
  end

  @doc """
  Returns the `MapSet` of every vertex reachable from `source` (including
  `source` itself).

  Raises `ArgumentError` if `source` is not in the graph.
  """
  @spec reachable_from(Graph.t(), any()) :: MapSet.t()
  def reachable_from(%Graph{} = g, source),
    do: bfs(g, source) |> Enum.into(MapSet.new())

  @doc """
  Topological order of all vertices via Kahn's algorithm.

  The order is deterministic: sources start in vertex term order, and each
  vertex releases its successors in term order (first in, first out). This
  is exactly igraph's `igraph_topological_sorting` order on the CSR built by
  `Grafi.Graph.to_csr/1`.

  Returns `{:error, :has_cycle}` if the graph has a cycle. An undirected
  graph with at least one edge counts as cyclic here.

  ## Examples

      iex> Grafi.new()
      ...> |> Grafi.add_edges([{:c, :d}, {:a, :d}, {:b, :c}])
      ...> |> Grafi.Algo.Traversal.topological_sort()
      {:ok, [:a, :b, :c, :d]}
  """
  @spec topological_sort(Graph.t()) :: {:ok, [any()]} | {:error, :has_cycle}
  def topological_sort(%Graph{} = g) do
    vs = g |> Graph.vertices() |> Enum.sort()
    in_deg = Map.new(vs, &{&1, Graph.in_degree(g, &1)})
    sources = Enum.filter(vs, &(in_deg[&1] == 0))
    do_kahn(g, :queue.from_list(sources), in_deg, [], length(vs))
  end

  # Degrees count distinct neighbours, matching one decrement per distinct
  # successor.
  defp do_kahn(g, q, in_deg, acc, remaining) do
    case :queue.out(q) do
      {:empty, _} when remaining == 0 ->
        {:ok, Enum.reverse(acc)}

      {:empty, _} ->
        {:error, :has_cycle}

      {{:value, v}, q} ->
        {q, in_deg} =
          g
          |> Graph.out_neighbors(v)
          |> Enum.sort()
          |> Enum.reduce({q, in_deg}, fn n, {q, d} ->
            d = Map.update!(d, n, &(&1 - 1))
            if d[n] == 0, do: {:queue.in(n, q), d}, else: {q, d}
          end)

        do_kahn(g, q, in_deg, [v | acc], remaining - 1)
    end
  end

  defp do_post(g, v, vis, acc) do
    if MapSet.member?(vis, v) do
      {acc, vis}
    else
      vis = MapSet.put(vis, v)

      {acc, vis} =
        Enum.reduce(Graph.out_neighbors(g, v), {acc, vis}, fn n, {a, v2} ->
          do_post(g, n, v2, a)
        end)

      {[v | acc], vis}
    end
  end

  defp vertex!(g, v) do
    if not Graph.has_vertex?(g, v),
      do: raise(ArgumentError, "vertex #{inspect(v)} is not in the graph")
  end
end
