defmodule Grafi.Serialize.EdgeListTest do
  use ExUnit.Case, async: true

  alias Grafi.Graph
  alias Grafi.Serialize.EdgeList

  doctest Grafi.Serialize.EdgeList

  describe "to_edge_list/2" do
    test "unweighted directed graph" do
      g = Graph.new() |> Graph.add_edges([{:a, :b}, {:b, :c}])
      text = EdgeList.to_edge_list(g)

      assert text =~ "a b"
      assert text =~ "b c"
    end

    test "weighted graph includes weight column when weight differs from 1.0" do
      g = Graph.new() |> Graph.add_edge(:a, :b, weight: 2.5)
      text = EdgeList.to_edge_list(g)

      assert text =~ "a b 2.5"
    end

    test "forced :weighted true always emits weight column" do
      g = Graph.new() |> Graph.add_edge(:a, :b)
      text = EdgeList.to_edge_list(g, weighted: true)

      assert text =~ "a b 1.0"
    end

    test "comment header is included" do
      g = Graph.new() |> Graph.add_edge(:a, :b)
      text = EdgeList.to_edge_list(g, comment: "my graph")

      assert String.starts_with?(text, "# my graph\n")
    end

    test "custom separator" do
      g = Graph.new() |> Graph.add_edge(:a, :b)
      text = EdgeList.to_edge_list(g, separator: "\t")

      assert text =~ "a\tb"
    end
  end

  describe "from_edge_list/2" do
    test "parses unweighted directed by default" do
      g = EdgeList.from_edge_list("a b\nb c")

      assert g.type == :directed
      assert Graph.num_vertices(g) == 3
      assert Graph.num_edges(g) == 2
      assert Graph.has_edge?(g, "a", "b")
      assert Graph.has_edge?(g, "b", "c")
    end

    test "parses weighted lines" do
      g = EdgeList.from_edge_list("a b 2.5\nb c 3.0")

      [e1] = Graph.edges_between(g, "a", "b")
      assert e1.weight == 2.5
    end

    test "parses undirected graph" do
      g = EdgeList.from_edge_list("a b\nb c", directed: false)

      assert g.type == :undirected
      assert Graph.has_edge?(g, "a", "b")
      assert Graph.has_edge?(g, "b", "a")
    end

    test "vertices_as_atoms option" do
      g = EdgeList.from_edge_list("a b", vertices_as_atoms: true)
      assert Graph.has_edge?(g, :a, :b)
    end

    test "ignores comment lines and blank lines" do
      g = EdgeList.from_edge_list("# header\na b\n\nb c\n")
      assert Graph.num_edges(g) == 2
    end

    test "default_weight option" do
      g = EdgeList.from_edge_list("a b", default_weight: 7.0)
      [e] = Graph.edges_between(g, "a", "b")
      assert e.weight == 7.0
    end

    test "malformed line returns error" do
      assert {:error, {:malformed_line, _}} = EdgeList.from_edge_list("a")
    end

    test "a non-numeric weight returns {:invalid_weight, token}" do
      assert EdgeList.from_edge_list("a b notanumber", weighted: true) ==
               {:error, {:invalid_weight, "notanumber"}}

      assert EdgeList.from_edge_list("a b 1.0\nb c 2x") == {:error, {:invalid_weight, "2x"}}
    end

    test "an out-of-range weight is an error, not an exception" do
      huge = String.duplicate("9", 400)

      assert EdgeList.from_edge_list("a b " <> huge) == {:error, {:invalid_weight, huge}}
      assert EdgeList.from_edge_list("a b 1e400") == {:error, {:invalid_weight, "1e400"}}
    end

    test "weight detection runs per line: a weight after an unweighted first line" do
      g = EdgeList.from_edge_list("a b\nb c 2.5")

      assert [%{weight: 1.0}] = Graph.edges_between(g, "a", "b")
      assert [%{weight: 2.5}] = Graph.edges_between(g, "b", "c")
    end

    test "weight detection runs per line: an unweighted line after a weighted one" do
      g = EdgeList.from_edge_list("a b 2.5\nb c", default_weight: 4.0)

      assert [%{weight: 2.5}] = Graph.edges_between(g, "a", "b")
      assert [%{weight: 4.0}] = Graph.edges_between(g, "b", "c")
    end

    test "without :weighted, four or more columns are malformed" do
      assert EdgeList.from_edge_list("a b 1 2") == {:error, {:malformed_line, "a b 1 2"}}
    end

    test "weighted: true requires a weight on every line" do
      assert EdgeList.from_edge_list("a b 1\nb c", weighted: true) ==
               {:error, {:malformed_line, "b c"}}
    end

    test "weighted: false ignores extra columns" do
      g = EdgeList.from_edge_list("a b 9 extra", weighted: false)
      assert [%{weight: 1.0}] = Graph.edges_between(g, "a", "b")
    end

    test ":separator splits on the string and trims fields, allowing spaces in names" do
      g = EdgeList.from_edge_list("New York , Boston, 2.5\nBoston,Albany", separator: ",")

      assert [%{weight: 2.5}] = Graph.edges_between(g, "New York", "Boston")
      assert [%{weight: 1.0}] = Graph.edges_between(g, "Boston", "Albany")
      assert Graph.num_vertices(g) == 3
    end

    test ":separator makes an empty field malformed" do
      assert EdgeList.from_edge_list("a,,2", separator: ",") ==
               {:error, {:malformed_line, "a,,2"}}
    end

    test ":max_bytes rejects larger input" do
      assert EdgeList.from_edge_list("a b", max_bytes: 2) == {:error, {:too_large, 3, 2}}
      assert %Graph{} = EdgeList.from_edge_list("a b", max_bytes: 3)
      assert %Graph{} = EdgeList.from_edge_list("a b", max_bytes: :infinity)
    end
  end

  describe "round-trip" do
    test "directed weighted graph round-trips" do
      g =
        Graph.new()
        |> Graph.add_edge("a", "b", weight: 2.5)
        |> Graph.add_edge("b", "c", weight: 3.0)
        |> Graph.add_edge("a", "c", weight: 7.0)

      text = EdgeList.to_edge_list(g)
      g2 = EdgeList.from_edge_list(text)

      assert Graph.num_edges(g2) == 3
      assert Graph.num_vertices(g2) == 3

      [e_ab] = Graph.edges_between(g2, "a", "b")
      assert e_ab.weight == 2.5
    end

    test "undirected round-trip" do
      g =
        Graph.new(type: :undirected)
        |> Graph.add_edge("x", "y", weight: 1.5)
        |> Graph.add_edge("y", "z", weight: 4.0)

      text = EdgeList.to_edge_list(g)
      g2 = EdgeList.from_edge_list(text, directed: false)

      assert g2.type == :undirected
      assert Graph.has_edge?(g2, "x", "y")
      assert Graph.has_edge?(g2, "y", "x")
      [e] = Graph.edges_between(g2, "x", "y")
      assert e.weight == 1.5
    end

    test "multi-edge round-trip" do
      g =
        Graph.new()
        |> Graph.add_edge("a", "b", weight: 1.0)
        |> Graph.add_edge("a", "b", weight: 2.0)

      text = EdgeList.to_edge_list(g, weighted: true)
      g2 = EdgeList.from_edge_list(text, weighted: true)

      assert Graph.num_edges(g2) == 2
      assert length(Graph.edges_between(g2, "a", "b")) == 2
    end

    test "separator: \",\" round-trips, including vertex names with spaces" do
      g =
        Graph.new()
        |> Graph.add_edge("New York", "Boston", weight: 2.5)
        |> Graph.add_edge("Boston", "a b c", weight: -1.0)

      text = EdgeList.to_edge_list(g, separator: ",")
      assert text =~ "New York,Boston,2.5"

      g2 = EdgeList.from_edge_list(text, separator: ",")

      assert Enum.sort(Graph.vertices(g2)) == ["Boston", "New York", "a b c"]
      assert [%{weight: 2.5}] = Graph.edges_between(g2, "New York", "Boston")
      assert [%{weight: -1.0}] = Graph.edges_between(g2, "Boston", "a b c")
    end

    test "mixed weighted and unweighted lines round-trip through per-line detection" do
      g = EdgeList.from_edge_list("a,b\nb,c,3.0", separator: ",")
      text = EdgeList.to_edge_list(g, separator: ",")
      g2 = EdgeList.from_edge_list(text, separator: ",")

      assert [%{weight: 1.0}] = Graph.edges_between(g2, "a", "b")
      assert [%{weight: 3.0}] = Graph.edges_between(g2, "b", "c")
    end
  end
end
