defmodule Grafi.Algo.Bipartite do
  @moduledoc """
  Bipartiteness testing, 2-coloring, side extraction, and one-mode projection.

  A graph is **bipartite** iff its vertices can be partitioned into two sets
  such that every edge connects a vertex in one set to a vertex in the other —
  equivalently, the graph contains no odd-length cycle.

  All algorithms here operate on the **underlying undirected graph**: edge
  direction is ignored, so a directed cycle `a -> b -> c -> a` is treated as
  the undirected triangle and reported as not bipartite.
  """

  alias Grafi.Algo.Neighborhood
  alias Grafi.Graph

  # ── Bipartiteness ─────────────────────────────────────────────────────

  @doc """
  Returns `true` if the graph is bipartite, `false` otherwise.

  Uses BFS-based 2-coloring across every connected component. An empty graph
  is trivially bipartite.

  ## Examples

      iex> Grafi.Graph.new()
      ...> |> Grafi.Graph.add_edges([{:a, :b}, {:b, :c}, {:c, :d}, {:d, :a}])
      ...> |> Grafi.Algo.Bipartite.bipartite?()
      true

      iex> Grafi.Graph.new()
      ...> |> Grafi.Graph.add_edges([{:a, :b}, {:b, :c}, {:c, :a}])
      ...> |> Grafi.Algo.Bipartite.bipartite?()
      false
  """
  @spec bipartite?(Graph.t()) :: boolean()
  def bipartite?(%Graph{} = g) do
    case coloring(g) do
      {:ok, _} -> true
      _ -> false
    end
  end

  @doc """
  Attempts to 2-color the graph.

  Returns `{:ok, colors}` where `colors` is a map `%{vertex => 0 | 1}`, or
  `{:error, :not_bipartite, {u, v}}` where `{u, v}` is one edge whose
  endpoints would receive the same color (a witness of an odd cycle).

  For directed graphs the algorithm uses the underlying undirected adjacency.
  """
  @spec coloring(Graph.t()) ::
          {:ok, %{any() => 0 | 1}} | {:error, :not_bipartite, {any(), any()}}
  def coloring(%Graph{} = g) do
    vs = Graph.vertices(g)

    Enum.reduce_while(vs, {:ok, %{}}, fn v, {:ok, colors} ->
      if Map.has_key?(colors, v) do
        {:cont, {:ok, colors}}
      else
        case bfs_color(g, v, Map.put(colors, v, 0)) do
          {:ok, c2} -> {:cont, {:ok, c2}}
          {:error, edge} -> {:halt, {:error, :not_bipartite, edge}}
        end
      end
    end)
  end

  @doc """
  Returns the two sides of a bipartite graph.

  Returns `{:ok, {set_a, set_b}}` with `set_a` containing the color-0 vertices
  and `set_b` the color-1 vertices, or `{:error, :not_bipartite}`.
  """
  @spec sets(Graph.t()) :: {:ok, {MapSet.t(), MapSet.t()}} | {:error, :not_bipartite}
  def sets(%Graph{} = g) do
    case coloring(g) do
      {:ok, colors} ->
        {a, b} =
          Enum.reduce(colors, {MapSet.new(), MapSet.new()}, fn
            {v, 0}, {a, b} -> {MapSet.put(a, v), b}
            {v, 1}, {a, b} -> {a, MapSet.put(b, v)}
          end)

        {:ok, {a, b}}

      {:error, :not_bipartite, _} ->
        {:error, :not_bipartite}
    end
  end

  # ── Projection ────────────────────────────────────────────────────────

  @doc """
  One-mode projection of a bipartite graph onto `side_vertices`.

  Given a bipartite graph and the set of vertices on one side, returns a new
  **undirected** graph on those vertices where `u` and `v` are connected iff
  they share at least one neighbor on the other side. The edge weight equals
  the number of shared neighbors.

  Vertices in `side_vertices` that are not in the graph are silently skipped.

  > #### Note {: .info}
  >
  > For efficiency, this function does **not** verify that the input is
  > bipartite or that `side_vertices` is exactly one side. If you pass a
  > non-bipartite graph the projection is well-defined (shared-neighbor
  > graph) but its semantic meaning may not be what you expect.

  ## Examples

      iex> g = Grafi.Graph.new(type: :undirected)
      ...>     |> Grafi.Graph.add_edges([{:u1, :m1}, {:u1, :m2},
      ...>                               {:u2, :m1}, {:u2, :m2}])
      iex> p = Grafi.Algo.Bipartite.project(g, [:u1, :u2])
      iex> Grafi.Graph.has_edge?(p, :u1, :u2)
      true
  """
  @spec project(Graph.t(), [any()] | MapSet.t()) :: Graph.t()
  def project(%Graph{} = g, side_vertices) do
    side =
      if is_struct(side_vertices, MapSet),
        do: side_vertices,
        else: MapSet.new(side_vertices)

    keep = Enum.filter(side, &Graph.has_vertex?(g, &1))

    # Compute shared-neighbor counts: for each "other-side" vertex w, every
    # pair (u, v) of its neighbors that lie in `side` shares one w.
    counts =
      Enum.reduce(Graph.vertices(g), %{}, fn w, acc ->
        if MapSet.member?(side, w) do
          acc
        else
          neigh =
            Graph.neighbors(g, w)
            |> Enum.filter(&MapSet.member?(side, &1))
            |> Enum.sort()

          add_pair_counts(neigh, acc)
        end
      end)

    base = Graph.new(type: :undirected) |> Graph.add_vertices(keep)

    Enum.reduce(counts, base, fn {{u, v}, c}, acc ->
      Graph.add_edge(acc, u, v, weight: c * 1.0)
    end)
  end

  # ── Internals ─────────────────────────────────────────────────────────

  defp bfs_color(g, start, colors) do
    do_bfs(:queue.from_list([start]), colors, g)
  end

  defp do_bfs(q, colors, g) do
    case :queue.out(q) do
      {:empty, _} ->
        {:ok, colors}

      {{:value, v}, rest} ->
        cv = Map.fetch!(colors, v)
        next = 1 - cv

        case Enum.reduce_while(undirected_neighbors(g, v), {colors, rest}, fn n, {c, q2} ->
               cond do
                 not Map.has_key?(c, n) ->
                   {:cont, {Map.put(c, n, next), :queue.in(n, q2)}}

                 Map.fetch!(c, n) == cv ->
                   {:halt, {:error, {v, n}}}

                 true ->
                   {:cont, {c, q2}}
               end
             end) do
          {:error, edge} -> {:error, edge}
          {c2, q2} -> do_bfs(q2, c2, g)
        end
    end
  end

  # A self-loop makes `v` its own neighbour, so it is reported as an odd cycle.
  defp undirected_neighbors(g, v), do: Neighborhood.neighbors(g, v, self_loops: :keep)

  # Given a sorted list of "side" neighbors of one other-side vertex w,
  # add 1 to the count for every unordered pair {u, v} drawn from the list.
  defp add_pair_counts([], acc), do: acc
  defp add_pair_counts([_], acc), do: acc

  defp add_pair_counts([u | rest], acc) do
    acc =
      Enum.reduce(rest, acc, fn v, a ->
        Map.update(a, {u, v}, 1, &(&1 + 1))
      end)

    add_pair_counts(rest, acc)
  end
end
