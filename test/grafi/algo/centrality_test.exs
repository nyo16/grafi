defmodule Grafi.Algo.CentralityTest do
  use ExUnit.Case, async: true

  alias Grafi.Algo.Centrality
  alias Grafi.Graph

  defp undirected(edges), do: Graph.new(type: :undirected) |> Graph.add_edges(edges)

  defp star(leaves), do: undirected(for l <- 1..leaves, do: {:c, l})

  for engine <- [:nif, :elixir] do
    @opts [engine: engine]

    describe "betweenness/2 fixtures (#{engine} engine)" do
      if engine == :nif, do: @describetag(:nif)

      # Normalized undirected scores divide the per-pair count by
      # (n - 1)(n - 2) / 2, the number of pairs not involving the vertex.

      test "P3: the middle vertex lies on the one a–c path" do
        # raw b = 1 pair; scale 2 / ((3 - 1)(3 - 2)) = 1.
        assert Centrality.betweenness(undirected([{:a, :b}, {:b, :c}]), @opts) ==
                 %{a: 0.0, b: 1.0, c: 0.0}
      end

      test "star with 4 leaves: centre 1.0, leaves 0.0" do
        # raw centre = C(4, 2) = 6 leaf pairs; scale 2 / (4 · 3) = 1/6.
        assert Centrality.betweenness(star(4), @opts) ==
                 %{:c => 1.0, 1 => 0.0, 2 => 0.0, 3 => 0.0, 4 => 0.0}
      end

      test "K4: every pair is adjacent, so all scores are 0.0" do
        k4 = undirected(for i <- 1..3, j <- (i + 1)..4, do: {i, j})
        assert Centrality.betweenness(k4, @opts) == %{1 => 0.0, 2 => 0.0, 3 => 0.0, 4 => 0.0}
      end

      test "directed path a -> b -> c: b is 1.0 raw and 0.5 normalized" do
        g = Graph.new(type: :directed) |> Graph.add_edges([{:a, :b}, {:b, :c}])

        # Directed normalization: 1 / ((n - 1)(n - 2)) = 1/2.
        assert Centrality.betweenness(g, @opts) == %{a: 0.0, b: 0.5, c: 0.0}

        assert Centrality.betweenness(g, [normalized: false] ++ @opts) ==
                 %{a: 0.0, b: 1.0, c: 0.0}
      end

      test "weighted: the heavy direct edge is bypassed through the middle vertex" do
        g = undirected([{:a, :c, weight: 10.0}, {:a, :b, weight: 1.0}, {:b, :c, weight: 1.0}])

        assert Centrality.betweenness(g, @opts) == %{a: 0.0, b: 0.0, c: 0.0}

        assert Centrality.betweenness(g, [weighted: true] ++ @opts) ==
                 %{a: 0.0, b: 1.0, c: 0.0}
      end

      test "weighted: two equal-length routes split the dependency" do
        # a reaches d via b or via c, both of length 2.
        g = undirected([{:a, :b, weight: 1.0}, {:b, :d, weight: 1.0}, {:a, :c}, {:c, :d}])

        # raw b = c = 1/2; scale 2 / ((4 - 1)(4 - 2)) = 1/3.
        result = Centrality.betweenness(g, [weighted: true] ++ @opts)
        assert_in_delta result[:b], 1 / 6, 1.0e-12
        assert_in_delta result[:c], 1 / 6, 1.0e-12
      end
    end

    describe "pagerank/2 (#{engine} engine)" do
      if engine == :nif, do: @describetag(:nif)

      test "a dangling vertex redistributes its rank (NetworkX values for a -> b)" do
        g = Graph.new(type: :directed) |> Graph.add_edge(:a, :b)

        # With b's mass spread evenly: a = 0.075 + 0.425 b and a + b = 1,
        # so a = 0.5 / 1.425.
        ranks = Centrality.pagerank(g, @opts)
        assert_in_delta ranks[:a], 0.5 / 1.425, 1.0e-6
        assert_in_delta ranks[:b], 1 - 0.5 / 1.425, 1.0e-6
      end

      test "edge weights split a vertex's rank proportionally" do
        g =
          Graph.new(type: :directed)
          |> Graph.add_edge(:a, :b, weight: 3.0)
          |> Graph.add_edge(:a, :c, weight: 1.0)

        # Nothing points at a, so a holds only the shared base term; b and c
        # get that base plus 0.85 · a split 3:1.
        ranks = Centrality.pagerank(g, @opts)
        assert_in_delta ranks[:b] - ranks[:a], 0.85 * 0.75 * ranks[:a], 1.0e-6
        assert_in_delta ranks[:c] - ranks[:a], 0.85 * 0.25 * ranks[:a], 1.0e-6
      end

      test "damping: 0.0 gives the uniform distribution" do
        g = Graph.new(type: :directed) |> Graph.add_edges([{:a, :b}, {:b, :c}, {:c, :b}])
        ranks = Centrality.pagerank(g, [damping: 0.0] ++ @opts)

        for v <- [:a, :b, :c], do: assert_in_delta(ranks[v], 1 / 3, 1.0e-9)
      end
    end
  end

  describe "pagerank/2 Elixir-engine options" do
    test "max_iter: 1 returns a single power-iteration step" do
      g = Graph.new(type: :directed) |> Graph.add_edge(:a, :b)

      # From [0.5, 0.5]: base = 0.15/2 + 0.85 · 0.5 (dangling b) / 2 = 0.2875;
      # b additionally receives 0.85 · 0.5 from a.
      ranks = Centrality.pagerank(g, max_iter: 1, engine: :elixir)
      assert_in_delta ranks[:a], 0.2875, 1.0e-12
      assert_in_delta ranks[:b], 0.7125, 1.0e-12
    end

    test "a looser tol stops earlier" do
      g = Graph.new(type: :directed) |> Graph.add_edges([{:a, :b}, {:b, :c}, {:c, :a}, {:a, :c}])

      loose = Centrality.pagerank(g, tol: 0.1, engine: :elixir)
      tight = Centrality.pagerank(g, tol: 1.0e-12, max_iter: 1_000, engine: :elixir)

      assert loose != tight
      for v <- [:a, :b, :c], do: assert_in_delta(loose[v], tight[v], 0.1)
    end

    test ":iterations and :tolerance are no longer accepted" do
      g = Graph.new(type: :directed) |> Graph.add_edge(:a, :b)

      for opt <- [iterations: 10, tolerance: 0.1] do
        assert_raise ArgumentError, ~r/unknown keys/, fn -> Centrality.pagerank(g, [opt]) end
      end
    end
  end

  describe "pagerank/2 Elixir engine on undirected self-loops" do
    test "a self-loop of weight 3 on a triangle counts twice, as in igraph" do
      g = undirected([{:a, :b}, {:b, :c}, {:c, :a}, {:a, :a, weight: 3.0}])

      # Hand power iteration with the loop adding 2 × 3 to a's outgoing
      # weight gives a = 38/63, b = c = 25/126.
      ranks = Centrality.pagerank(g, engine: :elixir, tol: 1.0e-12, max_iter: 1_000)

      for {v, expected} <- [a: 38 / 63, b: 25 / 126, c: 25 / 126],
          do: assert_in_delta(ranks[v], expected, 1.0e-9)
    end
  end

  describe "options" do
    test "every function with options rejects an unknown key" do
      g = Graph.new(type: :directed) |> Graph.add_edges([{:a, :b}, {:b, :c}])

      for fun <- [
            &Centrality.pagerank/2,
            &Centrality.betweenness/2,
            &Centrality.closeness/2,
            &Centrality.hits/2,
            &Centrality.katz/2,
            &Centrality.eigenvector/2,
            &Centrality.harmonic/2
          ] do
        assert_raise ArgumentError, ~r/unknown keys \[:bogus\]/, fn -> fun.(g, bogus: 1) end
      end
    end

    test "iteration knobs are type-checked" do
      g = Graph.new(type: :directed) |> Graph.add_edges([{:a, :b}, {:b, :c}])

      for fun <- [&Centrality.hits/2, &Centrality.katz/2, &Centrality.eigenvector/2] do
        assert_raise ArgumentError, ~r/:max_iter/, fn -> fun.(g, max_iter: 0) end
        assert_raise ArgumentError, ~r/:tol/, fn -> fun.(g, tol: -1.0) end
        # Like pagerank/2, the tolerance must be positive.
        assert_raise ArgumentError, ~r/:tol/, fn -> fun.(g, tol: 0) end
      end

      assert_raise ArgumentError, ~r/:weighted/, fn -> Centrality.harmonic(g, weighted: :yes) end
      assert_raise ArgumentError, ~r/:alpha/, fn -> Centrality.katz(g, alpha: "0.1") end
    end
  end

  describe "negative edge weights" do
    setup do
      %{g: undirected([{:a, :b, weight: -1}, {:b, :c}])}
    end

    # Weighted harmonic runs Dijkstra from every vertex; without a settled
    # set a negative undirected edge re-settled forever, so this hung.
    test "weighted harmonic raises; unweighted harmonic ignores weights", %{g: g} do
      assert {:raised, %ArgumentError{message: message}} =
               run_bounded(fn -> Centrality.harmonic(g, weighted: true) end)

      assert message =~ ~r/non-negative edge weights/
      assert Centrality.harmonic(g)[:b] == 2.0
    end

    # A negative adjacency entry voids Perron–Frobenius: on a single a–b
    # edge of weight -1 the iterate flips sign every round.
    test "weighted eigenvector raises; unweighted eigenvector ignores weights", %{g: g} do
      for opts <- [[], [weighted: true]] do
        assert_raise ArgumentError, ~r/non-negative edge weights/, fn ->
          Centrality.eigenvector(g, opts)
        end
      end

      scores = Centrality.eigenvector(g, weighted: false)
      assert Enum.all?(scores, fn {_v, x} -> x > 0 end)
    end
  end

  describe "vertex ids that compare equal" do
    # 1 and 1.0 are distinct vertices. On the path x – 1.0 – 1 only the
    # pair {x, 1} passes through 1.0; comparing ids with == skipped 1.0's
    # dependency from source 1 and halved its score.
    test "betweenness keeps 1 and 1.0 apart" do
      g = undirected([{:x, 1.0}, {1.0, 1}])
      scores = Centrality.betweenness(g, normalized: false, engine: :elixir)
      assert scores[1.0] == 1.0
      assert scores[1] == 0.0
    end
  end

  describe "weighting defaults (moduledoc table)" do
    # Path a -> b -> c with a heavy shortcut a -> c (weight 5): by hops c is
    # one step from a, by weight it is two.
    setup do
      g = Graph.new() |> Graph.add_edges([{:a, :b}, {:b, :c}, {:a, :c, weight: 5.0}])
      %{g: g}
    end

    test "harmonic ignores weights unless weighted: true", %{g: g} do
      assert Centrality.harmonic(g)[:a] == 2.0
      assert Centrality.harmonic(g, weighted: true)[:a] == 1.5
    end

    test "betweenness ignores weights unless weighted: true", %{g: g} do
      assert Centrality.betweenness(g, normalized: false, engine: :elixir)[:b] == 0.0

      assert Centrality.betweenness(g, weighted: true, normalized: false, engine: :elixir)[:b] ==
               1.0
    end

    test "closeness always uses weights", %{g: g} do
      # From a: b at 1, c at 2 (via b) => 2 / 3.
      assert_in_delta Centrality.closeness(g, engine: :elixir)[:a], 2 / 3, 1.0e-12
    end

    # Power iteration on a DAG decays to zero, so this one is undirected.
    test "eigenvector uses weights when any weight is not 1.0" do
      g = undirected([{:a, :b}, {:b, :c}, {:a, :c, weight: 5.0}])
      assert Centrality.eigenvector(g) == Centrality.eigenvector(g, weighted: true)
      refute Centrality.eigenvector(g) == Centrality.eigenvector(g, weighted: false)

      unit = undirected([{:a, :b}, {:b, :c}, {:a, :c}, {:c, :d}])
      assert Centrality.eigenvector(unit) == Centrality.eigenvector(unit, weighted: false)
    end

    test "hits and katz ignore weights", %{g: g} do
      unit = Graph.new() |> Graph.add_edges([{:a, :b}, {:b, :c}, {:a, :c}])
      assert Centrality.hits(g) == Centrality.hits(unit)
      assert Centrality.katz(g) == Centrality.katz(unit)
    end
  end

  describe "degree_centrality/1" do
    test "star: centre is adjacent to every other vertex" do
      assert Centrality.degree_centrality(star(4)) ==
               %{:c => 1.0, 1 => 0.25, 2 => 0.25, 3 => 0.25, 4 => 0.25}
    end

    test "fewer than two vertices yields %{}" do
      assert Centrality.degree_centrality(Graph.new()) == %{}
      assert Centrality.degree_centrality(Graph.new() |> Graph.add_vertex(:a)) == %{}
    end
  end

  # Runs `fun` in a task and returns `{:ok, result}` or `{:raised, exception}`,
  # failing the test if it takes over `ms` (for calls that used to hang).
  defp run_bounded(fun, ms \\ 5_000) do
    task =
      Task.async(fn ->
        try do
          {:ok, fun.()}
        rescue
          e -> {:raised, e}
        end
      end)

    case Task.yield(task, ms) || Task.shutdown(task, :brutal_kill) do
      {:ok, result} -> result
      _ -> flunk("did not return within #{ms} ms")
    end
  end
end
