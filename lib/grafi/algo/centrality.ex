defmodule Grafi.Algo.Centrality do
  @moduledoc """
  Centrality measures: PageRank, betweenness, closeness, degree, and more.

  PageRank, betweenness and closeness accept `engine: :auto | :nif | :elixir`
  (see `Grafi.NIF`). With `:auto`, graphs above the configured
  `:nif_threshold` vertices dispatch to igraph; smaller graphs run in pure
  Elixir. They raise `Grafi.NIFError` if the NIF fails or `engine: :nif` is
  unavailable.

  Every function raises `ArgumentError` on an unknown or invalid option.

  ## Edge weights

  | Function | How weights are used | `:weighted` option |
  |---|---|---|
  | `pagerank/2` | always: transition probability ∝ weight | none |
  | `closeness/2` | always: weight is path length | none |
  | `betweenness/2` | weight is path length | default `false` |
  | `harmonic/2` | weight is path length | default `false` |
  | `eigenvector/2` | adjacency entry is the summed weight | default `true` if any edge weight is not `1.0`, else `false` |
  | `hits/2`, `katz/2`, `degree_centrality/1` | ignored | none |

  Whenever weights are used, a negative edge weight raises `ArgumentError`
  (`closeness/2` and weighted `betweenness/2` also reject zero weights).
  Eigenvector centrality is not path-based, but a negative adjacency entry
  voids the Perron–Frobenius guarantee: power iteration can flip sign every
  round and never converge (an `a–b` edge of weight `-1` does).
  """

  alias Grafi.Algo.Distances
  alias Grafi.Algo.MinHeap
  alias Grafi.Args
  alias Grafi.Graph
  alias Grafi.NIF

  # ── PageRank ──────────────────────────────────────────────────────────

  @doc """
  PageRank via power iteration (Elixir) or PRPACK (igraph NIF).

  Edge weights are used (an edge's weight defaults to `1.0`; parallel edges
  add up). The rank of dangling vertices (no outgoing weight) is spread
  uniformly over all vertices, so the ranks sum to 1. This matches igraph,
  and NetworkX on graphs without undirected self-loops: an undirected
  self-loop adds its weight twice to its vertex's outgoing weight (igraph's
  degree convention), while NetworkX counts it once.

  ## Options
    - `:damping` — damping factor in `[0, 1)`, default `0.85`
    - `:max_iter` — max iterations (positive integer), default `100`
    - `:tol` — convergence threshold (positive), default `1.0e-6`;
      iteration stops once the L1 change is below `n * tol`
    - `:engine` — `:auto | :nif | :elixir`, see `Grafi.NIF`

  `:max_iter` and `:tol` apply to the Elixir engine only; igraph's
  PRPACK solver runs to its own convergence.

  Raises `ArgumentError` if an edge weight is negative.
  """
  @spec pagerank(Graph.t(), keyword()) :: %{any() => float()}
  def pagerank(%Graph{} = g, opts \\ []) do
    opts = Keyword.validate!(opts, damping: 0.85, max_iter: 100, tol: 1.0e-6, engine: :auto)
    Args.engine!(opts)
    damping = Args.float!(opts, :damping, 0.85, &(&1 >= 0 and &1 < 1), "a number in [0, 1)")
    max_iter = Args.pos_integer!(opts, :max_iter, 100)
    tol = Args.float!(opts, :tol, 1.0e-6, &(&1 > 0), "a positive number")
    Args.non_negative_weights!(g)

    dispatch(
      g,
      opts,
      &NIF.nif_pagerank(&1, damping, max_iter),
      fn -> pagerank_elixir(g, damping, max_iter, tol) end
    )
  end

  # ── Betweenness ───────────────────────────────────────────────────────

  @doc """
  Computes betweenness centrality for every vertex: the number of shortest
  paths between other vertex pairs that pass through it.

  Follows NetworkX's `betweenness_centrality`. On undirected graphs each
  unordered pair counts once. With `normalized: true` the scores are scaled
  by `2 / ((n - 1)(n - 2))` (undirected) or `1 / ((n - 1)(n - 2))`
  (directed), so the centre of a star scores `1.0`. Graphs with fewer than
  three vertices are not normalized.

  ## Options
    - `:weighted` — use edge weights as path lengths, default `false`
      (every edge has length 1)
    - `:normalized` — default `true`
    - `:engine` — `:auto | :nif | :elixir`, see `Grafi.NIF`

  On multigraphs the engines can differ: igraph counts parallel edges as
  distinct shortest paths, while the Elixir engine counts each neighbour
  once (using the lightest parallel edge when weighted).

  Raises `ArgumentError` if `weighted: true` and an edge weight is zero or
  negative. Unweighted betweenness ignores weights.
  """
  @spec betweenness(Graph.t(), keyword()) :: %{any() => float()}
  def betweenness(%Graph{} = g, opts \\ []) do
    opts = Keyword.validate!(opts, weighted: false, normalized: true, engine: :auto)
    Args.engine!(opts)
    weighted? = Args.boolean!(opts, :weighted, false)
    normalized? = Args.boolean!(opts, :normalized, true)
    if weighted?, do: Args.positive_weights!(g)

    dispatch(
      g,
      opts,
      &NIF.nif_betweenness(&1, weighted?, normalized?),
      fn -> betweenness_elixir(g, weighted?, normalized?) end
    )
  end

  # ── Closeness ─────────────────────────────────────────────────────────

  @doc """
  Computes closeness centrality for every vertex — the reciprocal of the
  average shortest-path distance from a vertex to every other reachable
  vertex. Edge weights are path lengths (an edge's weight defaults to `1.0`).

  Returns `%{}` for an empty or single-vertex graph (closeness is undefined
  with fewer than two vertices). Vertices that cannot reach any other
  vertex score `0.0`.

  ## Options
    - `:engine` — `:auto | :nif | :elixir`, see `Grafi.NIF`

  Raises `ArgumentError` if an edge weight is zero or negative.
  """
  @spec closeness(Graph.t(), keyword()) :: %{any() => float()}
  def closeness(%Graph{} = g, opts \\ []) do
    opts = Keyword.validate!(opts, engine: :auto)
    Args.engine!(opts)
    Args.positive_weights!(g)

    if Graph.num_vertices(g) <= 1,
      do: %{},
      else: dispatch(g, opts, &NIF.nif_closeness/1, fn -> closeness_elixir(g) end)
  end

  # Runs `nif_fun.(csr)` or `elixir_fun.()` according to the selected engine.
  # NIF results are per-index lists, re-keyed by vertex id.
  defp dispatch(g, opts, nif_fun, elixir_fun) do
    case NIF.engine(g, opts) do
      :nif ->
        {_idx, csr} = Graph.to_csr(g)
        NIF.by_vertex(csr, NIF.call!(nif_fun.(csr)))

      :elixir ->
        elixir_fun.()

      {:error, reason} ->
        raise Grafi.NIFError, reason: reason
    end
  end

  # ── Degree centrality ────────────────────────────────────────────────

  @doc "Computes normalized degree centrality for every vertex."
  @spec degree_centrality(Graph.t()) :: %{any() => float()}
  def degree_centrality(%Graph{} = g) do
    n = Graph.num_vertices(g)
    if n <= 1, do: %{}, else: Graph.vertices(g) |> Map.new(&{&1, Graph.degree(g, &1) / (n - 1)})
  end

  # ── Pure Elixir fallbacks ─────────────────────────────────────────────

  # Power iteration on the weighted transition matrix. `in_adj[v]` lists
  # `{u, w_uv / out_strength(u)}` for every u with an edge into v, built once
  # per call. Dangling vertices (out_strength 0) hand their rank out evenly.
  defp pagerank_elixir(g, d, max_iter, tol) do
    vs = Graph.vertices(g)
    n = length(vs)

    if n == 0 do
      %{}
    else
      strength = out_strength(g)

      ctx = %{
        vs: vs,
        n: n,
        d: d,
        max_iter: max_iter,
        tol: tol,
        in_adj: in_adjacency(g, strength),
        dangling: Enum.filter(vs, &(Map.get(strength, &1, 0.0) == 0.0))
      }

      do_pr(ctx, Map.new(vs, &{&1, 1.0 / n}), 0)
    end
  end

  defp do_pr(%{max_iter: max}, ranks, i) when i >= max, do: ranks

  defp do_pr(%{vs: vs, n: n, d: d} = ctx, ranks, i) do
    dangling_mass = Enum.reduce(ctx.dangling, 0.0, &(ranks[&1] + &2))
    base = (1.0 - d) / n + d * dangling_mass / n

    new =
      Map.new(vs, fn v ->
        inflow =
          ctx.in_adj
          |> Map.get(v, [])
          |> Enum.reduce(0.0, fn {u, p}, acc -> acc + ranks[u] * p end)

        {v, base + d * inflow}
      end)

    err = Enum.reduce(vs, 0.0, &(abs(new[&1] - ranks[&1]) + &2))
    if err < n * ctx.tol, do: new, else: do_pr(ctx, new, i + 1)
  end

  defp out_strength(%Graph{out_edges: out}) do
    Map.new(out, fn {u, targets} ->
      {u, Enum.reduce(targets, 0.0, fn {_v, edges}, acc -> acc + total_weight(edges) end)}
    end)
  end

  defp in_adjacency(%Graph{out_edges: out}, strength) do
    for {u, targets} <- out,
        s_u = Map.fetch!(strength, u),
        s_u > 0,
        {v, edges} <- targets,
        edges != [],
        reduce: %{} do
      acc ->
        p = total_weight(edges) / s_u
        Map.update(acc, v, [{u, p}], &[{u, p} | &1])
    end
  end

  defp total_weight(edges), do: Enum.reduce(edges, 0.0, &(&1.weight + &2))

  # Brandes' algorithm: one single-source shortest-path pass per vertex (BFS
  # when unweighted, Dijkstra when weighted), then dependency accumulation in
  # order of non-increasing distance.
  defp betweenness_elixir(g, weighted?, normalized?) do
    vs = Graph.vertices(g)

    raw =
      Enum.reduce(vs, Map.new(vs, &{&1, 0.0}), fn s, cb ->
        {stack, sigma, pred} = if weighted?, do: sssp_dijkstra(g, s), else: sssp_bfs(g, s)
        accumulate(stack, sigma, pred, s, cb)
      end)

    scale = betweenness_scale(length(vs), g.type, normalized?)
    Map.new(raw, fn {v, x} -> {v, x * scale} end)
  end

  defp accumulate(stack, sigma, pred, s, cb) do
    {_delta, cb} =
      Enum.reduce(stack, {%{}, cb}, fn w, {delta, cb} ->
        delta_w = Map.get(delta, w, 0.0)
        coeff = (1.0 + delta_w) / sigma[w]

        delta =
          Enum.reduce(Map.get(pred, w, []), delta, fn v, acc ->
            Map.update(acc, v, sigma[v] * coeff, &(&1 + sigma[v] * coeff))
          end)

        cb = if w === s, do: cb, else: Map.update!(cb, w, &(&1 + delta_w))
        {delta, cb}
      end)

    cb
  end

  # Undirected traversal reaches every unordered pair from both ends, so the
  # raw sum counts each pair twice; halve it. Normalization then divides by
  # the number of (ordered or unordered) pairs excluding the vertex itself.
  defp betweenness_scale(n, type, normalized?) do
    pair_factor = if type == :undirected, do: 0.5, else: 1.0

    cond do
      not normalized? or n <= 2 -> pair_factor
      type == :undirected -> 2.0 / ((n - 1) * (n - 2)) * pair_factor
      true -> 1.0 / ((n - 1) * (n - 2))
    end
  end

  # Returns {stack, sigma, pred}; the stack head is the farthest vertex.
  defp sssp_bfs(g, s) do
    do_sssp_bfs(:queue.from_list([s]), [], %{s => 1.0}, %{s => 0}, %{}, g)
  end

  defp do_sssp_bfs(q, stack, sigma, dist, pred, g) do
    case :queue.out(q) do
      {:empty, _} ->
        {stack, sigma, pred}

      {{:value, v}, rest_q} ->
        dv = dist[v]

        {q, sigma, dist, pred} =
          Graph.out_neighbors(g, v)
          |> Enum.reduce({rest_q, sigma, dist, pred}, fn w, {q, sig, d, p} ->
            case Map.fetch(d, w) do
              :error ->
                {:queue.in(w, q), Map.put(sig, w, sig[v]), Map.put(d, w, dv + 1),
                 Map.put(p, w, [v])}

              {:ok, dw} when dw == dv + 1 ->
                {q, Map.update!(sig, w, &(&1 + sig[v])), d, Map.update!(p, w, &[v | &1])}

              {:ok, _} ->
                {q, sig, d, p}
            end
          end)

        do_sssp_bfs(q, [v | stack], sigma, dist, pred, g)
    end
  end

  # Weighted single-source pass (Dijkstra). Parallel edges contribute their
  # lightest weight. Path lengths are compared with igraph's relative epsilon
  # so that float rounding doesn't split equal-length paths.
  defp sssp_dijkstra(g, s) do
    heap = MinHeap.new() |> MinHeap.insert({0.0, s})
    do_sssp_dijkstra(g, heap, %{s => 0.0}, %{s => 1.0}, %{}, %{}, [])
  end

  # `done` is a plain map used as a set of finalized vertices.
  defp do_sssp_dijkstra(g, heap, dist, sigma, pred, done, stack) do
    case MinHeap.pop(heap) do
      :empty ->
        {stack, sigma, pred}

      {:ok, {d, v}, heap} ->
        if Map.has_key?(done, v) or d > dist[v] do
          do_sssp_dijkstra(g, heap, dist, sigma, pred, done, stack)
        else
          {heap, dist, sigma, pred} =
            g.out_edges
            |> Map.get(v, %{})
            |> Enum.reject(fn {w, edges} -> edges == [] or Map.has_key?(done, w) end)
            |> Enum.reduce({heap, dist, sigma, pred}, fn {w, edges}, acc ->
              relax(acc, v, w, d + Enum.min_by(edges, & &1.weight).weight)
            end)

          do_sssp_dijkstra(g, heap, dist, sigma, pred, Map.put(done, v, true), [v | stack])
        end
    end
  end

  defp relax({heap, dist, sigma, pred}, v, w, alt) do
    case Map.fetch(dist, w) do
      {:ok, dw} ->
        cond do
          same_length?(alt, dw) ->
            {heap, dist, Map.update!(sigma, w, &(&1 + sigma[v])), Map.update!(pred, w, &[v | &1])}

          alt < dw ->
            {MinHeap.insert(heap, {alt, w}), Map.put(dist, w, alt), Map.put(sigma, w, sigma[v]),
             Map.put(pred, w, [v])}

          true ->
            {heap, dist, sigma, pred}
        end

      :error ->
        {MinHeap.insert(heap, {alt, w}), Map.put(dist, w, alt), Map.put(sigma, w, sigma[v]),
         Map.put(pred, w, [v])}
    end
  end

  # igraph_cmp_epsilon with IGRAPH_SHORTEST_PATH_EPSILON (1e-10).
  defp same_length?(a, b), do: a == b or abs(a - b) < 1.0e-10 * (abs(a) + abs(b))

  # Uses Wasserman–Faust normalization: each vertex's closeness is
  # (reachable - 1) / sum_of_distances_to_reachable, i.e. normalized by the
  # size of its *reachable* set rather than n - 1. This differs from
  # NetworkX's default (which scales by (reachable-1)/(n-1)); it is the more
  # meaningful variant on disconnected graphs.
  defp closeness_elixir(g) do
    n = Graph.num_vertices(g)

    if n <= 1,
      do: %{},
      else:
        Graph.vertices(g)
        |> Map.new(fn v ->
          dists = Distances.single_source(g, v, weighted: true, source: :include)
          total = dists |> Map.values() |> Enum.sum()
          {v, if(total > 0, do: (map_size(dists) - 1) / total, else: 0.0)}
        end)
  end

  # ── HITS ──────────────────────────────────────────────────────────────

  @doc """
  Hyperlink-Induced Topic Search (HITS, a.k.a. Kleinberg's algorithm).

  Returns `%{hubs: %{vertex => score}, authorities: %{vertex => score}}`.
  Computed by alternating power iteration on the adjacency matrix `A`
  (authorities ← Aᵀ · hubs) and its transpose (hubs ← A · authorities),
  L2-normalizing both vectors at every round.

  ## Options
    - `:max_iter` — max iterations, default `100`
    - `:tol` — L1 convergence epsilon, default `1.0e-6`
  """
  @spec hits(Graph.t(), keyword()) :: %{
          hubs: %{any() => float()},
          authorities: %{any() => float()}
        }
  def hits(%Graph{} = g, opts \\ []) do
    opts = Keyword.validate!(opts, max_iter: 100, tol: 1.0e-6)
    {max_iter, tol} = iteration_opts!(opts)
    vs = Graph.vertices(g)
    n = length(vs)

    if n == 0 do
      %{hubs: %{}, authorities: %{}}
    else
      init = Map.new(vs, &{&1, 1.0 / n})
      ctx = %{vs: vs, in: coefficients(g.in_edges, false), out: coefficients(g.out_edges, false)}
      {h, a} = do_hits(ctx, init, init, max_iter, tol, 0)
      %{hubs: h, authorities: a}
    end
  end

  defp do_hits(_ctx, h, a, max, _tol, i) when i >= max, do: {h, a}

  defp do_hits(%{vs: vs} = ctx, h, a, max, tol, i) do
    # authorities[v] = sum over u in in_neighbors(v) of hubs[u]
    a_new = vs |> Map.new(&{&1, weighted_sum(ctx.in, &1, h)}) |> l2_normalize(vs)
    # hubs[v] = sum over w in out_neighbors(v) of authorities[w]
    h_new = vs |> Map.new(&{&1, weighted_sum(ctx.out, &1, a_new)}) |> l2_normalize(vs)

    if l1_delta(h, h_new, vs) < tol and l1_delta(a, a_new, vs) < tol,
      do: {h_new, a_new},
      else: do_hits(ctx, h_new, a_new, max, tol, i + 1)
  end

  # ── Katz ──────────────────────────────────────────────────────────────

  @doc """
  Katz centrality via power iteration: `x ← α · Aᵀ · x + β · 1`.

  Returns `%{vertex => score}`.

  ## Options
    - `:alpha` — attenuation factor, default `0.1`. For convergence, `α`
      must be strictly less than the reciprocal of the largest eigenvalue
      of `A`. Not enforced — pick a value appropriate for your graph.
    - `:beta` — exogenous bias, default `1.0`
    - `:max_iter` — max iterations, default `100`
    - `:tol` — L1 convergence epsilon, default `1.0e-6`
  """
  @spec katz(Graph.t(), keyword()) :: %{any() => float()}
  def katz(%Graph{} = g, opts \\ []) do
    opts = Keyword.validate!(opts, alpha: 0.1, beta: 1.0, max_iter: 100, tol: 1.0e-6)
    alpha = Args.float!(opts, :alpha, 0.1, fn _ -> true end, "a number")
    beta = Args.float!(opts, :beta, 1.0, fn _ -> true end, "a number")
    {max_iter, tol} = iteration_opts!(opts)
    vs = Graph.vertices(g)

    if vs == [] do
      %{}
    else
      x0 = Map.new(vs, &{&1, 0.0})
      do_katz(coefficients(g.in_edges, false), vs, x0, alpha, beta, max_iter, tol, 0)
    end
  end

  defp do_katz(_in, _vs, x, _a, _b, max, _tol, i) when i >= max, do: x

  defp do_katz(in_coeffs, vs, x, alpha, beta, max, tol, i) do
    x_new = Map.new(vs, &{&1, alpha * weighted_sum(in_coeffs, &1, x) + beta})

    if l1_delta(x, x_new, vs) < tol,
      do: x_new,
      else: do_katz(in_coeffs, vs, x_new, alpha, beta, max, tol, i + 1)
  end

  # ── Eigenvector ───────────────────────────────────────────────────────

  @doc """
  Eigenvector centrality via power iteration on the adjacency matrix.

  Returns `%{vertex => score}`, L2-normalized so that `Σ score² = 1`
  (matching NetworkX). For directed graphs, iterates on the in-edge
  matrix: `x ← Aᵀ · x` (i.e. a vertex is important when pointed to by
  important vertices). The result is undefined on graphs with no edges;
  in that case every vertex gets `0.0`.

  ## Options
    - `:max_iter` — max iterations, default `100`
    - `:tol` — L1 convergence epsilon, default `1.0e-6`
    - `:weighted` — use edge weights when summing. Defaults to `true`
      if any edge in the graph has a non-default (`!= 1.0`) weight,
      `false` otherwise.

  Raises `ArgumentError` if weights are used and an edge weight is
  negative (see "Edge weights" above).
  """
  @spec eigenvector(Graph.t(), keyword()) :: %{any() => float()}
  def eigenvector(%Graph{} = g, opts \\ []) do
    opts = Keyword.validate!(opts, [:weighted, max_iter: 100, tol: 1.0e-6])
    {max_iter, tol} = iteration_opts!(opts)

    weighted =
      if Keyword.has_key?(opts, :weighted),
        do: Args.boolean!(opts, :weighted, false),
        else: Args.any_weight?(g, &(&1 != 1.0))

    if weighted, do: Args.non_negative_weights!(g)

    vs = Graph.vertices(g)
    n = length(vs)

    if n == 0 do
      %{}
    else
      init = Map.new(vs, &{&1, 1.0 / :math.sqrt(n)})
      do_eigen(coefficients(g.in_edges, weighted), vs, init, max_iter, tol, 0)
    end
  end

  defp do_eigen(_in, _vs, x, max, _tol, i) when i >= max, do: x

  defp do_eigen(in_coeffs, vs, x, max, tol, i) do
    x_new = vs |> Map.new(&{&1, weighted_sum(in_coeffs, &1, x)}) |> l2_normalize(vs)

    if l1_delta(x, x_new, vs) < tol,
      do: x_new,
      else: do_eigen(in_coeffs, vs, x_new, max, tol, i + 1)
  end

  # ── Harmonic ──────────────────────────────────────────────────────────

  @doc """
  Harmonic centrality: for each vertex `v`,
  `Σ_{u ≠ v, reachable} 1 / d(u, v)`.

  Returns `%{vertex => score}`. The result is *not* normalized by
  `(n - 1)`; matches NetworkX's default and stays comparable to
  `closeness/2`. Isolated vertices score `0.0`.

  ## Options
    - `:weighted` — `true` to use edge weights as path lengths (Dijkstra);
      default `false` (BFS, every edge has length 1)

  Raises `ArgumentError` if `weighted: true` and an edge weight is negative.
  """
  @spec harmonic(Graph.t(), keyword()) :: %{any() => float()}
  def harmonic(%Graph{} = g, opts \\ []) do
    opts = Keyword.validate!(opts, weighted: false)
    weighted = Args.boolean!(opts, :weighted, false)
    if weighted, do: Args.non_negative_weights!(g)
    vs = Graph.vertices(g)

    Map.new(vs, fn v ->
      dists = Distances.single_source(g, v, weighted: weighted, source: :exclude)

      # A zero-weight edge gives a zero distance, which contributes nothing.
      score =
        Enum.reduce(dists, 0.0, fn {_u, d}, acc -> if d == 0, do: acc, else: acc + 1.0 / d end)

      {v, score}
    end)
  end

  # ── Power-iteration helpers ──────────────────────────────────────────

  defp iteration_opts!(opts) do
    {Args.pos_integer!(opts, :max_iter, 100),
     Args.float!(opts, :tol, 1.0e-6, &(&1 > 0), "a positive number")}
  end

  # `%{v => [{u, coeff}]}` from an `in_edges` or `out_edges` map, built once
  # per call: one entry per distinct neighbour, with `coeff` the summed
  # weight of the parallel edges (`weighted?`) or `1.0`.
  defp coefficients(adjacency, weighted?) do
    Map.new(adjacency, fn {v, nbrs} ->
      {v, for({u, edges} <- nbrs, edges != [], do: {u, coefficient(edges, weighted?)})}
    end)
  end

  defp coefficient(edges, true), do: Enum.reduce(edges, 0.0, &(&2 + &1.weight))
  defp coefficient(_edges, false), do: 1.0

  defp weighted_sum(coeffs, v, x) do
    coeffs |> Map.get(v, []) |> Enum.reduce(0.0, fn {u, c}, acc -> acc + c * Map.fetch!(x, u) end)
  end

  defp l1_delta(old, new, vs) do
    Enum.reduce(vs, 0.0, fn v, acc ->
      acc + abs(Map.get(new, v, 0.0) - Map.get(old, v, 0.0))
    end)
  end

  defp l2_normalize(map, vs) do
    norm =
      Enum.reduce(vs, 0.0, fn v, acc ->
        x = Map.get(map, v, 0.0)
        acc + x * x
      end)
      |> :math.sqrt()

    if norm == 0.0,
      do: map,
      else: Map.new(map, fn {k, val} -> {k, val / norm} end)
  end
end
