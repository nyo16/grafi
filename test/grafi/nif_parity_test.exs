defmodule Grafi.NIFParityTest do
  # Both engines must return the same values (within float tolerance) for
  # every algorithm that has an igraph and an Elixir implementation. Graphs
  # are fixed-seed G(n, p) above the default NIF threshold, plus small
  # fixtures for the edge cases each contract defines.
  use ExUnit.Case, async: true

  @moduletag :nif

  alias Grafi.Algo.{Centrality, Cycles, Isomorphism, ShortestPath}
  alias Grafi.{DAG, Generators, Graph}

  @n 600

  defp er(n, p, seed, opts \\ []), do: Generators.erdos_renyi(n, p, [seed: seed] ++ opts)

  # Copies `g` with small integer weights derived from the endpoints. Integer
  # weights produce many equal-length paths, which exercises tie handling.
  defp with_weights(g) do
    base = Graph.new(type: g.type) |> Graph.add_vertices(Graph.vertices(g))

    Enum.reduce(Graph.edges(g), base, fn e, acc ->
      Graph.add_edge(acc, e.from, e.to, weight: 1.0 + rem(e.from * 31 + e.to * 17, 5))
    end)
  end

  defp assert_close(a, b, tol) do
    assert Map.keys(a) |> Enum.sort() == Map.keys(b) |> Enum.sort()

    for {k, x} <- a do
      y = Map.fetch!(b, k)

      assert abs(x - y) <= tol * max(1.0, abs(x)),
             "#{inspect(k)}: nif #{x} vs elixir #{y} (tolerance #{tol})"
    end
  end

  defp both(fun), do: {fun.(:nif), fun.(:elixir)}

  describe "pagerank" do
    test "weighted undirected graph: engines agree and ranks sum to 1" do
      g = er(@n, 0.01, 1) |> with_weights()

      {nif, elixir} =
        both(&Centrality.pagerank(g, engine: &1, tolerance: 1.0e-12, iterations: 1_000))

      assert_close(nif, elixir, 1.0e-6)
      assert abs(Enum.sum(Map.values(nif)) - 1.0) < 1.0e-9
      assert abs(Enum.sum(Map.values(elixir)) - 1.0) < 1.0e-9
    end

    test "directed graph with dangling vertices: engines agree and ranks sum to 1" do
      g = er(@n, 0.003, 2, directed: true)
      assert Enum.any?(Graph.vertices(g), &(Graph.out_degree(g, &1) == 0))

      {nif, elixir} =
        both(&Centrality.pagerank(g, engine: &1, tolerance: 1.0e-12, iterations: 1_000))

      assert_close(nif, elixir, 1.0e-6)
      assert abs(Enum.sum(Map.values(nif)) - 1.0) < 1.0e-9
      assert abs(Enum.sum(Map.values(elixir)) - 1.0) < 1.0e-9
    end
  end

  describe "betweenness" do
    setup do
      %{g: er(@n, 0.01, 3) |> with_weights()}
    end

    for weighted <- [false, true], normalized <- [false, true] do
      @opts [weighted: weighted, normalized: normalized]

      test "undirected, weighted: #{weighted}, normalized: #{normalized}", %{g: g} do
        {nif, elixir} = both(&Centrality.betweenness(g, [engine: &1] ++ @opts))
        assert_close(nif, elixir, 1.0e-9)
      end
    end

    test "directed, unweighted, normalized" do
      g = er(@n, 0.005, 4, directed: true)
      {nif, elixir} = both(&Centrality.betweenness(g, engine: &1))
      assert_close(nif, elixir, 1.0e-9)
    end
  end

  describe "closeness" do
    test "sink and isolated vertices score 0.0 on both engines" do
      g =
        Graph.new(type: :directed)
        |> Graph.add_edges([{:a, :b}, {:b, :c}])
        |> Graph.add_vertex(:z)

      # a reaches b (1) and c (2): (2 reachable) / (1 + 2) = 2/3.
      expected = %{a: 2 / 3, b: 1.0, c: 0.0, z: 0.0}
      assert both(&Centrality.closeness(g, engine: &1)) == {expected, expected}
    end

    test "weighted directed graph: engines agree" do
      g = er(@n, 0.005, 5, directed: true) |> with_weights()
      {nif, elixir} = both(&Centrality.closeness(g, engine: &1))
      assert_close(nif, elixir, 1.0e-12)
    end
  end

  describe "dijkstra" do
    test "parallel edges: both engines take the lighter edge" do
      g =
        Graph.new(type: :directed)
        |> Graph.add_edge(:a, :b, weight: 5.0)
        |> Graph.add_edge(:a, :b, weight: 1.0)

      assert both(&ShortestPath.dijkstra(g, :a, :b, engine: &1)) ==
               {{:ok, {[:a, :b], 1.0}}, {:ok, {[:a, :b], 1.0}}}
    end

    test "weighted undirected graph: distances agree for every reachable pair sampled" do
      g = er(@n, 0.01, 6) |> with_weights()

      for s <- [0, 17, 211], t <- [5, 99, 433, 599] do
        case both(&ShortestPath.dijkstra(g, s, t, engine: &1)) do
          {{:ok, {_, d_nif}}, {:ok, {_, d_elixir}}} -> assert_in_delta d_nif, d_elixir, 1.0e-9
          {nif, elixir} -> assert nif == elixir
        end
      end
    end
  end

  describe "strongly connected components" do
    test "canonical output is identical" do
      g = er(@n, 0.003, 7, directed: true)
      {nif, elixir} = both(&Cycles.strongly_connected_components(g, engine: &1))
      assert nif == elixir
      assert Enum.sort(List.flatten(nif)) == Enum.sort(Graph.vertices(g))
    end

    test "exact canonical order: sorted members, components by smallest vertex" do
      g =
        Graph.new(type: :directed)
        |> Graph.add_edges([{:c, :d}, {:d, :c}, {:a, :b}, {:b, :a}, {:b, :c}])

      assert both(&Cycles.strongly_connected_components(g, engine: &1)) ==
               {[[:a, :b], [:c, :d]], [[:a, :b], [:c, :d]]}
    end
  end

  describe "topological sort" do
    test "the deterministic Kahn order is identical" do
      g = er(@n, 0.01, 8, directed: true)
      base = Graph.new(type: :directed) |> Graph.add_vertices(Graph.vertices(g))

      dag =
        Enum.reduce(Graph.edges(g), base, fn e, acc ->
          if e.from < e.to, do: Graph.add_edge(acc, e.from, e.to), else: acc
        end)

      {:ok, dag} = DAG.from_graph(dag)
      {{:ok, nif}, {:ok, elixir}} = both(&DAG.topological_sort(dag, engine: &1))
      assert nif == elixir

      index = nif |> Enum.with_index() |> Map.new()
      assert Enum.all?(Graph.edges(DAG.to_graph(dag)), &(index[&1.from] < index[&1.to]))
    end

    test "exact Kahn order on a diamond with a parallel edge" do
      g =
        Graph.new(type: :directed)
        |> Graph.add_edges([{:a, :b}, {:a, :c}, {:b, :d}, {:c, :d}, {:c, :d}])

      {:ok, dag} = DAG.from_graph(g)

      assert both(&DAG.topological_sort(dag, engine: &1)) ==
               {{:ok, [:a, :b, :c, :d]}, {:ok, [:a, :b, :c, :d]}}
    end
  end

  describe "isomorphism on undirected graphs" do
    # Undirected CSR lists each edge once (N3.1); a doubled edge list would
    # make igraph match a multigraph instead of the graph itself.
    test "a relabelled random graph is isomorphic to the original on both engines" do
      g = er(30, 0.15, 9)
      relabel = Map.new(Graph.vertices(g), &{&1, "v#{29 - &1}"})

      h =
        Enum.reduce(
          Graph.edges(g),
          Graph.new(type: :undirected) |> Graph.add_vertices(Map.values(relabel)),
          fn e, acc -> Graph.add_edge(acc, relabel[e.from], relabel[e.to]) end
        )

      assert both(&Isomorphism.isomorphic?(g, h, engine: &1, timeout: 5_000)) == {true, true}

      assert {:ok, mapping} = Isomorphism.isomorphism(g, h, engine: :nif)
      assert Enum.all?(Graph.edges(g), &Graph.has_edge?(h, mapping[&1.from], mapping[&1.to]))
    end

    test "sub-isomorphism counts agree" do
      host = er(12, 0.5, 10)
      pattern = Graph.new(type: :undirected) |> Graph.add_edges([{1, 2}, {2, 3}, {3, 1}])

      {nif, elixir} =
        both(&Isomorphism.count_subgraph_isomorphisms(host, pattern, engine: &1))

      assert nif == elixir
      assert nif > 0
    end
  end

  # Convention C001: `to_csr/1` stores undirected edges twice and self-loops
  # as adjacent pairs, so a wrong halving corrupts igraph weights while every
  # simple-graph parity test still passes. Two loops of different weights on
  # one vertex catch a halving that keeps one loop twice.
  #
  # PageRank is the loop-sensitive check; closeness, weighted betweenness
  # and Dijkstra guard the parallel-edge rows. SCC ignores weights and only
  # detects lost connectivity, so its row adds a bridge made of parallel
  # edges. Not applicable here: topological sort (directed only), community
  # detection (no Elixir engine) and isomorphism (documented multigraph
  # caveat in `Grafi.Algo.Isomorphism` "Caveats").
  describe "undirected multigraph with self-loops (C001)" do
    setup do
      g =
        Graph.new(type: :undirected)
        |> Graph.add_edges([
          {:a, :b, weight: 1.0},
          {:a, :b, weight: 5.0},
          {:b, :b, weight: 2.0},
          {:b, :b, weight: 4.0},
          {:b, :c, weight: 3.0},
          {:c, :d, weight: 1.0},
          {:d, :a, weight: 2.0}
        ])

      %{g: g}
    end

    test "pagerank agrees", %{g: g} do
      {nif, elixir} =
        both(&Centrality.pagerank(g, engine: &1, tolerance: 1.0e-12, iterations: 1_000))

      assert_close(nif, elixir, 1.0e-9)
    end

    test "closeness agrees", %{g: g} do
      {nif, elixir} = both(&Centrality.closeness(g, engine: &1))
      assert_close(nif, elixir, 1.0e-12)
    end

    # Unweighted betweenness is excluded: igraph counts the parallel a–b
    # edges as distinct shortest paths (documented in `betweenness/2`).
    test "weighted betweenness agrees", %{g: g} do
      {nif, elixir} = both(&Centrality.betweenness(g, engine: &1, weighted: true))
      assert_close(nif, elixir, 1.0e-12)
    end

    test "dijkstra agrees", %{g: g} do
      # a–b has parallel edges of weight 1.0 and 5.0; the lighter one wins.
      assert both(&ShortestPath.dijkstra(g, :a, :b, engine: &1)) ==
               {{:ok, {[:a, :b], 1.0}}, {:ok, {[:a, :b], 1.0}}}

      assert both(&ShortestPath.dijkstra(g, :a, :d, engine: &1)) ==
               {{:ok, {[:a, :d], 2.0}}, {:ok, {[:a, :d], 2.0}}}
    end

    # d–e is a bridge of two parallel edges: a halving that drops both
    # copies splits off :e.
    test "scc agrees", %{g: g} do
      g = Graph.add_edges(g, [{:d, :e, weight: 1.0}, {:d, :e, weight: 2.0}, {:e, :e, weight: 3.0}])

      assert both(&Cycles.strongly_connected_components(g, engine: &1)) ==
               {[[:a, :b, :c, :d, :e]], [[:a, :b, :c, :d, :e]]}
    end

    test "igraph's pagerank on a triangle with a self-loop of weight 3 counts the loop twice" do
      g =
        Graph.new(type: :undirected)
        |> Graph.add_edges([{:a, :b}, {:b, :c}, {:c, :a}, {:a, :a, weight: 3.0}])

      # Hand power iteration with the loop adding 2 × 3 to a's outgoing
      # weight gives a = 38/63, b = c = 25/126. The Elixir half lives in
      # `Grafi.Algo.CentralityTest`.
      expected = %{a: 38 / 63, b: 25 / 126, c: 25 / 126}
      nif = Centrality.pagerank(g, engine: :nif, tolerance: 1.0e-12, iterations: 1_000)

      assert_close(nif, expected, 1.0e-9)
    end
  end
end
