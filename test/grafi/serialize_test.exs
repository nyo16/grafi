defmodule Grafi.SerializeTest do
  use ExUnit.Case, async: true

  alias Grafi.Graph

  describe "DOT export" do
    test "directed graph" do
      g =
        Grafi.new()
        |> Grafi.add_edges([{:a, :b}, {:b, :c}])

      dot = Grafi.to_dot(g)
      assert dot =~ "digraph"
      assert dot =~ "a -> b"
    end

    test "undirected graph" do
      g =
        Grafi.new(type: :undirected)
        |> Grafi.add_edge(:x, :y)

      dot = Grafi.to_dot(g)
      assert dot =~ "graph"
      assert dot =~ "--"
    end
  end

  describe "JSON round-trip" do
    test "directed weighted graph survives to_json |> from_json" do
      g =
        Grafi.new()
        |> Grafi.add_edge(:a, :b, weight: 2.5)
        |> Grafi.add_edge(:b, :c, weight: 3.0)
        |> Grafi.add_edge(:a, :c, weight: 7.0)

      json = Grafi.to_json(g)
      g2 = Grafi.from_json(json)

      # After JSON round-trip, vertex IDs become strings
      assert g2.type == :directed
      assert Graph.num_vertices(g2) == 3
      assert Graph.num_edges(g2) == 3
      assert Graph.has_edge?(g2, "a", "b")
      assert Graph.has_edge?(g2, "b", "c")
      assert Graph.has_edge?(g2, "a", "c")

      # Verify weights are preserved
      [edge_ab] = Graph.edges_between(g2, "a", "b")
      assert edge_ab.weight == 2.5
      [edge_bc] = Graph.edges_between(g2, "b", "c")
      assert edge_bc.weight == 3.0
    end

    test "undirected graph survives to_json |> from_json" do
      g =
        Grafi.new(type: :undirected)
        |> Grafi.add_edge(:x, :y, weight: 1.5)
        |> Grafi.add_edge(:y, :z)

      json = Grafi.to_json(g)
      g2 = Grafi.from_json(json)

      # After JSON round-trip, vertex IDs become strings
      assert g2.type == :undirected
      assert Graph.num_vertices(g2) == 3
      assert Graph.num_edges(g2) == 2
      assert Graph.has_edge?(g2, "x", "y")
      assert Graph.has_edge?(g2, "y", "x")
    end

    test "empty graph survives to_json |> from_json" do
      g = Grafi.new()
      json = Grafi.to_json(g)
      g2 = Grafi.from_json(json)

      assert g2.type == :directed
      assert Graph.num_vertices(g2) == 0
      assert Graph.num_edges(g2) == 0
    end

    test "to_json produces string containing expected keys and data" do
      g =
        Grafi.new()
        |> Grafi.add_edge(:a, :b, weight: 5.0)

      json = Grafi.to_json(g)

      assert is_binary(json)
      assert json =~ "directed"
      assert json =~ "a"
      assert json =~ "b"
      assert json =~ "5.0"
    end

    test "from_json with invalid JSON returns :malformed_json" do
      assert Grafi.from_json("{not json") == {:error, :malformed_json}
    end

    test "from_json missing keys returns :malformed_json" do
      assert Grafi.from_json(~s({"type": "directed"})) == {:error, :malformed_json}
      assert Grafi.from_json(~s({"vertices": [], "edges": []})) == {:error, :malformed_json}
    end

    test "from_json with wrong-typed fields returns :malformed_json" do
      assert Grafi.from_json(~s({"type": "directed", "vertices": "x", "edges": []})) ==
               {:error, :malformed_json}
    end
  end

  describe "DOT escaping" do
    test "vertex names with quotes are escaped" do
      g = Grafi.new() |> Grafi.add_edge("a\"b", "c")
      dot = Grafi.to_dot(g)
      # The embedded double-quote should be escaped as a backslash-quote.
      assert String.contains?(dot, "\"a\\\"b\"")
    end

    test "vertex names with backslashes are escaped" do
      g = Grafi.new() |> Grafi.add_edge("a\\b", "c")
      dot = Grafi.to_dot(g)
      assert String.contains?(dot, "\"a\\\\b\"")
    end

    test "control characters in vertex names raise" do
      g = Grafi.new() |> Grafi.add_edge("bad\x01name", "c")

      assert_raise ArgumentError, ~r/control characters/, fn ->
        Grafi.to_dot(g)
      end
    end
  end
end
