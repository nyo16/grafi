defmodule Grafi.Algo.KShortestPath do
  @moduledoc """
  K-shortest loopless paths via Yen's algorithm.

  Returns up to `k` simple (loopless) paths from `source` to `target`,
  sorted by total weight ascending. Pure Elixir.

  ## Complexity

  Yen's algorithm runs at worst `O(K · V · (E + V log V))` — it invokes
  Dijkstra up to `K · V` times, once per spur node per candidate path.
  This is **not cheap**; for large graphs prefer a single Dijkstra unless
  you genuinely need alternatives.
  """

  alias Grafi.Algo.MinHeap
  alias Grafi.Algo.ShortestPath
  alias Grafi.Graph

  @doc """
  Computes up to `k` loopless shortest paths from `source` to `target`,
  ordered by total weight ascending.

  Returns `{:ok, [{path, weight}, ...]}` on success — the list may be
  shorter than `k` if fewer loopless paths exist. Returns
  `{:error, :no_such_vertex}` if either endpoint is missing, or
  `{:error, :no_path}` when no path exists at all.

  ## Examples

      iex> g = Grafi.new() |> Grafi.add_edges([
      ...>   {:a, :b, weight: 1.0}, {:b, :d, weight: 1.0},
      ...>   {:a, :c, weight: 2.0}, {:c, :d, weight: 2.0}
      ...> ])
      iex> {:ok, [{p1, w1}, {_p2, w2}]} = Grafi.Algo.KShortestPath.yen(g, :a, :d, 2)
      iex> {p1, w1 <= w2}
      {[:a, :b, :d], true}
  """
  @spec yen(Graph.t(), any(), any(), pos_integer(), keyword()) ::
          {:ok, [{[any()], number()}]}
          | {:error, :no_such_vertex}
          | {:error, :no_path}
  def yen(%Graph{} = g, source, target, k, _opts \\ []) when is_integer(k) and k > 0 do
    cond do
      not Graph.has_vertex?(g, source) ->
        {:error, :no_such_vertex}

      not Graph.has_vertex?(g, target) ->
        {:error, :no_such_vertex}

      source == target ->
        {:ok, [{[source], 0.0}]}

      true ->
        case ShortestPath.dijkstra(g, source, target) do
          :no_path ->
            {:error, :no_path}

          {:error, _} = err ->
            err

          {:ok, {path, weight}} ->
            results = [{path, weight}]
            paths = yen_loop(g, source, target, k, results, MinHeap.new(), MapSet.new([path]))
            {:ok, paths}
        end
    end
  end

  # ── Internal ──────────────────────────────────────────────────────────

  defp yen_loop(_g, _s, _t, k, results, _candidates, _seen) when length(results) >= k,
    do: Enum.reverse(results)

  defp yen_loop(g, source, target, k, [{prev_path, _} | _] = results, candidates, seen) do
    candidates = enqueue_spur_candidates(g, source, target, prev_path, results, candidates, seen)

    case pop_unseen(candidates, seen) do
      :empty ->
        Enum.reverse(results)

      {:ok, {weight, path}, rest} ->
        seen = MapSet.put(seen, path)
        results = [{path, weight} | results]
        yen_loop(g, source, target, k, results, rest, seen)
    end
  end

  # For each spur node along prev_path, compute alternative candidates.
  defp enqueue_spur_candidates(g, _source, target, prev_path, results, candidates, seen) do
    # spur indices are 0..(len-2) — the last node has no successor to swap.
    indices = 0..(length(prev_path) - 2)

    Enum.reduce(indices, candidates, fn i, acc ->
      {root_path, spur_node} = split_at_spur(prev_path, i)

      # Edges to forbid: the next-edge of every previously-found path that
      # shares `root_path` as a prefix.
      forbidden_edges = forbidden_for_root(results ++ enqueued_paths(acc, seen), root_path)

      # Vertices to forbid: all root-path vertices except the spur itself
      # (otherwise the spur Dijkstra cannot leave its starting node).
      forbidden_vertices = MapSet.new(root_path) |> MapSet.delete(spur_node)

      modified = build_modified_graph(g, forbidden_vertices, forbidden_edges)

      case ShortestPath.dijkstra(modified, spur_node, target) do
        {:ok, {spur_path, spur_weight}} ->
          full_path = root_path ++ tl(spur_path)

          if loopless?(full_path) and not MapSet.member?(seen, full_path) do
            root_weight = path_weight(g, root_path)
            total = root_weight + spur_weight
            MinHeap.insert(acc, {total, full_path})
          else
            acc
          end

        _ ->
          acc
      end
    end)
  end

  # Yen's algorithm uses only *previously yielded* paths to derive
  # forbidden edges. We don't need to look inside the candidates heap.
  defp enqueued_paths(_candidates, _seen), do: []

  # path = [v0, v1, ..., vi, ..., vN].
  # Spur node is vi; root path is [v0..vi] (inclusive).
  defp split_at_spur(path, i) do
    root = Enum.take(path, i + 1)
    {root, List.last(root)}
  end

  # For each previously found path sharing `root_path` as prefix, return
  # the edge {u, v} where u = last(root_path), v = next vertex along that
  # path. These edges must be removed before the spur Dijkstra runs.
  defp forbidden_for_root(paths, root_path) do
    root_len = length(root_path)
    spur = List.last(root_path)

    Enum.reduce(paths, MapSet.new(), fn {p, _w}, acc ->
      cond do
        length(p) <= root_len -> acc
        Enum.take(p, root_len) != root_path -> acc
        true -> MapSet.put(acc, {spur, Enum.at(p, root_len)})
      end
    end)
  end

  # Build a graph with given vertices and edges removed. We preserve graph
  # type and edge weights, and silently drop edges incident to removed
  # vertices.
  defp build_modified_graph(g, forbidden_vertices, forbidden_edges) do
    g
    |> Graph.vertices()
    |> Enum.reject(&MapSet.member?(forbidden_vertices, &1))
    |> Enum.reduce(Graph.new(type: g.type), fn v, acc -> Graph.add_vertex(acc, v) end)
    |> add_filtered_edges(g, forbidden_vertices, forbidden_edges)
  end

  defp add_filtered_edges(acc, g, forbidden_vertices, forbidden_edges) do
    Enum.reduce(g.out_edges, acc, fn {from, targets}, acc1 ->
      if MapSet.member?(forbidden_vertices, from),
        do: acc1,
        else: add_targets(acc1, from, targets, forbidden_vertices, forbidden_edges)
    end)
  end

  defp add_targets(acc, from, targets, forbidden_vertices, forbidden_edges) do
    Enum.reduce(targets, acc, fn {to, edge_list}, acc2 ->
      if MapSet.member?(forbidden_vertices, to) or
           MapSet.member?(forbidden_edges, {from, to}) do
        acc2
      else
        Enum.reduce(edge_list, acc2, fn e, a ->
          Graph.add_edge(a, from, to, weight: e.weight, label: e.label)
        end)
      end
    end)
  end

  # Sum of minimum edge weights between consecutive vertices on a path.
  defp path_weight(_g, [_only]), do: 0.0

  defp path_weight(g, [u, v | rest]) do
    w = g |> Graph.edges_between(u, v) |> Enum.map(& &1.weight) |> Enum.min()
    w + path_weight(g, [v | rest])
  end

  defp path_weight(_g, []), do: 0.0

  defp loopless?(path), do: length(path) == path |> MapSet.new() |> MapSet.size()

  defp pop_unseen(heap, seen) do
    case MinHeap.pop(heap) do
      :empty ->
        :empty

      {:ok, {_w, path} = elem, rest} ->
        if MapSet.member?(seen, path),
          do: pop_unseen(rest, seen),
          else: {:ok, elem, rest}
    end
  end
end
