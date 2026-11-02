defmodule Grafi.Algo.Connectivity do
  @moduledoc """
  Bridges, articulation points, and biconnected components.

  All algorithms operate on the **underlying undirected graph**: for a
  directed `Grafi.Graph`, each directed edge `u -> v` is treated as the
  undirected edge `{u, v}`. The orientation is ignored. (This is the
  standard definition for these notions.)

  Implementation is a single DFS pass that computes, for each vertex `u`,
  a discovery time `disc[u]` and a low-link value `low[u]` — the lowest
  discovery time reachable from the subtree rooted at `u` via tree edges
  plus at most one back edge.

  **Bridge condition.** For a tree edge `(u, v)`, the edge is a bridge iff
  `low[v] > disc[u]`.

  **Articulation point condition.**
    * The DFS root is an articulation point iff it has more than one DFS
      child.
    * A non-root `u` with a DFS child `v` is an articulation point iff
      `low[v] >= disc[u]`.

  **Biconnected components.** Maintained via an edge stack: every time a
  tree or back edge is traversed it is pushed; when the articulation
  condition fires (`low[v] >= disc[u]`), the stack is popped down to (and
  including) the tree edge `(u, v)` — those edges form one biconnected
  component.

  ## Multigraphs

  Parallel edges between `u` and `v` are tracked individually by edge id.
  When the DFS traverses tree edge `e` from `u` to `v`, only that
  **specific edge** is treated as the parent; any *other* parallel edge
  from `v` back to `u` is a true back edge that lowers `low[v]`.
  Consequently a doubled edge is never a bridge:

      iex> g = Grafi.new(type: :undirected)
      ...>     |> Grafi.add_edge(:a, :b) |> Grafi.add_edge(:a, :b)
      iex> Grafi.Algo.Connectivity.bridges(g)
      []

  ## Self-loops

  A self-loop `(v, v)` is ignored — it can never be a bridge and does not
  contribute to the low-link computation.

  ## Edge ordering in results

  Bridges and biconnected-component edges are returned as `{u, v}` tuples
  with the smaller endpoint first (Erlang term order is total, so this is
  always well-defined).

  ## Reference

  Tarjan, R. E. (1972). *Depth-first search and linear graph algorithms.*
  SIAM Journal on Computing, 1(2), 146–160.
  """

  alias Grafi.Graph

  @type vertex :: any()
  @type edge :: {vertex(), vertex()}

  # ── Public API ────────────────────────────────────────────────────────

  @doc """
  Returns the list of bridge edges in the underlying undirected graph,
  each as a `{u, v}` tuple with the smaller endpoint first. Result is
  sorted.

  ## Examples

      iex> g = Grafi.new(type: :undirected)
      ...>     |> Grafi.add_edges([{:a, :b}, {:b, :c}, {:c, :d}])
      iex> Grafi.Algo.Connectivity.bridges(g)
      [{:a, :b}, {:b, :c}, {:c, :d}]
  """
  @spec bridges(Graph.t()) :: [edge()]
  def bridges(%Graph{} = g) do
    {bridges, _aps, _bccs} = run(g, false)
    Enum.sort(bridges)
  end

  @doc """
  Returns the set of articulation points (cut vertices) of the underlying
  undirected graph.

  ## Examples

      iex> g = Grafi.new(type: :undirected)
      ...>     |> Grafi.add_edges([{:a, :b}, {:b, :c}, {:b, :d}])
      iex> Grafi.Algo.Connectivity.articulation_points(g)
      MapSet.new([:b])
  """
  @spec articulation_points(Graph.t()) :: MapSet.t(vertex())
  def articulation_points(%Graph{} = g) do
    {_bridges, aps, _bccs} = run(g, false)
    aps
  end

  @doc """
  Returns the list of biconnected components of the underlying undirected
  graph. Each component is a `MapSet` of `{u, v}` edge tuples (smaller
  endpoint first). A bridge sits in its own one-edge component. Isolated
  vertices contribute no components.

  ## Examples

      iex> g = Grafi.new(type: :undirected)
      ...>     |> Grafi.add_edges([{:a, :b}, {:b, :c}, {:c, :a}])
      iex> [bcc] = Grafi.Algo.Connectivity.biconnected_components(g)
      iex> MapSet.size(bcc)
      3
  """
  @spec biconnected_components(Graph.t()) :: [MapSet.t(edge())]
  def biconnected_components(%Graph{} = g) do
    {_bridges, _aps, bccs} = run(g, true)
    bccs
  end

  @doc """
  Returns `true` iff the graph is biconnected: exactly one biconnected
  component covering every vertex (no isolated vertices, no articulation
  points).

  ## Examples

      iex> g = Grafi.new(type: :undirected)
      ...>     |> Grafi.add_edges([{:a, :b}, {:b, :c}, {:c, :a}])
      iex> Grafi.Algo.Connectivity.biconnected?(g)
      true
  """
  @spec biconnected?(Graph.t()) :: boolean()
  def biconnected?(%Graph{} = g) do
    case biconnected_components(g) do
      [bcc] ->
        verts_in_bcc =
          Enum.reduce(bcc, MapSet.new(), fn {u, v}, acc ->
            acc |> MapSet.put(u) |> MapSet.put(v)
          end)

        all_verts = MapSet.new(Graph.vertices(g))
        MapSet.size(all_verts) > 0 and MapSet.equal?(verts_in_bcc, all_verts)

      _ ->
        false
    end
  end

  # ── Core implementation ───────────────────────────────────────────────

  defp run(%Graph{} = g, want_bccs?) do
    adj = build_undirected_adj(g)

    state0 = %{
      adj: adj,
      time: 0,
      disc: %{},
      low: %{},
      bridges: [],
      aps: MapSet.new(),
      edge_stack: [],
      edge_stack_len: 0,
      bccs: [],
      want_bccs: want_bccs?
    }

    state =
      Enum.reduce(Graph.vertices(g), state0, fn v, st ->
        if Map.has_key?(st.disc, v) do
          st
        else
          {st, _root_children} = dfs(v, -1, true, st)

          # Anything left on the edge stack at the end of a DFS tree
          # forms a final biconnected component.
          flush_final_bcc(st)
        end
      end)

    {state.bridges, state.aps, Enum.reverse(state.bccs)}
  end

  defp flush_final_bcc(%{want_bccs: false} = st), do: st
  defp flush_final_bcc(%{edge_stack: []} = st), do: st

  defp flush_final_bcc(st) do
    bcc = MapSet.new(st.edge_stack)
    %{st | edge_stack: [], edge_stack_len: 0, bccs: [bcc | st.bccs]}
  end

  # Recursive DFS. `parent_eid` is the id of the edge by which we arrived
  # at `u` (or -1 for the root). `is_root?` indicates whether `u` is the
  # root of the current DFS tree. Returns `{state, child_count}` where
  # `child_count` is u's number of DFS children — used by the caller to
  # decide root articulation.
  defp dfs(u, parent_eid, is_root?, st) do
    st = visit(st, u)

    {st, child_count} =
      Enum.reduce(Map.get(st.adj, u, []), {st, 0}, fn {w, eid}, {s, cc} ->
        cond do
          eid == parent_eid ->
            # The very edge we arrived on — skip exactly one occurrence.
            # Multi-edges to the parent have *different* eids and will
            # fall into the "back edge" branch below, correctly lowering
            # low[u].
            {s, cc}

          Map.has_key?(s.disc, w) ->
            # Back edge (w is an ancestor or sibling already discovered).
            # Push the edge for biconnected components, then update
            # low[u] = min(low[u], disc[w]). We only push when
            # disc[w] < disc[u] to avoid double-pushing the same edge
            # from both endpoints when w is a descendant whose subtree
            # has finished (which can only happen in undirected DFS via
            # the same back edge in the other direction — and that case
            # has eid == some earlier edge already on the stack).
            if s.disc[w] < s.disc[u] do
              s = push_edge(s, u, w)

              {%{s | low: Map.put(s.low, u, min(s.low[u], s.disc[w]))}, cc}
            else
              {s, cc}
            end

          true ->
            # Tree edge u -> w.
            s = push_edge(s, u, w)
            stack_marker = s.edge_stack_len

            {s, _w_children} = dfs(w, eid, false, s)

            low_w = s.low[w]
            s = %{s | low: Map.put(s.low, u, min(s.low[u], low_w))}

            # Bridge?
            s =
              if low_w > s.disc[u] do
                %{s | bridges: [canonical_edge(u, w) | s.bridges]}
              else
                s
              end

            # Articulation (non-root)?
            s =
              if not is_root? and low_w >= s.disc[u] do
                %{s | aps: MapSet.put(s.aps, u)}
              else
                s
              end

            # Pop a biconnected component if the articulation condition
            # fired for this child. We slice off everything pushed on or
            # after `stack_marker - 1` (the tree edge (u, w) itself, plus
            # anything pushed during w's subtree).
            s =
              if s.want_bccs and low_w >= s.disc[u] do
                {popped, remaining} = pop_to(s.edge_stack, s.edge_stack_len - (stack_marker - 1))
                len = stack_marker - 1

                case popped do
                  [] ->
                    %{s | edge_stack: remaining, edge_stack_len: len}

                  _ ->
                    %{
                      s
                      | edge_stack: remaining,
                        edge_stack_len: len,
                        bccs: [MapSet.new(popped) | s.bccs]
                    }
                end
              else
                s
              end

            {s, cc + 1}
        end
      end)

    # Root articulation check: more than one DFS child.
    st =
      if is_root? and child_count > 1 do
        %{st | aps: MapSet.put(st.aps, u)}
      else
        st
      end

    {st, child_count}
  end

  # Pops the top `n_pop` edges (top = head). Returns `{popped, remaining}`
  # in O(n_pop): the caller tracks the stack length, so no `length/1`.
  defp pop_to(stack, n_pop), do: Enum.split(stack, n_pop)

  defp push_edge(%{want_bccs: false} = s, _u, _w), do: s

  defp push_edge(s, u, w),
    do: %{
      s
      | edge_stack: [canonical_edge(u, w) | s.edge_stack],
        edge_stack_len: s.edge_stack_len + 1
    }

  defp visit(st, v) do
    %{
      st
      | disc: Map.put(st.disc, v, st.time),
        low: Map.put(st.low, v, st.time),
        time: st.time + 1
    }
  end

  defp canonical_edge(u, v) when u <= v, do: {u, v}
  defp canonical_edge(u, v), do: {v, u}

  # ── Undirected adjacency construction ─────────────────────────────────

  # Builds `%{vertex => [{neighbor, edge_id}]}` where each undirected
  # edge gets one unique id and appears in both endpoints' adjacency
  # lists with that same id. Self-loops are dropped. Parallel edges each
  # get their own id.
  defp build_undirected_adj(%Graph{} = g) do
    verts = Graph.vertices(g)
    base = Map.new(verts, fn v -> {v, []} end)

    raw_pairs =
      g.out_edges
      |> Enum.flat_map(fn {from, targets} ->
        Enum.flat_map(targets, fn {to, edge_list} ->
          for _ <- edge_list, do: {from, to}
        end)
      end)

    pairs =
      case g.type do
        :undirected -> dedupe_undirected_pairs(raw_pairs)
        :directed -> raw_pairs
      end

    {adj, _} =
      Enum.reduce(pairs, {base, 0}, fn
        {u, u}, {acc, id} ->
          # self-loop: drop
          {acc, id}

        {u, v}, {acc, id} ->
          acc =
            acc
            |> Map.update(u, [{v, id}], &[{v, id} | &1])
            |> Map.update(v, [{u, id}], &[{u, id} | &1])

          {acc, id + 1}
      end)

    adj
  end

  # In an undirected `Grafi.Graph`, each undirected edge is stored as
  # two directed entries (u->v and v->u). Halve the multiplicity per
  # canonical {min, max} key.
  defp dedupe_undirected_pairs(raw) do
    raw
    |> Enum.reduce(%{}, fn {a, b}, acc ->
      key = if a <= b, do: {a, b}, else: {b, a}
      Map.update(acc, key, 1, &(&1 + 1))
    end)
    |> Enum.flat_map(fn {{a, b}, n} ->
      List.duplicate({a, b}, div(n, 2))
    end)
  end
end
