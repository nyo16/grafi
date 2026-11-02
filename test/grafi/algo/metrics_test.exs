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
  end

  describe "properties" do
    property "triangle_count >= 0 for random graphs" do
      check all(n <- integer(3..7), p <- float(min: 0.0, max: 1.0), seed <- integer(0..999)) do
        g = Generators.erdos_renyi(n, p, seed: seed, type: :undirected)
        assert Metrics.triangle_count(g) >= 0
      end
    end
  end
end
