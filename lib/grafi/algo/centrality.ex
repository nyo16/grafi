defmodule Grafi.Algo.Centrality do
  @moduledoc """
  Centrality measures: PageRank, betweenness, closeness, degree.

  For graphs above the configured `:nif_threshold` vertices, algorithms dispatch
  to igraph via NIF. Below that, pure Elixir implementations run.
  """

  alias Grafi.Graph

  # ── PageRank ──────────────────────────────────────────────────────────

  @doc """
  PageRank via power iteration (Elixir) or PRPACK (igraph NIF).

  ## Options
    - `:damping` — damping factor, default `0.85`
    - `:iterations` — max iterations, default `100`
    - `:tolerance` — convergence epsilon, default `1.0e-6`
  """
  @spec pagerank(Graph.t(), keyword()) :: %{any() => float()}
  def pagerank(%Graph{} = g, opts \\ []) do
    damping = Keyword.get(opts, :damping, 0.85)
    max_iter = Keyword.get(opts, :iterations, 100)

    if use_nif?(g) do
      {idx, csr} = Graph.to_csr(g)
      Grafi.NIF.validate_csr!(csr)
      ranks = Grafi.NIF.nif_pagerank(csr, damping, max_iter)
      reverse_idx = Map.new(idx, fn {v, i} -> {i, v} end)
      ranks |> Enum.with_index() |> Map.new(fn {r, i} -> {reverse_idx[i], r} end)
    else
      pagerank_elixir(g, damping, max_iter, Keyword.get(opts, :tolerance, 1.0e-6))
    end
  end

  # ── Betweenness ───────────────────────────────────────────────────────

  @doc "Computes betweenness centrality for every vertex."
  @spec betweenness(Graph.t()) :: %{any() => float()}
  def betweenness(%Graph{} = g) do
    if use_nif?(g) do
      {idx, csr} = Graph.to_csr(g)
      Grafi.NIF.validate_csr!(csr)
      scores = Grafi.NIF.nif_betweenness(csr)
      reverse_idx = Map.new(idx, fn {v, i} -> {i, v} end)
      scores |> Enum.with_index() |> Map.new(fn {s, i} -> {reverse_idx[i], s} end)
    else
      betweenness_elixir(g)
    end
  end

  # ── Closeness ─────────────────────────────────────────────────────────

  @doc """
  Computes closeness centrality for every vertex — the reciprocal of the
  average shortest-path distance from a vertex to every other reachable
  vertex.

  Returns `%{}` for an empty or single-vertex graph (closeness is undefined
  with fewer than two vertices). Vertices that cannot reach any other
  vertex score `0.0`.
  """
  @spec closeness(Graph.t()) :: %{any() => float()}
  def closeness(%Graph{} = g) do
    cond do
      Graph.num_vertices(g) <= 1 ->
        %{}

      use_nif?(g) ->
        {idx, csr} = Graph.to_csr(g)
        Grafi.NIF.validate_csr!(csr)
        scores = Grafi.NIF.nif_closeness(csr)
        reverse_idx = Map.new(idx, fn {v, i} -> {i, v} end)
        scores |> Enum.with_index() |> Map.new(fn {s, i} -> {reverse_idx[i], s} end)

      true ->
        closeness_elixir(g)
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

  defp pagerank_elixir(g, d, max_iter, tol) do
    vs = Graph.vertices(g)
    n = length(vs)

    if n == 0 do
      %{}
    else
      ranks = Map.new(vs, &{&1, 1.0 / n})
      do_pr(g, ranks, vs, n, d, max_iter, tol, 0)
    end
  end

  defp do_pr(_, ranks, _, _, _, max, _, i) when i >= max, do: ranks

  defp do_pr(g, ranks, vs, n, d, max, tol, i) do
    new =
      Map.new(vs, fn v ->
        sum =
          Graph.in_neighbors(g, v)
          |> Enum.reduce(0.0, fn u, acc ->
            od = Graph.out_degree(g, u)
            if od > 0, do: acc + ranks[u] / od, else: acc
          end)

        {v, (1.0 - d) / n + d * sum}
      end)

    if Enum.all?(vs, &(abs(new[&1] - ranks[&1]) < tol)),
      do: new,
      else: do_pr(g, new, vs, n, d, max, tol, i + 1)
  end

  defp betweenness_elixir(g) do
    vs = Graph.vertices(g)
    cb = Map.new(vs, &{&1, 0.0})

    cb =
      Enum.reduce(vs, cb, fn s, cb_acc ->
        {stack, sigma, _dist, pred} = brandes_bfs(g, s, vs)
        delta = Map.new(vs, &{&1, 0.0})

        {_, cb2} =
          Enum.reduce(stack, {delta, cb_acc}, fn w, {d, c} ->
            coeff = (1.0 + d[w]) / Map.get(sigma, w, 1.0)

            d =
              Enum.reduce(Map.get(pred, w, []), d, fn v, d2 ->
                Map.update!(d2, v, &(&1 + Map.get(sigma, v, 1.0) * coeff))
              end)

            c = if w != s, do: Map.update!(c, w, &(&1 + d[w])), else: c
            {d, c}
          end)

        cb2
      end)

    n = length(vs)

    if n > 2 do
      f = if g.type == :directed, do: 1.0 / ((n - 1) * (n - 2)), else: 2.0 / ((n - 1) * (n - 2))
      Map.new(cb, fn {v, val} -> {v, val * f} end)
    else
      cb
    end
  end

  defp brandes_bfs(g, s, _vs) do
    do_brandes(:queue.from_list([s]), [], %{s => 1.0}, %{s => 0}, %{}, g)
  end

  defp do_brandes(q, stack, sigma, dist, pred, g) do
    case :queue.out(q) do
      {:empty, _} ->
        {stack, sigma, %{}, pred}

      {{:value, v}, rest_q} ->
        stack = [v | stack]

        {qa, sigma, dist, pred} =
          Graph.out_neighbors(g, v)
          |> Enum.reduce({[], sigma, dist, pred}, fn w, {qa, sig, d, p} ->
            if not Map.has_key?(d, w) do
              {[w | qa], Map.put(sig, w, sig[v]), Map.put(d, w, d[v] + 1), Map.put(p, w, [v])}
            else
              if d[w] == d[v] + 1 do
                {qa, Map.update!(sig, w, &(&1 + sig[v])), d, Map.update(p, w, [v], &[v | &1])}
              else
                {qa, sig, d, p}
              end
            end
          end)

        new_q = Enum.reduce(Enum.reverse(qa), rest_q, fn w, q -> :queue.in(w, q) end)
        do_brandes(new_q, stack, sigma, dist, pred, g)
    end
  end

  defp closeness_elixir(g) do
    n = Graph.num_vertices(g)

    if n <= 1,
      do: %{},
      else:
        Graph.vertices(g)
        |> Map.new(fn v ->
          dists = Grafi.Algo.ShortestPath.dijkstra_all(g, v)
          total = dists |> Map.values() |> Enum.sum()
          {v, if(total > 0, do: (map_size(dists) - 1) / total, else: 0.0)}
        end)
  end

  defp use_nif?(g), do: Graph.num_vertices(g) > nif_threshold() and Grafi.NIF.available?()

  defp nif_threshold, do: Application.get_env(:grafi, :nif_threshold, 500)

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
    max_iter = Keyword.get(opts, :max_iter, 100)
    tol = Keyword.get(opts, :tol, 1.0e-6)
    vs = Graph.vertices(g)
    n = length(vs)

    if n == 0 do
      %{hubs: %{}, authorities: %{}}
    else
      init = Map.new(vs, &{&1, 1.0 / n})
      {h, a} = do_hits(g, vs, init, init, max_iter, tol, 0)
      %{hubs: h, authorities: a}
    end
  end

  defp do_hits(_g, _vs, h, a, max, _tol, i) when i >= max, do: {h, a}

  defp do_hits(g, vs, h, a, max, tol, i) do
    # authorities[v] = sum over u in in_neighbors(v) of hubs[u]
    a_new =
      Map.new(vs, fn v ->
        s = Enum.reduce(Graph.in_neighbors(g, v), 0.0, fn u, acc -> acc + Map.get(h, u, 0.0) end)
        {v, s}
      end)
      |> l2_normalize(vs)

    # hubs[v] = sum over w in out_neighbors(v) of authorities[w]
    h_new =
      Map.new(vs, fn v ->
        s =
          Enum.reduce(Graph.out_neighbors(g, v), 0.0, fn w, acc -> acc + Map.get(a_new, w, 0.0) end)

        {v, s}
      end)
      |> l2_normalize(vs)

    if l1_delta(h, h_new, vs) < tol and l1_delta(a, a_new, vs) < tol,
      do: {h_new, a_new},
      else: do_hits(g, vs, h_new, a_new, max, tol, i + 1)
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
    alpha = Keyword.get(opts, :alpha, 0.1)
    beta = Keyword.get(opts, :beta, 1.0)
    max_iter = Keyword.get(opts, :max_iter, 100)
    tol = Keyword.get(opts, :tol, 1.0e-6)
    vs = Graph.vertices(g)

    if vs == [] do
      %{}
    else
      x0 = Map.new(vs, &{&1, 0.0})
      do_katz(g, vs, x0, alpha, beta, max_iter, tol, 0)
    end
  end

  defp do_katz(_g, _vs, x, _a, _b, max, _tol, i) when i >= max, do: x

  defp do_katz(g, vs, x, alpha, beta, max, tol, i) do
    x_new =
      Map.new(vs, fn v ->
        s = Enum.reduce(Graph.in_neighbors(g, v), 0.0, fn u, acc -> acc + Map.get(x, u, 0.0) end)
        {v, alpha * s + beta}
      end)

    if l1_delta(x, x_new, vs) < tol,
      do: x_new,
      else: do_katz(g, vs, x_new, alpha, beta, max, tol, i + 1)
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
  """
  @spec eigenvector(Graph.t(), keyword()) :: %{any() => float()}
  def eigenvector(%Graph{} = g, opts \\ []) do
    max_iter = Keyword.get(opts, :max_iter, 100)
    tol = Keyword.get(opts, :tol, 1.0e-6)
    weighted = Keyword.get(opts, :weighted, any_non_unit_weight?(g))
    vs = Graph.vertices(g)
    n = length(vs)

    if n == 0 do
      %{}
    else
      init = Map.new(vs, &{&1, 1.0 / :math.sqrt(n)})
      do_eigen(g, vs, init, weighted, max_iter, tol, 0)
    end
  end

  defp do_eigen(_g, _vs, x, _w, max, _tol, i) when i >= max, do: x

  defp do_eigen(g, vs, x, weighted, max, tol, i) do
    x_new =
      Map.new(vs, fn v ->
        s =
          if weighted do
            Enum.reduce(Graph.in_neighbors(g, v), 0.0, fn u, acc ->
              w =
                Graph.edges_between(g, u, v)
                |> Enum.reduce(0.0, fn e, a -> a + e.weight end)

              acc + Map.get(x, u, 0.0) * w
            end)
          else
            Enum.reduce(Graph.in_neighbors(g, v), 0.0, fn u, acc ->
              acc + Map.get(x, u, 0.0)
            end)
          end

        {v, s}
      end)
      |> l2_normalize(vs)

    if l1_delta(x, x_new, vs) < tol,
      do: x_new,
      else: do_eigen(g, vs, x_new, weighted, max, tol, i + 1)
  end

  # ── Harmonic ──────────────────────────────────────────────────────────

  @doc """
  Harmonic centrality: for each vertex `v`,
  `Σ_{u ≠ v, reachable} 1 / d(u, v)`.

  Returns `%{vertex => score}`. The result is *not* normalized by
  `(n - 1)`; matches NetworkX's default and stays comparable to
  `closeness/1`. Distances are unweighted (BFS) by default; pass
  `weighted: true` to use Dijkstra. Isolated vertices score `0.0`.
  """
  @spec harmonic(Graph.t(), keyword()) :: %{any() => float()}
  def harmonic(%Graph{} = g, opts \\ []) do
    weighted = Keyword.get(opts, :weighted, false)
    vs = Graph.vertices(g)

    Map.new(vs, fn v ->
      dists = single_source_distances(g, v, weighted)

      score =
        Enum.reduce(dists, 0.0, fn {u, d}, acc ->
          cond do
            u == v -> acc
            d == 0 -> acc
            true -> acc + 1.0 / d
          end
        end)

      {v, score}
    end)
  end

  # ── Power-iteration helpers ──────────────────────────────────────────

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

  defp any_non_unit_weight?(%Graph{} = g) do
    Graph.edges(g) |> Enum.any?(&(&1.weight != 1.0))
  end

  defp single_source_distances(g, source, weighted?) do
    if weighted? do
      Grafi.Algo.ShortestPath.dijkstra_all(g, source)
    else
      bfs_distances(g, source)
    end
  end

  defp bfs_distances(g, source) do
    do_bfs_dist(:queue.from_list([source]), %{source => 0}, g)
  end

  defp do_bfs_dist(q, dist, g) do
    case :queue.out(q) do
      {:empty, _} ->
        dist

      {{:value, v}, rest} ->
        {dist, q2} =
          Graph.out_neighbors(g, v)
          |> Enum.reduce({dist, rest}, fn n, {d, q_acc} ->
            if Map.has_key?(d, n),
              do: {d, q_acc},
              else: {Map.put(d, n, d[v] + 1), :queue.in(n, q_acc)}
          end)

        do_bfs_dist(q2, dist, g)
    end
  end
end
