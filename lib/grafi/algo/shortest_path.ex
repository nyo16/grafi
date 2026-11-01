defmodule Grafi.Algo.ShortestPath do
  @dialyzer :no_opaque

  @moduledoc "Dijkstra, Bellman-Ford, A* — with igraph NIF acceleration."

  alias Grafi.Algo.MinHeap
  alias Grafi.Args
  alias Grafi.Graph
  alias Grafi.NIF

  @doc """
  Computes the shortest weighted path from `source` to `target` using Dijkstra's
  algorithm.

  Returns `{:ok, {path, distance}}` on success, `:no_path` if no path exists,
  `{:error, :no_such_vertex}` if either endpoint is not in the graph, or
  `{:error, :negative_weight}` if any edge weight is negative (Dijkstra is
  undefined there; use `bellman_ford/2`).

  ## Options
    - `:engine` — `:auto | :nif | :elixir`, see `Grafi.NIF`. With `:auto`,
      graphs above the configured `:nif_threshold` (default `500` vertices) run
      in igraph on a dirty scheduler. `engine: :nif` without the NIF returns
      `{:error, :nif_not_available}`.
  """
  @spec dijkstra(Graph.t(), any(), any(), keyword()) ::
          {:ok, {[any()], number()}}
          | :no_path
          | {:error,
             :no_such_vertex | :negative_weight | :nif_not_available | {:igraph, String.t()}}
  def dijkstra(%Graph{} = g, source, target, opts \\ []) do
    Args.engine!(opts)

    cond do
      not Graph.has_vertex?(g, source) or not Graph.has_vertex?(g, target) ->
        {:error, :no_such_vertex}

      Args.negative_weight?(g) ->
        {:error, :negative_weight}

      true ->
        case NIF.engine(g, opts) do
          :nif -> dijkstra_nif(g, source, target)
          :elixir -> dijkstra_elixir(g, source, target)
          {:error, _} = error -> error
        end
    end
  end

  defp dijkstra_nif(g, source, target) do
    {idx, csr} = Graph.to_csr(g)

    case NIF.call(NIF.nif_dijkstra(csr, Map.fetch!(idx, source), Map.fetch!(idx, target))) do
      {:ok, path_indices, dist} -> {:ok, {Enum.map(path_indices, &elem(csr.vertices, &1)), dist}}
      other -> other
    end
  end

  @doc """
  Computes shortest-path distances from `source` to every reachable vertex via
  Dijkstra's algorithm.

  Returns a map of `vertex => distance`. Unreachable vertices are omitted. Runs
  entirely in pure Elixir; intended for the small-graph case.
  """
  @spec dijkstra_all(Graph.t(), any()) :: %{any() => number()}
  def dijkstra_all(%Graph{} = g, source) do
    {dists, _} = do_dijkstra(g, source)
    dists
  end

  @doc """
  Computes shortest-path distances from `source` via the Bellman-Ford algorithm,
  which supports negative edge weights.

  Returns `{:ok, dists}` where `dists` is a map of `vertex => distance` (with
  unreachable vertices omitted), or `{:error, :negative_cycle}` if any negative
  cycle is reachable from `source`. O(|V|·|E|).

  On undirected graphs every edge is relaxed in both directions, so a
  negative-weight undirected edge reachable from `source` is itself a
  negative cycle (`u → v → u`) and yields `{:error, :negative_cycle}`, as in
  NetworkX.
  """
  @spec bellman_ford(Graph.t(), any()) :: {:ok, %{any() => number()}} | {:error, :negative_cycle}
  def bellman_ford(%Graph{} = g, source) do
    # TODO(perf): the inner Enum.reduce rebuilds a map of size |V| at every
    # edge relaxation, giving O(|V|·|E|·log|V|) instead of O(|V|·|E|).
    # For >1k vertices switch to an :array of distances indexed by the
    # vertex-id integer map, or wire up the NIF Bellman-Ford wrapper.
    vs = Graph.vertices(g)
    n = length(vs)
    dist = Map.new(vs, &{&1, if(&1 == source, do: 0.0, else: :infinity)})
    arcs = relaxation_arcs(g)

    dist =
      Enum.reduce(1..(n - 1)//1, dist, fn _, d ->
        Enum.reduce(arcs, d, fn {from, to, w}, d2 ->
          if d2[from] != :infinity and d2[from] + w < Map.get(d2, to, :infinity),
            do: Map.put(d2, to, d2[from] + w),
            else: d2
        end)
      end)

    neg =
      Enum.any?(arcs, fn {from, to, w} ->
        dist[from] != :infinity and dist[from] + w < dist[to]
      end)

    if neg,
      do: {:error, :negative_cycle},
      else: {:ok, Map.reject(dist, fn {_, v} -> v == :infinity end)}
  end

  # `{from, to, weight}` arcs to relax. An undirected edge can be traversed
  # both ways; a self-loop's reverse is itself.
  defp relaxation_arcs(%Graph{type: :directed} = g),
    do: Enum.map(Graph.edges(g), &{&1.from, &1.to, &1.weight})

  defp relaxation_arcs(%Graph{} = g) do
    Enum.flat_map(Graph.edges(g), fn
      %{from: v, to: v, weight: w} -> [{v, v, w}]
      %{from: f, to: t, weight: w} -> [{f, t, w}, {t, f, w}]
    end)
  end

  @doc """
  A* search for the shortest path from `source` to `target` guided by the
  admissible heuristic `h`, a function `vertex -> estimated_cost_to_target`.

  Returns `{:ok, {path, cost}}` on success, `:no_path` if `target` is
  unreachable, or `{:error, :no_such_vertex}` if either endpoint is missing.
  With `h.(_) == 0`, A* degenerates to Dijkstra.
  """
  @spec a_star(Graph.t(), any(), any(), (any() -> number())) ::
          {:ok, {[any()], number()}} | :no_path | {:error, :no_such_vertex}
  def a_star(%Graph{} = g, source, target, h) do
    cond do
      not Graph.has_vertex?(g, source) ->
        {:error, :no_such_vertex}

      not Graph.has_vertex?(g, target) ->
        {:error, :no_such_vertex}

      true ->
        heap = MinHeap.new() |> MinHeap.insert({h.(source), 0.0, source})
        do_astar(g, target, h, heap, %{source => 0.0}, %{}, MapSet.new())
    end
  end

  # ── Internal ──────────────────────────────────────────────────────────

  defp dijkstra_elixir(g, source, target) do
    {dists, parents} = do_dijkstra(g, source)

    case Map.get(dists, target) do
      nil -> :no_path
      d -> {:ok, {rebuild(parents, source, target, [target]), d}}
    end
  end

  defp do_dijkstra(g, source) do
    heap = MinHeap.new() |> MinHeap.insert({0.0, source})
    loop(g, heap, %{source => 0.0}, %{}, MapSet.new())
  end

  defp loop(g, heap, dists, parents, vis) do
    case MinHeap.pop(heap) do
      :empty ->
        {dists, parents}

      {:ok, {d, u}, rest_heap} ->
        if MapSet.member?(vis, u) do
          loop(g, rest_heap, dists, parents, vis)
        else
          vis = MapSet.put(vis, u)

          {heap2, dists, parents} =
            Graph.out_neighbors(g, u)
            |> Enum.reduce({rest_heap, dists, parents}, fn v, {h, ds, ps} ->
              w = Graph.edges_between(g, u, v) |> Enum.map(& &1.weight) |> Enum.min()
              alt = d + w

              if alt < Map.get(ds, v, :infinity),
                do: {MinHeap.insert(h, {alt, v}), Map.put(ds, v, alt), Map.put(ps, v, u)},
                else: {h, ds, ps}
            end)

          loop(g, heap2, dists, parents, vis)
        end
    end
  end

  defp rebuild(_, s, s, path), do: path

  defp rebuild(p, s, c, path) do
    case Map.get(p, c) do
      nil -> path
      par -> rebuild(p, s, par, [par | path])
    end
  end

  # The heap holds only {f_score, g_score, vertex}; the path is reconstructed
  # at the end from `came_from`. Storing the full path in every heap entry
  # would cost O(|frontier| · path_length) memory, unbounded on large graphs.
  defp do_astar(g, target, h, heap, g_score, came_from, closed) do
    case MinHeap.pop(heap) do
      :empty ->
        :no_path

      {:ok, {_, gc, cur}, rest_heap} ->
        cond do
          cur == target ->
            {:ok, {rebuild_came_from(came_from, cur, [cur]), gc}}

          MapSet.member?(closed, cur) ->
            do_astar(g, target, h, rest_heap, g_score, came_from, closed)

          true ->
            closed = MapSet.put(closed, cur)

            {new_heap, g_score, came_from} =
              Graph.out_neighbors(g, cur)
              |> Enum.reject(&MapSet.member?(closed, &1))
              |> Enum.reduce({rest_heap, g_score, came_from}, fn n, {heap_acc, gs, cf} ->
                w = Graph.edges_between(g, cur, n) |> Enum.map(& &1.weight) |> Enum.min()
                ng = gc + w

                if ng < Map.get(gs, n, :infinity) do
                  {MinHeap.insert(heap_acc, {ng + h.(n), ng, n}), Map.put(gs, n, ng),
                   Map.put(cf, n, cur)}
                else
                  {heap_acc, gs, cf}
                end
              end)

            do_astar(g, target, h, new_heap, g_score, came_from, closed)
        end
    end
  end

  # Walk parent pointers from the target back to the source (which has no
  # came_from entry), producing the path in source-to-target order.
  defp rebuild_came_from(came_from, cur, acc) do
    case Map.get(came_from, cur) do
      nil -> acc
      parent -> rebuild_came_from(came_from, parent, [parent | acc])
    end
  end
end
