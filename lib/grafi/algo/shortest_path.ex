defmodule Grafi.Algo.ShortestPath do
  @dialyzer :no_opaque

  @moduledoc "Dijkstra, Bellman-Ford, A* — with igraph NIF acceleration."

  alias Grafi.Algo.MinHeap
  alias Grafi.Args
  alias Grafi.Edge
  alias Grafi.Graph
  alias Grafi.NIF

  @doc """
  Computes the shortest weighted path from `source` to `target` using Dijkstra's
  algorithm.

  Returns `{:ok, {path, distance}}` on success, `:no_path` if no path exists,
  `{:error, :no_such_vertex}` if either endpoint is not in the graph, or
  `{:error, :negative_weight}` if any edge weight is negative (Dijkstra is
  undefined there; use `bellman_ford/2`).

  The Elixir engine stops as soon as `target` is settled, so a nearby target
  costs only the part of the graph closer to `source` than it.

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

  `weight_fn` maps each `%Grafi.Edge{}` to its cost, which must be
  non-negative; it defaults to the edge's `:weight`. Between parallel edges
  the cheapest wins. Johnson's algorithm (`Grafi.Algo.APSP.johnson/1`) passes
  its reweighting here instead of building a reweighted graph.

  Returns a map of `vertex => distance`. Unreachable vertices are omitted. Runs
  entirely in pure Elixir; intended for the small-graph case.

  ## Examples

      iex> g = Grafi.new() |> Grafi.add_edges([
      ...>   {:a, :b, weight: 1.0}, {:b, :c, weight: 2.0}, {:a, :c, weight: 5.0}
      ...> ])
      iex> Grafi.Algo.ShortestPath.dijkstra_all(g, :a)
      %{a: 0.0, b: 1.0, c: 3.0}
      iex> Grafi.Algo.ShortestPath.dijkstra_all(g, :a, fn _edge -> 1 end)
      %{a: 0.0, b: 1.0, c: 1.0}
  """
  @spec dijkstra_all(Graph.t(), any(), (Edge.t() -> number())) :: %{any() => number()}
  def dijkstra_all(%Graph{} = g, source, weight_fn \\ & &1.weight)
      when is_function(weight_fn, 1) do
    {dists, _} = run_dijkstra(g, source, :all, weight_fn, nil)
    dists
  end

  @doc """
  Computes shortest-path distances from `source` via the Bellman-Ford algorithm,
  which supports negative edge weights.

  Returns `{:ok, dists}` where `dists` is a map of `vertex => distance` (with
  unreachable vertices omitted), `{:error, :negative_cycle}` if any negative
  cycle is reachable from `source`, or `{:error, :no_such_vertex}` if `source`
  is not in the graph. O(|V|·|E|) in the worst case; it stops after the first
  round of relaxations that changes nothing, so graphs whose shortest paths
  have few edges finish in a few rounds.

  On undirected graphs every edge is relaxed in both directions, so a
  negative-weight undirected edge reachable from `source` is itself a
  negative cycle (`u → v → u`) and yields `{:error, :negative_cycle}`, as in
  NetworkX.
  """
  @spec bellman_ford(Graph.t(), any()) ::
          {:ok, %{any() => number()}} | {:error, :negative_cycle | :no_such_vertex}
  def bellman_ford(%Graph{} = g, source) do
    if Graph.has_vertex?(g, source) do
      relax_rounds(relaxation_arcs(g), %{source => 0.0}, Graph.num_vertices(g))
    else
      {:error, :no_such_vertex}
    end
  end

  # Without a reachable negative cycle a shortest path has at most |V| - 1
  # edges, so the distances stop changing within |V| - 1 rounds and the
  # next round changes nothing. A round that still changes something after
  # that means a negative cycle. Any unchanged round ends the search early.
  defp relax_rounds(_arcs, _dist, 0), do: {:error, :negative_cycle}

  defp relax_rounds(arcs, dist, rounds_left) do
    case relax_round(arcs, dist) do
      {dist, false} -> {:ok, dist}
      {dist, true} -> relax_rounds(arcs, dist, rounds_left - 1)
    end
  end

  # Unreached vertices are absent from `dist` (distance infinity).
  defp relax_round(arcs, dist) do
    Enum.reduce(arcs, {dist, false}, fn {from, to, w}, {d, _changed?} = acc ->
      case d do
        %{^from => df} ->
          alt = df + w
          if alt < Map.get(d, to, :infinity), do: {Map.put(d, to, alt), true}, else: acc

        _ ->
          acc
      end
    end)
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
    {dists, parents} = run_dijkstra(g, source, {:until, target}, & &1.weight, %{})

    case Map.fetch(dists, target) do
      {:ok, d} -> {:ok, {rebuild(parents, source, target, [target]), d}}
      :error -> :no_path
    end
  end

  # Lazy-deletion Dijkstra over the raw adjacency map. An undirected graph
  # stores each edge under both endpoints in `out_edges`, so a walk over
  # `out_edges[u]` relaxes it both ways. `stop` is `:all` or
  # `{:until, target}`; in the latter case the search returns as soon as
  # `target` is settled, when its distance (and parent chain) is final.
  # `parents` is `nil` when the caller only needs distances.
  defp run_dijkstra(g, source, stop, weight_fn, parents) do
    heap = MinHeap.insert(MinHeap.new(), {0.0, source})
    settle(g.out_edges, heap, %{source => 0.0}, parents, stop, weight_fn)
  end

  defp settle(out, heap, dists, parents, stop, weight_fn) do
    case MinHeap.pop(heap) do
      :empty ->
        {dists, parents}

      {:ok, {d, u}, rest} ->
        cond do
          # Stale entry: `u` was re-queued with a shorter distance.
          d > Map.fetch!(dists, u) ->
            settle(out, rest, dists, parents, stop, weight_fn)

          stop == {:until, u} ->
            {dists, parents}

          true ->
            {heap, dists, parents} =
              out
              |> Map.get(u, %{})
              |> Enum.reduce({rest, dists, parents}, &relax(&1, &2, u, d, weight_fn))

            settle(out, heap, dists, parents, stop, weight_fn)
        end
    end
  end

  defp relax({_v, []}, acc, _u, _d, _weight_fn), do: acc

  defp relax({v, [e | es]}, {heap, dists, parents} = acc, u, d, weight_fn) do
    alt = d + min_weight(es, weight_fn.(e), weight_fn)

    if alt < Map.get(dists, v, :infinity),
      do: {MinHeap.insert(heap, {alt, v}), Map.put(dists, v, alt), put_parent(parents, v, u)},
      else: acc
  end

  defp min_weight([], min, _weight_fn), do: min

  defp min_weight([e | es], min, weight_fn) do
    w = weight_fn.(e)
    min_weight(es, if(w < min, do: w, else: min), weight_fn)
  end

  defp put_parent(nil, _v, _u), do: nil
  defp put_parent(parents, v, u), do: Map.put(parents, v, u)

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
