defmodule Grafi.Algo.ShortestPathTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  doctest Grafi.Algo.ShortestPath

  alias Grafi.Algo.ShortestPath
  alias Grafi.Graph
  alias Grafi.Test.Generators

  # ── Helpers ───────────────────────────────────────────────────────────

  # A directed path 0 → 1 → … → n-1.
  defp path_graph(n) do
    Enum.reduce(1..(n - 1)//1, Graph.new() |> Graph.add_vertex(0), fn i, g ->
      Graph.add_edge(g, i - 1, i, weight: 1.0)
    end)
  end

  defp best_time(fun) do
    :erlang.garbage_collect()
    Enum.min(for _ <- 1..3, do: elem(:timer.tc(fun), 0))
  end

  # ── dijkstra/4 ────────────────────────────────────────────────────────

  describe "dijkstra/4" do
    test "undirected edges are relaxed in both directions" do
      g =
        Graph.new(type: :undirected)
        |> Graph.add_edges([{:a, :b, weight: 1.0}, {:b, :c, weight: 1.0}, {:a, :c, weight: 5.0}])

      assert ShortestPath.dijkstra(g, :c, :a, engine: :elixir) == {:ok, {[:c, :b, :a], 2.0}}
      assert ShortestPath.dijkstra(g, :a, :c, engine: :elixir) == {:ok, {[:a, :b, :c], 2.0}}
    end

    # A near target costs only what is closer than it; the base engine
    # settled the whole graph whatever the target.
    @tag :slow
    test "the Elixir engine stops once the target is settled" do
      n = 20_000
      g = path_graph(n)

      t_near = best_time(fn -> ShortestPath.dijkstra(g, 0, 1, engine: :elixir) end)
      t_far = best_time(fn -> ShortestPath.dijkstra(g, 0, n - 1, engine: :elixir) end)

      assert 3 * t_near < t_far, "near target #{t_near} µs vs far target #{t_far} µs"
    end
  end

  # ── dijkstra_all/3 ────────────────────────────────────────────────────

  describe "dijkstra_all/3" do
    test "costs each edge with the weight fn; the cheapest parallel edge wins" do
      g =
        Graph.new()
        |> Graph.add_edge(:a, :b, weight: 1.0, label: :road)
        |> Graph.add_edge(:a, :b, weight: 9.0, label: :rail)
        |> Graph.add_edge(:b, :c, weight: 1.0, label: :road)

      fare = fn
        %{label: :rail} -> 0.5
        %{weight: w} -> w * 10
      end

      assert ShortestPath.dijkstra_all(g, :a, fare) == %{a: 0.0, b: 0.5, c: 10.5}
      assert ShortestPath.dijkstra_all(g, :a) == %{a: 0.0, b: 1.0, c: 2.0}
    end

    test "undirected edges reach back to the source side" do
      g = Graph.new(type: :undirected) |> Graph.add_edge(:a, :b, weight: 2.0)
      assert ShortestPath.dijkstra_all(g, :b, & &1.weight) == %{a: 2.0, b: 0.0}
    end
  end

  # ── bellman_ford/2 ────────────────────────────────────────────────────

  describe "bellman_ford/2" do
    test "missing source: {:error, :no_such_vertex}" do
      g = Graph.new() |> Graph.add_edge(:a, :b)
      assert ShortestPath.bellman_ford(g, :ghost) == {:error, :no_such_vertex}
    end

    test "a long chain of negative edges still converges" do
      # The chain runs 9 → 8 → … → 0. Arcs are relaxed in vertex order
      # (1 → 0 first), so each round settles just one more vertex.
      g = Enum.reduce(9..1//-1, Graph.new(), &Graph.add_edge(&2, &1, &1 - 1, weight: -1.0))

      assert {:ok, dists} = ShortestPath.bellman_ford(g, 9)
      assert dists == Map.new(0..9, &{&1, &1 - 9.0})
    end

    test "a negative cycle needing every round is still detected" do
      g =
        Enum.reduce(5..1//-1, Graph.new(), fn i, acc -> Graph.add_edge(acc, i - 1, i) end)
        |> Graph.add_edge(5, 0, weight: -6.0)

      assert ShortestPath.bellman_ford(g, 0) == {:error, :negative_cycle}
    end

    property "agrees with Floyd-Warshall on DAGs with negative weights" do
      check all(g <- Generators.graph(type: :directed, id_type: :integer, weights: false)) do
        # Keep only forward edges u < v (so no cycle, hence no negative
        # cycle), with integer weights in -5..5 so that sums are exact.
        dag =
          g
          |> Graph.edges()
          |> Enum.filter(&(&1.from < &1.to))
          |> Enum.reduce(Graph.new() |> Graph.add_vertices(Graph.vertices(g)), fn e, acc ->
            w = :erlang.phash2({e.from, e.to, e.label}, 11) - 5.0
            Graph.add_edge(acc, e.from, e.to, weight: w)
          end)

        {:ok, fw} = Grafi.Algo.APSP.floyd_warshall(dag)

        for s <- Graph.vertices(dag) do
          assert ShortestPath.bellman_ford(dag, s) == {:ok, fw[s]}
        end
      end
    end

    # A star from the source settles in one round, so the early exit makes
    # the run linear; the base code ran |V| - 1 rounds, quadratic here.
    @tag :slow
    test "stops after the first round that changes nothing" do
      star = fn n -> Enum.reduce(1..n, Graph.new(), &Graph.add_edge(&2, 0, &1)) end
      {small, large} = {star.(500), star.(2_000)}

      t_small = best_time(fn -> ShortestPath.bellman_ford(small, 0) end)
      t_large = best_time(fn -> ShortestPath.bellman_ford(large, 0) end)

      assert t_large < 8 * max(t_small, 1_000),
             "4x the input took #{t_large} µs vs #{t_small} µs"
    end
  end
end
