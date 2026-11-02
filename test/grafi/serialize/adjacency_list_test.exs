defmodule Grafi.Serialize.AdjacencyListTest do
  use ExUnit.Case, async: true

  alias Grafi.Graph
  alias Grafi.Serialize.AdjacencyList

  doctest Grafi.Serialize.AdjacencyList

  describe "to_adjacency_list/2" do
    test "directed graph with multiple neighbors" do
      g = Graph.new() |> Graph.add_edges([{:a, :b}, {:a, :c}])
      text = AdjacencyList.to_adjacency_list(g)

      assert text =~ ~r/^a / or text =~ ~r/\na /
    end

    test "isolated vertex appears as a single-token line" do
      g = Graph.new() |> Graph.add_vertex(:lonely)
      text = AdjacencyList.to_adjacency_list(g)
      assert text == "lonely"
    end

    test "collapse_multi_edges=false emits duplicate neighbors" do
      g =
        Graph.new()
        |> Graph.add_edge(:a, :b)
        |> Graph.add_edge(:a, :b)

      text = AdjacencyList.to_adjacency_list(g, collapse_multi_edges: false)
      # Two b tokens on the a line
      a_line = text |> String.split("\n") |> Enum.find(&String.starts_with?(&1, "a "))
      assert Enum.count(String.split(a_line, " "), &(&1 == "b")) == 2
    end
  end

  describe "from_adjacency_list/2" do
    test "parses simple graph" do
      g = AdjacencyList.from_adjacency_list("a b c\nb\nc")
      assert Graph.num_vertices(g) == 3
      assert Graph.num_edges(g) == 2
      assert Graph.has_edge?(g, "a", "b")
      assert Graph.has_edge?(g, "a", "c")
    end

    test "isolated vertex parses to single-vertex line" do
      g = AdjacencyList.from_adjacency_list("solo")
      assert Graph.has_vertex?(g, "solo")
      assert Graph.num_edges(g) == 0
    end

    test "vertices_as_atoms option" do
      g = AdjacencyList.from_adjacency_list("a b", vertices_as_atoms: true)
      assert Graph.has_edge?(g, :a, :b)
    end

    test "undirected option" do
      g = AdjacencyList.from_adjacency_list("a b", directed: false)
      assert g.type == :undirected
      assert Graph.has_edge?(g, "a", "b")
      assert Graph.has_edge?(g, "b", "a")
    end

    test "ignores comment and blank lines" do
      g = AdjacencyList.from_adjacency_list("# comment\na b\n\n")
      assert Graph.num_edges(g) == 1
    end

    test "splits on any run of whitespace by default" do
      g = AdjacencyList.from_adjacency_list("a \t b   c\r\nb")
      assert Enum.sort(Graph.out_neighbors(g, "a")) == ["b", "c"]
    end

    test ":separator splits on the string and trims tokens, allowing spaces in names" do
      g = AdjacencyList.from_adjacency_list("New York , Boston,Albany\nBoston", separator: ",")

      assert Enum.sort(Graph.out_neighbors(g, "New York")) == ["Albany", "Boston"]
      assert Graph.num_vertices(g) == 3
    end

    test ":separator makes an empty token malformed" do
      assert AdjacencyList.from_adjacency_list("a,b,", separator: ",") ==
               {:error, {:malformed_line, "a,b,"}}
    end

    test ":max_bytes rejects larger input" do
      assert AdjacencyList.from_adjacency_list("a b", max_bytes: 2) ==
               {:error, {:too_large, 3, 2}}

      assert %Graph{} = AdjacencyList.from_adjacency_list("a b", max_bytes: 3)
    end
  end

  describe "round-trip" do
    test "directed graph (unweighted) round-trips" do
      g =
        Graph.new()
        |> Graph.add_edges([{"a", "b"}, {"a", "c"}, {"b", "c"}])

      text = AdjacencyList.to_adjacency_list(g)
      g2 = AdjacencyList.from_adjacency_list(text)

      assert Graph.num_vertices(g2) == 3
      assert Graph.num_edges(g2) == 3
      assert Graph.has_edge?(g2, "a", "b")
      assert Graph.has_edge?(g2, "a", "c")
      assert Graph.has_edge?(g2, "b", "c")
    end

    test "separator: \",\" round-trips vertex names with spaces" do
      g = Graph.new() |> Graph.add_edges([{"New York", "Boston"}, {"New York", "a b"}])

      text = AdjacencyList.to_adjacency_list(g, separator: ",")
      g2 = AdjacencyList.from_adjacency_list(text, separator: ",")

      assert Enum.sort(Graph.vertices(g2)) == ["Boston", "New York", "a b"]
      assert Enum.sort(Graph.out_neighbors(g2, "New York")) == ["Boston", "a b"]
      assert Graph.num_edges(g2) == 2
    end

    test "undirected round-trip" do
      g =
        Graph.new(type: :undirected)
        |> Graph.add_edges([{"x", "y"}, {"y", "z"}])

      text = AdjacencyList.to_adjacency_list(g)
      g2 = AdjacencyList.from_adjacency_list(text, directed: false)

      assert g2.type == :undirected
      assert Graph.has_edge?(g2, "x", "y")
      assert Graph.has_edge?(g2, "y", "z")
    end

    test "weights are lost on round-trip (documented limitation)" do
      g = Graph.new() |> Graph.add_edge("a", "b", weight: 42.0)
      text = AdjacencyList.to_adjacency_list(g)
      g2 = AdjacencyList.from_adjacency_list(text)
      [e] = Graph.edges_between(g2, "a", "b")
      assert e.weight == 1.0
    end
  end
end
