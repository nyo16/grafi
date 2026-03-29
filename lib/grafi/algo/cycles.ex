defmodule Grafi.Algo.Cycles do
  @moduledoc "Cycle detection, SCC (Tarjan), and graph condensation."

  alias Grafi.Graph

  @spec has_cycle?(Graph.t()) :: boolean()
  def has_cycle?(%Graph{} = g) do
    vs = Graph.vertices(g)
    colors = Map.new(vs, &{&1, :white})
    Enum.reduce_while(vs, colors, fn v, c ->
      if c[v] == :white do
        case dfs_check(g, v, c) do
          :cycle -> {:halt, :cycle}
          c2 -> {:cont, c2}
        end
      else
        {:cont, c}
      end
    end) == :cycle
  end

  @spec find_cycle(Graph.t()) :: {:ok, [any()]} | :no_cycle
  def find_cycle(%Graph{} = g) do
    vs = Graph.vertices(g)
    colors = Map.new(vs, &{&1, :white})
    result = Enum.reduce_while(vs, {colors, nil}, fn v, {c, _} ->
      if c[v] == :white do
        case dfs_find(g, v, c, []) do
          {:cycle, path, _} -> {:halt, {:found, path}}
          c2 -> {:cont, {c2, nil}}
        end
      else
        {:cont, {c, nil}}
      end
    end)
    case result do
      {:found, p} -> {:ok, p}
      _ -> :no_cycle
    end
  end

  @spec strongly_connected_components(Graph.t()) :: [[any()]]
  def strongly_connected_components(%Graph{} = g) do
    state = %{idx: 0, stack: [], on_stack: MapSet.new(), indices: %{}, lowlinks: %{}, sccs: []}
    state = Enum.reduce(Graph.vertices(g), state, fn v, st ->
      if Map.has_key?(st.indices, v), do: st, else: tarjan(g, v, st)
    end)
    Enum.reverse(state.sccs)
  end

  @spec connected_components(Graph.t()) :: [[any()]]
  def connected_components(%Graph{} = g) do
    {comps, _} = Enum.reduce(Graph.vertices(g), {[], MapSet.new()}, fn v, {cs, vis} ->
      if MapSet.member?(vis, v), do: {cs, vis}, else:
        (comp = Grafi.Algo.Traversal.bfs(g, v) |> Enum.to_list()
         {[comp | cs], Enum.reduce(comp, vis, &MapSet.put(&2, &1))})
    end)
    Enum.reverse(comps)
  end

  @spec condensation(Graph.t()) :: Graph.t()
  def condensation(%Graph{} = g) do
    sccs = strongly_connected_components(g)
    v2scc = Enum.reduce(sccs, %{}, fn scc, acc ->
      key = Enum.sort(scc)
      Enum.reduce(scc, acc, &Map.put(&2, &1, key))
    end)

    sg = Enum.reduce(sccs, Graph.new(type: :directed), fn scc, s ->
      Graph.add_vertex(s, Enum.sort(scc))
    end)

    Graph.edges(g) |> Enum.reduce(sg, fn e, s ->
      f = v2scc[e.from]; t = v2scc[e.to]
      if f != t and not Graph.has_edge?(s, f, t), do: Graph.add_edge(s, f, t), else: s
    end)
  end

  # ── Internal ──────────────────────────────────────────────────────────

  defp dfs_check(g, v, c) do
    c = Map.put(c, v, :gray)
    result = Enum.reduce_while(Graph.out_neighbors(g, v), c, fn n, c2 ->
      case c2[n] do
        :gray -> {:halt, :cycle}
        :white -> case dfs_check(g, n, c2) do :cycle -> {:halt, :cycle}; c3 -> {:cont, c3} end
        :black -> {:cont, c2}
      end
    end)
    if result == :cycle, do: :cycle, else: Map.put(result, v, :black)
  end

  defp dfs_find(g, v, c, path) do
    c = Map.put(c, v, :gray)
    path = path ++ [v]
    result = Enum.reduce_while(Graph.out_neighbors(g, v), c, fn n, c2 ->
      case c2[n] do
        :gray ->
          start = Enum.find_index(path, &(&1 == n))
          {:halt, {:cycle, Enum.slice(path, start..-1//1) ++ [n], c2}}
        :white ->
          case dfs_find(g, n, c2, path) do
            {:cycle, _, _} = cy -> {:halt, cy}
            c3 -> {:cont, c3}
          end
        :black -> {:cont, c2}
      end
    end)
    case result do
      {:cycle, _, _} = cy -> cy
      c2 -> Map.put(c2, v, :black)
    end
  end

  defp tarjan(g, v, st) do
    st = %{st |
      indices: Map.put(st.indices, v, st.idx),
      lowlinks: Map.put(st.lowlinks, v, st.idx),
      idx: st.idx + 1,
      stack: [v | st.stack],
      on_stack: MapSet.put(st.on_stack, v)
    }

    st = Enum.reduce(Graph.out_neighbors(g, v), st, fn w, s ->
      cond do
        not Map.has_key?(s.indices, w) ->
          s = tarjan(g, w, s)
          %{s | lowlinks: Map.put(s.lowlinks, v, min(s.lowlinks[v], s.lowlinks[w]))}
        MapSet.member?(s.on_stack, w) ->
          %{s | lowlinks: Map.put(s.lowlinks, v, min(s.lowlinks[v], s.indices[w]))}
        true -> s
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
