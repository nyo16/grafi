defmodule Grafi.Algo.Isomorphism do
  @dialyzer :no_opaque

  @moduledoc """
  (Sub)graph isomorphism via the VF2 algorithm.

  Two graphs `g1` and `g2` are **isomorphic** if there is a bijection
  `f: V(g1) -> V(g2)` such that `(u, v) ∈ E(g1) ⇔ (f(u), f(v)) ∈ E(g2)`.
  A pattern `p` is **sub-isomorphic** to a host `h` if there is an injection
  `f: V(p) -> V(h)` such that every edge `(u, v)` of `p` maps to an edge
  `(f(u), f(v))` of `h`. The matched subgraph does not have to be induced: a
  path on 3 vertices is sub-isomorphic to a triangle.

  ## Backends

  Every function accepts `engine: :auto | :nif | :elixir` (see `Grafi.NIF`).
  With `:auto`, all functions use igraph's `igraph_isomorphic_vf2` /
  `igraph_subisomorphic_vf2` family whenever the NIF is available, at any
  graph size. Otherwise a pure-Elixir, VF2-style backtracking search runs.
  It extends the mapping along pattern edges, so candidates come from the
  neighbourhood of an already-mapped vertex, and prunes by degree
  (sub-isomorphism) or by colour refinement over both graphs
  (isomorphism). Random sparse graphs with thousands of vertices are
  quick, but graphs that colour refinement cannot split, such as
  non-isomorphic strongly regular graphs, can take exponential time.

  ## Timeouts

  VF2 is exponential in the worst case. Pass `timeout: milliseconds` (an
  integer in `1..0xFFFFFFFF`) or `:infinity` to bound the search on either
  engine. When the option is absent, the `:grafi` application env key
  `vf2_timeout` applies; its default is `:infinity`:

      config :grafi, vf2_timeout: 5_000

  Deployments that match graphs from untrusted input should set a finite
  `vf2_timeout`, so one adversarial graph cannot pin a dirty scheduler (or
  the calling process) indefinitely. An explicit `:timeout` always wins
  over the config value.

  A search that runs out of time returns `{:error, :timeout}` from
  `isomorphism/3`, `subgraph_isomorphism/3` and
  `count_subgraph_isomorphisms/3`, and raises `Grafi.TimeoutError` from the
  `?` predicates.

  ## Errors

  The `?` predicates always return a boolean. They raise
  `Grafi.TimeoutError` on timeout and `Grafi.NIFError` for
  `:nif_not_available` (with `engine: :nif` and no NIF) or
  `{:igraph, message}` (an unexpected igraph failure).

  The other three functions return those as `{:error, :timeout}`,
  `{:error, :nif_not_available}` and `{:error, {:igraph, message}}`.

  Every function raises `ArgumentError` if the graphs differ in
  directedness, for an invalid `:engine` or `:timeout`, or for an invalid
  `vf2_timeout` when no `:timeout` is given.

  ## Caveats

    * Vertex and edge labels are **ignored** — only structure matters.
    * Multi-edges: the igraph engine matches edge multiplicities, while the
      Elixir engine treats parallel edges as a single adjacency. The engines
      can disagree on multigraphs.
    * Self-loops: the Elixir engine maps a pattern self-loop only onto a host
      self-loop. igraph's VF2 rejects graphs with self-loops, so the NIF
      engine returns `{:error, {:igraph, message}}` for them (the `?`
      predicates raise `Grafi.NIFError`).

  ## Examples

      iex> a = Grafi.Graph.new(type: :undirected)
      ...>       |> Grafi.Graph.add_edges([{:a, :b}, {:b, :c}, {:c, :a}])
      iex> b = Grafi.Graph.new(type: :undirected)
      ...>       |> Grafi.Graph.add_edges([{1, 2}, {2, 3}, {3, 1}])
      iex> Grafi.Algo.Isomorphism.isomorphic?(a, b)
      true
  """

  alias Grafi.Args
  alias Grafi.Graph
  alias Grafi.NIF

  @type mapping :: %{Graph.vertex_id() => Graph.vertex_id()}
  @type error :: {:error, :timeout | :nif_not_available | {:igraph, String.t()}}

  @timeout_throw {__MODULE__, :timeout}
  # Duplicated in mix.exs `application/0` `env:`; keep both in sync.
  @default_vf2_timeout :infinity
  # The largest timeout the NIF can turn into a steady_clock deadline.
  @max_timeout 0xFFFF_FFFF
  # Colour refinement (Elixir engine, full isomorphism): seed depth and
  # round budget, see `refine/3`.
  @profile_depth 3
  @refine_rounds_per_bit 2

  # ── Public API ────────────────────────────────────────────────────────

  @doc """
  Returns `true` if `g1` and `g2` are isomorphic.

  Different vertex counts or edge counts immediately return `false`. The
  Elixir engine also returns `false` at once when the degree multisets
  differ, on both graph types (in/out degree pairs when directed).

  ## Options
    - `:engine` — `:auto | :nif | :elixir`, see `Grafi.NIF`
    - `:timeout` — integer milliseconds in `1..0xFFFFFFFF`, or `:infinity`;
      defaults to `config :grafi, vf2_timeout` (`:infinity` unless set)

  ## Raises
    - `Grafi.TimeoutError` if the search runs out of time
    - `Grafi.NIFError` if `engine: :nif` is unavailable or igraph fails
    - `ArgumentError` for mixed directedness, an invalid option, or an
      invalid `vf2_timeout` config when no `:timeout` is given

  ## Examples

      iex> g = Grafi.Graph.new(type: :undirected)
      ...>       |> Grafi.Graph.add_edges([{:a, :b}, {:b, :c}, {:c, :a}])
      iex> Grafi.Algo.Isomorphism.isomorphic?(g, g)
      true
  """
  @spec isomorphic?(Graph.t(), Graph.t(), keyword()) :: boolean()
  def isomorphic?(%Graph{} = g1, %Graph{} = g2, opts \\ []) do
    timeout = validate!(g1, g2, opts)

    cond do
      Graph.num_vertices(g1) != Graph.num_vertices(g2) ->
        false

      Graph.num_edges(g1) != Graph.num_edges(g2) ->
        false

      Graph.num_vertices(g1) == 0 ->
        true

      true ->
        g1
        |> dispatch(
          opts,
          timeout,
          fn t -> unwrap_ok(nif2(&NIF.nif_isomorphic_vf2/3, g1, g2, t)) end,
          fn deadline -> elixir_isomorphic?(g1, g2, deadline) end
        )
        |> boolean!(timeout)
    end
  end

  @doc """
  Returns `true` if `pattern` is sub-isomorphic to `graph`.

  Accepts the same options, and raises the same exceptions, as
  `isomorphic?/3`.

  ## Examples

      iex> tri = Grafi.Graph.new(type: :undirected)
      ...>         |> Grafi.Graph.add_edges([{1, 2}, {2, 3}, {3, 1}])
      iex> k4 = Grafi.Graph.new(type: :undirected)
      ...>        |> Grafi.Graph.add_edges(for(i <- 1..3, j <- (i + 1)..4, do: {i, j}))
      iex> Grafi.Algo.Isomorphism.subgraph_isomorphic?(k4, tri)
      true
  """
  @spec subgraph_isomorphic?(Graph.t(), Graph.t(), keyword()) :: boolean()
  def subgraph_isomorphic?(%Graph{} = graph, %Graph{} = pattern, opts \\ []) do
    timeout = validate!(graph, pattern, opts)

    cond do
      Graph.num_vertices(pattern) == 0 ->
        true

      Graph.num_vertices(pattern) > Graph.num_vertices(graph) ->
        false

      true ->
        graph
        |> dispatch(
          opts,
          timeout,
          fn t -> unwrap_ok(nif2(&NIF.nif_subisomorphic_vf2/3, graph, pattern, t)) end,
          fn deadline -> find_one_subiso(graph, pattern, deadline) != nil end
        )
        |> boolean!(timeout)
    end
  end

  @doc """
  Returns `{:ok, mapping}` with one witness isomorphism between `g1` and
  `g2`, or `:no_isomorphism`.

  The returned mapping has keys from `g1`'s vertex set and values from
  `g2`'s vertex set. Accepts the same options as `isomorphic?/3`.

  Returns `{:error, :timeout}` if the search runs out of time,
  `{:error, :nif_not_available}` if `engine: :nif` is unavailable, and
  `{:error, {:igraph, message}}` if igraph fails.
  """
  @spec isomorphism(Graph.t(), Graph.t(), keyword()) ::
          {:ok, mapping()} | :no_isomorphism | error()
  def isomorphism(%Graph{} = g1, %Graph{} = g2, opts \\ []) do
    timeout = validate!(g1, g2, opts)

    cond do
      Graph.num_vertices(g1) != Graph.num_vertices(g2) ->
        :no_isomorphism

      Graph.num_edges(g1) != Graph.num_edges(g2) ->
        :no_isomorphism

      Graph.num_vertices(g1) == 0 ->
        {:ok, %{}}

      true ->
        dispatch(
          g1,
          opts,
          timeout,
          fn t -> nif_isomorphism(g1, g2, t) end,
          fn deadline -> elixir_isomorphism(g1, g2, deadline) end
        )
    end
  end

  @doc """
  Returns `{:ok, mapping}` with one witness sub-isomorphism (keys are
  `pattern` vertices, values are `graph` vertices), or `:no_isomorphism`.

  Accepts the same options as `isomorphic?/3` and returns the same
  `{:error, _}` tuples as `isomorphism/3`.
  """
  @spec subgraph_isomorphism(Graph.t(), Graph.t(), keyword()) ::
          {:ok, mapping()} | :no_isomorphism | error()
  def subgraph_isomorphism(%Graph{} = graph, %Graph{} = pattern, opts \\ []) do
    timeout = validate!(graph, pattern, opts)

    cond do
      Graph.num_vertices(pattern) == 0 ->
        {:ok, %{}}

      Graph.num_vertices(pattern) > Graph.num_vertices(graph) ->
        :no_isomorphism

      true ->
        dispatch(
          graph,
          opts,
          timeout,
          fn t -> nif_subgraph_isomorphism(graph, pattern, t) end,
          fn deadline ->
            case find_one_subiso(graph, pattern, deadline) do
              nil -> :no_isomorphism
              mapping -> {:ok, mapping}
            end
          end
        )
    end
  end

  @doc """
  Returns the number of distinct sub-isomorphisms from `pattern` into
  `graph`.

  Note that automorphisms of `pattern` produce distinct mappings even when
  they hit the same vertex set in `graph` — for example a triangle pattern
  matched into K_3 yields 6 sub-isomorphisms (3! orderings), not 1. This
  matches igraph's `igraph_count_subisomorphisms_vf2` semantics.

  Accepts the same options as `isomorphic?/3` and returns the same
  `{:error, _}` tuples as `isomorphism/3`.
  """
  @spec count_subgraph_isomorphisms(Graph.t(), Graph.t(), keyword()) ::
          non_neg_integer() | error()
  def count_subgraph_isomorphisms(%Graph{} = graph, %Graph{} = pattern, opts \\ []) do
    timeout = validate!(graph, pattern, opts)

    cond do
      Graph.num_vertices(pattern) == 0 ->
        1

      Graph.num_vertices(pattern) > Graph.num_vertices(graph) ->
        0

      true ->
        dispatch(
          graph,
          opts,
          timeout,
          fn t -> unwrap_ok(nif2(&NIF.nif_count_subisomorphisms_vf2/3, graph, pattern, t)) end,
          fn deadline -> elixir_count_subgraph_isomorphisms(graph, pattern, deadline) end
        )
    end
  end

  # ── Dispatch helpers ──────────────────────────────────────────────────

  # Runs every argument check before the early returns, so invalid options
  # raise on every input. Returns the resolved timeout.
  defp validate!(g1, g2, opts) do
    Args.engine!(opts)
    same_kind!(g1, g2)
    resolve_timeout(opts, Application.get_env(:grafi, :vf2_timeout, @default_vf2_timeout))
  end

  defp same_kind!(%Graph{type: a}, %Graph{type: b}) when a == b, do: :ok

  defp same_kind!(_, _),
    do: raise(ArgumentError, "isomorphism requires both graphs to have the same type")

  @doc false
  # The effective VF2 timeout: an explicit `:timeout` option wins over the
  # `config :grafi, vf2_timeout` value, which is validated only when used.
  # Pure, so the config path is testable without global state.
  @spec resolve_timeout(keyword(), term()) :: pos_integer() | :infinity
  def resolve_timeout(opts, config_value) do
    case Keyword.fetch(opts, :timeout) do
      {:ok, value} -> timeout!(value, ":timeout")
      :error -> timeout!(config_value, "config :grafi, vf2_timeout")
    end
  end

  defp timeout!(:infinity, _source), do: :infinity
  defp timeout!(ms, _source) when is_integer(ms) and ms in 1..@max_timeout, do: ms

  defp timeout!(other, source) do
    raise ArgumentError,
          "expected #{source} to be an integer in 1..#{@max_timeout} (milliseconds) " <>
            "or :infinity, got: #{inspect(other)}"
  end

  # VF2 has an Elixir engine, so `:auto` prefers the NIF at any size rather
  # than applying :nif_threshold. `nif_fun` receives the NIF's timeout
  # argument (0 = none); `elixir_fun` receives an absolute monotonic deadline.
  defp dispatch(host, opts, timeout, nif_fun, elixir_fun) do
    case NIF.engine(host, opts, prefer: :nif) do
      :nif -> nif_fun.(if timeout == :infinity, do: 0, else: timeout)
      :elixir -> run_elixir(timeout, elixir_fun)
      {:error, _} = error -> error
    end
  end

  # The `?` predicates promise a strict boolean, so the error tuples the
  # other functions return become exceptions here.
  defp boolean!(result, _timeout) when is_boolean(result), do: result
  defp boolean!({:error, :timeout}, timeout), do: raise(Grafi.TimeoutError, timeout: timeout)
  defp boolean!({:error, reason}, _timeout), do: raise(Grafi.NIFError, reason: reason)

  defp run_elixir(timeout, fun) do
    deadline =
      if timeout == :infinity,
        do: :infinity,
        else: System.monotonic_time(:millisecond) + timeout

    fun.(deadline)
  catch
    :throw, @timeout_throw -> {:error, :timeout}
  end

  # ── NIF dispatch ──────────────────────────────────────────────────────

  defp nif2(nif_fun, g1, g2, timeout_ms) do
    {_, csr1} = Graph.to_csr(g1)
    {_, csr2} = Graph.to_csr(g2)
    NIF.call(nif_fun.(csr1, csr2, timeout_ms))
  end

  defp unwrap_ok({:ok, value}), do: value
  defp unwrap_ok({:error, _} = error), do: error

  defp nif_isomorphism(g1, g2, timeout_ms) do
    {_, csr1} = Graph.to_csr(g1)
    {_, csr2} = Graph.to_csr(g2)

    case NIF.call(NIF.nif_isomorphism_vf2(csr1, csr2, timeout_ms)) do
      {:ok, map12} ->
        mapping =
          map12
          |> Enum.with_index()
          |> Map.new(fn {j, i} -> {elem(csr1.vertices, i), elem(csr2.vertices, j)} end)

        {:ok, mapping}

      {:error, :no_isomorphism} ->
        :no_isomorphism

      {:error, _} = error ->
        error
    end
  end

  # igraph's subisomorphic_vf2(G, P) returns map12 of length |V(G)| where
  # entry i is the pattern vertex that host vertex i was mapped to (or -1 if
  # host vertex i isn't part of the match). Invert it to pattern -> host.
  defp nif_subgraph_isomorphism(graph, pattern, timeout_ms) do
    {_, csr_g} = Graph.to_csr(graph)
    {_, csr_p} = Graph.to_csr(pattern)

    case NIF.call(NIF.nif_subgraph_isomorphism_vf2(csr_g, csr_p, timeout_ms)) do
      {:ok, map12} ->
        mapping =
          for {p_idx, g_idx} <- Enum.with_index(map12), p_idx != -1, into: %{} do
            {elem(csr_p.vertices, p_idx), elem(csr_g.vertices, g_idx)}
          end

        {:ok, mapping}

      {:error, :no_isomorphism} ->
        :no_isomorphism

      {:error, _} = error ->
        error
    end
  end

  # ── Pure-Elixir VF2-style backtracking fallback ───────────────────────
  #
  # A simpler version of VF2: state-space search over a pattern order
  # computed once (see `search_order/3`). Every vertex after a component
  # root has an earlier neighbour, its BFS parent, so its candidates are the
  # host neighbours of the parent's image rather than the whole host. Each
  # step also lists the pattern edges to earlier vertices, so the
  # consistency check reads only those.
  #
  # Every vertex has a key that a match must respect:
  #   * sub-isomorphism: `{out_degree, in_degree}`, and the host vertex's
  #     degrees must dominate the pattern vertex's;
  #   * full isomorphism: a colour from `refine/3` (colour refinement over
  #     both graphs), which must be equal. Colours subsume degrees and split
  #     regular graphs that degrees cannot.
  #
  # The search state that never changes lives in a context map:
  #   host_vs    : vertices of the host (the larger or same-size graph)
  #   host_adj   : %{h => {out :: MapSet, in :: MapSet}}
  #   host_key   : %{h => key}
  #   host_class : %{key => [h]} (full isomorphism only; root candidates)
  #   strict?    : true for full isomorphism, false for sub-isomorphism
  #   deadline   : monotonic millisecond deadline, or :infinity

  defp elixir_isomorphic?(g1, g2, deadline) do
    degree_seq(g1) == degree_seq(g2) and find_one(g1, g2, true, deadline) != nil
  end

  defp elixir_isomorphism(g1, g2, deadline) do
    with true <- degree_seq(g1) == degree_seq(g2),
         mapping when mapping != nil <- find_one(g1, g2, true, deadline) do
      {:ok, mapping}
    else
      _ -> :no_isomorphism
    end
  end

  defp find_one_subiso(graph, pattern, deadline), do: find_one(pattern, graph, false, deadline)

  defp elixir_count_subgraph_isomorphisms(graph, pattern, deadline) do
    {:ok, steps, ctx} = prepare(pattern, graph, false, deadline)
    backtrack_count(steps, %{}, MapSet.new(), ctx)
  end

  defp find_one(pattern, host, strict?, deadline) do
    case prepare(pattern, host, strict?, deadline) do
      {:ok, steps, ctx} -> backtrack_one(steps, %{}, MapSet.new(), ctx)
      :mismatch -> nil
    end
  end

  # Returns `{:ok, steps, ctx}`, or `:mismatch` when the colour classes
  # already rule out an isomorphism.
  defp prepare(pattern, host, strict?, deadline) do
    pat_adj = adjacency(pattern)
    host_adj = adjacency(host)
    dir? = pattern.type == :directed

    with {:ok, pat_key, host_key} <- keys(pat_adj, host_adj, dir?, strict?) do
      ctx = %{
        host_vs: Graph.vertices(host),
        host_adj: host_adj,
        host_key: host_key,
        host_class: if(strict?, do: Enum.group_by(host_key, &elem(&1, 1), &elem(&1, 0))),
        strict?: strict?,
        deadline: deadline
      }

      {:ok, search_order(pat_adj, pat_key, dir?), ctx}
    end
  end

  defp keys(pat_adj, host_adj, _dir?, false), do: {:ok, degrees(pat_adj), degrees(host_adj)}
  defp keys(pat_adj, host_adj, dir?, true), do: refine(pat_adj, host_adj, dir?)

  defp degrees(adj),
    do: Map.new(adj, fn {v, {out, in_}} -> {v, {MapSet.size(out), MapSet.size(in_)}} end)

  defp check_deadline!(%{deadline: :infinity}), do: :ok

  defp check_deadline!(%{deadline: deadline}) do
    if System.monotonic_time(:millisecond) >= deadline, do: throw(@timeout_throw), else: :ok
  end

  defp degree_seq(%Graph{type: :undirected} = g) do
    Graph.vertices(g) |> Enum.map(&Graph.degree(g, &1)) |> Enum.sort()
  end

  defp degree_seq(%Graph{} = g) do
    Graph.vertices(g)
    |> Enum.map(&{Graph.in_degree(g, &1), Graph.out_degree(g, &1)})
    |> Enum.sort()
  end

  # %{v => {out :: MapSet, in :: MapSet}}. Undirected graphs list every
  # neighbour in both sets.
  defp adjacency(g) do
    Map.new(Graph.vertices(g), fn v ->
      {v, {MapSet.new(Graph.out_neighbors(g, v)), MapSet.new(Graph.in_neighbors(g, v))}}
    end)
  end

  # ── Internal: search order ───────────────────────────────────────────

  # The pattern vertices in search order, as steps
  # `{v, parent, back_out, back_in, loop?, key}`:
  #
  #   * the order is a BFS of each component, rooted at the vertex with the
  #     rarest key (then the highest degree), visiting neighbours in the
  #     same order, so the most constrained vertices come first;
  #   * `parent` is `nil` for a root, else `{p, :out}` (edge p -> v, so v's
  #     image is an out-neighbour of p's) or `{p, :in}` (edge v -> p);
  #   * `back_out`/`back_in` are v's out-/in-neighbours earlier in the
  #     order, whose images must be out-/in-neighbours of v's image
  #     (`back_in` is empty for undirected graphs, whose sets are equal);
  #   * `loop?` is whether v has a self-loop.
  defp search_order(pat_adj, pat_key, dir?) do
    key_count = pat_key |> Map.values() |> Enum.frequencies()

    rank =
      Map.new(pat_adj, fn {v, {o, i}} ->
        {v, {Map.fetch!(key_count, Map.fetch!(pat_key, v)), -(MapSet.size(o) + MapSet.size(i))}}
      end)

    {order, _seen} =
      pat_adj
      |> Map.keys()
      |> Enum.sort_by(&Map.fetch!(rank, &1))
      |> Enum.reduce({[], MapSet.new()}, fn root, {order, seen} ->
        if MapSet.member?(seen, root),
          do: {order, seen},
          else:
            bfs_order(:queue.from_list([{root, nil}]), MapSet.put(seen, root), order, pat_adj, rank)
      end)

    order = Enum.reverse(order)
    pos = order |> Enum.with_index() |> Map.new(fn {{v, _parent}, i} -> {v, i} end)

    Enum.map(order, fn {v, parent} ->
      {out, in_} = Map.fetch!(pat_adj, v)
      earlier? = &(&1 != v and Map.fetch!(pos, &1) < Map.fetch!(pos, v))
      back_out = Enum.filter(out, earlier?)
      back_in = if dir?, do: Enum.filter(in_, earlier?), else: []
      {v, parent, back_out, back_in, MapSet.member?(out, v), Map.fetch!(pat_key, v)}
    end)
  end

  defp bfs_order(queue, seen, order, pat_adj, rank) do
    case :queue.out(queue) do
      {:empty, _} ->
        {order, seen}

      {{:value, {v, _parent} = entry}, queue} ->
        {out, in_} = Map.fetch!(pat_adj, v)

        next =
          out
          |> MapSet.union(in_)
          |> Enum.reject(&MapSet.member?(seen, &1))
          |> Enum.sort_by(&Map.fetch!(rank, &1))

        queue =
          Enum.reduce(next, queue, fn u, q ->
            :queue.in({u, {v, if(MapSet.member?(out, u), do: :out, else: :in)}}, q)
          end)

        bfs_order(queue, Enum.into(next, seen), [entry | order], pat_adj, rank)
    end
  end

  # ── Internal: backtracking ───────────────────────────────────────────

  # Searches for a single witness mapping (pattern vertex => host vertex), or
  # returns nil.
  defp backtrack_one([], mapping, _used, _ctx), do: mapping

  defp backtrack_one([{v, _, _, _, _, _} = step | rest], mapping, used, ctx) do
    check_deadline!(ctx)

    Enum.find_value(candidates(step, mapping, ctx), fn h ->
      if feasible?(step, h, mapping, used, ctx),
        do: backtrack_one(rest, Map.put(mapping, v, h), MapSet.put(used, h), ctx),
        else: nil
    end)
  end

  defp backtrack_count([], _mapping, _used, _ctx), do: 1

  defp backtrack_count([{v, _, _, _, _, _} = step | rest], mapping, used, ctx) do
    check_deadline!(ctx)

    Enum.reduce(candidates(step, mapping, ctx), 0, fn h, acc ->
      if feasible?(step, h, mapping, used, ctx),
        do: acc + backtrack_count(rest, Map.put(mapping, v, h), MapSet.put(used, h), ctx),
        else: acc
    end)
  end

  # A root may map anywhere; any other vertex must map next to its parent's
  # image, along the parent edge's direction.
  defp candidates({_v, nil, _, _, _, key}, _mapping, %{strict?: true} = ctx),
    do: Map.get(ctx.host_class, key, [])

  defp candidates({_v, nil, _, _, _, _}, _mapping, ctx), do: ctx.host_vs

  defp candidates({_v, {p, dir}, _, _, _, _}, mapping, ctx) do
    {out, in_} = Map.fetch!(ctx.host_adj, Map.fetch!(mapping, p))
    if dir == :out, do: out, else: in_
  end

  defp feasible?({_v, _parent, back_out, back_in, loop?, key}, h, mapping, used, ctx) do
    {h_out, h_in} = Map.fetch!(ctx.host_adj, h)

    not MapSet.member?(used, h) and
      key_fits?(Map.fetch!(ctx.host_key, h), key, ctx.strict?) and
      (not loop? or MapSet.member?(h_out, h)) and
      Enum.all?(back_out, &MapSet.member?(h_out, Map.fetch!(mapping, &1))) and
      Enum.all?(back_in, &MapSet.member?(h_in, Map.fetch!(mapping, &1)))
  end

  # Full isomorphism: colours must be equal. Sub-isomorphism: the host
  # degrees must dominate the pattern degrees.
  defp key_fits?(host_colour, pat_colour, true), do: host_colour == pat_colour

  defp key_fits?({h_out, h_in}, {p_out, p_in}, false), do: h_out >= p_out and h_in >= p_in

  # ── Internal: colour refinement ──────────────────────────────────────

  # Colour refinement (1-dimensional Weisfeiler–Leman) run on both graphs
  # at once, so equal colours mean the same thing in each: an isomorphism
  # can only map a vertex to one of the same colour. The seed colour is
  # the degrees, the self-loop flag, and the number of vertices at
  # distance 1..`@profile_depth` (ignoring direction), which also splits
  # regular graphs; each round then appends the sorted colours of the out-
  # (and, if directed, in-) neighbours. Stops when a round splits no class,
  # or after `@refine_rounds_per_bit` rounds per bit of the vertex count
  # (any round's colours are valid, later ones only prune more).
  #
  # Returns `{:ok, colours1, colours2}`, or `:mismatch` when the two graphs
  # have different numbers of vertices of some colour.
  defp refine(adj1, adj2, dir?) do
    max_rounds = @refine_rounds_per_bit * bit_length(map_size(adj1))
    {c1, c2, classes} = intern(seed_colours(adj1), seed_colours(adj2))
    refine(c1, c2, classes, adj1, adj2, dir?, max_rounds)
  end

  defp refine(c1, c2, classes, adj1, adj2, dir?, rounds_left) do
    cond do
      histogram(c1) != histogram(c2) ->
        :mismatch

      rounds_left == 0 ->
        {:ok, c1, c2}

      true ->
        case intern(signatures(c1, adj1, dir?), signatures(c2, adj2, dir?)) do
          {_, _, ^classes} -> {:ok, c1, c2}
          {d1, d2, more} -> refine(d1, d2, more, adj1, adj2, dir?, rounds_left - 1)
        end
    end
  end

  defp seed_colours(adj) do
    undirected = Map.new(adj, fn {v, {out, in_}} -> {v, MapSet.to_list(MapSet.union(out, in_))} end)

    Map.new(adj, fn {v, {out, in_}} ->
      {v, {MapSet.size(out), MapSet.size(in_), MapSet.member?(out, v), layer_sizes(undirected, v)}}
    end)
  end

  # The number of vertices at distance 1, 2, .. @profile_depth from v.
  defp layer_sizes(undirected, v) do
    {sizes, _frontier, _seen} =
      Enum.reduce(1..@profile_depth, {[], [v], MapSet.new([v])}, fn _, {sizes, frontier, seen} ->
        next =
          frontier
          |> Enum.flat_map(&Map.fetch!(undirected, &1))
          |> Enum.reject(&MapSet.member?(seen, &1))
          |> Enum.uniq()

        {[length(next) | sizes], next, Enum.into(next, seen)}
      end)

    Enum.reverse(sizes)
  end

  defp signatures(colours, adj, dir?) do
    Map.new(adj, fn {v, {out, in_}} ->
      in_colours = if dir?, do: neighbour_colours(colours, in_), else: []
      {v, {Map.fetch!(colours, v), neighbour_colours(colours, out), in_colours}}
    end)
  end

  defp neighbour_colours(colours, vs), do: vs |> Enum.map(&Map.fetch!(colours, &1)) |> Enum.sort()

  # Replaces each signature by its rank among the distinct signatures of
  # both graphs. Signatures hold no vertex ids, so the ranks agree across
  # the graphs. Also returns the number of distinct signatures.
  defp intern(sig1, sig2) do
    ids =
      (Map.values(sig1) ++ Map.values(sig2))
      |> Enum.uniq()
      |> Enum.sort()
      |> Enum.with_index()
      |> Map.new()

    rename = fn sigs -> Map.new(sigs, fn {v, sig} -> {v, Map.fetch!(ids, sig)} end) end
    {rename.(sig1), rename.(sig2), map_size(ids)}
  end

  defp histogram(colours), do: colours |> Map.values() |> Enum.frequencies()

  defp bit_length(n) when n < 2, do: 1
  defp bit_length(n), do: 1 + bit_length(div(n, 2))
end
