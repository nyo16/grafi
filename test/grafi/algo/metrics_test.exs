defmodule Grafi.Algo.MetricsTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias Grafi.Algo.Metrics
  alias Grafi.Generators
  alias Grafi.Graph

  doctest Grafi.Algo.Metrics

  describe "triangle counts" do
    test "triangle on three vertices: one triangle" do
      g = Graph.new(type: :undirected) |> Graph.add_edges([{:a, :b}, {:b, :c}, {:c, :a}])
      assert Metrics.triangle_count(g) == 1
      assert Metrics.triangles_per_vertex(g) == %{a: 1, b: 1, c: 1}
    end

    test "path graph has no triangles" do
      g = Graph.new(type: :undirected) |> Graph.add_edges([{:a, :b}, {:b, :c}, {:c, :d}])
      assert Metrics.triangle_count(g) == 0
      assert Map.values(Metrics.triangles_per_vertex(g)) |> Enum.sum() == 0
    end

    test "K4 contains four triangles" do
      g = Generators.complete(4, type: :undirected)
      assert Metrics.triangle_count(g) == 4
    end

    test "empty graph yields zero" do
      assert Metrics.triangle_count(Graph.new()) == 0
      assert Metrics.triangles_per_vertex(Graph.new()) == %{}
    end
  end

  describe "clustering coefficient" do
    test "triangle: local coefficient is 1.0 for every vertex" do
      g = Graph.new(type: :undirected) |> Graph.add_edges([{:a, :b}, {:b, :c}, {:c, :a}])
      assert Metrics.clustering_coefficient(g, :a) == 1.0
      assert Metrics.clustering_coefficient(g) == 1.0
    end

    test "star: center has 0 clustering" do
      g =
        Graph.new(type: :undirected)
        |> Graph.add_edges([{:c, :a}, {:c, :b}, {:c, :d}])

      assert Metrics.clustering_coefficient(g, :c) == 0.0
      # Average over non-isolated vertices: only :c has >= 2 neighbors.
      assert Metrics.clustering_coefficient(g) == 0.0
    end

    test "degree-1 vertex has clustering 0.0" do
      g = Graph.new(type: :undirected) |> Graph.add_edge(:a, :b)
      assert Metrics.clustering_coefficient(g, :a) == 0.0
    end

    test "a vertex not in the graph raises ArgumentError" do
      g = Graph.new(type: :undirected) |> Graph.add_edge(:a, :b)

      assert_raise ArgumentError, ~r/not in the graph/, fn ->
        Metrics.clustering_coefficient(g, :missing)
      end
    end

    test "self-loops and edge direction are ignored" do
      g =
        Graph.new()
        |> Graph.add_edges([{:a, :b}, {:b, :a}, {:b, :c}, {:c, :a}, {:a, :a}, {:a, :d}])

      # :a has neighbours b, c, d (the self-loop is dropped); only b–c links.
      assert Metrics.clustering_coefficient(g, :a) == 1 / 3
      assert Metrics.triangles_per_vertex(g) == %{a: 1, b: 1, c: 1, d: 0}
      assert Metrics.transitivity(g) == 3 / 5
    end
  end

  describe "transitivity" do
    test "triangle: transitivity is 1.0" do
      g = Graph.new(type: :undirected) |> Graph.add_edges([{:a, :b}, {:b, :c}, {:c, :a}])
      assert Metrics.transitivity(g) == 1.0
    end

    test "graph with no triples is 0.0" do
      g = Graph.new(type: :undirected) |> Graph.add_edge(:a, :b)
      assert Metrics.transitivity(g) == 0.0
    end

    test "star with 3 leaves: 0.0 (no closing edges)" do
      g =
        Graph.new(type: :undirected)
        |> Graph.add_edges([{:c, :a}, {:c, :b}, {:c, :d}])

      assert Metrics.transitivity(g) == 0.0
    end
  end

  describe "density" do
    test "K3 directed: 1.0" do
      g =
        Graph.new(type: :directed)
        |> Graph.add_edges([{:a, :b}, {:b, :a}, {:a, :c}, {:c, :a}, {:b, :c}, {:c, :b}])

      assert Metrics.density(g) == 1.0
    end

    test "K3 undirected: 1.0" do
      g = Graph.new(type: :undirected) |> Graph.add_edges([{:a, :b}, {:b, :c}, {:c, :a}])
      assert Metrics.density(g) == 1.0
    end

    test "single vertex returns 0.0" do
      g = Graph.new() |> Graph.add_vertex(:a)
      assert Metrics.density(g) == 0.0
    end

    test "empty graph returns 0.0" do
      assert Metrics.density(Graph.new()) == 0.0
    end

    property "density is in [0, 1] for any graph" do
      check all(n <- integer(0..6), seed <- integer(0..1_000)) do
        g = Generators.erdos_renyi(n, 0.5, seed: seed, type: :undirected)
        d = Metrics.density(g)
        assert d >= 0.0
        assert d <= 1.0 + 1.0e-9
      end
    end
  end

  describe "eccentricity / radius / diameter" do
    test "path graph P_3 has diameter 2, radius 1" do
      g = Graph.new(type: :undirected) |> Graph.add_edges([{:a, :b}, {:b, :c}])
      assert Metrics.eccentricity(g, :b) == 1
      assert Metrics.eccentricity(g, :a) == 2
      assert Metrics.diameter(g) == 2
      assert Metrics.radius(g) == 1
      assert Metrics.center(g) == [:b]
      assert Enum.sort(Metrics.periphery(g)) == [:a, :c]
    end

    test "C5 cycle: diameter 2, radius 2, all vertices in center" do
      g = Generators.cycle(5, type: :undirected)
      assert Metrics.diameter(g) == 2
      assert Metrics.radius(g) == 2
      assert Enum.sort(Metrics.center(g)) == [0, 1, 2, 3, 4]
    end

    test "disconnected graph: diameter is :infinity by default" do
      g = Graph.new(type: :undirected) |> Graph.add_edges([{:a, :b}, {:c, :d}])
      assert Metrics.diameter(g) == :infinity
      assert Metrics.radius(g) == :infinity
    end

    test "disconnected graph with connected: :ignore returns max finite" do
      g = Graph.new(type: :undirected) |> Graph.add_edges([{:a, :b}, {:c, :d}])
      assert Metrics.diameter(g, connected: :ignore) == 1
      assert Metrics.radius(g, connected: :ignore) == 1
    end

    test "weighted eccentricity uses Dijkstra" do
      g =
        Graph.new(type: :undirected)
        |> Graph.add_edges([{:a, :b, weight: 1.0}, {:b, :c, weight: 5.0}])

      assert Metrics.eccentricity(g, :a, weighted: true) == 6.0
      assert Metrics.diameter(g, weighted: true) == 6.0
    end

    test "eccentricities map covers every vertex" do
      g = Generators.cycle(4, type: :undirected)
      ecc = Metrics.eccentricities(g)
      assert map_size(ecc) == 4
      assert Enum.all?(Map.values(ecc), &(&1 == 2))
    end

    test "eccentricity of a vertex not in the graph raises ArgumentError" do
      g = Graph.new(type: :undirected) |> Graph.add_edge(:a, :b)

      assert_raise ArgumentError, ~r/not in the graph/, fn -> Metrics.eccentricity(g, :missing) end
    end

    test "distance metrics reject unknown and invalid options" do
      g = Graph.new(type: :undirected) |> Graph.add_edge(:a, :b)

      for fun <- [
            &Metrics.eccentricities/2,
            &Metrics.diameter/2,
            &Metrics.radius/2,
            &Metrics.center/2,
            &Metrics.periphery/2,
            &Metrics.eccentricity(&1, :a, &2)
          ] do
        assert_raise ArgumentError, ~r/unknown keys \[:bogus\]/, fn -> fun.(g, bogus: 1) end
        assert_raise ArgumentError, ~r/:connected/, fn -> fun.(g, connected: :maybe) end
        assert_raise ArgumentError, ~r/:weighted/, fn -> fun.(g, weighted: :yes) end
      end
    end

    # Dijkstra without a settled set re-settled a–b forever on a negative
    # undirected edge, so these calls hung; the task bounds them.
    test "weighted distance metrics raise on a negative edge weight" do
      g = Graph.new(type: :undirected) |> Graph.add_edge(:a, :b, weight: -1)

      for fun <- [
            &Metrics.eccentricity(&1, :a, &2),
            &Metrics.eccentricities/2,
            &Metrics.diameter/2,
            &Metrics.radius/2,
            &Metrics.center/2,
            &Metrics.periphery/2
          ] do
        assert {:raised, %ArgumentError{message: message}} =
                 run_bounded(fn -> fun.(g, weighted: true) end)

        assert message =~ ~r/non-negative edge weights/
      end

      # Unweighted distances ignore the weights.
      assert Metrics.eccentricity(g, :a) == 1
      assert Metrics.diameter(g) == 1
    end
  end

  describe "properties" do
    property "triangle metrics match a brute-force count over vertex triples" do
      check all(g <- Grafi.Test.Generators.graph(id_type: :integer, max_vertices: 9, max_edges: 30)) do
        adj = fn u, v -> u != v and (Graph.has_edge?(g, u, v) or Graph.has_edge?(g, v, u)) end
        vs = Graph.vertices(g)
        nbrs = Map.new(vs, fn v -> {v, Enum.filter(vs, &adj.(v, &1))} end)

        triangles =
          for a <- vs,
              b <- vs,
              c <- vs,
              a < b,
              b < c,
              adj.(a, b),
              adj.(b, c),
              adj.(a, c),
              do: [a, b, c]

        per_vertex = Map.new(vs, fn v -> {v, Enum.count(triangles, &(v in &1))} end)
        triples = Enum.sum(for {_v, ns} <- nbrs, k = length(ns), do: div(k * (k - 1), 2))

        assert Metrics.triangle_count(g) == length(triangles)
        assert Metrics.triangles_per_vertex(g) == per_vertex

        assert Metrics.transitivity(g) ==
                 if(triples == 0, do: 0.0, else: 3 * length(triangles) / triples)

        for v <- vs, k = length(nbrs[v]), k >= 2 do
          assert_in_delta Metrics.clustering_coefficient(g, v),
                          2 * per_vertex[v] / (k * (k - 1)),
                          1.0e-12
        end
      end
    end
  end

  describe "scaling" do
    # The forward algorithm is O(E^1.5); on a star it is linear. The old
    # per-vertex neighbour scan cost Σ deg(v)² (every leaf re-read the
    # centre's neighbours), quadratic on a star (16x). Counted in reductions,
    # which are deterministic for pure Elixir code, unlike wall-clock time.
    @tag :slow
    test "triangle metrics on a star scale linearly up to 20k leaves" do
      cost = fn fun, n ->
        g = Enum.reduce(1..n, Graph.new(type: :undirected), &Graph.add_edge(&2, 0, &1))
        {result, reds} = reductions(fn -> fun.(g) end)
        assert result == 0
        reds
      end

      for fun <- [
            &Metrics.triangle_count/1,
            &Metrics.transitivity/1,
            &Metrics.clustering_coefficient/1
          ] do
        {small, large} = {cost.(fun, 5_000), cost.(fun, 20_000)}
        assert large < 6 * small, "4x the leaves took #{Float.round(large / small, 1)}x"
      end
    end
  end

  # Runs `fun` in this process; returns its result and the reductions spent.
  defp reductions(fun) do
    {:reductions, before} = Process.info(self(), :reductions)
    result = fun.()
    {:reductions, after_} = Process.info(self(), :reductions)
    {result, after_ - before}
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
