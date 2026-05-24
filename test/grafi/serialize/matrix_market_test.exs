defmodule Grafi.Serialize.MatrixMarketTest do
  use ExUnit.Case, async: true

  alias Grafi.Graph
  alias Grafi.Serialize.MatrixMarket

  doctest Grafi.Serialize.MatrixMarket

  describe "to_matrix_market/2" do
    test "directed graph emits 'general' symmetry" do
      g = Graph.new() |> Graph.add_edge(:a, :b, weight: 1.0)
      text = MatrixMarket.to_matrix_market(g)

      assert String.starts_with?(text, "%%MatrixMarket matrix coordinate real general")
    end

    test "undirected graph emits 'symmetric' symmetry" do
      g = Graph.new(type: :undirected) |> Graph.add_edge(:a, :b)
      text = MatrixMarket.to_matrix_market(g)

      assert String.starts_with?(text, "%%MatrixMarket matrix coordinate real symmetric")
    end

    test "writes GRAFI_VERTEX comments for id round-trip" do
      g = Graph.new() |> Graph.add_edge(:alpha, :beta)
      text = MatrixMarket.to_matrix_market(g)

      assert text =~ "%GRAFI_VERTEX 1 "
      assert text =~ "%GRAFI_VERTEX 2 "
      assert text =~ "atom:alpha"
    end

    test "size line has correct nnz" do
      g =
        Graph.new()
        |> Graph.add_edges([{:a, :b}, {:b, :c}, {:a, :c}])

      text = MatrixMarket.to_matrix_market(g)
      # 3 vertices, 3 entries
      assert text =~ "3 3 3"
    end
  end

  describe "from_matrix_market/2" do
    test "parses with vertex comments" do
      input = """
      %%MatrixMarket matrix coordinate real general
      %GRAFI_VERTEX 1 a
      %GRAFI_VERTEX 2 b
      2 2 1
      1 2 2.5
      """

      g = MatrixMarket.from_matrix_market(input)
      assert g.type == :directed
      assert Graph.has_edge?(g, "a", "b")
      [e] = Graph.edges_between(g, "a", "b")
      assert e.weight == 2.5
    end

    test "parses without vertex comments (integer ids)" do
      input = """
      %%MatrixMarket matrix coordinate real general
      2 2 1
      1 2 1.0
      """

      g = MatrixMarket.from_matrix_market(input)
      assert Graph.has_edge?(g, 1, 2)
    end

    test "ignores unknown comments" do
      input = """
      %%MatrixMarket matrix coordinate real general
      % some random comment
      %GRAFI_VERTEX 1 a
      %GRAFI_VERTEX 2 b
      % another comment
      2 2 1
      1 2 1.0
      """

      g = MatrixMarket.from_matrix_market(input)
      assert Graph.has_edge?(g, "a", "b")
    end

    test "missing header returns error" do
      assert {:error, _} = MatrixMarket.from_matrix_market("garbage\n")
    end

    test "malformed body returns error" do
      input = """
      %%MatrixMarket matrix coordinate real general
      2 2 1
      not numbers
      """

      assert {:error, _} = MatrixMarket.from_matrix_market(input)
    end

    test "isolated vertex preserved through comment + zero-row" do
      input = """
      %%MatrixMarket matrix coordinate real general
      %GRAFI_VERTEX 1 a
      %GRAFI_VERTEX 2 b
      %GRAFI_VERTEX 3 c
      3 3 1
      1 2 1.0
      """

      g = MatrixMarket.from_matrix_market(input)
      assert Graph.has_vertex?(g, "c")
    end
  end

  describe "round-trip" do
    test "directed graph round-trips with string ids" do
      g =
        Graph.new()
        |> Graph.add_edge("a", "b", weight: 2.5)
        |> Graph.add_edge("b", "c", weight: 3.0)
        |> Graph.add_edge("a", "c", weight: 7.0)

      text = MatrixMarket.to_matrix_market(g)
      g2 = MatrixMarket.from_matrix_market(text)

      assert g2.type == :directed
      assert Graph.num_vertices(g2) == 3
      [e_ab] = Graph.edges_between(g2, "a", "b")
      assert e_ab.weight == 2.5
    end

    test "atom vertex ids round-trip" do
      g = Graph.new() |> Graph.add_edge(:athens, :sparta, weight: 1.0)
      text = MatrixMarket.to_matrix_market(g)
      g2 = MatrixMarket.from_matrix_market(text)
      assert Graph.has_edge?(g2, :athens, :sparta)
    end

    test "undirected round-trip" do
      g =
        Graph.new(type: :undirected)
        |> Graph.add_edge("x", "y", weight: 1.5)

      text = MatrixMarket.to_matrix_market(g)
      g2 = MatrixMarket.from_matrix_market(text)

      assert g2.type == :undirected
      assert Graph.has_edge?(g2, "x", "y")
      assert Graph.has_edge?(g2, "y", "x")
    end

    test "parallel multi-edges collapse via weight sum (documented)" do
      g =
        Graph.new()
        |> Graph.add_edge("a", "b", weight: 1.0)
        |> Graph.add_edge("a", "b", weight: 2.0)

      text = MatrixMarket.to_matrix_market(g)
      g2 = MatrixMarket.from_matrix_market(text)

      # Multi-edges are collapsed to a single edge with summed weight.
      assert Graph.num_edges(g2) == 1
      [e] = Graph.edges_between(g2, "a", "b")
      assert e.weight == 3.0
    end
  end
end
