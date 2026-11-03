defmodule Grafi.Algo.ShortestPathTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  doctest Grafi.Algo.ShortestPath

  alias Grafi.Algo.ShortestPath
  alias Grafi.Graph
  alias Grafi.Test.Generators

  # ── Helpers ───────────────────────────────────────────────────────────

  # Rebuilds `g` with small positive integer weights, so that sums are exact
  # and equal-length paths are common.
  defp with_positive_weights(g) do
    base = Graph.new(type: g.type) |> Graph.add_vertices(Graph.vertices(g))

    Enum.reduce(Graph.edges(g), base, fn e, acc ->
      w = 1.0 + :erlang.phash2({e.from, e.to, e.label}, 9)
      Graph.add_edge(acc, e.from, e.to, weight: w, label: e.label)
    end)
  end

  defp path_weight(_g, [_only]), do: 0.0

  defp path_weight(g, [u, v | rest]) do
    w = g |> Graph.edges_between(u, v) |> Enum.map(& &1.weight) |> Enum.min()
    w + path_weight(g, [v | rest])
  end

  # A directed path 0 → 1 → … → n-1.
  defp path_graph(n) do
    Enum.reduce(1..(n - 1)//1, Graph.new() |> Graph.add_vertex(0), fn i, g ->
      Graph.add_edge(g, i - 1, i, weight: 1.0)
    end)
  end

  # Reductions spent by `fun` in this process: deterministic, unlike wall
  # clock, so a scaling ratio can be asserted tightly.
  defp reductions(fun) do
    {:reductions, before} = Process.info(self(), :reductions)
    fun.()
    {:reductions, after_call} = Process.info(self(), :reductions)
    after_call - before
  end

  defp best_time(fun) do
    :erlang.garbage_collect()
    Enum.min(for _ <- 1..3, do: elem(:timer.tc(fun), 0))
  end

  # Runs `fun` in a task and fails, instead of hanging, if it takes longer
  # than `ms`.
  defp within(ms, fun) do
    task = Task.async(fun)
    assert {:ok, result} = Task.yield(task, ms) || Task.shutdown(task, :brutal_kill)
    result
  end

  # Edges `:s → 1.0 (1)`, `:s → 1 (5)` and `1.0 → 1 (1)`: `1` and `1.0` are
  # distinct vertices, and the shortest path to `1` goes through `1.0`.
  defp int_float_graph do
    Graph.new()
    |> Graph.add_edges([{:s, 1.0, weight: 1.0}, {:s, 1, weight: 5.0}, {1.0, 1, weight: 1.0}])
  end

  # ── dijkstra/4 ────────────────────────────────────────────────────────

  describe "dijkstra/4" do
    test "unreachable target: {:error, :no_path} (Elixir engine)" do
      g = Graph.new() |> Graph.add_edge(:a, :b) |> Graph.add_vertex(:c)
      assert ShortestPath.dijkstra(g, :a, :c, engine: :elixir) == {:error, :no_path}
      assert ShortestPath.dijkstra(g, :b, :a, engine: :elixir) == {:error, :no_path}
    end

    @tag :nif
    test "unreachable target: {:error, :no_path} (NIF engine)" do
      g = Graph.new() |> Graph.add_edge(:a, :b) |> Graph.add_vertex(:c)
      assert ShortestPath.dijkstra(g, :a, :c, engine: :nif) == {:error, :no_path}
    end

    test "missing endpoints: {:error, :no_such_vertex}" do
      g = Graph.new() |> Graph.add_edge(:a, :b)
      assert ShortestPath.dijkstra(g, :ghost, :b) == {:error, :no_such_vertex}
      assert ShortestPath.dijkstra(g, :a, :ghost) == {:error, :no_such_vertex}
    end

    test "unknown options raise ArgumentError" do
      g = Graph.new() |> Graph.add_edge(:a, :b)

      assert_raise ArgumentError, ~r/unknown keys \[:engin\]/, fn ->
        ShortestPath.dijkstra(g, :a, :b, engin: :elixir)
      end
    end

    test "undirected edges are relaxed in both directions" do
      g =
        Graph.new(type: :undirected)
        |> Graph.add_edges([{:a, :b, weight: 1.0}, {:b, :c, weight: 1.0}, {:a, :c, weight: 5.0}])

      assert ShortestPath.dijkstra(g, :c, :a, engine: :elixir) == {:ok, {[:c, :b, :a], 2.0}}
      assert ShortestPath.dijkstra(g, :a, :c, engine: :elixir) == {:ok, {[:a, :b, :c], 2.0}}
    end

    test "vertex ids compare strictly: 1 and 1.0 are distinct" do
      g = int_float_graph()
      assert ShortestPath.dijkstra(g, :s, 1, engine: :elixir) == {:ok, {[:s, 1.0, 1], 2.0}}
      assert ShortestPath.dijkstra(g, :s, 1.0, engine: :elixir) == {:ok, {[:s, 1.0], 1.0}}
    end

    property "Elixir engine agrees with dijkstra_all/2 and Bellman-Ford on every pair" do
      check all(g <- Generators.graph(weights: false, max_vertices: 8), max_runs: 50) do
        g = with_positive_weights(g)

        for s <- Graph.vertices(g) do
          dists = ShortestPath.dijkstra_all(g, s)
          assert ShortestPath.bellman_ford(g, s) == {:ok, dists}

          for t <- Graph.vertices(g) do
            case ShortestPath.dijkstra(g, s, t, engine: :elixir) do
              {:ok, {path, d}} ->
                assert d == Map.fetch!(dists, t)
                assert hd(path) == s and List.last(path) == t
                assert path_weight(g, path) == d

              {:error, :no_path} ->
                refute Map.has_key?(dists, t)
            end
          end
        end
      end
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

    test "a missing source raises ArgumentError" do
      g = Graph.new() |> Graph.add_edge(:a, :b)

      assert_raise ArgumentError, ~r/:ghost is not in the graph/, fn ->
        ShortestPath.dijkstra_all(g, :ghost)
      end
    end

    test "a negative undirected edge raises instead of relaxing forever" do
      g = Graph.new(type: :undirected) |> Graph.add_edge(:a, :b, weight: -1)

      within(5_000, fn ->
        assert_raise ArgumentError, ~r/non-negative edge weights/, fn ->
          ShortestPath.dijkstra_all(g, :a)
        end
      end)
    end

    test "a negative directed 2-cycle raises instead of relaxing forever" do
      g = Graph.new() |> Graph.add_edges([{:a, :b, weight: 1.0}, {:b, :a, weight: -3.0}])

      within(5_000, fn ->
        assert_raise ArgumentError, ~r/non-negative edge weights/, fn ->
          ShortestPath.dijkstra_all(g, :a)
        end
      end)
    end

    test "a weight fn returning a negative cost raises" do
      g = Graph.new() |> Graph.add_edges([{:a, :b, weight: 1.0}, {:b, :c, weight: 1.0}])
      cost = fn %{from: from} -> if from == :b, do: -0.5, else: 1.0 end

      within(5_000, fn ->
        assert_raise ArgumentError, ~r/non-negative edge weights/, fn ->
          ShortestPath.dijkstra_all(g, :a, cost)
        end
      end)
    end

    test "vertex ids compare strictly: 1 and 1.0 are distinct" do
      assert ShortestPath.dijkstra_all(int_float_graph(), :s) == %{:s => 0.0, 1.0 => 1.0, 1 => 2.0}
    end
  end

  # ── a_star/4 ──────────────────────────────────────────────────────────

  describe "a_star/4" do
    test "vertex ids compare strictly: 1 and 1.0 are distinct" do
      assert ShortestPath.a_star(int_float_graph(), :s, 1, fn _ -> 0 end) ==
               {:ok, {[:s, 1.0, 1], 2.0}}
    end

    test "a negative undirected edge still terminates" do
      g = Graph.new(type: :undirected) |> Graph.add_edge(:a, :b, weight: -1) |> Graph.add_vertex(:c)

      assert within(5_000, fn -> ShortestPath.a_star(g, :a, :c, fn _ -> 0 end) end) ==
               {:error, :no_path}
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
      {small, large} = {star.(1_000), star.(4_000)}

      r_small = reductions(fn -> ShortestPath.bellman_ford(small, 0) end)
      r_large = reductions(fn -> ShortestPath.bellman_ford(large, 0) end)

      # Linear: about 4x. Quadratic (|V| - 1 rounds): about 16x.
      assert r_large < 8 * r_small, "4x the input took #{r_large} vs #{r_small} reductions"
    end
  end
end
