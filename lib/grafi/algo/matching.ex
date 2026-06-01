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

  Hopcroft–Karp requires the caller to supply the *left* side of the
  bipartition explicitly. If `Grafi.Algo.Bipartite.bipartite?/1` is
  available, the graph is sanity-checked against it; otherwise, callers
  are responsible for ensuring bipartiteness.
  """

  alias Grafi.Graph

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
  def hopcroft_karp(%Graph{} = g, left_side, _opts \\ []) do
    left_set =
      if is_struct(left_side, MapSet),
        do: left_side,
        else: MapSet.new(left_side)

    with :ok <- maybe_check_bipartite(g) do
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

      {pair_l, pair_r} = run_hk(lefts, adj)

      matching =
        pair_l
        |> Enum.reduce(%{}, fn {l, r}, acc -> Map.put(acc, l, r) end)
        |> then(fn m ->
          Enum.reduce(pair_r, m, fn {r, l}, acc -> Map.put(acc, r, l) end)
        end)

      {:ok, %{matching: matching, size: map_size(pair_l)}}
    end
  end

  defp maybe_check_bipartite(g) do
    if Code.ensure_loaded?(Grafi.Algo.Bipartite) and
         function_exported?(Grafi.Algo.Bipartite, :bipartite?, 1) do
      if Grafi.Algo.Bipartite.bipartite?(g),
        do: :ok,
        else: {:error, :not_bipartite}
    else
      :ok
    end
  end

  # Main HK loop: alternate layered BFS + DFS augmentation until BFS can
  # no longer reach an unmatched right vertex.
  defp run_hk(lefts, adj) do
    do_hk(lefts, adj, %{}, %{})
  end

  defp do_hk(lefts, adj, pair_l, pair_r) do
    case hk_bfs(lefts, adj, pair_l, pair_r) do
      :done ->
        {pair_l, pair_r}

      {:ok, dist} ->
        {pair_l, pair_r, _dist} =
          Enum.reduce(lefts, {pair_l, pair_r, dist}, fn l, {pl, pr, d} ->
            if Map.has_key?(pl, l) do
              {pl, pr, d}
            else
              case hk_dfs(l, adj, pl, pr, d) do
                {:ok, pl2, pr2, d2} -> {pl2, pr2, d2}
                {:fail, d2} -> {pl, pr, d2}
              end
            end
          end)

        do_hk(lefts, adj, pair_l, pair_r)
    end
  end

  # Layered BFS from all currently unmatched left vertices. Returns
  # `{:ok, dist}` if an augmenting path was discovered (so DFS should
  # follow), or `:done` if no unmatched right vertex is reachable (the
  # current matching is maximum).
  defp hk_bfs(lefts, adj, pair_l, pair_r) do
    {dist, queue} =
      Enum.reduce(lefts, {%{}, :queue.new()}, fn l, {d, q} ->
        if Map.has_key?(pair_l, l) do
          {Map.put(d, l, :inf), q}
        else
          {Map.put(d, l, 0), :queue.in(l, q)}
        end
      end)

    case hk_bfs_loop(queue, dist, adj, pair_r, false) do
      {false, _dist} -> :done
      {true, dist} -> {:ok, dist}
    end
  end

  defp hk_bfs_loop(queue, dist, adj, pair_r, found) do
    case :queue.out(queue) do
      {:empty, _} ->
        {found, dist}

      {{:value, u}, rest} ->
        du = Map.fetch!(dist, u)

        {dist, queue, found} =
          Enum.reduce(Map.get(adj, u, []), {dist, rest, found}, fn v, {d, q, f} ->
            case Map.get(pair_r, v) do
              nil ->
                # Unmatched right vertex reached: augmenting path exists.
                {d, q, true}

              next_l ->
                if Map.get(d, next_l, :inf) == :inf do
                  {Map.put(d, next_l, du + 1), :queue.in(next_l, q), f}
                else
                  {d, q, f}
                end
            end
          end)

        hk_bfs_loop(queue, dist, adj, pair_r, found)
    end
  end

  # DFS along the layered graph from a left vertex `u`. Steps from `u`
  # to a right neighbour `v`, then (if v is matched) recurses on
  # `pair_r[v]` only if it sits in the next BFS layer.
  defp hk_dfs(u, adj, pair_l, pair_r, dist) do
    do_hk_dfs(Map.get(adj, u, []), u, adj, pair_l, pair_r, dist)
  end

  defp do_hk_dfs([], u, _adj, _pair_l, _pair_r, dist) do
    {:fail, Map.put(dist, u, :inf)}
  end

  defp do_hk_dfs([v | rest], u, adj, pair_l, pair_r, dist) do
    case Map.get(pair_r, v) do
      nil ->
        {:ok, Map.put(pair_l, u, v), Map.put(pair_r, v, u), dist}

      next_l ->
        if Map.get(dist, next_l, :inf) == Map.fetch!(dist, u) + 1 do
          case hk_dfs(next_l, adj, pair_l, pair_r, dist) do
            {:ok, pl, pr, d2} ->
              {:ok, Map.put(pl, u, v), Map.put(pr, v, u), d2}

            {:fail, d2} ->
              do_hk_dfs(rest, u, adj, pair_l, pair_r, d2)
          end
        else
          do_hk_dfs(rest, u, adj, pair_l, pair_r, dist)
        end
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
  def hungarian(cost_matrix, opts \\ [])

  def hungarian([], _opts), do: {:ok, %{assignment: [], cost: 0, unmatched: []}}

  def hungarian(cost_matrix, opts) when is_list(cost_matrix) do
    maximize? = Keyword.get(opts, :maximize, false)
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
  # All arrays are 1-indexed tuples of size `n + 1` (index 0 is a
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

  defp jv_solve(n, c) do
    # Pre-fill all tuples to size n+1 with zeros / sentinels.
    init = List.duplicate(0, n + 1) |> List.to_tuple()
    u = init
    v = init
    p = init

    Enum.reduce(1..n, %{u: u, v: v, p: p}, fn i, %{u: u, v: v, p: p} ->
      jv_assign_row(i, n, c, u, v, p)
    end)
  end

  # Augment row `i` into the assignment.
  defp jv_assign_row(i, n, c, u, v, p) do
    # p[0] = i: column 0 is the "phantom" matched to row i so the search
    # can start from j0 = 0.
    p = put_elem(p, 0, i)

    # minv[j] = min reduced cost reachable to column j so far.
    # way[j] = previous column on the alternating tree path to column j.
    # used[j] = whether column j has been pulled into the tree.
    minv = List.duplicate(@inf, n + 1) |> List.to_tuple()
    way = List.duplicate(0, n + 1) |> List.to_tuple()
    used = List.duplicate(false, n + 1) |> List.to_tuple()

    {u, v, p, way, j_end} = jv_loop(0, n, c, u, v, p, way, minv, used)

    # Augment along `way` from j_end back to 0.
    p = jv_augment(j_end, p, way)
    %{u: u, v: v, p: p}
  end

  # Outer loop: each iteration picks the column j0 currently being
  # processed (initially 0 = phantom), expands all not-yet-used columns,
  # updates potentials by delta, and either terminates (if j1 points to
  # an unassigned column) or continues with j0 := j1.
  defp jv_loop(j0, n, c, u, v, p, way, minv, used) do
    used = put_elem(used, j0, true)
    i0 = elem(p, j0)

    {minv, way, delta, j1} =
      jv_scan(1, n, i0, j0, c, u, v, used, minv, way, @inf, 0)

    {u, v} = jv_update_potentials(0, n, used, p, u, v, delta)
    minv = jv_decrement_minv(0, n, used, minv, delta)

    if elem(p, j1) == 0 do
      {u, v, p, way, j1}
    else
      jv_loop(j1, n, c, u, v, p, way, minv, used)
    end
  end

  # For each unused column j, compute reduced cost from row i0 and
  # update minv[j] / way[j]; track the smallest minv and its column.
  defp jv_scan(j, n, _i0, _j0, _c, _u, _v, _used, minv, way, delta, j1) when j > n,
    do: {minv, way, delta, j1}

  defp jv_scan(j, n, i0, j0, c, u, v, used, minv, way, delta, j1) do
    if elem(used, j) do
      jv_scan(j + 1, n, i0, j0, c, u, v, used, minv, way, delta, j1)
    else
      cij = c |> elem(i0 - 1) |> elem(j - 1)
      cur = cij - elem(u, i0) - elem(v, j)

      {minv, way} =
        if cur < elem(minv, j) do
          {put_elem(minv, j, cur), put_elem(way, j, j0)}
        else
          {minv, way}
        end

      mj2 = elem(minv, j)

      {delta, j1} =
        if mj2 < delta do
          {mj2, j}
        else
          {delta, j1}
        end

      jv_scan(j + 1, n, i0, j0, c, u, v, used, minv, way, delta, j1)
    end
  end

  # Potential update: for every column j (0..n):
  #   if used[j]:   u[p[j]] += delta;   v[j] -= delta
  #   else:         (handled by jv_decrement_minv on minv)
  defp jv_update_potentials(j, n, _used, _p, u, v, _delta) when j > n, do: {u, v}

  defp jv_update_potentials(j, n, used, p, u, v, delta) do
    {u, v} =
      if elem(used, j) do
        i = elem(p, j)
        u = put_elem(u, i, elem(u, i) + delta)
        v = put_elem(v, j, elem(v, j) - delta)
        {u, v}
      else
        {u, v}
      end

    jv_update_potentials(j + 1, n, used, p, u, v, delta)
  end

  # For unused columns, decrement minv by delta (so future reduced-cost
  # comparisons remain valid).
  defp jv_decrement_minv(j, n, _used, minv, _delta) when j > n, do: minv

  defp jv_decrement_minv(j, n, used, minv, delta) do
    minv =
      if elem(used, j) do
        minv
      else
        put_elem(minv, j, elem(minv, j) - delta)
      end

    jv_decrement_minv(j + 1, n, used, minv, delta)
  end

  defp jv_augment(j1, p, way) do
    if j1 == 0 do
      p
    else
      j_prev = elem(way, j1)
      i_prev = elem(p, j_prev)
      p = put_elem(p, j1, i_prev)
      jv_augment(j_prev, p, way)
    end
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

    * `:maximize` — defaults to `true` (matchings on weighted graphs
      typically maximise total weight).

  ## Examples

      iex> g = Grafi.Graph.new(type: :undirected)
      ...>     |> Grafi.Graph.add_edges([{:l1, :r1, weight: 5.0},
      ...>                               {:l1, :r2, weight: 1.0},
      ...>                               {:l2, :r2, weight: 4.0}])
      iex> {:ok, %{matching: m}} = Grafi.Algo.Matching.weighted_bipartite_matching(g, [:l1, :l2])
      iex> {Map.get(m, :l1), Map.get(m, :l2)}
      {:r1, :r2}
  """
  @spec weighted_bipartite_matching(Graph.t(), [any()] | MapSet.t(), keyword()) ::
          {:ok, %{matching: %{any() => any()}, weight: number()}}
          | {:error, :not_bipartite}
  def weighted_bipartite_matching(%Graph{} = g, left_side, opts \\ []) do
    maximize? = Keyword.get(opts, :maximize, true)

    left_set =
      if is_struct(left_side, MapSet),
        do: left_side,
        else: MapSet.new(left_side)

    with :ok <- maybe_check_bipartite(g) do
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
            neigh_weights = right_weights(g, l, left_set)

            Enum.map(rights, fn r ->
              Map.get(neigh_weights, r, sentinel)
            end)
          end)

        {:ok, %{assignment: assignment}} = hungarian(cost_matrix, maximize: maximize?)

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

  defp right_weights(g, l, left_set) do
    out_w =
      g.out_edges
      |> Map.get(l, %{})
      |> Enum.reject(fn {to, _} -> MapSet.member?(left_set, to) end)
      |> Enum.map(fn {to, edges} ->
        {to, edges |> Enum.map(& &1.weight) |> Enum.max(fn -> 0.0 end)}
      end)
      |> Map.new()

    in_w =
      g.in_edges
      |> Map.get(l, %{})
      |> Enum.reject(fn {from, _} -> MapSet.member?(left_set, from) end)
      |> Enum.map(fn {from, edges} ->
        {from, edges |> Enum.map(& &1.weight) |> Enum.max(fn -> 0.0 end)}
      end)
      |> Map.new()

    Map.merge(out_w, in_w, fn _k, a, b -> max(a, b) end)
  end
end
