defmodule Grafi.GraphTest do
  use ExUnit.Case, async: true
  alias Grafi.Graph

  describe "construction" do
    test "new/0 creates empty directed graph" do
      g = Graph.new()
      assert g.type == :directed
      assert Graph.num_vertices(g) == 0
      assert Graph.num_edges(g) == 0
    end

    test "new/1 with :undirected" do
      g = Graph.new(type: :undirected)
      assert g.type == :undirected
    end
  end

  describe "vertices" do
    test "add and query vertices" do
      g = Graph.new() |> Graph.add_vertices([:a, :b, :c])
      assert Graph.num_vertices(g) == 3
      assert Graph.has_vertex?(g, :a)
      refute Graph.has_vertex?(g, :z)
    end

    test "add vertex with label" do
      g = Graph.new() |> Graph.add_vertex(:a, label: "Athens")
      assert Graph.label(g, :a) == "Athens"
    end

    test "delete vertex removes incident edges" do
      g = Graph.new()
        |> Graph.add_edges([{:a, :b}, {:b, :c}, {:c, :a}])
        |> Graph.delete_vertex(:b)

      assert Graph.num_vertices(g) == 2
      refute Graph.has_edge?(g, :a, :b)
      refute Graph.has_edge?(g, :b, :c)
    end

    test "duplicate add is a no-op" do
      g = Graph.new() |> Graph.add_vertex(:a) |> Graph.add_vertex(:a)
      assert Graph.num_vertices(g) == 1
    end
  end

  describe "edges" do
    test "add edge auto-creates vertices" do
      g = Graph.new() |> Graph.add_edge(:x, :y)
      assert Graph.has_vertex?(g, :x)
      assert Graph.has_vertex?(g, :y)
      assert Graph.has_edge?(g, :x, :y)
      assert Graph.num_edges(g) == 1
    end

    test "weighted edges" do
      g = Graph.new() |> Graph.add_edge(:a, :b, weight: 3.5)
      [edge] = Graph.edges_between(g, :a, :b)
      assert edge.weight == 3.5
    end

    test "undirected edges are bidirectional" do
      g = Graph.new(type: :undirected) |> Graph.add_edge(:a, :b)
      assert Graph.has_edge?(g, :a, :b)
      assert Graph.has_edge?(g, :b, :a)
      assert Graph.num_edges(g) == 1  # counted once
    end

    test "delete edge" do
      g = Graph.new() |> Graph.add_edge(:a, :b) |> Graph.delete_edge(:a, :b)
      refute Graph.has_edge?(g, :a, :b)
      assert Graph.num_edges(g) == 0
    end

    test "batch add_edges" do
      g = Graph.new()
        |> Graph.add_edges([{:a, :b}, {:b, :c}, {:c, :d, weight: 2.0}])
      assert Graph.num_edges(g) == 3
      assert Graph.num_vertices(g) == 4
    end
  end

  describe "queries" do
    setup do
      g = Graph.new()
        |> Graph.add_edges([{:a, :b}, {:a, :c}, {:b, :d}, {:c, :d}])
      %{g: g}
    end

    test "out_neighbors", %{g: g} do
      assert Enum.sort(Graph.out_neighbors(g, :a)) == [:b, :c]
    end

    test "in_neighbors", %{g: g} do
      assert Enum.sort(Graph.in_neighbors(g, :d)) == [:b, :c]
    end

    test "degree", %{g: g} do
      assert Graph.out_degree(g, :a) == 2
      assert Graph.in_degree(g, :d) == 2
    end

    test "subgraph", %{g: g} do
      sg = Graph.subgraph(g, [:a, :b])
      assert Graph.num_vertices(sg) == 2
      assert Graph.has_edge?(sg, :a, :b)
      refute Graph.has_edge?(sg, :b, :d)
    end

    test "transpose", %{g: g} do
      t = Graph.transpose(g)
      assert Graph.has_edge?(t, :b, :a)
      refute Graph.has_edge?(t, :a, :b)
    end
  end

  describe "CSR conversion" do
    test "to_csr produces valid format" do
      g = Graph.new() |> Graph.add_edges([{:a, :b, weight: 1.0}, {:b, :c, weight: 2.0}])
      {idx, csr} = Graph.to_csr(g)

      assert map_size(idx) == 3
      assert length(csr.row_offsets) == 4  # n_vertices + 1
      assert length(csr.col_indices) == 2
      assert length(csr.weights) == 2
      assert csr.n_vertices == 3
      assert csr.directed == true
    end
  end

  describe "Enumerable protocol" do
    test "Enum.count works" do
      g = Graph.new() |> Graph.add_vertices([:a, :b, :c])
      assert Enum.count(g) == 3
    end

    test "Enum.member? works" do
      g = Graph.new() |> Graph.add_vertex(:x)
      assert Enum.member?(g, :x)
    end
  end
end

defmodule Grafi.DAGTest do
  use ExUnit.Case, async: true
  alias Grafi.DAG

  test "topological sort" do
    dag = DAG.new()
      |> DAG.add_edge(:a, :b)
      |> DAG.add_edge(:b, :c)
      |> DAG.add_edge(:a, :c)

    assert {:ok, sorted} = DAG.topological_sort(dag)
    assert hd(sorted) == :a
    assert List.last(sorted) == :c
  end

  test "cycle prevention" do
    dag = DAG.new() |> DAG.add_edge(:a, :b)

    assert_raise Grafi.CycleError, fn ->
      DAG.add_edge(dag, :b, :a)
    end
  end

  test "self-loop prevention" do
    assert_raise Grafi.CycleError, fn ->
      DAG.new() |> DAG.add_edge(:a, :a)
    end
  end

  test "layers" do
    dag = DAG.new()
      |> DAG.add_edges([{:a, :c}, {:b, :c}, {:c, :d}])

    layers = DAG.layers(dag)
    assert :a in layers[0]
    assert :b in layers[0]
    assert layers[1] == [:c]
    assert layers[2] == [:d]
  end

  test "sources and sinks" do
    dag = DAG.new()
      |> DAG.add_edges([{:a, :b}, {:b, :c}])

    assert DAG.sources(dag) == [:a]
    assert DAG.sinks(dag) == [:c]
  end

  test "critical path" do
    dag = DAG.new()
      |> DAG.add_edges([
        {:a, :b, weight: 3.0},
        {:a, :c, weight: 1.0},
        {:b, :d, weight: 2.0},
        {:c, :d, weight: 10.0}
      ])

    {path, cost} = DAG.critical_path(dag)
    assert path == [:a, :c, :d]
    assert cost == 11.0
  end
end

defmodule Grafi.AlgoTest do
  use ExUnit.Case, async: true

  setup do
    g = Grafi.new()
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
    g = Grafi.new()
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
    g = Grafi.new()
      |> Grafi.add_edges([{:a, :b}, {:b, :c}, {:c, :a}, {:d, :c}])

    sccs = Grafi.scc(g)
    big_scc = Enum.find(sccs, &(length(&1) == 3))
    assert big_scc != nil
    assert MapSet.new(big_scc) == MapSet.new([:a, :b, :c])
  end

  test "condensation" do
    g = Grafi.new()
      |> Grafi.add_edges([{:a, :b}, {:b, :a}, {:b, :c}])

    cg = Grafi.condensation(g)
    # The cycle {:a, :b} should be contracted
    assert Grafi.Graph.num_vertices(cg) == 2
  end

  test "Bellman-Ford" do
    g = Grafi.new()
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

defmodule Grafi.SerializeTest do
  use ExUnit.Case, async: true

  test "DOT export" do
    g = Grafi.new()
      |> Grafi.add_edges([{:a, :b}, {:b, :c}])

    dot = Grafi.to_dot(g)
    assert dot =~ "digraph"
    assert dot =~ "a -> b"
  end

  test "DOT undirected" do
    g = Grafi.new(type: :undirected)
      |> Grafi.add_edge(:x, :y)

    dot = Grafi.to_dot(g)
    assert dot =~ "graph"
    assert dot =~ "--"
  end
end
