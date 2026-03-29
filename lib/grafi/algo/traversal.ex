defmodule Grafi.Algo.Traversal do
  @moduledoc "BFS, DFS, and reachability — all lazy via `Stream`."

  alias Grafi.Graph

  @spec bfs(Graph.t(), any()) :: Enumerable.t()
  def bfs(%Graph{} = g, start) do
    Stream.resource(
      fn -> {[start], MapSet.new([start])} end,
      fn
        {[], _} -> {:halt, nil}
        {[v | rest], vis} ->
          new = Graph.out_neighbors(g, v) |> Enum.reject(&MapSet.member?(vis, &1))
          {[v], {rest ++ new, Enum.reduce(new, vis, &MapSet.put(&2, &1))}}
      end,
      fn _ -> :ok end
    )
  end

  @spec dfs(Graph.t(), any()) :: Enumerable.t()
  def dfs(%Graph{} = g, start) do
    Stream.resource(
      fn -> {[start], MapSet.new()} end,
      fn
        {[], _} -> {:halt, nil}
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

  @spec dfs_post(Graph.t(), any()) :: [any()]
  def dfs_post(%Graph{} = g, start) do
    {r, _} = do_post(g, start, MapSet.new(), [])
    r
  end

  @spec reachable?(Graph.t(), any(), any()) :: boolean()
  def reachable?(%Graph{} = g, source, target),
    do: bfs(g, source) |> Enum.any?(&(&1 == target))

  @spec reachable_from(Graph.t(), any()) :: MapSet.t()
  def reachable_from(%Graph{} = g, source),
    do: bfs(g, source) |> Enum.into(MapSet.new())

  defp do_post(g, v, vis, acc) do
    if MapSet.member?(vis, v), do: {acc, vis}, else:
      (vis = MapSet.put(vis, v)
       {acc, vis} = Enum.reduce(Graph.out_neighbors(g, v), {acc, vis}, fn n, {a, v2} -> do_post(g, n, v2, a) end)
       {[v | acc], vis})
  end
end
