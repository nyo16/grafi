defmodule Grafi.Algo.KCoreTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias Grafi.Algo.KCore
  alias Grafi.Graph

  doctest Grafi.Algo.KCore

  describe "core_numbers/1" do
    test "empty graph returns empty map" do
      assert KCore.core_numbers(Graph.new(type: :undirected)) == %{}
    end

    test "isolated vertices have core 0" do
      g = Graph.new(type: :undirected) |> Graph.add_vertices([:a, :b, :c])
      assert KCore.core_numbers(g) == %{a: 0, b: 0, c: 0}
    end

    test "triangle: every vertex has core 2" do
      g =
        Graph.new(type: :undirected)
        |> Graph.add_edges([{:a, :b}, {:b, :c}, {:c, :a}])

      assert KCore.core_numbers(g) == %{a: 2, b: 2, c: 2}
    end

    test "star K_{1,n}: all vertices have core 1" do
      # The whole star is its own 1-core; nothing has degree >= 2.
      g =
        Graph.new(type: :undirected)
        |> Graph.add_edges([{:c, :l1}, {:c, :l2}, {:c, :l3}, {:c, :l4}])

      assert KCore.core_numbers(g) == %{c: 1, l1: 1, l2: 1, l3: 1, l4: 1}
    end

    test "complete graph K_5: every vertex has core 4" do
      g =
        Graph.new(type: :undirected)
        |> Graph.add_edges(for(i <- 1..4, j <- (i + 1)..5, do: {i, j}))

      cores = KCore.core_numbers(g)
      assert map_size(cores) == 5
      assert Enum.all?(cores, fn {_, c} -> c == 4 end)
    end

    test "triangle with pendant: triangle is 2-core, pendant is 1-core" do
      g =
        Graph.new(type: :undirected)
        |> Graph.add_edges([{:a, :b}, {:b, :c}, {:c, :a}, {:c, :d}])

      assert KCore.core_numbers(g) == %{a: 2, b: 2, c: 2, d: 1}
    end

    test "directed graph uses underlying undirected" do
      g = Graph.new() |> Graph.add_edges([{:a, :b}, {:b, :c}, {:c, :a}])
      cores = KCore.core_numbers(g)
      assert Enum.all?(cores, fn {_, c} -> c == 2 end)
    end

    test "self-loops are ignored for the purpose of core numbers" do
      g =
        Graph.new(type: :undirected)
        |> Graph.add_edges([{:a, :a}, {:a, :b}, {:b, :c}, {:c, :a}])

      assert KCore.core_numbers(g) == %{a: 2, b: 2, c: 2}
    end
  end

  describe "k_core/2" do
    test "extracts the right subgraph for k = 2" do
      g =
        Graph.new(type: :undirected)
        |> Graph.add_edges([{:a, :b}, {:b, :c}, {:c, :a}, {:c, :d}])

      sub = KCore.k_core(g, 2)
      assert Enum.sort(Graph.vertices(sub)) == [:a, :b, :c]
      # `Graph.edges/1` lists each undirected edge once.
      assert length(Graph.edges(sub)) == 3
      assert sub.type == :undirected
    end

    test "k = 0 keeps all vertices" do
      g =
        Graph.new(type: :undirected)
        |> Graph.add_vertices([:x, :y])
        |> Graph.add_edge(:x, :y)

      sub = KCore.k_core(g, 0)
      assert Enum.sort(Graph.vertices(sub)) == [:x, :y]
    end

    test "k larger than degeneracy returns empty graph" do
      g =
        Graph.new(type: :undirected)
        |> Graph.add_edges([{:a, :b}, {:b, :c}])

      sub = KCore.k_core(g, 5)
      assert Graph.num_vertices(sub) == 0
    end
  end

  describe "degeneracy/1" do
    test "empty graph has degeneracy 0" do
      assert KCore.degeneracy(Graph.new(type: :undirected)) == 0
    end

    test "triangle has degeneracy 2" do
      g =
        Graph.new(type: :undirected)
        |> Graph.add_edges([{:a, :b}, {:b, :c}, {:c, :a}])

      assert KCore.degeneracy(g) == 2
    end

    test "K_5 has degeneracy 4" do
      g =
        Graph.new(type: :undirected)
        |> Graph.add_edges(for(i <- 1..4, j <- (i + 1)..5, do: {i, j}))

      assert KCore.degeneracy(g) == 4
    end

    test "tree has degeneracy 1" do
      g =
        Graph.new(type: :undirected)
        |> Graph.add_edges([{:r, :a}, {:r, :b}, {:a, :c}, {:b, :d}])

      assert KCore.degeneracy(g) == 1
    end
  end

  describe "property: core number bounded by degree" do
    property "every vertex's core number <= its degree" do
      check all(
              vs <- uniq_list_of(atom(:alphanumeric), min_length: 1, max_length: 10),
              edges <- list_of({member_of(vs), member_of(vs)}, max_length: 20)
            ) do
        g =
          Graph.new(type: :undirected)
          |> Graph.add_vertices(vs)
          |> Graph.add_edges(edges)

        cores = KCore.core_numbers(g)

        for {v, c} <- cores do
          assert c <= Graph.degree(g, v),
                 "core #{c} > degree #{Graph.degree(g, v)} for #{inspect(v)}"
        end
      end
    end
  end
end
