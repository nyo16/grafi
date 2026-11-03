defmodule Grafi.Generators do
  @moduledoc """
  Synthetic graph generators — classical (complete, cycle, path, grid)
  and random (Erdős–Rényi, Barabási–Albert, Watts–Strogatz, random
  regular).

  Every generator returns a `%Grafi.Graph{}`. Like `Grafi.Graph.new/1`,
  generators build a directed graph by default; pass `type: :undirected`
  for the undirected version. Edge weights are `1.0`. Vertices are
  integers `0..n-1` except for `grid/3`, whose vertices are `{i, j}`
  tuples. Unknown options raise `ArgumentError`.

  Random generators accept a `:seed` option; when present, the
  generator-local `:rand` state is seeded with `{:exsss, seed}` for
  reproducible runs. Without a seed, generators draw from the calling
  process's `:rand` state. A `:seed` that is not an integer raises
  `ArgumentError`.
  """

  alias Grafi.Graph

  # ── Classical generators ─────────────────────────────────────────────

  @doc """
  Complete graph K_n on integer vertices `0..n-1`.

  ## Options
    * `:type` — `:directed` (default; both `(i, j)` and `(j, i)` for every
      distinct pair) or `:undirected`.

  ## Examples

      iex> g = Grafi.Generators.complete(4, type: :undirected)
      iex> {Grafi.Graph.num_vertices(g), Grafi.Graph.num_edges(g)}
      {4, 6}
  """
  @spec complete(non_neg_integer(), keyword()) :: Graph.t()
  def complete(n, opts \\ []) when is_integer(n) and n >= 0 do
    opts = opts!(opts, [])
    g = new_graph(n, opts)
    directed? = opts[:type] == :directed

    Enum.reduce(0..(n - 1)//1, g, fn i, acc ->
      Enum.reduce((i + 1)..(n - 1)//1, acc, fn j, a ->
        a = Graph.add_edge(a, i, j)
        if directed?, do: Graph.add_edge(a, j, i), else: a
      end)
    end)
  end

  @doc """
  Cycle graph C_n on integer vertices `0..n-1`. Edges connect each `i`
  to `i+1 mod n`. Option: `:type` (default `:directed`).

  ## Examples

      iex> g = Grafi.Generators.cycle(5)
      iex> {Grafi.Graph.num_vertices(g), Grafi.Graph.num_edges(g)}
      {5, 5}
  """
  @spec cycle(non_neg_integer(), keyword()) :: Graph.t()
  def cycle(n, opts \\ []) when is_integer(n) and n >= 0 do
    g = new_graph(n, opts!(opts, []))
    if n < 2, do: g, else: Enum.reduce(0..(n - 1)//1, g, &Graph.add_edge(&2, &1, rem(&1 + 1, n)))
  end

  @doc """
  Path graph P_n on integer vertices `0..n-1`. Edges connect each `i`
  to `i+1`. Option: `:type` (default `:directed`).

  ## Examples

      iex> g = Grafi.Generators.path(4)
      iex> {Grafi.Graph.num_vertices(g), Grafi.Graph.num_edges(g)}
      {4, 3}
  """
  @spec path(non_neg_integer(), keyword()) :: Graph.t()
  def path(n, opts \\ []) when is_integer(n) and n >= 0 do
    g = new_graph(n, opts!(opts, []))
    if n < 2, do: g, else: Enum.reduce(0..(n - 2)//1, g, &Graph.add_edge(&2, &1, &1 + 1))
  end

  @doc """
  m × n grid graph. Vertices are `{i, j}` tuples with `0 ≤ i < m` and
  `0 ≤ j < n`. Each vertex is connected to its four-axis neighbors (in
  increasing `i`/`j` direction when directed). Option: `:type` (default
  `:directed`).

  ## Examples

      iex> g = Grafi.Generators.grid(3, 4)
      iex> {Grafi.Graph.num_vertices(g), Grafi.Graph.num_edges(g)}
      {12, 17}
  """
  @spec grid(non_neg_integer(), non_neg_integer(), keyword()) :: Graph.t()
  def grid(m, n, opts \\ []) when is_integer(m) and is_integer(n) and m >= 0 and n >= 0 do
    g = Graph.new(type: opts!(opts, [])[:type])

    verts = for i <- 0..(m - 1)//1, j <- 0..(n - 1)//1, do: {i, j}
    g = Enum.reduce(verts, g, &Graph.add_vertex(&2, &1))

    g =
      Enum.reduce(verts, g, fn {i, j}, acc ->
        acc = if i + 1 < m, do: Graph.add_edge(acc, {i, j}, {i + 1, j}), else: acc
        if j + 1 < n, do: Graph.add_edge(acc, {i, j}, {i, j + 1}), else: acc
      end)

    g
  end

  # ── Random generators ────────────────────────────────────────────────

  @doc """
  Erdős–Rényi G(n, p) random graph: each potential edge is included
  independently with probability `p`. Vertices are integers `0..n-1`.

  ## Options
    * `:seed` — integer seed for reproducibility (uses `:exsss`).
    * `:type` — `:directed` (default; each ordered pair independently) or
      `:undirected`.

  ## Examples

      iex> g = Grafi.Generators.erdos_renyi(20, 0.5, seed: 1)
      iex> Grafi.Graph.num_vertices(g)
      20
  """
  @spec erdos_renyi(non_neg_integer(), float(), keyword()) :: Graph.t()
  def erdos_renyi(n, p, opts \\ [])
      when is_integer(n) and n >= 0 and is_number(p) and p >= 0 and p <= 1 do
    opts = opts!(opts, seed: nil)
    _ = seed_rand(opts)
    g = new_graph(n, opts)
    directed? = opts[:type] == :directed

    Enum.reduce(0..(n - 1)//1, g, fn i, acc ->
      js = if directed?, do: 0..(n - 1)//1, else: (i + 1)..(n - 1)//1

      Enum.reduce(js, acc, fn j, a ->
        cond do
          i == j -> a
          :rand.uniform() < p -> Graph.add_edge(a, i, j)
          true -> a
        end
      end)
    end)
  end

  @doc """
  Barabási–Albert preferential-attachment scale-free graph.

  Starts from an `(m+1)`-clique and adds `n - (m+1)` new vertices, each
  attached to `m` existing vertices chosen with probability proportional
  to current degree. Requires `1 ≤ m < n`.

  ## Options
    * `:seed` — integer seed for reproducibility.
    * `:type` — `:directed` (default; each new vertex points at its `m`
      targets) or `:undirected`.

  ## Examples

      iex> g = Grafi.Generators.barabasi_albert(20, 2, seed: 7)
      iex> Grafi.Graph.num_vertices(g)
      20
  """
  @spec barabasi_albert(pos_integer(), pos_integer(), keyword()) :: Graph.t()
  def barabasi_albert(n, m, opts \\ [])
      when is_integer(n) and is_integer(m) and m >= 1 and n > m do
    opts = opts!(opts, seed: nil)
    _ = seed_rand(opts)
    g = complete(m + 1, type: opts[:type])

    # `targets` is the multiset (as a list) used for preferential attachment;
    # each vertex appears once per incident edge.
    targets =
      for i <- 0..m, j <- 0..m, i != j, i < j, do: [i, j]

    targets = List.flatten(targets)

    {g, _targets} =
      Enum.reduce((m + 1)..(n - 1)//1, {g, targets}, fn v, {acc_g, t_acc} ->
        chosen = sample_distinct(t_acc, m)

        acc_g =
          Enum.reduce(chosen, acc_g, fn u, ag -> Graph.add_edge(ag, v, u) end)

        # Extend the multiset: each new edge contributes once for `v` and once
        # for the chosen neighbor.
        new_targets = chosen ++ List.duplicate(v, m) ++ t_acc
        {acc_g, new_targets}
      end)

    g
  end

  @doc """
  Watts–Strogatz small-world graph.

  Starts with a ring lattice on `n` vertices where each vertex is
  connected to its `k` nearest neighbors (k must be even and < n).
  Then each edge is rewired with probability `p`: the source is kept
  and the target replaced by a random other vertex, avoiding
  self-loops and duplicates.

  ## Options
    * `:seed` — integer seed for reproducibility.
    * `:type` — `:directed` (default) or `:undirected`. The lattice and
      rewiring are undirected; a directed graph orients each resulting edge
      from its smaller vertex to its larger one, so in- and out-degrees vary
      (with `p = 0.0`, vertex `i` points at `i+1..i+k/2` except where the
      ring wraps past `n - 1`).

  ## Examples

      iex> g = Grafi.Generators.watts_strogatz(20, 4, 0.0)
      iex> Grafi.Graph.num_edges(g)
      40
  """
  @spec watts_strogatz(pos_integer(), pos_integer(), float(), keyword()) :: Graph.t()
  def watts_strogatz(n, k, p, opts \\ [])
      when is_integer(n) and is_integer(k) and is_number(p) and n > k and k >= 2 and
             rem(k, 2) == 0 and p >= 0 and p <= 1 do
    opts = opts!(opts, seed: nil)
    _ = seed_rand(opts)

    # Initial ring lattice: connect each i to i+1, i+2, ..., i+k/2 (mod n).
    half = div(k, 2)

    initial_edges =
      for i <- 0..(n - 1), j <- 1..half do
        a = i
        b = rem(i + j, n)
        if a < b, do: {a, b}, else: {b, a}
      end
      |> Enum.uniq()

    edge_set = MapSet.new(initial_edges)

    rewired =
      Enum.reduce(initial_edges, edge_set, fn {a, b}, es ->
        if :rand.uniform() < p do
          # Remove (a, b) and pick a new target.
          es = MapSet.delete(es, {a, b})
          new_b = pick_new_target(a, b, n, es)
          MapSet.put(es, normalize_edge(a, new_b))
        else
          es
        end
      end)

    g = new_graph(n, opts)
    Enum.reduce(rewired, g, fn {a, b}, acc -> Graph.add_edge(acc, a, b) end)
  end

  @doc """
  Random `d`-regular graph on `n` vertices via the pairing model.

  Requires `n * d` even. Generates `d` half-edges per vertex and pairs
  them at random; rejects the attempt (up to 100 retries) if a
  self-loop or duplicate is produced.

  ## Options
    * `:seed` — integer seed for reproducibility.
    * `:type` — `:directed` (default) or `:undirected`. The pairing is
      undirected; a directed graph orients each edge from its smaller vertex
      to its larger one. Every vertex then has total (in + out) degree `d`,
      but its in- and out-degrees vary, so the graph is not regular in the
      directed sense.

  ## Examples

      iex> g = Grafi.Generators.random_regular(10, 3, seed: 42)
      iex> Grafi.Graph.num_vertices(g)
      10
  """
  @spec random_regular(pos_integer(), non_neg_integer(), keyword()) :: Graph.t()
  def random_regular(n, d, opts \\ [])
      when is_integer(n) and is_integer(d) and n > 0 and d >= 0 and
             rem(n * d, 2) == 0 and d < n do
    opts = opts!(opts, seed: nil)
    _ = seed_rand(opts)
    attempt_regular(n, d, opts, 100)
  end

  defp attempt_regular(_n, _d, _opts, 0),
    do: raise(RuntimeError, "random_regular: pairing failed after 100 attempts")

  defp attempt_regular(n, 0, opts, _tries), do: new_graph(n, opts)

  defp attempt_regular(n, d, opts, tries) do
    half_edges = for v <- 0..(n - 1), _ <- 1..d, do: v
    shuffled = Enum.shuffle(half_edges)

    case pair_off(shuffled, %{}, []) do
      :retry ->
        attempt_regular(n, d, opts, tries - 1)

      {:ok, edges} ->
        g = new_graph(n, opts)
        Enum.reduce(edges, g, fn {a, b}, acc -> Graph.add_edge(acc, a, b) end)
    end
  end

  defp pair_off([], _seen, acc), do: {:ok, acc}

  defp pair_off([a, b | rest], seen, acc) do
    e = normalize_edge(a, b)

    cond do
      a == b -> :retry
      is_map_key(seen, e) -> :retry
      true -> pair_off(rest, Map.put(seen, e, true), [e | acc])
    end
  end

  # ── Internal helpers ─────────────────────────────────────────────────

  # Validates `opts` (`:type` plus the generator's own `extra` keys, with
  # defaults) and returns them with defaults filled in.
  defp opts!(opts, extra) do
    opts = Keyword.validate!(opts, [type: :directed] ++ extra)

    unless opts[:type] in [:directed, :undirected] do
      raise ArgumentError,
            "expected :type to be :directed or :undirected, got: #{inspect(opts[:type])}"
    end

    opts
  end

  defp new_graph(n, opts) do
    g = Graph.new(type: opts[:type])
    if n == 0, do: g, else: Graph.add_vertices(g, Enum.to_list(0..(n - 1)))
  end

  defp seed_rand(opts) do
    case Keyword.get(opts, :seed) do
      nil ->
        :ok

      seed when is_integer(seed) ->
        _ = :rand.seed(:exsss, {seed, seed, seed})
        :ok

      other ->
        raise ArgumentError, "expected :seed to be an integer, got: #{inspect(other)}"
    end
  end

  # `picked` is a map `%{vertex => true}`; its keys come out in the same
  # order MapSet.to_list/1 would give, keeping seeded output unchanged.
  defp sample_distinct(pool, count) do
    do_sample(pool, %{}, count)
  end

  defp do_sample(_pool, picked, 0), do: Map.keys(picked)

  defp do_sample([], picked, _count), do: Map.keys(picked)

  defp do_sample(pool, picked, count) do
    candidate = Enum.random(pool)

    if is_map_key(picked, candidate),
      do: do_sample(pool, picked, count),
      else: do_sample(pool, Map.put(picked, candidate, true), count - 1)
  end

  defp pick_new_target(a, b, n, es) do
    candidates =
      0..(n - 1)
      |> Enum.filter(fn x ->
        x != a and x != b and not MapSet.member?(es, normalize_edge(a, x))
      end)

    case candidates do
      [] -> b
      list -> Enum.random(list)
    end
  end

  defp normalize_edge(a, b) when a <= b, do: {a, b}
  defp normalize_edge(a, b), do: {b, a}
end
