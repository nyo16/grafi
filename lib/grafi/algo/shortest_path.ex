defmodule Grafi.Algo.ShortestPath do
  @moduledoc "Dijkstra, Bellman-Ford, A* — with igraph NIF acceleration."

  alias Grafi.Graph

  @nif_threshold 500

  @spec dijkstra(Graph.t(), any(), any(), keyword()) :: {:ok, {[any()], number()}} | :no_path
  def dijkstra(%Graph{} = g, source, target, opts \\ []) do
    if Graph.num_vertices(g) > @nif_threshold and Grafi.NIF.available?() do
      {idx, csr} = Graph.to_csr(g)
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

    dist = Enum.reduce(1..(n-1)//1, dist, fn _, d ->
      Enum.reduce(all_e, d, fn e, d2 ->
        if d2[e.from] != :infinity and d2[e.from] + e.weight < Map.get(d2, e.to, :infinity),
          do: Map.put(d2, e.to, d2[e.from] + e.weight),
          else: d2
      end)
    end)

    neg = Enum.any?(all_e, &(dist[&1.from] != :infinity and dist[&1.from] + &1.weight < dist[&1.to]))
    if neg, do: {:error, :negative_cycle}, else: {:ok, Map.reject(dist, fn {_, v} -> v == :infinity end)}
  end

  @spec a_star(Graph.t(), any(), any(), (any() -> number())) :: {:ok, {[any()], number()}} | :no_path
  def a_star(%Graph{} = g, source, target, h) do
    do_astar(g, target, h, [{h.(source), 0.0, source, [source]}], MapSet.new())
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
    loop(g, [{0.0, source}], %{source => 0.0}, %{}, MapSet.new())
  end

  defp loop(_, [], dists, parents, _), do: {dists, parents}
  defp loop(g, [{d, u} | rest], dists, parents, vis) do
    if MapSet.member?(vis, u), do: loop(g, rest, dists, parents, vis), else:
      (vis = MapSet.put(vis, u)
       {pq, dists, parents} =
         Graph.out_neighbors(g, u)
         |> Enum.reduce({rest, dists, parents}, fn v, {q, ds, ps} ->
           w = Graph.edges_between(g, u, v) |> Enum.map(& &1.weight) |> Enum.min()
           alt = d + w
           if alt < Map.get(ds, v, :infinity),
             do: {ins(q, {alt, v}), Map.put(ds, v, alt), Map.put(ps, v, u)},
             else: {q, ds, ps}
         end)
       loop(g, pq, dists, parents, vis))
  end

  defp ins([], e), do: [e]
  defp ins([{d, _} = h | t], {nd, _} = e) when nd < d, do: [e, h | t]
  defp ins([h | t], e), do: [h | ins(t, e)]

  defp rebuild(_, s, s, path), do: path
  defp rebuild(p, s, c, path) do
    case Map.get(p, c) do
      nil -> path
      par -> rebuild(p, s, par, [par | path])
    end
  end

  defp do_astar(_, _, _, [], _), do: :no_path
  defp do_astar(g, target, h, [{_, gc, cur, path} | rest], closed) do
    if cur == target, do: {:ok, {Enum.reverse(path), gc}}, else:
      if MapSet.member?(closed, cur), do: do_astar(g, target, h, rest, closed), else:
        (closed = MapSet.put(closed, cur)
         new = Graph.out_neighbors(g, cur)
               |> Enum.reject(&MapSet.member?(closed, &1))
               |> Enum.map(fn n ->
                 w = Graph.edges_between(g, cur, n) |> Enum.map(& &1.weight) |> Enum.min()
                 ng = gc + w
                 {ng + h.(n), ng, n, [n | path]}
               end)
         do_astar(g, target, h, merge_open(rest, new), closed))
  end

  defp merge_open(ex, []), do: ex
  defp merge_open(ex, [e | r]), do: merge_open(ins_open(ex, e), r)

  defp ins_open([], e), do: [e]
  defp ins_open([{f1, _, _, _} = h | t], {f2, _, _, _} = e) when f2 < f1, do: [e, h | t]
  defp ins_open([h | t], e), do: [h | ins_open(t, e)]
end
