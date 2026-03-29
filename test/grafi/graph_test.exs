defmodule Grafi.GraphTest do
  use ExUnit.Case, async: true
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

  describe "CSR conversion" do
    test "to_csr produces valid format" do
      g = Graph.new() |> Graph.add_edges([{:a, :b, weight: 1.0}, {:b, :c, weight: 2.0}])
      {idx, csr} = Graph.to_csr(g)

      assert map_size(idx) == 3
      # n_vertices + 1
      assert length(csr.row_offsets) == 4
      assert length(csr.col_indices) == 2
      assert length(csr.weights) == 2
      assert csr.n_vertices == 3
      assert csr.directed == true
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
end
