defmodule Grafi.Algo.KShortestPath do
  @dialyzer :no_opaque

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
  `{:error, :no_such_vertex}` if either endpoint is missing,
  `{:error, :no_path}` when no path exists at all, or
  `{:error, :negative_weight}` if any edge weight is negative.

  Undirected graphs are supported: an undirected edge is forbidden in both
  directions while a spur path is searched.

  It takes no options yet; unknown options raise `ArgumentError`.

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
          | {:error, :no_such_vertex | :no_path | :negative_weight}
  def yen(%Graph{} = g, source, target, k, opts \\ []) when is_integer(k) and k > 0 do
    Keyword.validate!(opts, [])

    cond do
      not Graph.has_vertex?(g, source) ->
        {:error, :no_such_vertex}

      not Graph.has_vertex?(g, target) ->
        {:error, :no_such_vertex}

      source == target ->
        {:ok, [{[source], 0.0}]}

      true ->
        case ShortestPath.dijkstra(g, source, target, engine: :elixir) do
          {:ok, {path, _weight} = first} ->
            {:ok, yen_loop(g, target, k, [first], 1, MinHeap.new(), MapSet.new([path]))}

          {:error, _} = err ->
            err
        end
    end
  end

  # ── Internal ──────────────────────────────────────────────────────────

  # `results` is newest-first and holds `count` paths.
  defp yen_loop(_g, _target, k, results, k, _candidates, _seen), do: Enum.reverse(results)

  defp yen_loop(g, target, k, [{prev_path, _} | _] = results, count, candidates, seen) do
    [source | after_source] = prev_path
    candidates = spurs(g, target, after_source, [source], 0.0, results, candidates, seen)

    case pop_unseen(candidates, seen) do
      :empty ->
        Enum.reverse(results)

      {:ok, {weight, path}, rest} ->
        yen_loop(g, target, k, [{path, weight} | results], count + 1, rest, MapSet.put(seen, path))
    end
  end

  # Takes each vertex of the previous path but the last as the spur node in
  # turn. `root_rev` is the root path reversed, headed by the spur node, and
  # `root_weight` its weight; `remaining` is the rest of the previous path.
  defp spurs(_g, _target, [], _root_rev, _root_weight, _results, candidates, _seen),
    do: candidates

  defp spurs(g, target, [next | rest], [spur | _] = root_rev, root_weight, results, cands, seen) do
    root_path = Enum.reverse(root_rev)
    # Root vertices other than the spur are off limits, which keeps the
    # spur path, and so the full path, loopless.
    forbidden_vertices = MapSet.new(tl(root_rev))
    forbidden_edges = forbidden_edges(g, results, root_path, spur)

    cands =
      case spur_dijkstra(g, spur, target, forbidden_vertices, forbidden_edges) do
        {:ok, {[_spur | spur_tail], spur_weight}} ->
          full_path = root_path ++ spur_tail

          if MapSet.member?(seen, full_path),
            do: cands,
            else: MinHeap.insert(cands, {root_weight + spur_weight, full_path})

        :error ->
          cands
      end

    step = g.out_edges |> Map.fetch!(spur) |> Map.fetch!(next) |> min_weight()
    spurs(g, target, rest, [next | root_rev], root_weight + step, results, cands, seen)
  end

  # Yen forbids, for every previously yielded path that starts with
  # `root_path`, its edge out of the spur node. An undirected edge is
  # forbidden in both orientations, since `out_edges` stores it under both
  # endpoints.
  defp forbidden_edges(%Graph{type: type}, results, root_path, spur) do
    Enum.reduce(results, MapSet.new(), fn {path, _weight}, acc ->
      case next_after_prefix(path, root_path) do
        {:ok, next} when type == :undirected ->
          acc |> MapSet.put({spur, next}) |> MapSet.put({next, spur})

        {:ok, next} ->
          MapSet.put(acc, {spur, next})

        :error ->
          acc
      end
    end)
  end

  defp next_after_prefix([v | path], [v | prefix]), do: next_after_prefix(path, prefix)
  defp next_after_prefix([next | _], []), do: {:ok, next}
  defp next_after_prefix(_path, _prefix), do: :error

  # Dijkstra from `spur` to `target` on the graph minus the forbidden
  # vertices and edges, skipping them during relaxation instead of building
  # a reduced graph. Halts as soon as `target` is settled.
  defp spur_dijkstra(%Graph{out_edges: out}, spur, target, forbidden_vertices, forbidden_edges) do
    heap = MinHeap.insert(MinHeap.new(), {0.0, spur})
    forbidden = {forbidden_vertices, forbidden_edges}
    spur_settle(out, heap, %{spur => 0.0}, %{}, target, forbidden)
  end

  defp spur_settle(out, heap, dists, parents, target, forbidden) do
    case MinHeap.pop(heap) do
      :empty ->
        :error

      {:ok, {d, u}, rest} ->
        cond do
          # Stale entry: `u` was re-queued with a shorter distance.
          d > Map.fetch!(dists, u) ->
            spur_settle(out, rest, dists, parents, target, forbidden)

          u == target ->
            {:ok, {path_to(parents, u, [u]), d}}

          true ->
            {heap, dists, parents} =
              out
              |> Map.get(u, %{})
              |> Enum.reduce({rest, dists, parents}, &spur_relax(&1, &2, u, d, forbidden))

            spur_settle(out, heap, dists, parents, target, forbidden)
        end
    end
  end

  defp spur_relax({_v, []}, acc, _u, _d, _forbidden), do: acc

  defp spur_relax({v, edges}, {heap, dists, parents} = acc, u, d, {vertices, edge_set}) do
    alt = d + min_weight(edges)

    if MapSet.member?(vertices, v) or MapSet.member?(edge_set, {u, v}) or
         alt >= Map.get(dists, v, :infinity),
       do: acc,
       else: {MinHeap.insert(heap, {alt, v}), Map.put(dists, v, alt), Map.put(parents, v, u)}
  end

  defp path_to(parents, v, acc) do
    case Map.get(parents, v) do
      nil -> acc
      u -> path_to(parents, u, [u | acc])
    end
  end

  defp min_weight([e | es]), do: Enum.reduce(es, e.weight, &min(&1.weight, &2))

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
