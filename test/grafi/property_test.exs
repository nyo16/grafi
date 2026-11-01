defmodule Grafi.PropertyTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias Grafi.Graph

  # Generator for a list of unique atom vertex names
  defp vertex_list do
    gen all(names <- uniq_list_of(atom(:alphanumeric), min_length: 0, max_length: 20)) do
      names
    end
  end

  # Generator for a graph with random vertices and weighted edges, returned
  # with the vertex list and the `{u, v, weight}` edge list in insertion
  # order. Either type; endpoints may repeat, so the graph can have parallel
  # edges and self-loops, and weights tell parallel edges apart. Edge
  # endpoints are drawn with `member_of/1` (not `Enum.random/1`) so they stay
  # under StreamData's control and counterexamples shrink reproducibly.
  defp graph_with_vertices do
    gen all(
          type <- member_of([:directed, :undirected]),
          verts <- uniq_list_of(atom(:alphanumeric), min_length: 1, max_length: 15),
          edges <-
            list_of({member_of(verts), member_of(verts), member_of([1.0, 2.0, 5.0])},
              max_length: 30
            )
        ) do
      opts_edges = for {u, v, w} <- edges, do: {u, v, weight: w}
      g = Graph.new(type: type) |> Graph.add_vertices(verts) |> Graph.add_edges(opts_edges)
      {g, verts, edges}
    end
  end

  defp random_graph do
    gen(all({g, _verts, _edges} <- graph_with_vertices()), do: g)
  end

  defp graph_op(verts) do
    v = member_of(verts)

    one_of([
      tuple({constant(:delete_edge), v, v}),
      tuple({constant(:delete_nth_edge), non_negative_integer()}),
      tuple({constant(:delete_vertex), v}),
      tuple({constant(:subgraph), list_of(v)})
    ])
  end

  # `:delete_nth_edge` always targets an existing edge (when there is one),
  # since random endpoint pairs often miss.
  defp resolve_op(g, {:delete_nth_edge, i}) do
    case Graph.edges(g) do
      [] -> {:delete_edge, nil, nil}
      es -> es |> Enum.at(rem(i, length(es))) |> then(&{:delete_edge, &1.from, &1.to})
    end
  end

  defp resolve_op(_g, op), do: op

  defp apply_op(g, {:delete_edge, u, v}), do: Graph.delete_edge(g, u, v)
  defp apply_op(g, {:delete_vertex, v}), do: Graph.delete_vertex(g, v)
  defp apply_op(g, {:subgraph, keep}), do: Graph.subgraph(g, keep)

  # Reference model, built from the generated input and never from a graph:
  # the vertex set plus edges as `{seq, from, to, weight}`, where `seq` is
  # the insertion order.
  defp model(type, verts, edges) do
    %{
      type: type,
      vertices: MapSet.new(verts),
      edges: for({{u, v, w}, seq} <- Enum.with_index(edges), do: {seq, u, v, w})
    }
  end

  defp model_step(m, {:delete_vertex, v}) do
    %{
      m
      | vertices: MapSet.delete(m.vertices, v),
        edges: Enum.reject(m.edges, fn {_seq, f, t, _w} -> f == v or t == v end)
    }
  end

  defp model_step(m, {:subgraph, keep}) do
    kept = MapSet.intersection(m.vertices, MapSet.new(keep))
    both_kept? = fn {_seq, f, t, _w} -> MapSet.member?(kept, f) and MapSet.member?(kept, t) end
    %{m | vertices: kept, edges: Enum.filter(m.edges, both_kept?)}
  end

  # `delete_edge/3` removes the most recently added edge between u and v
  # (in either orientation when undirected).
  defp model_step(m, {:delete_edge, u, v}) do
    case Enum.filter(m.edges, &joins?(m.type, &1, u, v)) do
      [] -> m
      matching -> %{m | edges: List.delete(m.edges, Enum.max_by(matching, &elem(&1, 0)))}
    end
  end

  defp joins?(:directed, {_seq, f, t, _w}, u, v), do: f == u and t == v
  defp joins?(:undirected, {_seq, f, t, _w}, u, v), do: {f, t} in [{u, v}, {v, u}]

  # Multisets of `{from, to, weight}`. Undirected `edges/1` entries are
  # oriented `from <= to`, so the model orients its undirected edges the same way.
  defp edge_bag(g), do: g |> Graph.edges() |> Enum.frequencies_by(&{&1.from, &1.to, &1.weight})

  defp model_bag(%{type: type, edges: edges}) do
    Enum.frequencies_by(edges, fn
      {_seq, f, t, w} when type == :undirected and t < f -> {t, f, w}
      {_seq, f, t, w} -> {f, t, w}
    end)
  end

  defp assert_matches_model(g, m, after_op) do
    msg = "after #{inspect(after_op)}"

    assert MapSet.new(Graph.vertices(g)) == m.vertices, msg
    assert Graph.num_vertices(g) == MapSet.size(m.vertices), msg
    assert edge_bag(g) == model_bag(m), msg
    assert_consistent(g, msg)
  end

  # Invariants of the adjacency maps, checked over every stored list, so an
  # orphaned copy under either endpoint is caught.
  defp assert_consistent(g, msg) do
    {_idx, csr} = Graph.to_csr(g)

    assert Graph.num_edges(g) == length(Graph.edges(g)), msg
    assert byte_size(csr.col_indices) == 8 * Graph.num_edges(g), msg

    for {u, targets} <- g.out_edges, {t, el} <- targets do
      assert stored(g.in_edges, t, u) == el, msg

      # Both stored copies of an undirected edge stay in step.
      if g.type == :undirected and u != t,
        do: assert(weights(stored(g.out_edges, t, u)) == weights(el), msg)
    end

    for {t, sources} <- g.in_edges, {u, el} <- sources do
      assert stored(g.out_edges, u, t) == el, msg
    end

    for u <- Graph.vertices(g) do
      assert Graph.out_degree(g, u) == length(Graph.out_neighbors(g, u)), msg
      assert Graph.in_degree(g, u) == length(Graph.in_neighbors(g, u)), msg
    end
  end

  defp stored(adj, u, v), do: adj |> Map.get(u, %{}) |> Map.get(v, [])
  defp weights(edges), do: Enum.map(edges, & &1.weight)

  describe "invariants" do
    property "num_vertices == length(vertices)" do
      check all(verts <- vertex_list()) do
        g = Graph.new() |> Graph.add_vertices(verts)
        assert Graph.num_vertices(g) == length(Graph.vertices(g))
      end
    end

    property "num_edges == length(edges)" do
      check all(g <- random_graph()) do
        assert Graph.num_edges(g) == length(Graph.edges(g))
      end
    end

    property "deletes and subgraphs match an insertion-ordered model and keep adjacency consistent" do
      check all(
              {g, verts, edges} <- graph_with_vertices(),
              ops <- list_of(graph_op(verts), max_length: 10)
            ) do
        m = model(g.type, verts, edges)
        assert_matches_model(g, m, :seed)

        Enum.reduce(ops, {g, m}, fn op, {g, m} ->
          op = resolve_op(g, op)
          {g, m} = {apply_op(g, op), model_step(m, op)}
          assert_matches_model(g, m, op)
          {g, m}
        end)
      end
    end

    property "transpose(transpose(g)) preserves structure" do
      check all(g <- random_graph()) do
        tt = g |> Graph.transpose() |> Graph.transpose()

        assert Graph.num_vertices(tt) == Graph.num_vertices(g)
        assert Graph.num_edges(tt) == Graph.num_edges(g)

        # Every edge in original must be in double-transposed graph
        for e <- Graph.edges(g) do
          assert Graph.has_edge?(tt, e.from, e.to),
                 "edge #{inspect(e.from)} -> #{inspect(e.to)} lost after double transpose"
        end
      end
    end
  end
end
