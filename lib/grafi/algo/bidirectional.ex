defmodule Grafi.Algo.Bidirectional do
  @moduledoc """
  Bidirectional Dijkstra — runs two Dijkstra searches simultaneously,
  one forward from `source` (following out-edges) and one backward from
  `target` (following in-edges). Terminates as soon as the two frontiers
  meet and any further expansion is provably worse than the best
  shortest-path candidate so far.

  Especially effective on large graphs where `source` and `target` are
  close — both frontiers stay small. Result is identical in weight to
  classical Dijkstra; the path may differ when multiple equally short
  paths exist.
  """

  alias Grafi.Algo.MinHeap
  alias Grafi.Graph

  @inf :infinity

  @doc """
  Bidirectional Dijkstra shortest path. Returns the same shapes as
  `Grafi.Algo.ShortestPath.dijkstra/4`:

    * `{:ok, {path, weight}}` on success
    * `{:error, :no_path}` if no path exists
    * `{:error, :no_such_vertex}` if either endpoint is missing

  It takes no options yet; unknown options raise `ArgumentError`.

  Edge weights must be non-negative. For undirected graphs the backward
  frontier walks the same adjacency as the forward one; for directed
  graphs it walks the reverse adjacency via `Grafi.Graph.in_neighbors/2`.

  ## Examples

      iex> g = Grafi.new() |> Grafi.add_edges([
      ...>   {:a, :b, weight: 1.0}, {:b, :c, weight: 2.0}, {:a, :c, weight: 5.0}
      ...> ])
      iex> Grafi.Algo.Bidirectional.dijkstra(g, :a, :c)
      {:ok, {[:a, :b, :c], 3.0}}
  """
  @spec dijkstra(Graph.t(), any(), any(), keyword()) ::
          {:ok, {[any()], number()}} | {:error, :no_path | :no_such_vertex}
  def dijkstra(%Graph{} = g, source, target, opts \\ []) do
    Keyword.validate!(opts, [])

    cond do
      not Graph.has_vertex?(g, source) ->
        {:error, :no_such_vertex}

      not Graph.has_vertex?(g, target) ->
        {:error, :no_such_vertex}

      source == target ->
        {:ok, {[source], 0.0}}

      true ->
        do_bidi(g, source, target)
    end
  end

  # ── Internal ──────────────────────────────────────────────────────────

  defp do_bidi(g, source, target) do
    fwd = %{
      heap: MinHeap.new() |> MinHeap.insert({0.0, source}),
      dist: %{source => 0.0},
      pred: %{},
      settled: MapSet.new()
    }

    bwd = %{
      heap: MinHeap.new() |> MinHeap.insert({0.0, target}),
      dist: %{target => 0.0},
      pred: %{},
      settled: MapSet.new()
    }

    case loop(g, fwd, bwd, @inf, nil) do
      {:no_path} ->
        {:error, :no_path}

      {:ok, meet, total, fwd_final, bwd_final} ->
        path =
          rebuild(fwd_final.pred, source, meet) ++ tl(rebuild_bwd(bwd_final.pred, target, meet))

        {:ok, {path, total}}
    end
  end

  defp loop(g, fwd, bwd, best, meet) do
    fwd_top = top_key(fwd.heap)
    bwd_top = top_key(bwd.heap)

    cond do
      fwd_top == :empty and bwd_top == :empty ->
        if meet == nil, do: {:no_path}, else: {:ok, meet, best, fwd, bwd}

      # Termination: the smallest possible new path length is at least
      # min_fwd + min_bwd; if that >= best, no future expansion can
      # improve the meeting candidate.
      meet != nil and key_sum(fwd_top, bwd_top) >= best ->
        {:ok, meet, best, fwd, bwd}

      # Pop from the smaller frontier (balanced strategy).
      should_step_fwd?(fwd_top, bwd_top) ->
        step(:fwd, g, fwd, bwd, best, meet)

      true ->
        step(:bwd, g, fwd, bwd, best, meet)
    end
  end

  defp top_key(nil), do: :empty
  defp top_key({{k, _}, _}), do: k

  defp key_sum(:empty, _), do: @inf
  defp key_sum(_, :empty), do: @inf
  defp key_sum(a, b), do: a + b

  defp should_step_fwd?(:empty, _), do: false
  defp should_step_fwd?(_, :empty), do: true
  defp should_step_fwd?(a, b), do: a <= b

  defp step(:fwd, g, fwd, bwd, best, meet) do
    {fwd2, popped} = pop_next(fwd)

    case popped do
      nil ->
        loop(g, fwd2, bwd, best, meet)

      {d, u} ->
        fwd2 = %{fwd2 | settled: MapSet.put(fwd2.settled, u)}
        {fwd3, best, meet} = relax_forward(g, u, d, fwd2, bwd, best, meet)
        {best, meet} = maybe_update_meet(u, fwd3, bwd, best, meet)
        loop(g, fwd3, bwd, best, meet)
    end
  end

  defp step(:bwd, g, fwd, bwd, best, meet) do
    {bwd2, popped} = pop_next(bwd)

    case popped do
      nil ->
        loop(g, fwd, bwd2, best, meet)

      {d, u} ->
        bwd2 = %{bwd2 | settled: MapSet.put(bwd2.settled, u)}
        {bwd3, best, meet} = relax_backward(g, u, d, bwd2, fwd, best, meet)
        {best, meet} = maybe_update_meet(u, fwd, bwd3, best, meet)
        loop(g, fwd, bwd3, best, meet)
    end
  end

  # Pop a non-stale entry off the heap (skipping outdated keys).
  defp pop_next(side) do
    case MinHeap.pop(side.heap) do
      :empty ->
        {%{side | heap: nil}, nil}

      {:ok, {d, u}, rest} ->
        cur = Map.get(side.dist, u, @inf)
        # Stale entry: a better distance has been recorded since this was queued.
        if MapSet.member?(side.settled, u) or d > cur do
          pop_next(%{side | heap: rest})
        else
          {%{side | heap: rest}, {d, u}}
        end
    end
  end

  defp relax_forward(g, u, du, fwd, bwd, best, meet) do
    Graph.out_neighbors(g, u)
    |> Enum.reduce({fwd, best, meet}, fn v, {acc, best_a, meet_a} ->
      if MapSet.member?(acc.settled, v) do
        {acc, best_a, meet_a}
      else
        w = g |> Graph.edges_between(u, v) |> Enum.map(& &1.weight) |> Enum.min()
        alt = du + w

        if alt < Map.get(acc.dist, v, @inf) do
          acc = %{
            acc
            | dist: Map.put(acc.dist, v, alt),
              pred: Map.put(acc.pred, v, u),
              heap: MinHeap.insert(acc.heap, {alt, v})
          }

          # Candidate path through v.
          db = Map.get(bwd.dist, v, @inf)

          {best_a, meet_a} =
            if db != @inf and alt + db < best_a, do: {alt + db, v}, else: {best_a, meet_a}

          {acc, best_a, meet_a}
        else
          {acc, best_a, meet_a}
        end
      end
    end)
  end

  defp relax_backward(g, u, du, bwd, fwd, best, meet) do
    Graph.in_neighbors(g, u)
    |> Enum.reduce({bwd, best, meet}, fn v, {acc, best_a, meet_a} ->
      if MapSet.member?(acc.settled, v) do
        {acc, best_a, meet_a}
      else
        # Edge in the original graph goes v -> u; we follow it in reverse.
        w = g |> Graph.edges_between(v, u) |> Enum.map(& &1.weight) |> Enum.min()
        alt = du + w

        if alt < Map.get(acc.dist, v, @inf) do
          acc = %{
            acc
            | dist: Map.put(acc.dist, v, alt),
              pred: Map.put(acc.pred, v, u),
              heap: MinHeap.insert(acc.heap, {alt, v})
          }

          df = Map.get(fwd.dist, v, @inf)

          {best_a, meet_a} =
            if df != @inf and df + alt < best_a, do: {df + alt, v}, else: {best_a, meet_a}

          {acc, best_a, meet_a}
        else
          {acc, best_a, meet_a}
        end
      end
    end)
  end

  # Whenever a vertex has been touched by *both* frontiers, see if it
  # gives us a better total. The meeting vertex is whichever minimises
  # dist_fwd[v] + dist_bwd[v] across every such v.
  defp maybe_update_meet(u, fwd, bwd, best, meet) do
    df = Map.get(fwd.dist, u, @inf)
    db = Map.get(bwd.dist, u, @inf)

    cond do
      df == @inf or db == @inf ->
        {best, meet}

      df + db < best ->
        {df + db, u}

      true ->
        {best, meet}
    end
  end

  # Forward path: walk predecessors from `meet` back to `source`, then reverse.
  defp rebuild(pred, source, meet), do: build_chain(pred, source, meet, [meet])

  defp build_chain(_pred, source, source, acc), do: acc

  defp build_chain(pred, source, cur, acc) do
    case Map.get(pred, cur) do
      nil -> acc
      p -> build_chain(pred, source, p, [p | acc])
    end
  end

  # Backward path: in the backward search, pred[v] is the *next* vertex
  # toward target. So from `meet`, following preds yields meet, ..., target.
  defp rebuild_bwd(pred, target, meet), do: build_chain_bwd(pred, target, meet, [meet])

  defp build_chain_bwd(_pred, target, target, acc), do: Enum.reverse(acc)

  defp build_chain_bwd(pred, target, cur, acc) do
    case Map.get(pred, cur) do
      nil -> Enum.reverse(acc)
      n -> build_chain_bwd(pred, target, n, [n | acc])
    end
  end
end
