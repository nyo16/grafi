defmodule Grafi.Algo.ShortestPath do
  @moduledoc "Dijkstra, Bellman-Ford, A* — with igraph NIF acceleration."

  alias Grafi.Graph
  alias Grafi.Algo.MinHeap

  @spec dijkstra(Graph.t(), any(), any(), keyword()) :: {:ok, {[any()], number()}} | :no_path
  def dijkstra(%Graph{} = g, source, target, opts \\ []) do
    if Graph.num_vertices(g) > nif_threshold() and Grafi.NIF.available?() do
      {idx, csr} = Graph.to_csr(g)
      Grafi.NIF.validate_csr!(csr)
      rev = Map.new(idx, fn {v, i} -> {i, v} end)

      case Grafi.NIF.nif_dijkstra(csr, idx[source], idx[target]) do
        {:ok, path_indices, dist} -> {:ok, {Enum.map(path_indices, &rev[&1]), dist}}
        :no_path -> :no_path
      end
    else
      dijkstra_elixir(g, source, target, opts)
    end
  end

  @spec dijkstra_all(Graph.t(), any()) :: %{any() => number()}
  def dijkstra_all(%Graph{} = g, source) do
    {dists, _} = do_dijkstra(g, source)
    dists
  end

  @spec bellman_ford(Graph.t(), any()) :: {:ok, %{any() => number()}} | {:error, :negative_cycle}
  def bellman_ford(%Graph{} = g, source) do
    vs = Graph.vertices(g)
    n = length(vs)
    dist = Map.new(vs, &{&1, if(&1 == source, do: 0.0, else: :infinity)})
    all_e = Graph.edges(g)

    dist =
      Enum.reduce(1..(n - 1)//1, dist, fn _, d ->
        Enum.reduce(all_e, d, fn e, d2 ->
          if d2[e.from] != :infinity and d2[e.from] + e.weight < Map.get(d2, e.to, :infinity),
            do: Map.put(d2, e.to, d2[e.from] + e.weight),
            else: d2
        end)
      end)

    neg =
      Enum.any?(all_e, &(dist[&1.from] != :infinity and dist[&1.from] + &1.weight < dist[&1.to]))

    if neg,
      do: {:error, :negative_cycle},
      else: {:ok, Map.reject(dist, fn {_, v} -> v == :infinity end)}
  end

  @spec a_star(Graph.t(), any(), any(), (any() -> number())) ::
          {:ok, {[any()], number()}} | :no_path
  def a_star(%Graph{} = g, source, target, h) do
    heap = MinHeap.new() |> MinHeap.insert({h.(source), 0.0, source, [source]})
    do_astar(g, target, h, heap, MapSet.new())
  end

  # ── Internal ──────────────────────────────────────────────────────────

  defp dijkstra_elixir(g, source, target, _opts) do
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

  defp do_astar(g, target, h, heap, closed) do
    case MinHeap.pop(heap) do
      :empty ->
        :no_path

      {:ok, {_, gc, cur, path}, rest_heap} ->
        cond do
          cur == target ->
            {:ok, {Enum.reverse(path), gc}}

          MapSet.member?(closed, cur) ->
            do_astar(g, target, h, rest_heap, closed)

          true ->
            closed = MapSet.put(closed, cur)

            new_heap =
              Graph.out_neighbors(g, cur)
              |> Enum.reject(&MapSet.member?(closed, &1))
              |> Enum.reduce(rest_heap, fn n, heap_acc ->
                w = Graph.edges_between(g, cur, n) |> Enum.map(& &1.weight) |> Enum.min()
                ng = gc + w
                MinHeap.insert(heap_acc, {ng + h.(n), ng, n, [n | path]})
              end)

            do_astar(g, target, h, new_heap, closed)
        end
    end
  end

  defp nif_threshold, do: Application.get_env(:grafi, :nif_threshold, 500)
end
