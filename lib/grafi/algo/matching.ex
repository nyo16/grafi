defmodule Grafi.Algo.Matching do
  @moduledoc """
  Bipartite matching algorithms.

  This module provides two complementary algorithms for matching on a
  bipartite graph `G = (L ∪ R, E)`:

  * `hopcroft_karp/3` — maximum **cardinality** matching in `O(E · √V)`
    using the classical Hopcroft–Karp alternating-BFS/DFS scheme.

  * `hungarian/2` — minimum-cost (or maximum-cost) **weighted** matching
    on a cost matrix in `O(n³)` using the Kuhn–Munkres / Jonker–Volgenant
    style algorithm with potentials and slack arrays.

  * `weighted_bipartite_matching/3` — convenience wrapper that builds a
    cost matrix from the edge weights of a bipartite `Grafi.Graph` and
    dispatches to `hungarian/2`.

  ## Bipartition responsibility

  `hopcroft_karp/3` and `weighted_bipartite_matching/3` take the *left*
  side of the bipartition from the caller, and return
  `{:error, :not_bipartite}` when `Grafi.Algo.Bipartite.bipartite?/1`
  rejects the graph.
  """

  alias Grafi.{Args, Graph}

  # Sentinel "infinity" used to pad rectangular cost matrices in
  # `hungarian/2` and to represent missing edges in
  # `weighted_bipartite_matching/3`. Sized so that 2·INF still fits in a
  # double-precision float without overflow.
  @inf 1.0e15

  # ── Hopcroft–Karp (maximum cardinality) ──────────────────────────────

  @doc """
  Maximum-cardinality bipartite matching via the Hopcroft–Karp algorithm.

  `left_side` is the list (or `MapSet`) of vertices that constitute one
  side of the bipartition; every other vertex in the graph is treated
  as belonging to the right side. For undirected graphs we read
  adjacency from `Grafi.Graph.out_neighbors/2`; for directed graphs we
  consider both out- and in-neighbors so that edge direction is
  irrelevant.

  Returns `{:ok, %{matching: m, size: k}}` where `m` is the
  **bidirectional** matching — every matched pair `(l, r)` appears twice
  as `m[l] = r` and `m[r] = l` for O(1) lookup from either side — and
  `k` is the number of matched pairs. If `Grafi.Algo.Bipartite` reports
  the graph as not bipartite, returns `{:error, :not_bipartite}`.

  Complexity: `O(E · √V)`.

  ## Examples

      iex> g = Grafi.Graph.new(type: :undirected)
      ...>     |> Grafi.Graph.add_edges([{:l1, :r1}, {:l1, :r2}, {:l2, :r2}])
      iex> {:ok, %{size: k}} = Grafi.Algo.Matching.hopcroft_karp(g, [:l1, :l2])
      iex> k
      2
  """
  @spec hopcroft_karp(Graph.t(), [any()] | MapSet.t(), keyword()) ::
          {:ok, %{matching: %{any() => any()}, size: non_neg_integer()}}
          | {:error, :not_bipartite}
  def hopcroft_karp(%Graph{} = g, left_side, opts \\ []) do
    _ = Keyword.validate!(opts, [])

    left_set =
      if is_struct(left_side, MapSet),
        do: left_side,
        else: MapSet.new(left_side)

    with :ok <- check_bipartite(g) do
      lefts = left_set |> Enum.filter(&Graph.has_vertex?(g, &1))

      adj =
        Map.new(lefts, fn l ->
          neigh =
            case g.type do
              :undirected ->
                Graph.out_neighbors(g, l)

              :directed ->
                Enum.uniq(Graph.out_neighbors(g, l) ++ Graph.in_neighbors(g, l))
            end

          {l, Enum.reject(neigh, &MapSet.member?(left_set, &1))}
        end)

      {pair_l, pair_r} = do_hk(lefts, adj, %{}, %{})

      {:ok, %{matching: Map.merge(pair_l, pair_r), size: map_size(pair_l)}}
    end
  end

  defp check_bipartite(g) do
    if Grafi.Algo.Bipartite.bipartite?(g), do: :ok, else: {:error, :not_bipartite}
  end

  # Main HK loop over the still-free left vertices. Each phase layers the
  # graph by BFS from them, up to the first layer `limit` that touches a
  # free right vertex, then augments along vertex-disjoint shortest
  # augmenting paths by DFS. Stops when the BFS reaches no free right
  # vertex.
  defp do_hk(free, adj, pair_l, pair_r) do
    case hk_bfs(free, adj, pair_r) do
      :done ->
        {pair_l, pair_r}

      {:ok, dist, limit} ->
        {still_free, pair_l, pair_r, _dist} =
          Enum.reduce(free, {[], pair_l, pair_r, dist}, fn l, {fr, pl, pr, d} ->
            case hk_dfs(l, 0, adj, pl, pr, d, limit) do
              {:ok, pl2, pr2, d2} -> {fr, pl2, pr2, d2}
              {:fail, d2} -> {[l | fr], pl, pr, d2}
            end
          end)

        do_hk(:lists.reverse(still_free), adj, pair_l, pair_r)
    end
  end

  # Layered BFS from the free left vertices (layer 0). `dist` maps each
  # reached left vertex to its layer. Halts as soon as a layer-`limit`
  # vertex has a free right neighbour and returns `{:ok, dist, limit}`:
  # every shortest augmenting path ends there, so deeper layers are never
  # needed. Returns `:done` if no free right vertex is reachable (the
  # matching is maximum).
  defp hk_bfs(free, adj, pair_r) do
    dist = Map.new(free, &{&1, 0})
    hk_bfs_loop(:queue.from_list(free), dist, adj, pair_r)
  end

  defp hk_bfs_loop(queue, dist, adj, pair_r) do
    case :queue.out(queue) do
      {:empty, _} ->
        :done

      {{:value, u}, rest} ->
        du = Map.fetch!(dist, u)

        case hk_expand(Map.get(adj, u, []), du + 1, dist, rest, pair_r) do
          :free -> {:ok, dist, du}
          {dist, queue} -> hk_bfs_loop(queue, dist, adj, pair_r)
        end
    end
  end

  defp hk_expand([], _next, dist, queue, _pair_r), do: {dist, queue}

  defp hk_expand([v | rest], next, dist, queue, pair_r) do
    case Map.get(pair_r, v) do
      nil ->
        :free

      l when is_map_key(dist, l) ->
        hk_expand(rest, next, dist, queue, pair_r)

      l ->
        hk_expand(rest, next, Map.put(dist, l, next), :queue.in(l, queue), pair_r)
    end
  end

  # DFS from the left vertex `u` (on layer `du`) along the layered graph:
  # to a free right neighbour if `u` is on the last layer, else through a
  # matched right neighbour `v` to `pair_r[v]` on layer `du + 1`. A vertex
  # with no augmenting path is dropped from `dist`, so no later DFS in the
  # phase revisits it.
  defp hk_dfs(u, du, adj, pair_l, pair_r, dist, limit) do
    do_hk_dfs(Map.get(adj, u, []), u, du, adj, pair_l, pair_r, dist, limit)
  end

  defp do_hk_dfs([], u, _du, _adj, _pair_l, _pair_r, dist, _limit) do
    {:fail, Map.delete(dist, u)}
  end

  defp do_hk_dfs([v | rest], u, du, adj, pair_l, pair_r, dist, limit) do
    case Map.get(pair_r, v) do
      nil when du == limit ->
        {:ok, Map.put(pair_l, u, v), Map.put(pair_r, v, u), dist}

      next_l when next_l != nil and du < limit and :erlang.map_get(next_l, dist) == du + 1 ->
        case hk_dfs(next_l, du + 1, adj, pair_l, pair_r, dist, limit) do
          {:ok, pl, pr, d2} ->
            {:ok, Map.put(pl, u, v), Map.put(pr, v, u), d2}

          {:fail, d2} ->
            do_hk_dfs(rest, u, du, adj, pair_l, pair_r, d2, limit)
        end

      _ ->
        do_hk_dfs(rest, u, du, adj, pair_l, pair_r, dist, limit)
    end
  end

  # ── Hungarian (minimum-cost weighted matching) ───────────────────────

  @doc """
  Solves the assignment problem on a cost matrix in `O(n³)`.

  `cost_matrix` is a list-of-lists with `n` rows (left vertices) and
  `m` columns (right vertices). The matrix may be rectangular: it is
  internally padded with a sentinel `#{inspect(@inf)}` cost to make
  it square, and any left vertex whose optimal column lands on a
  padding column is reported as unmatched.

  Returns `{:ok, %{assignment: a, cost: c, unmatched: u}}` where
  `a[i]` is the right index assigned to left index `i` (or `nil` if
  unmatched), `c` is the total cost over **real** (non-padded) pairs,
  and `u` is the list of left indices that received no real
  assignment.

  ## Options

    * `:maximize` — if `true`, internally negate costs to maximise the
      total. Defaults to `false`.

  Implementation follows the standard `O(n³)` Kuhn–Munkres / Jonker–
  Volgenant algorithm with row/column potentials and a Dijkstra-style
  inner loop (see Jonker & Volgenant, 1987, "A shortest augmenting
  path algorithm for dense and sparse linear assignment problems";
  also Kuhn, 1955).

  ## Examples

      iex> m = [[1, 2, 3], [4, 5, 6], [7, 8, 9]]
      iex> {:ok, %{assignment: a, cost: c}} = Grafi.Algo.Matching.hungarian(m)
      iex> {a, c}
      {[0, 1, 2], 15}
  """
  @spec hungarian([[number()]], keyword()) ::
          {:ok, %{assignment: [non_neg_integer() | nil], cost: number(), unmatched: [integer()]}}
  def hungarian(cost_matrix, opts \\ []) when is_list(cost_matrix) do
    opts = Keyword.validate!(opts, maximize: false)
    maximize? = Args.boolean!(opts, :maximize, false)
    solve_assignment(cost_matrix, maximize?)
  end

  defp solve_assignment([], _maximize?), do: {:ok, %{assignment: [], cost: 0, unmatched: []}}

  defp solve_assignment(cost_matrix, maximize?) do
    n_rows = length(cost_matrix)
    n_cols = cost_matrix |> hd() |> length()
    n = max(n_rows, n_cols)

    # Optionally negate for maximisation, then pad to square.
    raw =
      Enum.map(cost_matrix, fn row ->
        Enum.map(row, fn c -> if maximize?, do: -c, else: c end)
      end)

    cost_sq = pad_matrix(raw, n_rows, n_cols, n, @inf)

    # Tuple-of-tuples for O(1) random access. 0-indexed.
    c = cost_sq |> Enum.map(&List.to_tuple/1) |> List.to_tuple()

    # Run the Jonker–Volgenant inner solver.
    %{p: p_assigned} = jv_solve(n, c)

    # `p_assigned[j] = i` ⇒ column j is assigned to row i (1-indexed).
    # Invert to obtain assignment by row.
    row_assignment =
      Enum.reduce(1..n, %{}, fn j, acc ->
        i = elem(p_assigned, j)
        if i == 0, do: acc, else: Map.put(acc, i, j)
      end)

    # Tuple-of-tuples of the original (unpadded) costs for O(1) lookup while
    # trimming — avoids an O(n²) Enum.at/Enum.at per assigned row.
    orig_costs = cost_matrix |> Enum.map(&List.to_tuple/1) |> List.to_tuple()

    # Trim to original row count and mask padding columns as nil.
    {assignment, cost_sum, unmatched} =
      Enum.reduce(0..(n_rows - 1), {[], 0, []}, fn i, {as, sum, un} ->
        j1 = Map.get(row_assignment, i + 1, 0)
        j = j1 - 1

        if j < 0 or j >= n_cols do
          {[nil | as], sum, [i | un]}
        else
          orig = orig_costs |> elem(i) |> elem(j)
          {[j | as], sum + orig, un}
        end
      end)

    {:ok,
     %{
       assignment: Enum.reverse(assignment),
       cost: cost_sum,
       unmatched: Enum.reverse(unmatched)
     }}
  end

  defp pad_matrix(rows, n_rows, n_cols, n, pad) do
    extra_cols = n - n_cols
    pad_row_extra = List.duplicate(pad, extra_cols)

    padded_rows = Enum.map(rows, fn row -> row ++ pad_row_extra end)

    extra_rows_needed = n - n_rows
    extra_row = List.duplicate(pad, n)
    padded_rows ++ List.duplicate(extra_row, extra_rows_needed)
  end

  # ── Jonker–Volgenant inner solver ────────────────────────────────────
  #
  # `u`, `v` and `p` are 1-indexed tuples of size `n + 1` (index 0 is a
  # sentinel "row 0 / col 0" slot used by the algorithm). Cost matrix
  # `c` is 0-indexed (size n×n).
  #
  # Variables follow the classical reference at
  # https://cp-algorithms.com/graph/hungarian-algorithm.html :
  #
  #   u[i] - row potential (row 1..n)
  #   v[j] - column potential (col 1..n)
  #   p[j] - row currently assigned to column j (0 means unassigned)
  #   way[j] - in the alternating tree, the column we came from to reach j
  #
  # `put_elem/3` copies the whole tuple, so the reference's in-place
  # updates of `minv`, `way`, `u` and `v` would cost O(n) each, O(n²) per
  # scan and O(n⁴) overall. Instead, while one row is being inserted:
  #
  #   * the columns not yet in the alternating tree are a list of
  #     `{j, minv[j] + d, way[j]}`, rebuilt by each scan in one pass, where
  #     `d` is the sum of the deltas so far. Storing `minv + d` makes the
  #     reference's "minv[j] -= delta for every free column" a no-op;
  #   * the columns in the tree are a list of `{j, way[j], d_when_added}`;
  #   * `u` and `v` change only once, when the row is done: a tree column
  #     added when the delta sum was `d_j` has v[j] -= d - d_j and
  #     u[p[j]] += d - d_j. A scan only reads u[p[j0]] for the column j0
  #     just added and v[j] for free columns, which are not updated yet.
  #
  # A scan is O(n) and a row needs at most n scans, so the solver is O(n³).

  defp jv_solve(n, c) do
    init = :erlang.make_tuple(n + 1, 0)

    Enum.reduce(1..n, %{u: init, v: init, p: init}, fn i, %{u: u, v: v, p: p} ->
      jv_assign_row(i, n, c, u, v, p)
    end)
  end

  # Augment row `i` into the assignment.
  defp jv_assign_row(i, n, c, u, v, p) do
    # p[0] = i: column 0 is the "phantom" matched to row i so the search
    # can start from j0 = 0.
    p = put_elem(p, 0, i)
    free = for j <- 1..n, do: {j, @inf, 0}

    {tree, j_end, way_end, d} = jv_grow(0, 0, free, [], 0, c, u, v, p)

    shifts = for {j, _way, d_j} <- tree, do: {j, d - d_j}
    v = jv_add(v, :erlang.make_tuple(n + 1, 0, for({j, s} <- shifts, do: {j + 1, -s})))
    u = jv_add(u, :erlang.make_tuple(n + 1, 0, for({j, s} <- shifts, do: {elem(p, j) + 1, s})))

    # Augment along `way` from j_end back to 0.
    way = Map.new(tree, fn {j, w, _d_j} -> {j, w} end)
    p = jv_augment(j_end, way_end, p, way)
    %{u: u, v: v, p: p}
  end

  # One iteration: add column j0 (reached from `way_j0`) to the tree, scan
  # row p[j0] against the free columns, and either stop at the closest
  # free column j1 if it is unassigned, or continue from it.
  defp jv_grow(j0, way_j0, free, tree, d, c, u, v, p) do
    tree = [{j0, way_j0, d} | tree]
    i0 = elem(p, j0)

    {free, d, j1, way_j1} =
      jv_scan(free, j0, elem(c, i0 - 1), elem(u, i0), v, d, [], :none, 0, 0)

    if elem(p, j1) == 0 do
      {tree, j1, way_j1, d}
    else
      jv_grow(j1, way_j1, free, tree, d, c, u, v, p)
    end
  end

  # Drops j0 from the free list, lowers each free column's minv to its
  # reduced cost from row i0 (recording way[j] = j0), and finds the free
  # column j1 with the smallest minv (the first one on ties, as in the
  # reference). Returns the new list and `d + delta`, which is j1's stored
  # value. `:none` compares greater than every number.
  defp jv_scan([], _j0, _row, _ui0, _v, _d, acc, best, j1, way_j1),
    do: {:lists.reverse(acc), best, j1, way_j1}

  defp jv_scan([{j0, _, _} | rest], j0, row, ui0, v, d, acc, best, j1, way_j1),
    do: jv_scan(rest, j0, row, ui0, v, d, acc, best, j1, way_j1)

  defp jv_scan([{j, stored, way_j} | rest], j0, row, ui0, v, d, acc, best, j1, way_j1) do
    cur = elem(row, j - 1) - ui0 - elem(v, j) + d
    {stored, way_j} = if cur < stored, do: {cur, j0}, else: {stored, way_j}
    acc = [{j, stored, way_j} | acc]

    if stored < best,
      do: jv_scan(rest, j0, row, ui0, v, d, acc, stored, j, way_j),
      else: jv_scan(rest, j0, row, ui0, v, d, acc, best, j1, way_j1)
  end

  # Element-wise sum of two equal-size tuples.
  defp jv_add(a, b) do
    for(i <- 0..(tuple_size(a) - 1), do: elem(a, i) + elem(b, i)) |> List.to_tuple()
  end

  defp jv_augment(0, _way_j, p, _way), do: p

  defp jv_augment(j1, j_prev, p, way) do
    p = put_elem(p, j1, elem(p, j_prev))
    jv_augment(j_prev, Map.fetch!(way, j_prev), p, way)
  end

  # ── Weighted bipartite matching on a graph ───────────────────────────

  @doc """
  Maximum-weight (or minimum-weight) bipartite matching on a weighted
  `Grafi.Graph`.

  Extracts a cost matrix from the edge weights and dispatches to
  `hungarian/2`. The right side is taken to be all vertices not in
  `left_side`; both sides are sorted in canonical Erlang term order
  to produce a deterministic column / row ordering.

  Missing edges receive a sentinel cost of `#{inspect(@inf)}` for
  minimisation, or `-#{inspect(@inf)}` for maximisation, so the
  solver naturally avoids them when better real alternatives exist.
  Pairs ultimately matched to a sentinel cell are dropped from the
  returned matching.

  Returns `{:ok, %{matching: m, weight: w}}` where `m` maps each
  matched left vertex to its matched right vertex (one direction
  only) and `w` is the sum of real edge weights over matched pairs.

  ## Options

    * `:maximize` — if `true`, maximise the total weight. Defaults to
      `false` (minimise, as in `hungarian/2`). Between parallel edges, the
      lightest one counts when minimising and the heaviest when
      maximising.

  ## Examples

      iex> g = Grafi.Graph.new(type: :undirected)
      ...>     |> Grafi.Graph.add_edges([{:l1, :r1, weight: 5.0},
      ...>                               {:l1, :r2, weight: 1.0},
      ...>                               {:l2, :r1, weight: 2.0},
      ...>                               {:l2, :r2, weight: 4.0}])
      iex> {:ok, %{matching: min}} = Grafi.Algo.Matching.weighted_bipartite_matching(g, [:l1, :l2])
      iex> {min[:l1], min[:l2]}
      {:r2, :r1}
      iex> {:ok, %{matching: max}} =
      ...>   Grafi.Algo.Matching.weighted_bipartite_matching(g, [:l1, :l2], maximize: true)
      iex> {max[:l1], max[:l2]}
      {:r1, :r2}
  """
  @spec weighted_bipartite_matching(Graph.t(), [any()] | MapSet.t(), keyword()) ::
          {:ok, %{matching: %{any() => any()}, weight: number()}}
          | {:error, :not_bipartite}
  def weighted_bipartite_matching(%Graph{} = g, left_side, opts \\ []) do
    opts = Keyword.validate!(opts, maximize: false)
    maximize? = Args.boolean!(opts, :maximize, false)

    left_set =
      if is_struct(left_side, MapSet),
        do: left_side,
        else: MapSet.new(left_side)

    with :ok <- check_bipartite(g) do
      lefts =
        left_set
        |> Enum.filter(&Graph.has_vertex?(g, &1))
        |> Enum.sort()

      rights =
        Graph.vertices(g)
        |> Enum.reject(&MapSet.member?(left_set, &1))
        |> Enum.sort()

      sentinel = if maximize?, do: -@inf, else: @inf

      if lefts == [] or rights == [] do
        {:ok, %{matching: %{}, weight: 0.0}}
      else
        cost_matrix =
          Enum.map(lefts, fn l ->
            neigh_weights = right_weights(g, l, left_set, maximize?)

            Enum.map(rights, fn r ->
              Map.get(neigh_weights, r, sentinel)
            end)
          end)

        {:ok, %{assignment: assignment}} = solve_assignment(cost_matrix, maximize?)

        # Tuples for O(1) indexed access inside the reduce below.
        lefts_t = List.to_tuple(lefts)
        rights_t = List.to_tuple(rights)
        costs_t = cost_matrix |> Enum.map(&List.to_tuple/1) |> List.to_tuple()

        {matching, weight} =
          assignment
          |> Enum.with_index()
          |> Enum.reduce({%{}, 0.0}, fn
            {nil, _i}, acc ->
              acc

            {j, i}, {m, w} ->
              l = elem(lefts_t, i)
              r = elem(rights_t, j)
              wt = costs_t |> elem(i) |> elem(j)

              if wt == sentinel do
                {m, w}
              else
                {Map.put(m, l, r), w + wt}
              end
          end)

        {:ok, %{matching: matching, weight: weight}}
      end
    end
  end

  # Weight of the edge from `l` to each right neighbour: the heaviest
  # parallel edge when maximising, the lightest when minimising.
  defp right_weights(g, l, left_set, maximize?) do
    pick = if maximize?, do: &max/2, else: &min/2

    for adjacent <- [g.out_edges, g.in_edges],
        {r, edges} <- Map.get(adjacent, l, %{}),
        not MapSet.member?(left_set, r),
        e <- edges,
        reduce: %{} do
      acc -> Map.update(acc, r, e.weight, &pick.(&1, e.weight))
    end
  end
end
