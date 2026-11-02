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
      assert Graph.num_edges(sub) == 3
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

  describe "property: matches a naive peeling reference" do
    property "core numbers equal repeated removal of vertices of degree < k" do
      check all(g <- Grafi.Test.Generators.graph(max_vertices: 12, max_edges: 30)) do
        assert KCore.core_numbers(g) == naive_cores(g)
      end
    end
  end

  describe "scaling" do
    # Batagelj–Zaversnik is O(V + E): 4x the leaves takes about 4x as long.
    # The old peeling rewrote a degree-indexed tuple per decrement, O(V · Δ),
    # so a star went quadratic (16x; over 60 s at 100k leaves). Best of 3.
    @tag :slow
    test "core numbers of a star scale linearly up to 100k leaves" do
      # One input alive at a time, so timed runs don't GC the other.
      best = fn n ->
        g = Enum.reduce(1..n, Graph.new(type: :undirected), &Graph.add_edge(&2, 0, &1))
        cores = KCore.core_numbers(g)
        assert map_size(cores) == n + 1
        assert Enum.all?(cores, fn {_v, c} -> c == 1 end)

        Enum.min(
          for _ <- 1..3 do
            :erlang.garbage_collect()
            elem(:timer.tc(KCore, :core_numbers, [g]), 0)
          end
        )
      end

      {t_small, t_large} = {best.(25_000), best.(100_000)}
      assert t_large < 8 * t_small, "4x the leaves took #{Float.round(t_large / t_small, 1)}x"
    end
  end

  # Core number of v = the largest k such that v survives repeatedly deleting
  # every vertex with fewer than k distinct non-self neighbours.
  defp naive_cores(g) do
    adj =
      Map.new(Graph.vertices(g), fn v ->
        {v, g |> Graph.neighbors(v) |> List.delete(v) |> MapSet.new()}
      end)

    Map.new(adj, fn {v, _} ->
      {v, Enum.find(0..map_size(adj), fn k -> not Map.has_key?(k_survivors(adj, k + 1), v) end)}
    end)
  end

  defp k_survivors(adj, k) do
    drop = for {v, ns} <- adj, MapSet.size(ns) < k, do: v

    if drop == [] do
      adj
    else
      gone = MapSet.new(drop)

      adj
      |> Map.drop(drop)
      |> Map.new(fn {v, ns} -> {v, MapSet.difference(ns, gone)} end)
      |> k_survivors(k)
    end
  end
end
