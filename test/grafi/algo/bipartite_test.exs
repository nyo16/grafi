defmodule Grafi.Algo.BipartiteTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias Grafi.Algo.Bipartite
  alias Grafi.Graph

  doctest Grafi.Algo.Bipartite

  describe "bipartite?/1" do
    test "empty graph is trivially bipartite" do
      assert Bipartite.bipartite?(Graph.new(type: :undirected))
      assert Bipartite.bipartite?(Graph.new())
    end

    test "single vertex is bipartite" do
      g = Graph.new(type: :undirected) |> Graph.add_vertex(:a)
      assert Bipartite.bipartite?(g)
    end

    test "K_{3,3} is bipartite" do
      g =
        Graph.new(type: :undirected)
        |> Graph.add_edges(for(u <- [:u1, :u2, :u3], v <- [:v1, :v2, :v3], do: {u, v}))

      assert Bipartite.bipartite?(g)
    end

    test "triangle K_3 is not bipartite" do
      g =
        Graph.new(type: :undirected)
        |> Graph.add_edges([{:a, :b}, {:b, :c}, {:c, :a}])

      refute Bipartite.bipartite?(g)
    end

    test "even cycle C_4 is bipartite" do
      g =
        Graph.new(type: :undirected)
        |> Graph.add_edges([{:a, :b}, {:b, :c}, {:c, :d}, {:d, :a}])

      assert Bipartite.bipartite?(g)
    end

    test "odd cycle C_5 is not bipartite" do
      g =
        Graph.new(type: :undirected)
        |> Graph.add_edges([{:a, :b}, {:b, :c}, {:c, :d}, {:d, :e}, {:e, :a}])

      refute Bipartite.bipartite?(g)
    end

    test "treats directed graph as undirected" do
      # Directed triangle still violates bipartiteness when treated undirected.
      g = Graph.new() |> Graph.add_edges([{:a, :b}, {:b, :c}, {:c, :a}])
      refute Bipartite.bipartite?(g)
    end

    test "disconnected components: all must be bipartite" do
      g =
        Graph.new(type: :undirected)
        |> Graph.add_edges([{:a, :b}, {:c, :d}, {:d, :e}, {:e, :c}])

      refute Bipartite.bipartite?(g)
    end

    test "forest is bipartite" do
      g =
        Graph.new(type: :undirected)
        |> Graph.add_edges([{:r, :l}, {:r, :r2}, {:l, :ll}])

      assert Bipartite.bipartite?(g)
    end
  end

  describe "coloring/1" do
    test "K_{3,3} coloring respects partition" do
      g =
        Graph.new(type: :undirected)
        |> Graph.add_edges(for(u <- [:u1, :u2, :u3], v <- [:v1, :v2, :v3], do: {u, v}))

      assert {:ok, colors} = Bipartite.coloring(g)
      assert map_size(colors) == 6

      for e <- Graph.edges(g) do
        assert colors[e.from] != colors[e.to]
      end
    end

    test "triangle reports a violating edge" do
      g =
        Graph.new(type: :undirected)
        |> Graph.add_edges([{:a, :b}, {:b, :c}, {:c, :a}])

      assert {:error, {:not_bipartite, {u, v}}} = Bipartite.coloring(g)
      assert u in [:a, :b, :c]
      assert v in [:a, :b, :c]
      assert u != v
      # The violating edge must actually exist in the underlying graph.
      assert Graph.has_edge?(g, u, v) or Graph.has_edge?(g, v, u)
    end

    test "a self-loop is an odd cycle" do
      g = Graph.new(type: :undirected) |> Graph.add_edges([{:a, :b}, {:b, :b}])

      assert {:error, {:not_bipartite, {:b, :b}}} = Bipartite.coloring(g)
      refute Bipartite.bipartite?(g)
    end

    test "isolated vertex gets a color" do
      g = Graph.new(type: :undirected) |> Graph.add_vertex(:x)
      assert {:ok, %{x: c}} = Bipartite.coloring(g)
      assert c in [0, 1]
    end
  end

  describe "sets/1" do
    test "K_{3,3} returns the two sides" do
      g =
        Graph.new(type: :undirected)
        |> Graph.add_edges(for(u <- [:u1, :u2, :u3], v <- [:v1, :v2, :v3], do: {u, v}))

      assert {:ok, {a, b}} = Bipartite.sets(g)
      assert MapSet.size(a) == 3
      assert MapSet.size(b) == 3
      assert MapSet.disjoint?(a, b)

      # One side must be exactly the u's, the other exactly the v's.
      us = MapSet.new([:u1, :u2, :u3])
      vs = MapSet.new([:v1, :v2, :v3])

      assert (MapSet.equal?(a, us) and MapSet.equal?(b, vs)) or
               (MapSet.equal?(a, vs) and MapSet.equal?(b, us))
    end

    test "triangle errors" do
      g =
        Graph.new(type: :undirected)
        |> Graph.add_edges([{:a, :b}, {:b, :c}, {:c, :a}])

      assert {:error, :not_bipartite} = Bipartite.sets(g)
    end
  end

  describe "project/2" do
    test "small bipartite projection: shared-neighbor weights" do
      # u1 - m1, u1 - m2, u2 - m1, u2 - m2: u1 and u2 share m1 and m2.
      g =
        Graph.new(type: :undirected)
        |> Graph.add_edges([{:u1, :m1}, {:u1, :m2}, {:u2, :m1}, {:u2, :m2}])

      p = Bipartite.project(g, [:u1, :u2])

      assert Graph.num_vertices(p) == 2
      assert Graph.has_edge?(p, :u1, :u2)
      [edge] = Graph.edges(p)
      assert edge.weight == 2.0
    end

    test "no shared neighbors yields no edges" do
      g =
        Graph.new(type: :undirected)
        |> Graph.add_edges([{:u1, :m1}, {:u2, :m2}])

      p = Bipartite.project(g, [:u1, :u2])
      assert Graph.num_edges(p) == 0
      assert MapSet.new(Graph.vertices(p)) == MapSet.new([:u1, :u2])
    end

    test "accepts a MapSet for side" do
      g =
        Graph.new(type: :undirected)
        |> Graph.add_edges([{:u1, :m1}, {:u2, :m1}])

      p = Bipartite.project(g, MapSet.new([:u1, :u2]))
      assert Graph.has_edge?(p, :u1, :u2)
    end

    test "three-side vertices, partial overlap" do
      # u1-{m1,m2}, u2-{m2,m3}, u3-{m1,m3}
      g =
        Graph.new(type: :undirected)
        |> Graph.add_edges([
          {:u1, :m1},
          {:u1, :m2},
          {:u2, :m2},
          {:u2, :m3},
          {:u3, :m1},
          {:u3, :m3}
        ])

      p = Bipartite.project(g, [:u1, :u2, :u3])

      # Each pair shares exactly one m: weight 1.
      assert Graph.num_edges(p) == 3

      for {a, b} <- [{:u1, :u2}, {:u2, :u3}, {:u1, :u3}] do
        [e] = Graph.edges_between(p, a, b)
        assert e.weight == 1.0
      end
    end

    test "side vertices not in graph are skipped" do
      g =
        Graph.new(type: :undirected)
        |> Graph.add_edges([{:u1, :m1}, {:u2, :m1}])

      p = Bipartite.project(g, [:u1, :u2, :ghost])
      refute Graph.has_vertex?(p, :ghost)
      assert Graph.has_edge?(p, :u1, :u2)
    end
  end

  describe "property: random bipartite construction is bipartite" do
    property "graph built as A-B edges is always bipartite" do
      check all(
              left_seed <-
                uniq_list_of(Grafi.Test.Generators.vertex_id(:simple_string),
                  min_length: 1,
                  max_length: 8
                ),
              right_seed <-
                uniq_list_of(Grafi.Test.Generators.vertex_id(:simple_string),
                  min_length: 1,
                  max_length: 8
                ),
              edge_count <- integer(0..30)
            ) do
        # Tag sides to keep them strictly disjoint, using a 3-tuple so
        # `Graph.add_vertices/2` doesn't mistake it for `{vertex, opts}`.
        left = Enum.map(left_seed, &{:left, &1, nil})
        right = Enum.map(right_seed, &{:right, &1, nil})

        edges =
          if edge_count > 0 do
            for _ <- 1..edge_count, do: {Enum.random(left), Enum.random(right)}
          else
            []
          end

        g =
          Graph.new(type: :undirected)
          |> Graph.add_vertices(left ++ right)
          |> Graph.add_edges(edges)

        assert Bipartite.bipartite?(g)
      end
    end
  end
end
