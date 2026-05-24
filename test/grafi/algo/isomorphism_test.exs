defmodule Grafi.Algo.IsomorphismTest do
  use ExUnit.Case, async: true

  alias Grafi.Algo.Isomorphism
  alias Grafi.Graph

  doctest Grafi.Algo.Isomorphism

  # ── Builders ──────────────────────────────────────────────────────────

  defp k(n, opts \\ []) do
    type = Keyword.get(opts, :type, :undirected)

    Graph.new(type: type)
    |> Graph.add_edges(for(i <- 1..n, j <- (i + 1)..n//1, do: {i, j}))
  end

  defp path(labels, opts \\ []) do
    type = Keyword.get(opts, :type, :undirected)
    edges = labels |> Enum.chunk_every(2, 1, :discard) |> Enum.map(fn [a, b] -> {a, b} end)
    Graph.new(type: type) |> Graph.add_edges(edges)
  end

  defp triangle(opts \\ []) do
    type = Keyword.get(opts, :type, :undirected)
    Graph.new(type: type) |> Graph.add_edges([{:a, :b}, {:b, :c}, {:c, :a}])
  end

  # Verify that a mapping is a valid isomorphism from g1 to g2.
  defp valid_iso?(g1, g2, mapping) do
    Graph.num_vertices(g1) == map_size(mapping) and
      Enum.all?(Graph.vertices(g1), &Map.has_key?(mapping, &1)) and
      Enum.uniq(Map.values(mapping)) |> length() == map_size(mapping) and
      Enum.all?(Graph.edges(g1), fn e ->
        Graph.has_edge?(g2, mapping[e.from], mapping[e.to])
      end) and
      Enum.all?(Graph.edges(g2), fn e ->
        rev = Map.new(mapping, fn {k, v} -> {v, k} end)
        Graph.has_edge?(g1, rev[e.from], rev[e.to])
      end)
  end

  # ── isomorphic?/2 ─────────────────────────────────────────────────────

  describe "isomorphic?/2" do
    test "two K_3 graphs are isomorphic" do
      a = triangle()
      b = Graph.new(type: :undirected) |> Graph.add_edges([{1, 2}, {2, 3}, {3, 1}])
      assert Isomorphism.isomorphic?(a, b)
    end

    test "K_3 and P_3 are not isomorphic" do
      tri = triangle()
      p = path([:x, :y, :z])
      refute Isomorphism.isomorphic?(tri, p)
    end

    test "K_3 and K_4 are not isomorphic (vertex-count mismatch)" do
      refute Isomorphism.isomorphic?(triangle(), k(4))
    end

    test "g is isomorphic to itself" do
      g =
        Graph.new(type: :undirected)
        |> Graph.add_edges([{1, 2}, {2, 3}, {3, 4}, {4, 1}, {1, 3}])

      assert Isomorphism.isomorphic?(g, g)
    end

    test "two empty graphs are isomorphic" do
      a = Graph.new(type: :undirected)
      b = Graph.new(type: :undirected)
      assert Isomorphism.isomorphic?(a, b)
    end

    test "two singleton graphs are isomorphic" do
      a = Graph.new(type: :undirected) |> Graph.add_vertex(:x)
      b = Graph.new(type: :undirected) |> Graph.add_vertex(1)
      assert Isomorphism.isomorphic?(a, b)
    end

    test "raises on mismatched directedness" do
      a = Graph.new(type: :directed) |> Graph.add_edges([{:a, :b}])
      b = Graph.new(type: :undirected) |> Graph.add_edges([{:a, :b}])
      assert_raise ArgumentError, fn -> Isomorphism.isomorphic?(a, b) end
    end

    test "directed: cycle vs reverse cycle (isomorphic as a 3-cycle)" do
      a = Graph.new() |> Graph.add_edges([{:a, :b}, {:b, :c}, {:c, :a}])
      b = Graph.new() |> Graph.add_edges([{1, 2}, {2, 3}, {3, 1}])
      assert Isomorphism.isomorphic?(a, b)
    end
  end

  # ── isomorphism/2 ─────────────────────────────────────────────────────

  describe "isomorphism/2" do
    test "returns a valid mapping on isomorphic graphs" do
      a = triangle()
      b = Graph.new(type: :undirected) |> Graph.add_edges([{10, 20}, {20, 30}, {30, 10}])

      assert {:ok, mapping} = Isomorphism.isomorphism(a, b)
      assert valid_iso?(a, b, mapping)
    end

    test "identity for self-isomorphism is valid" do
      g =
        Graph.new(type: :undirected)
        |> Graph.add_edges([{1, 2}, {2, 3}, {3, 4}])

      assert {:ok, mapping} = Isomorphism.isomorphism(g, g)
      assert valid_iso?(g, g, mapping)
    end

    test "returns :no_isomorphism on non-isomorphic graphs" do
      assert Isomorphism.isomorphism(triangle(), path([:a, :b, :c])) == :no_isomorphism
    end

    test "empty graphs map to empty mapping" do
      a = Graph.new(type: :undirected)
      b = Graph.new(type: :undirected)
      assert {:ok, mapping} = Isomorphism.isomorphism(a, b)
      assert mapping == %{}
    end
  end

  # ── subgraph_isomorphic?/2 ────────────────────────────────────────────

  describe "subgraph_isomorphic?/2" do
    test "triangle is sub-isomorphic to K_4" do
      assert Isomorphism.subgraph_isomorphic?(k(4), triangle())
    end

    test "K_4 is NOT sub-isomorphic to triangle" do
      refute Isomorphism.subgraph_isomorphic?(triangle(), k(4))
    end

    test "P_3 is sub-isomorphic to a 5-vertex graph containing a path" do
      host =
        Graph.new(type: :undirected)
        |> Graph.add_edges([{:a, :b}, {:b, :c}, {:c, :d}, {:d, :e}])

      pattern = path([1, 2, 3])

      assert Isomorphism.subgraph_isomorphic?(host, pattern)
    end

    test "empty pattern always matches" do
      assert Isomorphism.subgraph_isomorphic?(triangle(), Graph.new(type: :undirected))
    end

    test "any graph contains itself as sub-isomorphic" do
      g = k(4)
      assert Isomorphism.subgraph_isomorphic?(g, g)
    end
  end

  # ── subgraph_isomorphism/2 ───────────────────────────────────────────

  describe "subgraph_isomorphism/2" do
    test "returns a valid pattern->host mapping" do
      host = k(4)
      pattern = triangle()

      assert {:ok, mapping} = Isomorphism.subgraph_isomorphism(host, pattern)
      assert map_size(mapping) == 3

      # Every pattern edge must exist in host between the mapped vertices.
      assert Enum.all?(Graph.edges(pattern), fn e ->
               Graph.has_edge?(host, mapping[e.from], mapping[e.to])
             end)
    end

    test "returns :no_isomorphism when pattern is larger" do
      assert Isomorphism.subgraph_isomorphism(triangle(), k(4)) == :no_isomorphism
    end
  end

  # ── count_subgraph_isomorphisms/2 ────────────────────────────────────

  describe "count_subgraph_isomorphisms/2" do
    test "triangle into K_4 yields 24 sub-isomorphisms (4 triangles × 3! orderings)" do
      assert Isomorphism.count_subgraph_isomorphisms(k(4), triangle()) == 24
    end

    test "triangle into K_3 yields 6 (3! orderings)" do
      assert Isomorphism.count_subgraph_isomorphisms(triangle(), triangle()) == 6
    end

    test "P_3 (3 vertices, 2 edges) into K_3 yields 6" do
      # In K_3, every ordered choice (a, b, c) of three distinct vertices
      # forms a P_3 (since any two are adjacent). 3·2·1 = 6.
      assert Isomorphism.count_subgraph_isomorphisms(triangle(), path([1, 2, 3])) == 6
    end

    test "pattern larger than host yields 0" do
      assert Isomorphism.count_subgraph_isomorphisms(triangle(), k(4)) == 0
    end

    test "empty pattern yields 1" do
      assert Isomorphism.count_subgraph_isomorphisms(triangle(), Graph.new(type: :undirected)) ==
               1
    end
  end
end
