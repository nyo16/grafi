defmodule Grafi.AlgoTest do
  use ExUnit.Case, async: true
  doctest Grafi

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

  # ── Stream D batch 6: extra centralities ────────────────────────────

  describe "extra centralities (HITS, Katz, eigenvector, harmonic)" do
    alias Grafi.Algo.Centrality

    defp star_undirected(n_leaves) do
      leaves = for i <- 1..n_leaves, do: {:leaf, i}

      Enum.reduce(leaves, Grafi.new(type: :undirected) |> Grafi.add_vertex(:center), fn l, g ->
        Grafi.add_edge(g, :center, l)
      end)
    end

    defp k4_undirected do
      vs = [:a, :b, :c, :d]

      pairs =
        for u <- vs, v <- vs, u < v, do: {u, v}

      Grafi.new(type: :undirected) |> Grafi.add_edges(pairs)
    end

    test "HITS: empty graph returns empty maps" do
      assert Centrality.hits(Grafi.new()) == %{hubs: %{}, authorities: %{}}
    end

    test "HITS: single vertex puts all mass on itself" do
      g = Grafi.new() |> Grafi.add_vertex(:lonely)
      result = Centrality.hits(g)
      assert Map.keys(result.hubs) == [:lonely]
      assert Map.keys(result.authorities) == [:lonely]
    end

    test "HITS: K_4 is symmetric (every vertex scores equally)" do
      g = k4_undirected()
      %{hubs: h, authorities: a} = Centrality.hits(g)
      hub_vals = Map.values(h)
      auth_vals = Map.values(a)
      hub_max = Enum.max(hub_vals)
      hub_min = Enum.min(hub_vals)
      auth_max = Enum.max(auth_vals)
      auth_min = Enum.min(auth_vals)
      assert_in_delta hub_max - hub_min, 0.0, 1.0e-6
      assert_in_delta auth_max - auth_min, 0.0, 1.0e-6
    end

    test "HITS: star K_{1,5} — center dominates" do
      g = star_undirected(5)
      %{hubs: h, authorities: a} = Centrality.hits(g)
      leaf = {:leaf, 1}
      assert h[:center] >= h[leaf]
      assert a[:center] >= a[leaf]
    end

    test "Katz: two isolated vertices each get beta" do
      g = Grafi.new() |> Grafi.add_vertices([:x, :y])
      scores = Centrality.katz(g, beta: 1.0, alpha: 0.1)
      assert scores[:x] == 1.0
      assert scores[:y] == 1.0
    end

    test "Katz: K_4 symmetric" do
      g = k4_undirected()
      scores = Centrality.katz(g, alpha: 0.1)
      vals = Map.values(scores)
      assert_in_delta Enum.max(vals) - Enum.min(vals), 0.0, 1.0e-6
    end

    test "Katz: empty graph yields empty map" do
      assert Centrality.katz(Grafi.new()) == %{}
    end

    test "eigenvector: K_4 symmetric" do
      g = k4_undirected()
      scores = Centrality.eigenvector(g)
      vals = Map.values(scores)
      assert_in_delta Enum.max(vals) - Enum.min(vals), 0.0, 1.0e-6
      # L2-normalized: sum of squares == 1
      sum_sq = Enum.reduce(vals, 0.0, fn v, acc -> acc + v * v end)
      assert_in_delta sum_sq, 1.0, 1.0e-6
    end

    test "eigenvector: star — center scores highest" do
      g = star_undirected(5)
      scores = Centrality.eigenvector(g)
      leaf_scores = for {{:leaf, _}, s} <- scores, do: s
      assert scores[:center] >= Enum.max(leaf_scores)
    end

    test "eigenvector: empty graph yields empty map" do
      assert Centrality.eigenvector(Grafi.new()) == %{}
    end

    test "harmonic: path P_3 — middle gets 2.0, ends get 1.5" do
      g =
        Grafi.new(type: :undirected)
        |> Grafi.add_edges([{:a, :b}, {:b, :c}])

      scores = Centrality.harmonic(g)
      assert_in_delta scores[:b], 2.0, 1.0e-9
      assert_in_delta scores[:a], 1.5, 1.0e-9
      assert_in_delta scores[:c], 1.5, 1.0e-9
    end

    test "harmonic: empty graph and single vertex" do
      assert Centrality.harmonic(Grafi.new()) == %{}
      g = Grafi.new() |> Grafi.add_vertex(:lonely)
      assert Centrality.harmonic(g) == %{lonely: 0.0}
    end

    test "harmonic: two isolated vertices score 0" do
      g = Grafi.new() |> Grafi.add_vertices([:x, :y])
      scores = Centrality.harmonic(g)
      assert scores[:x] == 0.0
      assert scores[:y] == 0.0
    end

    test "harmonic: weighted opt uses Dijkstra distances" do
      g =
        Grafi.new(type: :undirected)
        |> Grafi.add_edges([{:a, :b, weight: 2.0}, {:b, :c, weight: 2.0}])

      scores = Centrality.harmonic(g, weighted: true)
      # From :b → :a is 2.0, :b → :c is 2.0; harmonic = 1/2 + 1/2 = 1.0
      assert_in_delta scores[:b], 1.0, 1.0e-9
    end
  end
end
