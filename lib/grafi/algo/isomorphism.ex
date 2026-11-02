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
  It uses the same feasibility pruning ideas (degree-based candidate
  filtering, look-ahead via 1-neighbour terminal sets) but is intended for
  small graphs only (≲ 12 vertices).

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
  # This is a simpler version of VF2: state-space search with degree-based
  # feasibility pruning and a "candidate from the next mapped vertex's
  # neighbourhood" heuristic to keep the branching factor down. It also
  # falls back to the unmapped pool when no neighbour candidate exists.
  # Adequate for small graphs (≤ ~12 vertices).
  #
  # The search state that never changes lives in a context map:
  #   pat_vs   : vertices of the pattern (the smaller graph)
  #   host_vs  : vertices of the host (the larger or same-size graph)
  #   pat_adj  : adjacency map for pat_vs
  #   host_adj : adjacency map for host_vs
  #   dir?     : edge mode
  #   strict?  : true for full isomorphism (degrees must match exactly),
  #              false for sub-isomorphism (host degree must dominate)
  #   deadline : monotonic millisecond deadline, or :infinity

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
    backtrack_count(context(pattern, graph, false, deadline), %{}, MapSet.new())
  end

  defp find_one(pattern, host, strict?, deadline) do
    backtrack_one(context(pattern, host, strict?, deadline), %{}, MapSet.new())
  end

  defp context(pattern, host, strict?, deadline) do
    pat_vs = Graph.vertices(pattern)
    host_vs = Graph.vertices(host)

    %{
      pat_vs: pat_vs,
      host_vs: host_vs,
      pat_adj: adjacency(pattern, pat_vs),
      host_adj: adjacency(host, host_vs),
      dir?: pattern.type == :directed,
      strict?: strict?,
      deadline: deadline
    }
  end

  defp check_deadline!(%{deadline: :infinity}), do: :ok

  defp check_deadline!(%{deadline: deadline}) do
    if System.monotonic_time(:millisecond) >= deadline, do: throw(@timeout_throw), else: :ok
  end

  # ── Internal: backtracking ───────────────────────────────────────────

  defp degree_seq(%Graph{type: :undirected} = g) do
    Graph.vertices(g) |> Enum.map(&Graph.degree(g, &1)) |> Enum.sort()
  end

  defp degree_seq(%Graph{} = g) do
    Graph.vertices(g)
    |> Enum.map(&{Graph.in_degree(g, &1), Graph.out_degree(g, &1)})
    |> Enum.sort()
  end

  # adjacency: %{v => %{out: MapSet, in: MapSet}}
  defp adjacency(g, vs) do
    Map.new(vs, fn v ->
      {v,
       %{
         out: MapSet.new(Graph.out_neighbors(g, v)),
         in: MapSet.new(Graph.in_neighbors(g, v))
       }}
    end)
  end

  # Searches for a single witness mapping (pattern vertex => host vertex), or
  # returns nil.
  defp backtrack_one(ctx, mapping, used) do
    check_deadline!(ctx)

    case pick_next_pattern_vertex(ctx.pat_vs, mapping) do
      nil ->
        mapping

      v ->
        Enum.find_value(candidates_for(v, mapping, used, ctx), fn h ->
          if consistent?(v, h, mapping, ctx),
            do: backtrack_one(ctx, Map.put(mapping, v, h), MapSet.put(used, h)),
            else: nil
        end)
    end
  end

  defp backtrack_count(ctx, mapping, used) do
    check_deadline!(ctx)

    case pick_next_pattern_vertex(ctx.pat_vs, mapping) do
      nil ->
        1

      v ->
        Enum.reduce(candidates_for(v, mapping, used, ctx), 0, fn h, acc ->
          if consistent?(v, h, mapping, ctx),
            do: acc + backtrack_count(ctx, Map.put(mapping, v, h), MapSet.put(used, h)),
            else: acc
        end)
    end
  end

  # Next pattern vertex to map: the first unmapped one, or nil when every
  # pattern vertex is mapped.
  defp pick_next_pattern_vertex(pat_vs, mapping) do
    Enum.find(pat_vs, &(not Map.has_key?(mapping, &1)))
  end

  defp candidates_for(v, mapping, used, ctx) do
    %{host_vs: host_vs, host_adj: host_adj, pat_adj: pat_adj, strict?: strict?} = ctx
    pat_deg_out = MapSet.size(pat_adj[v].out)
    pat_deg_in = MapSet.size(pat_adj[v].in)

    pool =
      Enum.filter(host_vs, fn h ->
        ho_out = MapSet.size(host_adj[h].out)
        ho_in = MapSet.size(host_adj[h].in)

        not MapSet.member?(used, h) and
          if strict? do
            # Full isomorphism: degrees must match exactly.
            ho_out == pat_deg_out and ho_in == pat_deg_in
          else
            # Sub-isomorphism: host must dominate pattern degree.
            ho_out >= pat_deg_out and ho_in >= pat_deg_in
          end
      end)

    # If some neighbour of v is already mapped, restrict candidates to
    # neighbours of that mapped host vertex. The consistency check would
    # still reject inconsistent picks, but filtering early prunes the search.
    mapped_neighbour_in_pattern =
      Enum.find(MapSet.union(pat_adj[v].out, pat_adj[v].in), &Map.has_key?(mapping, &1))

    case mapped_neighbour_in_pattern do
      nil ->
        pool

      pu ->
        h_pu = mapping[pu]
        constraint = MapSet.union(host_adj[h_pu].out, host_adj[h_pu].in)
        Enum.filter(pool, &MapSet.member?(constraint, &1))
    end
  end

  # For each already-mapped pattern neighbour u of v, mapping[u] must be a
  # corresponding neighbour of h.
  defp consistent?(v, h, mapping, %{pat_adj: pat_adj, host_adj: host_adj, dir?: dir?}) do
    pa = pat_adj[v]
    ha = host_adj[h]

    mapped_within?(pa.out, ha.out, mapping) and
      (not dir? or mapped_within?(pa.in, ha.in, mapping))
  end

  defp mapped_within?(pattern_neighbours, host_neighbours, mapping) do
    Enum.all?(pattern_neighbours, fn u ->
      case Map.fetch(mapping, u) do
        {:ok, hu} -> MapSet.member?(host_neighbours, hu)
        :error -> true
      end
    end)
  end
end
