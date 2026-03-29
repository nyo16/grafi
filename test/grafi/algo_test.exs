defmodule Grafi.AlgoTest do
  use ExUnit.Case, async: true

  setup do
    g =
      Grafi.new()
      |> Grafi.add_edges([
        {:a, :b, weight: 1.0},
        {:b, :c, weight: 2.0},
        {:a, :c, weight: 5.0},
        {:c, :d, weight: 1.0}
      ])

    %{g: g}
  end

  test "BFS order", %{g: g} do
    order = Grafi.bfs(g, :a) |> Enum.to_list()
    assert hd(order) == :a
    assert length(order) == 4
  end

  test "DFS visits all", %{g: g} do
    order = Grafi.dfs(g, :a) |> Enum.to_list()
    assert MapSet.new(order) == MapSet.new([:a, :b, :c, :d])
  end

  test "Dijkstra shortest path", %{g: g} do
    assert {:ok, {path, dist}} = Grafi.shortest_path(g, :a, :d)
    assert path == [:a, :b, :c, :d]
    assert dist == 4.0
  end

  test "Dijkstra no path" do
    g = Grafi.new() |> Grafi.add_vertices([:a, :b])
    assert Grafi.shortest_path(g, :a, :b) == :no_path
  end

  test "PageRank" do
    g =
      Grafi.new()
      |> Grafi.add_edges([{:a, :b}, {:b, :c}, {:c, :a}, {:d, :c}])

    ranks = Grafi.pagerank(g)
    assert map_size(ranks) == 4
    # All ranks should sum to ~1.0
    total = ranks |> Map.values() |> Enum.sum()
    assert_in_delta total, 1.0, 0.01
  end

  test "has_cycle?" do
    cyclic = Grafi.new() |> Grafi.add_edges([{:a, :b}, {:b, :c}, {:c, :a}])
    acyclic = Grafi.new() |> Grafi.add_edges([{:a, :b}, {:b, :c}])

    assert Grafi.has_cycle?(cyclic)
    refute Grafi.has_cycle?(acyclic)
  end

  test "find_cycle" do
    g = Grafi.new() |> Grafi.add_edges([{:a, :b}, {:b, :c}, {:c, :a}])
    assert {:ok, cycle} = Grafi.find_cycle(g)
    assert length(cycle) >= 3
  end

  test "SCC" do
    g =
      Grafi.new()
      |> Grafi.add_edges([{:a, :b}, {:b, :c}, {:c, :a}, {:d, :c}])

    sccs = Grafi.scc(g)
    big_scc = Enum.find(sccs, &(length(&1) == 3))
    assert big_scc != nil
    assert MapSet.new(big_scc) == MapSet.new([:a, :b, :c])
  end

  test "condensation" do
    g =
      Grafi.new()
      |> Grafi.add_edges([{:a, :b}, {:b, :a}, {:b, :c}])

    cg = Grafi.condensation(g)
    # The cycle {:a, :b} should be contracted
    assert Grafi.Graph.num_vertices(cg) == 2
  end

  test "Bellman-Ford" do
    g =
      Grafi.new()
      |> Grafi.add_edges([
        {:a, :b, weight: 1.0},
        {:b, :c, weight: -2.0},
        {:a, :c, weight: 5.0}
      ])

    assert {:ok, dists} = Grafi.Algo.ShortestPath.bellman_ford(g, :a)
    assert dists[:c] == -1.0
  end

  test "A* search", %{g: g} do
    # Simple heuristic: always 0 (reduces to Dijkstra)
    assert {:ok, {path, _}} = Grafi.a_star(g, :a, :d, fn _ -> 0 end)
    assert hd(path) == :a
    assert List.last(path) == :d
  end
end
