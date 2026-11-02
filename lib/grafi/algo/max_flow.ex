defmodule Grafi.Algo.MaxFlow do
  @moduledoc """
  Maximum s-t flow and minimum s-t cut algorithms — Edmonds-Karp,
  Dinic's algorithm, and minimum cut extraction via Max-Flow Min-Cut.

  Edge `:weight` is interpreted as a non-negative **capacity**. Both
  algorithms operate on a residual graph represented as a nested map
  `%{u => %{v => residual_cap}}`. For each forward edge `(u, v)` with
  capacity `c`, the residual graph starts with capacity `c` on `(u, v)`
  and `0` on the reverse `(v, u)` (unless an explicit reverse edge is
  given, in which case the two capacities add independently).

  Parallel edges between the same `(u, v)` pair are **summed** — every
  parallel edge contributes its capacity. Self-loops are ignored — they
  can never carry s-t flow.

  ## Directed vs undirected

  * **Directed** graphs (default): each edge contributes capacity in its
    declared direction only.
  * **Undirected** graphs: each edge is treated as bidirectional, with
    its full capacity available in *each* direction independently.

  ## Return shape

  `edmonds_karp/4`, `dinic/4` and `max_flow/4` (which dispatches to one
  of the two by its `:algo` option) return
  `{:ok, %{flow: total_flow, flows: %{{u, v} => flow}}}` on success.
  `flows` records the net flow pushed along each original directed edge
  (omitting edges that carry zero flow). For undirected graphs the flow
  is reported in the direction it was actually pushed.

  `min_cut/4` returns
  `{:ok, %{cut_value: number(), source_side: MapSet.t(), sink_side: MapSet.t(), cut_edges: [{u, v}]}}`.
  By the Max-Flow Min-Cut theorem, `cut_value` equals the maximum flow.

  ## Errors

  * `{:error, :no_such_vertex}` — `source` or `sink` is not in the graph.
  * `{:error, :negative_capacity}` — any edge weight is negative.
  """

  alias Grafi.{Args, Graph}

  @type flow_map :: %{{any(), any()} => number()}
  @type result :: %{flow: number(), flows: flow_map()}

  @doc """
  Maximum s-t flow via the Edmonds-Karp algorithm — Ford-Fulkerson with
  BFS-based augmenting path selection. Runs in O(V·E²).

  Returns `{:ok, %{flow: total, flows: %{{u, v} => flow}}}`, or
  `{:error, :no_such_vertex}` / `{:error, :negative_capacity}`.

  ## Examples

      iex> g = Grafi.new() |> Grafi.add_edges([
      ...>   {:s, :a, weight: 3}, {:s, :b, weight: 2},
      ...>   {:a, :b, weight: 2}, {:a, :t, weight: 2}, {:b, :t, weight: 3}
      ...> ])
      iex> {:ok, %{flow: f}} = Grafi.Algo.MaxFlow.edmonds_karp(g, :s, :t)
      iex> f
      5
  """
  @spec edmonds_karp(Graph.t(), any(), any(), keyword()) ::
          {:ok, result()} | {:error, :no_such_vertex | :negative_capacity}
  def edmonds_karp(%Graph{} = g, source, sink, opts \\ []) do
    _ = Keyword.validate!(opts, [])

    with :ok <- validate(g, source, sink) do
      run(g, source, sink, &edmonds_karp_loop/3)
    end
  end

  @doc """
  Maximum s-t flow via Dinic's algorithm — BFS-built level graph plus
  DFS-found blocking flows. Runs in O(V²·E).

  Returns `{:ok, %{flow: total, flows: %{{u, v} => flow}}}`, or
  `{:error, :no_such_vertex}` / `{:error, :negative_capacity}`.

  ## Examples

      iex> g = Grafi.new() |> Grafi.add_edges([
      ...>   {:s, :a, weight: 3}, {:s, :b, weight: 2},
      ...>   {:a, :b, weight: 2}, {:a, :t, weight: 2}, {:b, :t, weight: 3}
      ...> ])
      iex> {:ok, %{flow: f}} = Grafi.Algo.MaxFlow.dinic(g, :s, :t)
      iex> f
      5
  """
  @spec dinic(Graph.t(), any(), any(), keyword()) ::
          {:ok, result()} | {:error, :no_such_vertex | :negative_capacity}
  def dinic(%Graph{} = g, source, sink, opts \\ []) do
    _ = Keyword.validate!(opts, [])

    with :ok <- validate(g, source, sink) do
      run(g, source, sink, &dinic_loop/3)
    end
  end

  @doc """
  Maximum s-t flow with the algorithm chosen by `:algo`.

  ## Options

    * `:algo` — `:dinic` (the default, `dinic/4`) or `:edmonds_karp`
      (`edmonds_karp/4`). Any other value raises `ArgumentError`.

  Returns the same shapes as `dinic/4`.

  ## Examples

      iex> g = Grafi.new() |> Grafi.add_edges([
      ...>   {:s, :a, weight: 3}, {:s, :b, weight: 2},
      ...>   {:a, :b, weight: 2}, {:a, :t, weight: 2}, {:b, :t, weight: 3}
      ...> ])
      iex> {:ok, %{flow: f}} = Grafi.Algo.MaxFlow.max_flow(g, :s, :t, algo: :edmonds_karp)
      iex> f
      5
  """
  @spec max_flow(Graph.t(), any(), any(), keyword()) ::
          {:ok, result()} | {:error, :no_such_vertex | :negative_capacity}
  def max_flow(%Graph{} = g, source, sink, opts \\ []) do
    opts = Keyword.validate!(opts, algo: :dinic)
    algo_fn = algo!(opts)

    with :ok <- validate(g, source, sink) do
      run(g, source, sink, algo_fn)
    end
  end

  @doc """
  Minimum s-t cut via the Max-Flow Min-Cut theorem.

  Computes a maximum flow (using `:dinic` by default, switchable via
  the `:algo` option to `:edmonds_karp`, as in `max_flow/4`), then BFS-walks the residual
  graph from `source` along edges with strictly positive residual
  capacity. Vertices reached form the `source_side`; the remaining
  vertices form the `sink_side`. Original edges crossing from source
  side to sink side are the cut edges, and their capacities sum to
  the max-flow value.

  Returns
  `{:ok, %{cut_value: number(), source_side: MapSet.t(), sink_side: MapSet.t(), cut_edges: [{u, v}]}}`,
  or `{:error, :no_such_vertex}` / `{:error, :negative_capacity}`.

  ## Examples

      iex> g = Grafi.new() |> Grafi.add_edges([
      ...>   {:s, :a, weight: 3}, {:s, :b, weight: 2},
      ...>   {:a, :b, weight: 2}, {:a, :t, weight: 2}, {:b, :t, weight: 3}
      ...> ])
      iex> {:ok, %{cut_value: v}} = Grafi.Algo.MaxFlow.min_cut(g, :s, :t)
      iex> v
      5
  """
  @spec min_cut(Graph.t(), any(), any(), keyword()) ::
          {:ok,
           %{
             cut_value: number(),
             source_side: MapSet.t(),
             sink_side: MapSet.t(),
             cut_edges: [{any(), any()}]
           }}
          | {:error, :no_such_vertex | :negative_capacity}
  def min_cut(%Graph{} = g, source, sink, opts \\ []) do
    opts = Keyword.validate!(opts, algo: :dinic)
    run_fn = algo!(opts)

    with :ok <- validate(g, source, sink) do
      all_v = MapSet.new(Graph.vertices(g))

      if source == sink do
        {:ok,
         %{
           cut_value: 0,
           source_side: MapSet.new([source]),
           sink_side: MapSet.delete(all_v, source),
           cut_edges: []
         }}
      else
        caps = build_capacities(g)
        {residual, total} = run_full(caps, source, sink, run_fn)
        source_side = reachable(residual, source)
        sink_side = MapSet.difference(all_v, source_side)
        cut_edges = collect_cut_edges(caps, source_side, sink_side)

        {:ok,
         %{
           cut_value: total,
           source_side: source_side,
           sink_side: sink_side,
           cut_edges: cut_edges
         }}
      end
    end
  end

  # ── Validation ────────────────────────────────────────────────────────

  defp algo!(opts) do
    case Keyword.fetch!(opts, :algo) do
      :dinic ->
        &dinic_loop/3

      :edmonds_karp ->
        &edmonds_karp_loop/3

      other ->
        raise ArgumentError,
              "expected :algo to be :dinic or :edmonds_karp, got: #{inspect(other)}"
    end
  end

  defp validate(g, source, sink) do
    cond do
      not Graph.has_vertex?(g, source) -> {:error, :no_such_vertex}
      not Graph.has_vertex?(g, sink) -> {:error, :no_such_vertex}
      Args.negative_weight?(g) -> {:error, :negative_capacity}
      true -> :ok
    end
  end

  # ── Top-level orchestration ───────────────────────────────────────────

  defp run(_g, source, sink, _algo_fn) when source == sink do
    {:ok, %{flow: 0, flows: %{}}}
  end

  defp run(g, source, sink, algo_fn) do
    caps = build_capacities(g)
    {residual, total} = run_full(caps, source, sink, algo_fn)
    flows = derive_flows(caps, residual)
    {:ok, %{flow: total, flows: flows}}
  end

  defp run_full(caps, source, sink, algo_fn) do
    residual = build_residual(caps)
    algo_fn.(residual, source, sink)
  end

  # ── Capacity construction ─────────────────────────────────────────────

  # Build the *original* directed capacity map `%{u => %{v => cap}}`.
  # Parallel edges sum. Self-loops are dropped. For undirected graphs
  # each edge contributes capacity in both directions independently.
  defp build_capacities(%Graph{out_edges: out, type: type}) do
    Enum.reduce(out, %{}, fn {from, targets}, acc ->
      Enum.reduce(targets, acc, fn {to, edges}, acc2 ->
        if from == to do
          acc2
        else
          cap = Enum.reduce(edges, 0, fn e, s -> s + e.weight end)
          add_cap(acc2, from, to, cap, type)
        end
      end)
    end)
  end

  defp add_cap(map, from, to, cap, :directed) do
    bump(map, from, to, cap)
  end

  defp add_cap(map, from, to, cap, :undirected) do
    # `Graph.add_edge/4` on an undirected graph stores both directions
    # already (see Graph.add_edge), so we'd double-count if we manually
    # added the reverse here. The undirected semantics are therefore
    # automatically expressed: each undirected edge contributes `cap`
    # in each direction.
    bump(map, from, to, cap)
  end

  defp bump(map, from, to, cap) do
    Map.update(map, from, %{to => cap}, fn inner ->
      Map.update(inner, to, cap, &(&1 + cap))
    end)
  end

  # Build the residual capacity map: forward edges get their original
  # capacity, reverse edges get 0 (unless an explicit reverse forward
  # edge exists, in which case its capacity stands and the two pair up).
  defp build_residual(caps) do
    # Start with all forward capacities
    residual = caps

    # For every (u, v) in caps, ensure (v, u) has at least a 0 entry
    Enum.reduce(caps, residual, fn {u, inner}, acc ->
      Enum.reduce(inner, acc, fn {v, _cap}, acc2 ->
        Map.update(acc2, v, %{u => 0}, fn r ->
          Map.update(r, u, 0, & &1)
        end)
      end)
    end)
  end

  # ── Edmonds-Karp ──────────────────────────────────────────────────────

  defp edmonds_karp_loop(residual, source, sink) do
    do_ek(residual, source, sink, 0)
  end

  defp do_ek(residual, source, sink, total) do
    case bfs_augmenting_path(residual, source, sink) do
      nil ->
        {residual, total}

      path ->
        bottleneck = path_bottleneck(residual, path)
        residual = push_flow(residual, path, bottleneck)
        do_ek(residual, source, sink, total + bottleneck)
    end
  end

  # Standard BFS that follows edges with strictly positive residual.
  # Returns a list of vertices [source, ..., sink], or nil.
  defp bfs_augmenting_path(residual, source, sink) do
    queue = :queue.in(source, :queue.new())
    parents = %{source => :__root__}
    bfs_loop(residual, queue, parents, sink)
  end

  defp bfs_loop(residual, queue, parents, sink) do
    case :queue.out(queue) do
      {:empty, _} ->
        nil

      {{:value, u}, rest} ->
        if u == sink do
          rebuild_path(parents, sink)
        else
          {queue2, parents2} =
            residual
            |> Map.get(u, %{})
            |> Enum.reduce({rest, parents}, fn {v, cap}, {q, ps} ->
              if cap > 0 and not Map.has_key?(ps, v) do
                {:queue.in(v, q), Map.put(ps, v, u)}
              else
                {q, ps}
              end
            end)

          bfs_loop(residual, queue2, parents2, sink)
        end
    end
  end

  defp rebuild_path(parents, v), do: rebuild_path(parents, v, [])

  defp rebuild_path(_parents, :__root__, acc), do: acc

  defp rebuild_path(parents, v, acc) do
    case Map.fetch(parents, v) do
      :error -> acc
      {:ok, :__root__} -> [v | acc]
      {:ok, p} -> rebuild_path(parents, p, [v | acc])
    end
  end

  defp path_bottleneck(residual, [u, v | rest]) do
    cap = residual |> Map.fetch!(u) |> Map.fetch!(v)
    path_bottleneck_step(residual, v, rest, cap)
  end

  defp path_bottleneck_step(_residual, _u, [], min), do: min

  defp path_bottleneck_step(residual, u, [v | rest], min) do
    cap = residual |> Map.fetch!(u) |> Map.fetch!(v)
    path_bottleneck_step(residual, v, rest, Kernel.min(min, cap))
  end

  defp push_flow(residual, [_], _b), do: residual

  defp push_flow(residual, [u, v | rest], b) do
    residual
    |> update_in([u, v], &(&1 - b))
    |> update_in([v, u], &(&1 + b))
    |> push_flow([v | rest], b)
  end

  # ── Dinic's algorithm ─────────────────────────────────────────────────

  defp dinic_loop(residual, source, sink) do
    do_dinic(residual, source, sink, 0)
  end

  defp do_dinic(residual, source, sink, total) do
    case build_levels(residual, source, sink) do
      nil ->
        {residual, total}

      levels ->
        {residual, pushed} = blocking_flow(residual, source, sink, levels)
        do_dinic(residual, source, sink, total + pushed)
    end
  end

  # BFS from source, recording the distance (level) of every reachable
  # vertex along edges with positive residual. Returns the level map if
  # the sink is reachable, else nil.
  defp build_levels(residual, source, sink) do
    queue = :queue.in(source, :queue.new())
    levels = %{source => 0}
    levels = bfs_levels(residual, queue, levels, sink)

    if Map.has_key?(levels, sink), do: levels, else: nil
  end

  defp bfs_levels(residual, queue, levels, sink) do
    case :queue.out(queue) do
      {:empty, _} ->
        levels

      {{:value, u}, rest} ->
        # Early termination once sink discovered: we still need to drain
        # entries at the same level, but stopping here keeps the level
        # graph small without affecting correctness.
        if Map.has_key?(levels, sink) and Map.fetch!(levels, u) >= Map.fetch!(levels, sink) do
          levels
        else
          {queue2, levels2} =
            residual
            |> Map.get(u, %{})
            |> Enum.reduce({rest, levels}, fn {v, cap}, {q, ls} ->
              if cap > 0 and not Map.has_key?(ls, v) do
                {:queue.in(v, q), Map.put(ls, v, Map.fetch!(ls, u) + 1)}
              else
                {q, ls}
              end
            end)

          bfs_levels(residual, queue2, levels2, sink)
        end
    end
  end

  # Repeatedly DFS-push flow along level-respecting edges until no
  # source→sink augmenting path remains in the level graph. We track an
  # `iter` map of "next-neighbour-cursor lists" per vertex, which is
  # Dinic's classic trick for amortizing the DFS work.
  defp blocking_flow(residual, source, sink, levels) do
    # iter maps each vertex to the list of neighbours it has yet to try.
    iter =
      residual
      |> Map.new(fn {u, inner} -> {u, Map.keys(inner)} end)

    do_blocking(residual, source, sink, levels, iter, 0)
  end

  defp do_blocking(residual, source, sink, levels, iter, pushed) do
    case dfs_push(residual, source, sink, levels, iter, :infinity) do
      {:no_path, residual, iter} ->
        _ = iter
        {residual, pushed}

      {:pushed, delta, residual, iter} ->
        do_blocking(residual, source, sink, levels, iter, pushed + delta)
    end
  end

  # DFS from `u` toward `sink`, only following neighbours `v` such that
  # `levels[v] == levels[u] + 1` AND residual[u][v] > 0. Pushes the
  # bottleneck flow on the first path found. Returns either
  #   {:pushed, delta, residual', iter'}
  # or
  #   {:no_path, residual, iter'}
  # The iter map is *advanced* past dead-end neighbours so future DFS
  # calls don't retry them — this is what gives Dinic its O(V·E) per
  # blocking-flow bound.
  defp dfs_push(residual, u, sink, _levels, iter, flow_in) when u == sink do
    {:pushed, flow_in, residual, iter}
  end

  defp dfs_push(residual, u, sink, levels, iter, flow_in) do
    u_level = Map.fetch!(levels, u)
    neighbours = Map.get(iter, u, [])
    try_neighbours(residual, u, u_level, sink, levels, iter, flow_in, neighbours)
  end

  defp try_neighbours(residual, u, _u_level, _sink, _levels, iter, _flow_in, []) do
    {:no_path, residual, Map.put(iter, u, [])}
  end

  defp try_neighbours(residual, u, u_level, sink, levels, iter, flow_in, [v | rest]) do
    cap = residual |> Map.fetch!(u) |> Map.fetch!(v)
    v_level = Map.get(levels, v)

    if cap > 0 and v_level == u_level + 1 do
      bottleneck = Kernel.min(flow_in, cap)

      case dfs_push(residual, v, sink, levels, iter, bottleneck) do
        {:pushed, delta, residual2, iter2} ->
          residual3 =
            residual2
            |> update_in([u, v], &(&1 - delta))
            |> update_in([v, u], &(&1 + delta))

          # If this edge is now saturated drop it from u's iter list.
          iter3 =
            if get_in(residual3, [u, v]) == 0 do
              Map.put(iter2, u, rest)
            else
              # Keep `v` at the head so we may push more through it later.
              Map.put(iter2, u, [v | rest])
            end

          {:pushed, delta, residual3, iter3}

        {:no_path, residual2, iter2} ->
          # v led to a dead end at this level — skip it forever.
          iter3 = Map.put(iter2, u, rest)
          try_neighbours(residual2, u, u_level, sink, levels, iter3, flow_in, rest)
      end
    else
      # Wrong level or no residual capacity — skip.
      iter2 = Map.put(iter, u, rest)
      try_neighbours(residual, u, u_level, sink, levels, iter2, flow_in, rest)
    end
  end

  # ── Flow extraction ───────────────────────────────────────────────────

  # Net flow on original edge (u, v) = original_cap(u,v) - residual(u,v),
  # but clamped at the actual pushed amount on that direction. With paired
  # forward/reverse capacities the residual increase on the reverse edge
  # captures back-pushed flow. We report only positive net flows on edges
  # that exist in the original graph.
  defp derive_flows(caps, residual) do
    for {u, inner} <- caps,
        {v, cap} <- inner,
        flow = cap - Map.fetch!(Map.fetch!(residual, u), v),
        flow > 0,
        into: %{} do
      {{u, v}, flow}
    end
  end

  # ── Min-cut helpers ───────────────────────────────────────────────────

  defp reachable(residual, source) do
    queue = :queue.in(source, :queue.new())
    do_reachable(residual, queue, MapSet.new([source]))
  end

  defp do_reachable(residual, queue, visited) do
    case :queue.out(queue) do
      {:empty, _} ->
        visited

      {{:value, u}, rest} ->
        {queue2, visited2} =
          residual
          |> Map.get(u, %{})
          |> Enum.reduce({rest, visited}, fn {v, cap}, {q, vs} ->
            if cap > 0 and not MapSet.member?(vs, v) do
              {:queue.in(v, q), MapSet.put(vs, v)}
            else
              {q, vs}
            end
          end)

        do_reachable(residual, queue2, visited2)
    end
  end

  defp collect_cut_edges(caps, source_side, sink_side) do
    for {u, inner} <- caps,
        MapSet.member?(source_side, u),
        {v, cap} <- inner,
        cap > 0,
        MapSet.member?(sink_side, v) do
      {u, v}
    end
  end
end
