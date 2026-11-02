defmodule Grafi.Algo.Cycles do
  @moduledoc """
  Cycle detection, strongly connected components (Tarjan), connected
  components, and graph condensation.

  > For DAGs with build-time cycle prevention, use `Grafi.DAG` — it raises
  > `Grafi.CycleError` on any edge that would close a cycle.
  """

  alias Grafi.Algo.Traversal
  alias Grafi.Args
  alias Grafi.Graph
  alias Grafi.NIF

  @doc """
  Returns true if the graph contains at least one cycle.

  Directed graphs: a directed cycle (a self-loop counts). Undirected graphs:
  a DFS that skips the tree edge to the parent once, so a single edge is not
  a cycle but a self-loop, a parallel pair or a triangle is. Same DFS as
  `find_cycle/1`.
  """
  @spec has_cycle?(Graph.t()) :: boolean()
  def has_cycle?(%Graph{} = g), do: match?({:ok, _}, find_cycle(g))

  @doc """
  Finds one cycle, as a closed walk `[v0, v1, ..., v0]` along real edges, or
  returns `{:error, :no_cycle}`. See `has_cycle?/1` for the undirected rules.

  ## Examples

      iex> Grafi.new(type: :undirected)
      ...> |> Grafi.add_edge(:a, :b)
      ...> |> Grafi.Algo.Cycles.find_cycle()
      {:error, :no_cycle}

      iex> Grafi.new()
      ...> |> Grafi.add_edges([{:a, :b}, {:b, :a}])
      ...> |> Grafi.Algo.Cycles.find_cycle()
      {:ok, [:a, :b, :a]}
  """
  @spec find_cycle(Graph.t()) :: {:ok, [any()]} | {:error, :no_cycle}
  def find_cycle(%Graph{} = g) do
    undirected? = g.type == :undirected

    Enum.reduce_while(g |> Graph.vertices() |> Enum.sort(), %{}, fn v, c ->
      if Map.has_key?(c, v) do
        {:cont, c}
      else
        case dfs_find(g, undirected?, v, :root, c, []) do
          {:cycle, path} -> {:halt, {:ok, path}}
          c2 -> {:cont, c2}
        end
      end
    end)
    |> case do
      {:ok, _} = found -> found
      _colors -> {:error, :no_cycle}
    end
  end

  @doc """
  Returns all strongly connected components.

  The output is canonical: each component's vertices are sorted by term
  order, and components are ordered by their smallest vertex. Both engines
  return exactly this list.

  ## Options
    - `:engine` — `:auto | :nif | :elixir`, see `Grafi.NIF`. The Elixir
      engine uses Tarjan's algorithm. Raises `Grafi.NIFError` if the NIF
      fails or `engine: :nif` is unavailable.
  """
  @spec strongly_connected_components(Graph.t(), keyword()) :: [[any()]]
  def strongly_connected_components(%Graph{} = g, opts \\ []) do
    opts = Keyword.validate!(opts, engine: :auto)
    Args.engine!(opts)

    case NIF.engine(g, opts) do
      :nif -> scc_nif(g)
      :elixir -> g |> tarjan_sccs() |> Enum.map(&Enum.sort/1) |> Enum.sort_by(&hd/1)
      {:error, reason} -> raise Grafi.NIFError, reason: reason
    end
  end

  # igraph reports a component id per vertex index. Indices follow term order,
  # so collecting members in index order yields sorted components, already
  # ordered by their smallest vertex: the canonical form in O(V), no sort.
  defp scc_nif(g) do
    {_idx, csr} = Graph.to_csr(g)
    {membership, _n_components} = NIF.call!(NIF.nif_scc(csr))

    {members, order} =
      membership
      |> Enum.with_index()
      |> Enum.reduce({%{}, []}, fn {c, i}, {members, order} ->
        v = elem(csr.vertices, i)

        case members do
          %{^c => vs} -> {%{members | c => [v | vs]}, order}
          _ -> {Map.put(members, c, [v]), [c | order]}
        end
      end)

    order |> Enum.reverse() |> Enum.map(&Enum.reverse(members[&1]))
  end

  defp tarjan_sccs(g) do
    state = %{idx: 0, stack: [], on_stack: MapSet.new(), indices: %{}, lowlinks: %{}, sccs: []}

    state =
      Enum.reduce(Graph.vertices(g), state, fn v, st ->
        if Map.has_key?(st.indices, v), do: st, else: tarjan(g, v, st)
      end)

    state.sccs
  end

  @doc """
  Returns the connected components, ignoring edge direction: for a directed
  graph these are the weakly connected components.

  The output is canonical: each component is sorted by term order, and
  components are ordered by their smallest vertex.

  ## Examples

      iex> Grafi.new()
      ...> |> Grafi.add_edges([{:b, :a}, {:c, :a}])
      ...> |> Grafi.Algo.Cycles.connected_components()
      [[:a, :b, :c]]
  """
  @spec connected_components(Graph.t()) :: [[any()]]
  def connected_components(%Graph{} = g) do
    {comps, _} =
      Enum.reduce(Graph.vertices(g), {[], MapSet.new()}, fn v, {cs, vis} ->
        if MapSet.member?(vis, v) do
          {cs, vis}
        else
          comp = g |> Traversal.weak_bfs(v) |> Enum.to_list()
          {[Enum.sort(comp) | cs], Enum.reduce(comp, vis, &MapSet.put(&2, &1))}
        end
      end)

    Enum.sort_by(comps, &hd/1)
  end

  @doc """
  Returns the condensation DAG, where each SCC is collapsed into a single
  vertex.

  Vertex ids are the integers `0..k-1`, the SCC's index in the canonical
  `strongly_connected_components/1` order, and each vertex's label is its
  sorted member list. There is one edge `i -> j` whenever some edge leads
  from SCC `i` to SCC `j` (`i != j`).

  ## Examples

      iex> c = Grafi.new()
      ...>     |> Grafi.add_edges([{:a, :b}, {:b, :a}, {:b, :c}])
      ...>     |> Grafi.Algo.Cycles.condensation()
      iex> {Grafi.Graph.label(c, 0), Grafi.Graph.label(c, 1), Grafi.Graph.has_edge?(c, 0, 1)}
      {[:a, :b], [:c], true}
  """
  @spec condensation(Graph.t()) :: Graph.t()
  def condensation(%Graph{} = g) do
    indexed = g |> strongly_connected_components() |> Enum.with_index()

    v2scc =
      Enum.reduce(indexed, %{}, fn {scc, i}, acc ->
        Enum.reduce(scc, acc, &Map.put(&2, &1, i))
      end)

    sg =
      Enum.reduce(indexed, Graph.new(type: :directed), fn {scc, i}, s ->
        Graph.add_vertex(s, i, label: scc)
      end)

    Graph.edges(g)
    |> Enum.reduce(sg, fn e, s ->
      f = v2scc[e.from]
      t = v2scc[e.to]
      if f != t and not Graph.has_edge?(s, f, t), do: Graph.add_edge(s, f, t), else: s
    end)
  end

  # ── Internal ──────────────────────────────────────────────────────────

  # Colour-marking DFS shared by has_cycle?/1 and find_cycle/1. `parent` is
  # the vertex we arrived from (`:root` at a tree root); undirected graphs
  # skip that tree edge once, so only a second (parallel) edge to the parent
  # closes a cycle. A gray neighbour closes a cycle; black ones are finished.
  # Returns the updated colours, or `{:cycle, closed_walk}`.
  defp dfs_find(g, undirected?, v, parent, c, path) do
    c = Map.put(c, v, :gray)
    path = [v | path]

    g.out_edges
    |> Map.get(v, %{})
    |> Enum.reduce_while(c, fn
      {_n, []}, c2 ->
        {:cont, c2}

      {n, [_single]}, c2 when undirected? and {:parent, n} == parent ->
        {:cont, c2}

      {n, _el}, c2 ->
        case c2 do
          %{^n => :gray} ->
            {:halt, {:cycle, close_cycle(path, n)}}

          %{^n => :black} ->
            {:cont, c2}

          _white ->
            case dfs_find(g, undirected?, n, {:parent, v}, c2, path) do
              {:cycle, _} = cy -> {:halt, cy}
              c3 -> {:cont, c3}
            end
        end
    end)
    |> case do
      {:cycle, _} = cy -> cy
      c2 -> Map.put(c2, v, :black)
    end
  end

  # `path` is the DFS stack, newest first; `n` is on it. The cycle is the
  # stack from `n` up to the current vertex, closed back at `n`.
  defp close_cycle(path, n) do
    {up_to_n, [^n | _]} = Enum.split_while(path, &(&1 != n))
    [n | Enum.reverse(up_to_n)] ++ [n]
  end

  defp tarjan(g, v, st) do
    st = %{
      st
      | indices: Map.put(st.indices, v, st.idx),
        lowlinks: Map.put(st.lowlinks, v, st.idx),
        idx: st.idx + 1,
        stack: [v | st.stack],
        on_stack: MapSet.put(st.on_stack, v)
    }

    st =
      Enum.reduce(Graph.out_neighbors(g, v), st, fn w, s ->
        cond do
          not Map.has_key?(s.indices, w) ->
            s = tarjan(g, w, s)
            %{s | lowlinks: Map.put(s.lowlinks, v, min(s.lowlinks[v], s.lowlinks[w]))}

          MapSet.member?(s.on_stack, w) ->
            %{s | lowlinks: Map.put(s.lowlinks, v, min(s.lowlinks[v], s.indices[w]))}

          true ->
            s
        end
      end)

    if st.lowlinks[v] == st.indices[v] do
      {scc, stack, on_stack} = pop_scc(st.stack, st.on_stack, v, [])
      %{st | stack: stack, on_stack: on_stack, sccs: [scc | st.sccs]}
    else
      st
    end
  end

  defp pop_scc([w | r], os, v, scc) do
    os = MapSet.delete(os, w)
    scc = [w | scc]
    if w == v, do: {Enum.reverse(scc), r, os}, else: pop_scc(r, os, v, scc)
  end
end
