defmodule Grafi.Algo.Centrality do
  @moduledoc """
  Centrality measures: PageRank, betweenness, closeness, degree.

  For graphs above `@nif_threshold` vertices, algorithms dispatch to
  igraph via NIF. Below that, pure Elixir implementations run.
  """

  alias Grafi.Graph

  @nif_threshold 500

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
      ranks = Grafi.NIF.nif_pagerank(csr, damping, max_iter)
      reverse_idx = Map.new(idx, fn {v, i} -> {i, v} end)
      ranks |> Enum.with_index() |> Map.new(fn {r, i} -> {reverse_idx[i], r} end)
    else
      pagerank_elixir(g, damping, max_iter, Keyword.get(opts, :tolerance, 1.0e-6))
    end
  end

  # ── Betweenness ───────────────────────────────────────────────────────

  @spec betweenness(Graph.t()) :: %{any() => float()}
  def betweenness(%Graph{} = g) do
    if use_nif?(g) do
      {idx, csr} = Graph.to_csr(g)
      scores = Grafi.NIF.nif_betweenness(csr)
      reverse_idx = Map.new(idx, fn {v, i} -> {i, v} end)
      scores |> Enum.with_index() |> Map.new(fn {s, i} -> {reverse_idx[i], s} end)
    else
      betweenness_elixir(g)
    end
  end

  # ── Closeness ─────────────────────────────────────────────────────────

  @spec closeness(Graph.t()) :: %{any() => float()}
  def closeness(%Graph{} = g) do
    if use_nif?(g) do
      {idx, csr} = Graph.to_csr(g)
      scores = Grafi.NIF.nif_closeness(csr)
      reverse_idx = Map.new(idx, fn {v, i} -> {i, v} end)
      scores |> Enum.with_index() |> Map.new(fn {s, i} -> {reverse_idx[i], s} end)
    else
      closeness_elixir(g)
    end
  end

  # ── Degree centrality ────────────────────────────────────────────────

  @spec degree_centrality(Graph.t()) :: %{any() => float()}
  def degree_centrality(%Graph{} = g) do
    n = Graph.num_vertices(g)
    if n <= 1, do: %{}, else:
      Graph.vertices(g) |> Map.new(&{&1, Graph.degree(g, &1) / (n - 1)})
  end

  # ── Pure Elixir fallbacks ─────────────────────────────────────────────

  defp pagerank_elixir(g, d, max_iter, tol) do
    vs = Graph.vertices(g)
    n = length(vs)
    if n == 0, do: (throw %{})
    ranks = Map.new(vs, &{&1, 1.0 / n})
    do_pr(g, ranks, vs, n, d, max_iter, tol, 0)
  catch
    r -> r
  end

  defp do_pr(_, ranks, _, _, _, max, _, i) when i >= max, do: ranks
  defp do_pr(g, ranks, vs, n, d, max, tol, i) do
    new = Map.new(vs, fn v ->
      sum = Graph.in_neighbors(g, v)
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

    cb = Enum.reduce(vs, cb, fn s, cb_acc ->
      {stack, sigma, dist, pred} = brandes_bfs(g, s, vs)
      delta = Map.new(vs, &{&1, 0.0})

      {_, cb2} = Enum.reduce(stack, {delta, cb_acc}, fn w, {d, c} ->
        coeff = (1.0 + d[w]) / Map.get(sigma, w, 1.0)
        d = Enum.reduce(Map.get(pred, w, []), d, fn v, d2 ->
          Map.update!(d2, v, &(&1 + Map.get(sigma, v, 1.0) * coeff))
        end)
        c = if w != s, do: Map.update!(c, w, &(&1 + d[w])), else: c
        {d, c}
      end)
      cb2
    end)

    n = length(vs)
    if n > 2 do
      f = if g.type == :directed, do: 1.0 / ((n-1)*(n-2)), else: 2.0 / ((n-1)*(n-2))
      Map.new(cb, fn {v, val} -> {v, val * f} end)
    else
      cb
    end
  end

  defp brandes_bfs(g, s, _vs) do
    do_brandes([s], [], %{s => 1.0}, %{s => 0}, %{}, g)
  end

  defp do_brandes([], stack, sigma, _dist, pred, _g), do: {stack, sigma, %{}, pred}
  defp do_brandes([v | rest], stack, sigma, dist, pred, g) do
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
    do_brandes(rest ++ Enum.reverse(qa), stack, sigma, dist, pred, g)
  end

  defp closeness_elixir(g) do
    n = Graph.num_vertices(g)
    if n <= 1, do: %{}, else:
      Graph.vertices(g) |> Map.new(fn v ->
        dists = Grafi.Algo.ShortestPath.dijkstra_all(g, v)
        total = dists |> Map.values() |> Enum.sum()
        {v, if(total > 0, do: (map_size(dists) - 1) / total, else: 0.0)}
      end)
  end

  defp use_nif?(g), do: Graph.num_vertices(g) > @nif_threshold and Grafi.NIF.available?()
end
