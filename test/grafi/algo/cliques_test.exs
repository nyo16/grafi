defmodule Grafi.Algo.CliquesTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias Grafi.Algo.Cliques
  alias Grafi.Graph

  doctest Grafi.Algo.Cliques

  describe "maximal_cliques/1" do
    test "empty graph yields no cliques" do
      assert Cliques.maximal_cliques(Graph.new(type: :undirected)) == []
    end

    test "single vertex yields one clique of size 1" do
      g = Graph.new(type: :undirected) |> Graph.add_vertex(:a)
      assert [c] = Cliques.maximal_cliques(g)
      assert MapSet.equal?(c, MapSet.new([:a]))
    end

    test "triangle has one maximal clique of size 3" do
      g =
        Graph.new(type: :undirected)
        |> Graph.add_edges([{:a, :b}, {:b, :c}, {:c, :a}])

      assert [clique] = Cliques.maximal_cliques(g)
      assert MapSet.equal?(clique, MapSet.new([:a, :b, :c]))
    end

    test "K_4 has one maximal clique of size 4" do
      g =
        Graph.new(type: :undirected)
        |> Graph.add_edges(for(i <- 1..3, j <- (i + 1)..4, do: {i, j}))

      assert [clique] = Cliques.maximal_cliques(g)
      assert MapSet.equal?(clique, MapSet.new([1, 2, 3, 4]))
    end

    test "path P_4 has three maximal cliques (the edges)" do
      g =
        Graph.new(type: :undirected)
        |> Graph.add_edges([{:a, :b}, {:b, :c}, {:c, :d}])

      cliques = Cliques.maximal_cliques(g) |> MapSet.new()

      expected =
        MapSet.new([
          MapSet.new([:a, :b]),
          MapSet.new([:b, :c]),
          MapSet.new([:c, :d])
        ])

      assert MapSet.equal?(cliques, expected)
    end

    test "two disjoint triangles yield two cliques of size 3" do
      g =
        Graph.new(type: :undirected)
        |> Graph.add_edges([
          {:a, :b},
          {:b, :c},
          {:c, :a},
          {:x, :y},
          {:y, :z},
          {:z, :x}
        ])

      cliques = Cliques.maximal_cliques(g)
      assert length(cliques) == 2
      assert Enum.all?(cliques, &(MapSet.size(&1) == 3))

      sets = MapSet.new(cliques)

      assert MapSet.equal?(
               sets,
               MapSet.new([MapSet.new([:a, :b, :c]), MapSet.new([:x, :y, :z])])
             )
    end

    test "bowtie: two triangles sharing one vertex yields two cliques of size 3" do
      g =
        Graph.new(type: :undirected)
        |> Graph.add_edges([
          {:a, :b},
          {:b, :c},
          {:c, :a},
          {:c, :d},
          {:d, :e},
          {:e, :c}
        ])

      cliques = Cliques.maximal_cliques(g)
      assert length(cliques) == 2
      assert Enum.all?(cliques, &(MapSet.size(&1) == 3))

      assert MapSet.new(cliques) ==
               MapSet.new([MapSet.new([:a, :b, :c]), MapSet.new([:c, :d, :e])])
    end

    test "self-loops are ignored" do
      g =
        Graph.new(type: :undirected)
        |> Graph.add_edges([{:a, :a}, {:a, :b}, {:b, :c}, {:c, :a}])

      assert [clique] = Cliques.maximal_cliques(g)
      assert MapSet.equal?(clique, MapSet.new([:a, :b, :c]))
    end

    test "operates on underlying undirected graph for directed inputs" do
      g = Graph.new() |> Graph.add_edges([{:a, :b}, {:b, :c}, {:c, :a}])
      assert [clique] = Cliques.maximal_cliques(g)
      assert MapSet.equal?(clique, MapSet.new([:a, :b, :c]))
    end
  end

  describe "maximum_clique/1, clique_number/1, count_cliques/1" do
    test "empty graph" do
      g = Graph.new(type: :undirected)
      assert MapSet.equal?(Cliques.maximum_clique(g), MapSet.new())
      assert Cliques.clique_number(g) == 0
      assert Cliques.count_cliques(g) == 0
    end

    test "clique_number matches maximum_clique size" do
      g =
        Graph.new(type: :undirected)
        |> Graph.add_edges([
          {:a, :b},
          {:b, :c},
          {:c, :a},
          {:c, :d},
          {:d, :e},
          {:e, :c}
        ])

      assert Cliques.clique_number(g) == Cliques.maximum_clique(g) |> MapSet.size()
      assert Cliques.clique_number(g) == 3
    end

    test "K_4 maximum clique size = 4" do
      g =
        Graph.new(type: :undirected)
        |> Graph.add_edges(for(i <- 1..3, j <- (i + 1)..4, do: {i, j}))

      assert Cliques.clique_number(g) == 4
    end

    test "count_cliques on P_4" do
      g =
        Graph.new(type: :undirected)
        |> Graph.add_edges([{:a, :b}, {:b, :c}, {:c, :d}])

      assert Cliques.count_cliques(g) == 3
    end
  end

  describe "property: every maximal clique is actually a clique" do
    property "all pairs inside a reported clique are adjacent" do
      check all(
              vs <- uniq_list_of(atom(:alphanumeric), min_length: 1, max_length: 8),
              edges <- list_of({member_of(vs), member_of(vs)}, max_length: 15)
            ) do
        g =
          Graph.new(type: :undirected)
          |> Graph.add_vertices(vs)
          |> Graph.add_edges(edges)

        for clique <- Cliques.maximal_cliques(g) do
          members = MapSet.to_list(clique)

          for u <- members, v <- members, u < v do
            assert Graph.has_edge?(g, u, v) or Graph.has_edge?(g, v, u),
                   "clique #{inspect(members)} contains non-adjacent pair " <>
                     "#{inspect(u)}, #{inspect(v)}"
          end
        end
      end
    end
  end

  describe "maximal_cliques/2 :max_results" do
    test "caps the number of cliques returned" do
      # 4 disconnected vertices => 4 singleton maximal cliques.
      g =
        Graph.new(type: :undirected)
        |> Graph.add_vertex(:a)
        |> Graph.add_vertex(:b)
        |> Graph.add_vertex(:c)
        |> Graph.add_vertex(:d)

      assert length(Cliques.maximal_cliques(g, max_results: 2)) == 2
      assert length(Cliques.maximal_cliques(g, max_results: :infinity)) == 4
    end

    test "returned entries are still valid maximal cliques" do
      g =
        Graph.new(type: :undirected)
        |> Graph.add_edges([{:a, :b}, {:b, :c}, {:c, :a}, {:x, :y}, {:y, :z}, {:z, :x}])

      capped = Cliques.maximal_cliques(g, max_results: 1)
      assert length(capped) == 1
      assert Enum.all?(capped, &is_struct(&1, MapSet))
    end
  end
end
