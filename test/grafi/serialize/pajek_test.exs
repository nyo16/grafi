defmodule Grafi.Serialize.PajekTest do
  use ExUnit.Case, async: true

  alias Grafi.Graph
  alias Grafi.Serialize.Pajek

  doctest Grafi.Serialize.Pajek

  describe "to_pajek/2" do
    test "directed graph emits *Arcs" do
      g = Graph.new() |> Graph.add_edge(:a, :b)
      text = Pajek.to_pajek(g)

      assert text =~ "*Vertices 2"
      assert text =~ "*Arcs"
      refute text =~ "*Edges"
    end

    test "undirected graph emits *Edges" do
      g = Graph.new(type: :undirected) |> Graph.add_edge(:a, :b)
      text = Pajek.to_pajek(g)

      assert text =~ "*Edges"
      refute text =~ "*Arcs"
    end

    test "vertex labels quoted, weights included" do
      g = Graph.new() |> Graph.add_edge(:a, :b, weight: 2.5)
      text = Pajek.to_pajek(g)

      assert text =~ ~s("a")
      assert text =~ ~s("b")
      assert text =~ "2.5"
    end

    test "vertex with double-quote in name is escaped" do
      g = Graph.new() |> Graph.add_vertex("a\"b")
      text = Pajek.to_pajek(g)
      assert text =~ ~s("a\\"b")
    end
  end

  describe "from_pajek/2" do
    test "parses minimal valid input" do
      input = """
      *Vertices 2
      1 "a"
      2 "b"
      *Arcs
      1 2 1.0
      """

      g = Pajek.from_pajek(input)
      assert g.type == :directed
      assert Graph.num_vertices(g) == 2
      assert Graph.has_edge?(g, "a", "b")
    end

    test "parses *Edges as undirected" do
      input = """
      *Vertices 2
      1 "a"
      2 "b"
      *Edges
      1 2 1.0
      """

      g = Pajek.from_pajek(input)
      assert g.type == :undirected
    end

    test "weights are preserved" do
      input = """
      *Vertices 2
      1 "x"
      2 "y"
      *Arcs
      1 2 4.5
      """

      g = Pajek.from_pajek(input)
      [e] = Graph.edges_between(g, "x", "y")
      assert e.weight == 4.5
    end

    test "missing header returns error" do
      assert {:error, _} = Pajek.from_pajek("just garbage\n")
    end

    test "empty input returns error" do
      assert {:error, _} = Pajek.from_pajek("")
    end

    test "malformed edge line returns error" do
      input = """
      *Vertices 1
      1 "a"
      *Arcs
      bogus
      """

      assert {:error, _} = Pajek.from_pajek(input)
    end
  end

  describe "round-trip" do
    test "directed weighted graph" do
      g =
        Graph.new()
        |> Graph.add_edge("a", "b", weight: 2.5)
        |> Graph.add_edge("b", "c", weight: 3.0)
        |> Graph.add_edge("a", "c", weight: 7.0)

      text = Pajek.to_pajek(g)
      g2 = Pajek.from_pajek(text)

      assert g2.type == :directed
      assert Graph.num_vertices(g2) == 3
      assert Graph.num_edges(g2) == 3
      [e_ab] = Graph.edges_between(g2, "a", "b")
      assert e_ab.weight == 2.5
    end

    test "undirected round-trip" do
      g =
        Graph.new(type: :undirected)
        |> Graph.add_edge("x", "y", weight: 1.5)

      text = Pajek.to_pajek(g)
      g2 = Pajek.from_pajek(text)

      assert g2.type == :undirected
      assert Graph.has_edge?(g2, "x", "y")
      assert Graph.has_edge?(g2, "y", "x")
    end

    test "multi-edge round-trip" do
      g =
        Graph.new()
        |> Graph.add_edge("a", "b", weight: 1.0)
        |> Graph.add_edge("a", "b", weight: 2.0)

      text = Pajek.to_pajek(g)
      g2 = Pajek.from_pajek(text)

      assert Graph.num_edges(g2) == 2
      assert length(Graph.edges_between(g2, "a", "b")) == 2
    end

    test "vertices are 1-indexed in output" do
      g = Graph.new() |> Graph.add_vertices([:x, :y, :z])
      text = Pajek.to_pajek(g)
      lines = String.split(text, "\n")
      # First vertex line is "1 ..."
      vertex_lines = Enum.filter(lines, &Regex.match?(~r/^\d+ /, &1))
      assert hd(vertex_lines) =~ ~r/^1 /
    end
  end
end
