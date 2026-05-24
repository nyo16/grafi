defmodule Grafi.Algo.Isomorphism do
  @moduledoc """
  (Sub)graph isomorphism via the VF2 algorithm.

  Two graphs `g1` and `g2` are **isomorphic** if there is a bijection
  `f: V(g1) -> V(g2)` such that `(u, v) ∈ E(g1) ⇔ (f(u), f(v)) ∈ E(g2)`.
  A pattern `p` is **sub-isomorphic** to a host `h` if `p` is isomorphic to
  some vertex-induced subgraph of `h`.

  ## Backends

  When the igraph NIF is loaded, all functions in this module dispatch to
  igraph's battle-tested `igraph_isomorphic_vf2` / `igraph_subisomorphic_vf2`
  family. Otherwise a pure-Elixir, VF2-style backtracking search runs as a
  fallback. The fallback uses the same feasibility pruning ideas
  (degree-based candidate filtering, look-ahead via 1-neighbour terminal
  sets) but is intended for small graphs only (≲ 12 vertices).

  ## Caveats

    * Both graphs must have the same directedness (`:directed`/`:undirected`).
      Otherwise `ArgumentError` is raised.
    * Vertex and edge labels are **ignored** — only structure matters.
    * Multi-edges and self-loops in the input contribute only as a single
      adjacency for matching purposes (matches igraph's VF2 behaviour).

  ## Examples

      iex> a = Grafi.Graph.new(type: :undirected)
      ...>       |> Grafi.Graph.add_edges([{:a, :b}, {:b, :c}, {:c, :a}])
      iex> b = Grafi.Graph.new(type: :undirected)
      ...>       |> Grafi.Graph.add_edges([{1, 2}, {2, 3}, {3, 1}])
      iex> Grafi.Algo.Isomorphism.isomorphic?(a, b)
      true
  """

  alias Grafi.Graph

  @type mapping :: %{Graph.vertex_id() => Graph.vertex_id()}

  # ── Public API ────────────────────────────────────────────────────────

  @doc """
  Returns `true` if `g1` and `g2` are isomorphic.

  Different vertex counts or edge counts immediately return `false`. For
  undirected graphs, mismatched degree multisets are an instant `false`.

  ## Examples

      iex> g = Grafi.Graph.new(type: :undirected)
      ...>       |> Grafi.Graph.add_edges([{:a, :b}, {:b, :c}, {:c, :a}])
      iex> Grafi.Algo.Isomorphism.isomorphic?(g, g)
      true
  """
  @spec isomorphic?(Graph.t(), Graph.t()) :: boolean()
  def isomorphic?(%Graph{} = g1, %Graph{} = g2) do
    same_kind!(g1, g2)

    cond do
      Graph.num_vertices(g1) != Graph.num_vertices(g2) -> false
      Graph.num_edges(g1) != Graph.num_edges(g2) -> false
      Graph.num_vertices(g1) == 0 -> true
      use_nif?(g1, g2) -> nif_isomorphic?(g1, g2)
      true -> elixir_isomorphic?(g1, g2)
    end
  end

  @doc """
  Returns `true` if `pattern` is sub-isomorphic to `graph`.

  ## Examples

      iex> tri = Grafi.Graph.new(type: :undirected)
      ...>         |> Grafi.Graph.add_edges([{1, 2}, {2, 3}, {3, 1}])
      iex> k4 = Grafi.Graph.new(type: :undirected)
      ...>        |> Grafi.Graph.add_edges(for(i <- 1..3, j <- (i + 1)..4, do: {i, j}))
      iex> Grafi.Algo.Isomorphism.subgraph_isomorphic?(k4, tri)
      true
  """
  @spec subgraph_isomorphic?(Graph.t(), Graph.t()) :: boolean()
  def subgraph_isomorphic?(%Graph{} = graph, %Graph{} = pattern) do
    same_kind!(graph, pattern)

    cond do
      Graph.num_vertices(pattern) == 0 -> true
      Graph.num_vertices(pattern) > Graph.num_vertices(graph) -> false
      use_nif?(graph, pattern) -> nif_subisomorphic?(graph, pattern)
      true -> elixir_subgraph_isomorphic?(graph, pattern)
    end
  end

  @doc """
  Returns `{:ok, mapping}` with one witness isomorphism between `g1` and
  `g2`, or `:no_isomorphism`.

  The returned mapping has keys from `g1`'s vertex set and values from
  `g2`'s vertex set.
  """
  @spec isomorphism(Graph.t(), Graph.t()) :: {:ok, mapping()} | :no_isomorphism
  def isomorphism(%Graph{} = g1, %Graph{} = g2) do
    same_kind!(g1, g2)

    cond do
      Graph.num_vertices(g1) != Graph.num_vertices(g2) ->
        :no_isomorphism

      Graph.num_edges(g1) != Graph.num_edges(g2) ->
        :no_isomorphism

      Graph.num_vertices(g1) == 0 ->
        {:ok, %{}}

      use_nif?(g1, g2) ->
        nif_isomorphism(g1, g2)

      true ->
        elixir_isomorphism(g1, g2)
    end
  end

  @doc """
  Returns `{:ok, mapping}` with one witness sub-isomorphism (keys are
  `pattern` vertices, values are `graph` vertices), or `:no_isomorphism`.
  """
  @spec subgraph_isomorphism(Graph.t(), Graph.t()) :: {:ok, mapping()} | :no_isomorphism
  def subgraph_isomorphism(%Graph{} = graph, %Graph{} = pattern) do
    same_kind!(graph, pattern)

    cond do
      Graph.num_vertices(pattern) == 0 ->
        {:ok, %{}}

      Graph.num_vertices(pattern) > Graph.num_vertices(graph) ->
        :no_isomorphism

      use_nif?(graph, pattern) ->
        nif_subgraph_isomorphism(graph, pattern)

      true ->
        elixir_subgraph_isomorphism(graph, pattern)
    end
  end

  @doc """
  Returns the number of distinct sub-isomorphisms from `pattern` into
  `graph`.

  Note that automorphisms of `pattern` produce distinct mappings even when
  they hit the same vertex set in `graph` — for example a triangle pattern
  matched into K_3 yields 6 sub-isomorphisms (3! orderings), not 1. This
  matches igraph's `igraph_count_subisomorphisms_vf2` semantics.
  """
  @spec count_subgraph_isomorphisms(Graph.t(), Graph.t()) :: non_neg_integer()
  def count_subgraph_isomorphisms(%Graph{} = graph, %Graph{} = pattern) do
    same_kind!(graph, pattern)

    cond do
      Graph.num_vertices(pattern) == 0 ->
        1

      Graph.num_vertices(pattern) > Graph.num_vertices(graph) ->
        0

      use_nif?(graph, pattern) ->
        nif_count_subisomorphisms(graph, pattern)

      true ->
        elixir_count_subgraph_isomorphisms(graph, pattern)
    end
  end

  # ── Dispatch helpers ──────────────────────────────────────────────────

  defp same_kind!(%Graph{type: a}, %Graph{type: b}) when a == b, do: :ok

  defp same_kind!(_, _),
    do: raise(ArgumentError, "isomorphism requires both graphs to have the same type")

  defp use_nif? do
    Grafi.NIF.available?() and Application.get_env(:grafi, :nif_enabled, true)
  end

  defp use_nif?(_g1, _g2), do: use_nif?()

  # ── NIF dispatch ──────────────────────────────────────────────────────

  defp nif_isomorphic?(g1, g2) do
    {_, csr1} = Graph.to_csr(g1)
    {_, csr2} = Graph.to_csr(g2)
    Grafi.NIF.validate_csr!(csr1)
    Grafi.NIF.validate_csr!(csr2)

    case Grafi.NIF.nif_isomorphic_vf2(csr1, csr2) do
      {:ok, iso} -> iso
    end
  end

  defp nif_subisomorphic?(graph, pattern) do
    {_, csr_g} = Graph.to_csr(graph)
    {_, csr_p} = Graph.to_csr(pattern)
    Grafi.NIF.validate_csr!(csr_g)
    Grafi.NIF.validate_csr!(csr_p)

    case Grafi.NIF.nif_subisomorphic_vf2(csr_g, csr_p) do
      {:ok, iso} -> iso
    end
  end

  defp nif_isomorphism(g1, g2) do
    {idx1, csr1} = Graph.to_csr(g1)
    {idx2, csr2} = Graph.to_csr(g2)
    Grafi.NIF.validate_csr!(csr1)
    Grafi.NIF.validate_csr!(csr2)

    rev1 = reverse_index(idx1)
    rev2 = reverse_index(idx2)

    case Grafi.NIF.nif_isomorphism_vf2(csr1, csr2) do
      {:ok, map12} ->
        mapping =
          map12
          |> Enum.with_index()
          |> Map.new(fn {j, i} -> {Map.fetch!(rev1, i), Map.fetch!(rev2, j)} end)

        {:ok, mapping}

      {:error, :no_isomorphism} ->
        :no_isomorphism
    end
  end

  defp nif_subgraph_isomorphism(graph, pattern) do
    # igraph's subisomorphic_vf2(G, P) returns map12 of length |V(G)|
    # where entry i is the pattern vertex that host vertex i was mapped
    # to (or -1 if host vertex i isn't part of the match). We invert to
    # produce a pattern -> host mapping.
    {idx_g, csr_g} = Graph.to_csr(graph)
    {idx_p, csr_p} = Graph.to_csr(pattern)
    Grafi.NIF.validate_csr!(csr_g)
    Grafi.NIF.validate_csr!(csr_p)

    rev_g = reverse_index(idx_g)
    rev_p = reverse_index(idx_p)

    case Grafi.NIF.nif_subgraph_isomorphism_vf2(csr_g, csr_p) do
      {:ok, map12} ->
        mapping =
          map12
          |> Enum.with_index()
          |> Enum.reduce(%{}, fn {p_idx, g_idx}, acc ->
            if p_idx == -1 do
              acc
            else
              Map.put(acc, Map.fetch!(rev_p, p_idx), Map.fetch!(rev_g, g_idx))
            end
          end)

        {:ok, mapping}

      {:error, :no_isomorphism} ->
        :no_isomorphism
    end
  end

  defp nif_count_subisomorphisms(graph, pattern) do
    {_, csr_g} = Graph.to_csr(graph)
    {_, csr_p} = Graph.to_csr(pattern)
    Grafi.NIF.validate_csr!(csr_g)
    Grafi.NIF.validate_csr!(csr_p)

    case Grafi.NIF.nif_count_subisomorphisms_vf2(csr_g, csr_p) do
      {:ok, n} -> n
    end
  end

  defp reverse_index(idx), do: Map.new(idx, fn {v, i} -> {i, v} end)

  # ── Pure-Elixir VF2-style backtracking fallback ───────────────────────
  #
  # This is a simpler version of VF2: state-space search with degree-based
  # feasibility pruning and a "candidate from the next mapped vertex's
  # neighbourhood" heuristic to keep the branching factor down. It also
  # falls back to the unmapped pool when no neighbour candidate exists.
  # Adequate for small graphs (≤ ~12 vertices).

  defp elixir_isomorphic?(g1, g2) do
    if degree_seq(g1) != degree_seq(g2),
      do: false,
      else: find_one_iso(g1, g2) != nil
  end

  defp elixir_isomorphism(g1, g2) do
    if degree_seq(g1) != degree_seq(g2) do
      :no_isomorphism
    else
      case find_one_iso(g1, g2) do
        nil -> :no_isomorphism
        mapping -> {:ok, mapping}
      end
    end
  end

  defp elixir_subgraph_isomorphic?(graph, pattern) do
    find_one_subiso(graph, pattern) != nil
  end

  defp elixir_subgraph_isomorphism(graph, pattern) do
    case find_one_subiso(graph, pattern) do
      nil -> :no_isomorphism
      mapping -> {:ok, mapping}
    end
  end

  defp elixir_count_subgraph_isomorphisms(graph, pattern) do
    pattern_vs = Graph.vertices(pattern)
    host_vs = Graph.vertices(graph)
    pattern_adj = adjacency(pattern, pattern_vs)
    host_adj = adjacency(graph, host_vs)

    backtrack_count(
      pattern_vs,
      host_vs,
      pattern_adj,
      host_adj,
      pattern.type == :directed,
      pattern,
      graph,
      %{},
      MapSet.new()
    )
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

  defp find_one_iso(g1, g2) do
    vs1 = Graph.vertices(g1)
    vs2 = Graph.vertices(g2)
    adj1 = adjacency(g1, vs1)
    adj2 = adjacency(g2, vs2)
    directed? = g1.type == :directed
    backtrack_one(vs1, vs2, adj1, adj2, directed?, g1, g2, %{}, MapSet.new(), true)
  end

  defp find_one_subiso(graph, pattern) do
    pattern_vs = Graph.vertices(pattern)
    host_vs = Graph.vertices(graph)
    pattern_adj = adjacency(pattern, pattern_vs)
    host_adj = adjacency(graph, host_vs)
    directed? = pattern.type == :directed

    backtrack_one(
      pattern_vs,
      host_vs,
      pattern_adj,
      host_adj,
      directed?,
      pattern,
      graph,
      %{},
      MapSet.new(),
      false
    )
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

  # backtrack_one searches for a single witness.
  #   pattern_vs  : list of vertices in the *smaller* graph
  #   host_vs     : list of vertices in the *larger* (or same) graph
  #   pat_adj     : adjacency map for pattern_vs
  #   host_adj    : adjacency map for host_vs
  #   directed?   : edge mode
  #   pat_graph   : the pattern graph struct (for degree)
  #   host_graph  : the host graph struct (for degree)
  #   mapping     : pattern_vertex => host_vertex (so far)
  #   used_hosts  : MapSet of host vertices already used
  #   strict?     : true for full isomorphism (bijection enforced via vertex counts +
  #                 degree-seq equality up the stack), false for sub-isomorphism
  defp backtrack_one(
         pat_vs,
         _host_vs,
         _pat_adj,
         _host_adj,
         _dir?,
         _pg,
         _hg,
         mapping,
         _used,
         _strict?
       )
       when length(pat_vs) == map_size(mapping) do
    mapping
  end

  defp backtrack_one(pat_vs, host_vs, pat_adj, host_adj, dir?, pg, hg, mapping, used, strict?) do
    case pick_next_pattern_vertex(pat_vs, mapping) do
      nil ->
        mapping

      v ->
        candidates =
          candidates_for(v, mapping, used, host_vs, host_adj, pat_adj, dir?, pg, hg, strict?)

        Enum.find_value(candidates, fn h ->
          if consistent?(v, h, mapping, pat_adj, host_adj, dir?) do
            backtrack_one(
              pat_vs,
              host_vs,
              pat_adj,
              host_adj,
              dir?,
              pg,
              hg,
              Map.put(mapping, v, h),
              MapSet.put(used, h),
              strict?
            )
          else
            nil
          end
        end)
    end
  end

  defp backtrack_count(pat_vs, host_vs, pat_adj, host_adj, dir?, pg, hg, mapping, used)
       when length(pat_vs) == map_size(mapping) do
    _ = {pat_vs, host_vs, pat_adj, host_adj, dir?, pg, hg, mapping, used}
    1
  end

  defp backtrack_count(pat_vs, host_vs, pat_adj, host_adj, dir?, pg, hg, mapping, used) do
    case pick_next_pattern_vertex(pat_vs, mapping) do
      nil ->
        1

      v ->
        candidates =
          candidates_for(v, mapping, used, host_vs, host_adj, pat_adj, dir?, pg, hg, false)

        Enum.reduce(candidates, 0, fn h, acc ->
          if consistent?(v, h, mapping, pat_adj, host_adj, dir?) do
            acc +
              backtrack_count(
                pat_vs,
                host_vs,
                pat_adj,
                host_adj,
                dir?,
                pg,
                hg,
                Map.put(mapping, v, h),
                MapSet.put(used, h)
              )
          else
            acc
          end
        end)
    end
  end

  # Next pattern vertex to map: prefer one adjacent to the already-mapped
  # frontier (the classic VF2 "T1 ∪ T2" heuristic). Falls back to any
  # unmapped pattern vertex.
  defp pick_next_pattern_vertex(pat_vs, mapping) do
    mapped = Map.keys(mapping) |> MapSet.new()
    unmapped = Enum.reject(pat_vs, &MapSet.member?(mapped, &1))

    case unmapped do
      [] -> nil
      _ -> hd(unmapped)
    end
  end

  defp candidates_for(v, mapping, used, host_vs, host_adj, pat_adj, _dir?, pg, hg, strict?) do
    pat_deg_out = MapSet.size(pat_adj[v].out)
    pat_deg_in = MapSet.size(pat_adj[v].in)

    pool = Enum.reject(host_vs, &MapSet.member?(used, &1))

    pool =
      Enum.filter(pool, fn h ->
        ho_out = MapSet.size(host_adj[h].out)
        ho_in = MapSet.size(host_adj[h].in)

        if strict? do
          # Full isomorphism: degrees must match exactly.
          ho_out == pat_deg_out and ho_in == pat_deg_in
        else
          # Sub-isomorphism: host must dominate pattern degree.
          ho_out >= pat_deg_out and ho_in >= pat_deg_in
        end
      end)

    # Tiny boost: if some neighbour of v is already mapped, restrict
    # candidates to neighbours of that mapped host vertex. The
    # consistency check would still reject inconsistent picks, but
    # filtering early prunes the search.
    mapped_neighbour_in_pattern =
      Enum.find(MapSet.union(pat_adj[v].out, pat_adj[v].in), &Map.has_key?(mapping, &1))

    case mapped_neighbour_in_pattern do
      nil ->
        _ = {pg, hg}
        pool

      pu ->
        h_pu = mapping[pu]
        constraint = MapSet.union(host_adj[h_pu].out, host_adj[h_pu].in)
        Enum.filter(pool, &MapSet.member?(constraint, &1))
    end
  end

  # consistent?/6 — for each already-mapped pattern neighbour u of v,
  # mapping[u] must be a corresponding neighbour of h.
  defp consistent?(v, h, mapping, pat_adj, host_adj, directed?) do
    pa = pat_adj[v]
    ha = host_adj[h]

    if directed? do
      Enum.all?(pa.out, fn u ->
        case Map.fetch(mapping, u) do
          {:ok, hu} -> MapSet.member?(ha.out, hu)
          :error -> true
        end
      end) and
        Enum.all?(pa.in, fn u ->
          case Map.fetch(mapping, u) do
            {:ok, hu} -> MapSet.member?(ha.in, hu)
            :error -> true
          end
        end)
    else
      Enum.all?(pa.out, fn u ->
        case Map.fetch(mapping, u) do
          {:ok, hu} -> MapSet.member?(ha.out, hu)
          :error -> true
        end
      end)
    end
  end
end
