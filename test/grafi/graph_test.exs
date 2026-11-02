defmodule Grafi.GraphTest do
  use ExUnit.Case, async: true
  doctest Grafi.Graph
  alias Grafi.Graph

  describe "construction" do
    test "new/0 creates empty directed graph" do
      g = Graph.new()
      assert g.type == :directed
      assert Graph.num_vertices(g) == 0
      assert Graph.num_edges(g) == 0
    end

    test "new/1 with :undirected" do
      g = Graph.new(type: :undirected)
      assert g.type == :undirected
    end
  end

  describe "vertices" do
    test "add and query vertices" do
      g = Graph.new() |> Graph.add_vertices([:a, :b, :c])
      assert Graph.num_vertices(g) == 3
      assert Graph.has_vertex?(g, :a)
      refute Graph.has_vertex?(g, :z)
    end

    test "add vertex with label" do
      g = Graph.new() |> Graph.add_vertex(:a, label: "Athens")
      assert Graph.label(g, :a) == "Athens"
    end

    test "delete vertex removes incident edges" do
      g =
        Graph.new()
        |> Graph.add_edges([{:a, :b}, {:b, :c}, {:c, :a}])
        |> Graph.delete_vertex(:b)

      assert Graph.num_vertices(g) == 2
      refute Graph.has_edge?(g, :a, :b)
      refute Graph.has_edge?(g, :b, :c)
    end

    test "duplicate add is a no-op" do
      g = Graph.new() |> Graph.add_vertex(:a) |> Graph.add_vertex(:a)
      assert Graph.num_vertices(g) == 1
    end
  end

  describe "edges" do
    test "add edge auto-creates vertices" do
      g = Graph.new() |> Graph.add_edge(:x, :y)
      assert Graph.has_vertex?(g, :x)
      assert Graph.has_vertex?(g, :y)
      assert Graph.has_edge?(g, :x, :y)
      assert Graph.num_edges(g) == 1
    end

    test "weighted edges" do
      g = Graph.new() |> Graph.add_edge(:a, :b, weight: 3.5)
      [edge] = Graph.edges_between(g, :a, :b)
      assert edge.weight == 3.5
    end

    test "undirected edges are bidirectional" do
      g = Graph.new(type: :undirected) |> Graph.add_edge(:a, :b)
      assert Graph.has_edge?(g, :a, :b)
      assert Graph.has_edge?(g, :b, :a)
      # counted once
      assert Graph.num_edges(g) == 1
    end

    test "delete edge" do
      g = Graph.new() |> Graph.add_edge(:a, :b) |> Graph.delete_edge(:a, :b)
      refute Graph.has_edge?(g, :a, :b)
      assert Graph.num_edges(g) == 0
    end

    test "batch add_edges" do
      g =
        Graph.new()
        |> Graph.add_edges([{:a, :b}, {:b, :c}, {:c, :d, weight: 2.0}])

      assert Graph.num_edges(g) == 3
      assert Graph.num_vertices(g) == 4
    end
  end

  describe "queries" do
    setup do
      g =
        Graph.new()
        |> Graph.add_edges([{:a, :b}, {:a, :c}, {:b, :d}, {:c, :d}])

      %{g: g}
    end

    test "out_neighbors", %{g: g} do
      assert Enum.sort(Graph.out_neighbors(g, :a)) == [:b, :c]
    end

    test "in_neighbors", %{g: g} do
      assert Enum.sort(Graph.in_neighbors(g, :d)) == [:b, :c]
    end

    test "degree", %{g: g} do
      assert Graph.out_degree(g, :a) == 2
      assert Graph.in_degree(g, :d) == 2
    end

    test "subgraph", %{g: g} do
      sg = Graph.subgraph(g, [:a, :b])
      assert Graph.num_vertices(sg) == 2
      assert Graph.has_edge?(sg, :a, :b)
      refute Graph.has_edge?(sg, :b, :d)
    end

    test "transpose", %{g: g} do
      t = Graph.transpose(g)
      assert Graph.has_edge?(t, :b, :a)
      refute Graph.has_edge?(t, :a, :b)
    end
  end

  describe "multigraph edge accounting" do
    test "edges/1 lists every unlabelled parallel edge" do
      g =
        Graph.new(type: :undirected)
        |> Graph.add_edges([{:a, :b, weight: 1.0}, {:a, :b, weight: 5.0}])

      edges = Graph.edges(g)
      assert edges |> Enum.map(& &1.weight) |> Enum.sort() == [1.0, 5.0]
      assert Enum.all?(edges, &(&1.from == :a and &1.to == :b))
      assert length(edges) == Graph.num_edges(g)
    end

    test "edges/1 lists each of several self-loops once" do
      g =
        Graph.new(type: :undirected)
        |> Graph.add_edges([{:a, :a, weight: 1.0}, {:a, :a, weight: 7.0}])

      edges = Graph.edges(g)
      assert edges |> Enum.map(& &1.weight) |> Enum.sort() == [1.0, 7.0]
      assert length(edges) == Graph.num_edges(g)
    end

    # More than 32 vertices, so the adjacency maps are hash-ordered and the
    # first copy met is not always the lower endpoint's.
    test "edges/1 orients each undirected edge from <= to" do
      g = Graph.new(type: :undirected) |> Graph.add_edges(for i <- 39..1//-1, do: {i, i - 1})
      edges = Graph.edges(g)

      assert length(edges) == 39
      assert Enum.all?(edges, &(&1.from <= &1.to))
    end

    test "edges/1 lists an undirected edge between ids that compare equal but differ once" do
      g = Graph.new(type: :undirected) |> Graph.add_edge(1, 1.0, weight: 3.0)
      {_idx, csr} = Graph.to_csr(g)

      assert [%{weight: 3.0}] = Graph.edges(g)
      assert byte_size(csr.col_indices) == 8

      sg = Graph.subgraph(g, [1, 1.0])
      assert Graph.num_edges(sg) == 1
      assert length(Graph.edges(sg)) == 1

      for {u, v} <- [{1, 1.0}, {1.0, 1}] do
        deleted = Graph.delete_edge(g, u, v)
        assert {Graph.num_edges(deleted), Graph.edges(deleted)} == {0, []}
      end
    end

    test "delete_vertex/2 counts an undirected self-loop once" do
      g =
        Graph.new(type: :undirected)
        |> Graph.add_edges([{:a, :a}, {:a, :b}])
        |> Graph.delete_vertex(:a)

      assert Graph.num_edges(g) == 0
    end

    test "delete_vertex/2 counts a directed self-loop once" do
      g =
        Graph.new()
        |> Graph.add_edges([{:a, :a}, {:a, :b}, {:c, :a}])
        |> Graph.delete_vertex(:a)

      assert Graph.num_edges(g) == 0
    end

    test "subgraph/2 copies each undirected edge and self-loop once" do
      sg =
        Graph.new(type: :undirected)
        |> Graph.add_edges([{:a, :b}, {:a, :a}, {:b, :c}])
        |> Graph.subgraph([:a, :b])

      assert Graph.num_edges(sg) == 2
      assert length(Graph.edges_between(sg, :a, :b)) == 1
      assert length(Graph.edges(sg)) == 2
    end

    test "subgraph/2 keeps parallel-edge order, so delete_edge/3 still drops the newest" do
      for type <- [:directed, :undirected] do
        sg =
          Graph.new(type: type)
          |> Graph.add_edges([
            {:a, :b, weight: 1.0},
            {:a, :b, weight: 5.0},
            {:a, :a, weight: 2.0},
            {:a, :a, weight: 4.0}
          ])
          |> Graph.subgraph([:a, :b])
          |> Graph.delete_edge(:a, :b)
          |> Graph.delete_edge(:a, :a)

        assert sg |> Graph.edges() |> Enum.map(& &1.weight) |> Enum.sort() == [1.0, 2.0],
               "#{type}"
      end
    end
  end

  describe "CSR conversion" do
    defp ints(bin), do: for(<<i::signed-native-64 <- bin>>, do: i)
    defp floats(bin), do: for(<<w::float-native-64 <- bin>>, do: w)

    test "to_csr produces valid format" do
      g = Graph.new() |> Graph.add_edges([{:a, :b, weight: 1.0}, {:b, :c, weight: 2.0}])
      {idx, csr} = Graph.to_csr(g)

      assert idx == %{a: 0, b: 1, c: 2}
      assert ints(csr.row_offsets) == [0, 1, 2, 2]
      assert ints(csr.col_indices) == [1, 2]
      assert floats(csr.weights) == [1.0, 2.0]
      assert csr.n_vertices == 3
      assert csr.directed == true
      assert csr.vertices == {:a, :b, :c}
    end

    test "to_csr lists every undirected edge once, including parallel edges and self-loops" do
      g =
        Graph.new(type: :undirected)
        |> Graph.add_edges([
          {:a, :b, weight: 1.0},
          {:a, :b, weight: 5.0},
          {:b, :b, weight: 2.0},
          {:b, :c, weight: 3.0}
        ])

      {idx, csr} = Graph.to_csr(g)
      offsets = ints(csr.row_offsets)
      cols = ints(csr.col_indices)
      weights = floats(csr.weights)

      assert length(cols) == Graph.num_edges(g)
      assert List.last(offsets) == Graph.num_edges(g)

      edges =
        for row <- 0..(csr.n_vertices - 1),
            j <- Enum.at(offsets, row)..(Enum.at(offsets, row + 1) - 1)//1 do
          {row, Enum.at(cols, j), Enum.at(weights, j)}
        end

      a = idx[:a]
      b = idx[:b]
      c = idx[:c]
      assert Enum.sort(edges) == Enum.sort([{a, b, 1.0}, {a, b, 5.0}, {b, b, 2.0}, {b, c, 3.0}])
    end

    test "to_csr keeps one copy of each of several undirected self-loops on a vertex" do
      g =
        Graph.new(type: :undirected)
        |> Graph.add_edges([{:a, :a, weight: 1.0}, {:a, :a, weight: 7.0}])

      {_idx, csr} = Graph.to_csr(g)

      assert Enum.sort(floats(csr.weights)) == [1.0, 7.0]
      assert length(ints(csr.col_indices)) == Graph.num_edges(g)

      # delete_edge/3 drops the newest loop; the older one must survive intact.
      {_idx, csr} = g |> Graph.delete_edge(:a, :a) |> Graph.to_csr()
      assert floats(csr.weights) == [1.0]
    end
  end

  describe "Enumerable protocol" do
    test "Enum.count works" do
      g = Graph.new() |> Graph.add_vertices([:a, :b, :c])
      assert Enum.count(g) == 3
    end

    test "Enum.member? works" do
      g = Graph.new() |> Graph.add_vertex(:x)
      assert Enum.member?(g, :x)
    end
  end

  describe "add_edge/4 :weight validation" do
    for w <- ["2", nil, :x] do
      test "raises ArgumentError for weight: #{inspect(w)}" do
        assert_raise ArgumentError, ~r/:weight/, fn ->
          Graph.add_edge(Graph.new(), :a, :b, weight: unquote(w))
        end
      end
    end
  end
end
