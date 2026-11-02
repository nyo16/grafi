defmodule Grafi.Algo.APSP do
  @dialyzer :no_opaque

  @moduledoc """
  All-pairs shortest path algorithms — Floyd-Warshall and Johnson's.

  Floyd-Warshall is dense (O(V^3)) and handles negative edges. Johnson's
  reweights the graph via a virtual source + Bellman-Ford, then runs Dijkstra
  from each vertex; preferable on sparse graphs (O(V·E·log V)).

  Distance maps are sparse — unreachable `{from, to}` pairs are omitted rather
  than stored as `:infinity`.
  """

  alias Grafi.Algo.ShortestPath
  alias Grafi.Graph

  @typedoc "Sparse distance matrix: from => %{to => distance}."
  @type dist_matrix :: %{any() => %{any() => number()}}

  @typedoc "Predecessor matrix for path reconstruction: from => %{to => prev_of_to}."
  @type pred_matrix :: %{any() => %{any() => any()}}

  # ── Floyd-Warshall ────────────────────────────────────────────────────

  @doc """
  Floyd-Warshall all-pairs shortest path. O(V^3) time, O(V^2) space.

  Handles negative edges. Returns `{:error, :negative_cycle}` if any negative
  cycle exists (detected via `dist[v][v] < 0`).

  ## Examples

      iex> g = Grafi.new() |> Grafi.add_edges([
      ...>   {:a, :b, weight: 1.0},
      ...>   {:b, :c, weight: 2.0},
      ...>   {:a, :c, weight: 5.0}
      ...> ])
      iex> {:ok, d} = Grafi.Algo.APSP.floyd_warshall(g)
      iex> d[:a][:c]
      3.0
  """
  @spec floyd_warshall(Graph.t()) :: {:ok, dist_matrix()} | {:error, :negative_cycle}
  def floyd_warshall(%Graph{} = g) do
    case do_floyd_warshall(g, false) do
      {:error, :negative_cycle} -> {:error, :negative_cycle}
      {:ok, dists, _preds} -> {:ok, dists}
    end
  end

  @doc """
  Floyd-Warshall variant that also records predecessors for path reconstruction.

  Returns `{:ok, dists, preds}` where `preds[from][to]` is the predecessor of
  `to` on the shortest path starting at `from`. Pair `to reconstruct_path/3`.

  ## Examples

      iex> g = Grafi.new() |> Grafi.add_edges([
      ...>   {:a, :b, weight: 1.0},
      ...>   {:b, :c, weight: 2.0},
      ...>   {:a, :c, weight: 5.0}
      ...> ])
      iex> {:ok, _d, p} = Grafi.Algo.APSP.floyd_warshall_with_paths(g)
      iex> Grafi.Algo.APSP.reconstruct_path(p, :a, :c)
      {:ok, [:a, :b, :c]}
  """
  @spec floyd_warshall_with_paths(Graph.t()) ::
          {:ok, dist_matrix(), pred_matrix()} | {:error, :negative_cycle}
  def floyd_warshall_with_paths(%Graph{} = g), do: do_floyd_warshall(g, true)

  @doc """
  Reconstructs the shortest path `from -> to` from a predecessor matrix
  produced by `floyd_warshall_with_paths/1`.

  Returns `{:ok, [from, ..., to]}` or `:no_path`. The trivial path `from == to`
  returns `{:ok, [from]}` whenever `from` appears in the matrix.

  ## Examples

      iex> g = Grafi.new() |> Grafi.add_edges([
      ...>   {:a, :b, weight: 1.0},
      ...>   {:b, :c, weight: 2.0}
      ...> ])
      iex> {:ok, _d, p} = Grafi.Algo.APSP.floyd_warshall_with_paths(g)
      iex> Grafi.Algo.APSP.reconstruct_path(p, :a, :c)
      {:ok, [:a, :b, :c]}
  """
  @spec reconstruct_path(pred_matrix(), any(), any()) :: {:ok, [any()]} | :no_path
  def reconstruct_path(preds, from, to) do
    cond do
      from == to and Map.has_key?(preds, from) ->
        {:ok, [from]}

      not Map.has_key?(preds, from) ->
        :no_path

      true ->
        case walk_preds(preds[from], from, to, [to]) do
          :no_path -> :no_path
          path -> {:ok, path}
        end
    end
  end

  defp walk_preds(_row, from, from, acc), do: acc

  defp walk_preds(row, from, cur, acc) do
    case Map.get(row, cur) do
      nil -> :no_path
      ^from -> [from | acc]
      prev -> walk_preds(row, from, prev, [prev | acc])
    end
  end

  # ── Johnson's algorithm ───────────────────────────────────────────────

  @doc """
  Johnson's algorithm: reweight via Bellman-Ford from a virtual source, then
  Dijkstra from each vertex. O(V·E·log V) — preferred over Floyd-Warshall on
  sparse graphs.

  Same return shape as `floyd_warshall/1`. Returns `{:error, :negative_cycle}`
  if Bellman-Ford detects a negative cycle reachable from the virtual source
  (i.e. anywhere in the graph).

  ## Examples

      iex> g = Grafi.new() |> Grafi.add_edges([
      ...>   {:a, :b, weight: 1.0},
      ...>   {:b, :c, weight: -2.0},
      ...>   {:a, :c, weight: 5.0}
      ...> ])
      iex> {:ok, d} = Grafi.Algo.APSP.johnson(g)
      iex> d[:a][:c]
      -1.0
  """
  @spec johnson(Graph.t()) :: {:ok, dist_matrix()} | {:error, :negative_cycle}
  def johnson(%Graph{} = g) do
    vs = Graph.vertices(g)

    # Virtual source `:"$johnson_src"` connected to every real vertex with a
    # zero-weight edge. We use a tag tuple to avoid collisions with user atoms.
    src = {:__johnson_virtual_source__, make_ref()}
    aug = Enum.reduce(vs, Graph.add_vertex(g, src), &Graph.add_edge(&2, src, &1, weight: 0.0))

    case ShortestPath.bellman_ford(aug, src) do
      {:error, :negative_cycle} ->
        {:error, :negative_cycle}

      {:ok, h_with_src} ->
        # h[v] = shortest distance from virtual source. Defaults to 0 for any
        # vertex not in the BF result (shouldn't happen since src reaches all).
        h = Map.new(vs, fn v -> {v, Map.get(h_with_src, v, 0.0)} end)

        dists =
          Map.new(vs, fn u ->
            d_reweighted = ShortestPath.dijkstra_all(g, u, &reweight(&1, h))

            # Convert back: d(u,v) = d'(u,v) - h[u] + h[v]
            hu = Map.fetch!(h, u)

            row =
              for {v, d_prime} <- d_reweighted, into: %{} do
                {v, d_prime - hu + Map.fetch!(h, v)}
              end

            {u, row}
          end)

        {:ok, dists}
    end
  end

  # ── Transitive closure ───────────────────────────────────────────────

  @doc """
  Boolean reachability matrix. Returns `%{from => MapSet.t()}` where the
  MapSet contains every vertex reachable from `from` (including `from`
  itself, by convention).

  Implemented via BFS from each vertex — cheaper than running APSP when only
  reachability is needed.

  ## Examples

      iex> g = Grafi.new() |> Grafi.add_edges([{:a, :b}, {:b, :c}])
      iex> tc = Grafi.Algo.APSP.transitive_closure(g)
      iex> MapSet.to_list(tc[:a]) |> Enum.sort()
      [:a, :b, :c]
      iex> MapSet.to_list(tc[:c])
      [:c]
  """
  @spec transitive_closure(Graph.t()) :: %{any() => MapSet.t()}
  def transitive_closure(%Graph{} = g) do
    Map.new(Graph.vertices(g), fn v ->
      {v, Grafi.Algo.Traversal.reachable_from(g, v)}
    end)
  end

  # ── Internal: Floyd-Warshall core ─────────────────────────────────────

  defp do_floyd_warshall(g, record_preds?) do
    vs = Graph.vertices(g)

    # Initialise: self-loops at 0, edge weights from the graph (take min for
    # multi-edges), everything else absent.
    {init_dists, init_preds} =
      Enum.reduce(vs, {%{}, %{}}, fn u, {d, p} ->
        row = %{u => 0.0}
        pred_row = if record_preds?, do: %{}, else: nil

        {row, pred_row} =
          Enum.reduce(Graph.out_neighbors(g, u), {row, pred_row}, fn v, {r, pr} ->
            w = Graph.edges_between(g, u, v) |> Enum.map(& &1.weight) |> Enum.min()

            cond do
              v == u and w >= 0 ->
                # ignore non-negative self-loop (0 is already there)
                {r, pr}

              w < Map.get(r, v, :infinity) ->
                {Map.put(r, v, w), if(record_preds?, do: Map.put(pr, v, u), else: pr)}

              true ->
                {r, pr}
            end
          end)

        d = Map.put(d, u, row)
        p = if record_preds?, do: Map.put(p, u, pred_row), else: p
        {d, p}
      end)

    {dists, preds} =
      Enum.reduce(vs, {init_dists, init_preds}, fn k, {d, p} ->
        relax_through(d, p, vs, k, record_preds?)
      end)

    if Enum.any?(vs, fn v -> (dists[v][v] || 0.0) < 0 end) do
      {:error, :negative_cycle}
    else
      {:ok, dists, preds}
    end
  end

  # For a fixed intermediate vertex k, relax every (i, j) pair.
  defp relax_through(dists, preds, vs, k, record_preds?) do
    Enum.reduce(vs, {dists, preds}, fn i, {d, p} ->
      case d[i][k] do
        nil ->
          {d, p}

        dik ->
          row_k = d[k]
          row_i = d[i]
          pred_row_i = if record_preds?, do: p[i], else: nil
          pred_row_k = if record_preds?, do: p[k], else: nil

          {new_row_i, new_pred_row_i} =
            Enum.reduce(row_k, {row_i, pred_row_i}, fn {j, dkj}, {ri, pri} ->
              relax_one(j, dik + dkj, ri, pri, k, pred_row_k, record_preds?)
            end)

          d = Map.put(d, i, new_row_i)
          p = if record_preds?, do: Map.put(p, i, new_pred_row_i), else: p
          {d, p}
      end
    end)
  end

  # Relax distance dist[i][j] using intermediate k. Returns updated
  # {row_i, pred_row_i}. Predecessor of j on i->k->j is the predecessor
  # of j on the k->j path (or k itself if k is the direct predecessor).
  defp relax_one(j, alt, ri, pri, k, pred_row_k, record_preds?) do
    if alt < Map.get(ri, j, :infinity) do
      ri = Map.put(ri, j, alt)
      pri = if record_preds?, do: Map.put(pri, j, Map.get(pred_row_k, j, k)), else: pri
      {ri, pri}
    else
      {ri, pri}
    end
  end

  # Johnson reweighting: w'(u, v) = w(u, v) + h[u] - h[v], non-negative
  # once `h` holds the Bellman-Ford potentials.
  defp reweight(edge, h) do
    edge.weight + Map.fetch!(h, edge.from) - Map.fetch!(h, edge.to)
  end
end
