defmodule Grafi.GeneratorsTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias Grafi.Generators
  alias Grafi.Graph

  doctest Grafi.Generators

  describe "options" do
    test "generators are directed by default, like Graph.new/1" do
      assert Generators.complete(3).type == :directed
      assert Generators.erdos_renyi(5, 0.5, seed: 1).type == :directed
      assert Generators.grid(2, 2).type == :directed
      assert Generators.complete(3, type: :undirected).type == :undirected
    end

    test "unknown options and bad types raise ArgumentError" do
      assert_raise ArgumentError, ~r/unknown keys \[:directed\]/, fn ->
        Generators.complete(3, directed: true)
      end

      assert_raise ArgumentError, ~r/:type to be :directed or :undirected/, fn ->
        Generators.cycle(3, type: :both)
      end

      assert_raise ArgumentError, ~r/unknown keys \[:seed\]/, fn ->
        Generators.path(3, seed: 1)
      end
    end
  end

  describe "complete/2" do
    test "K5 has 10 undirected edges and uniform degree 4" do
      g = Generators.complete(5, type: :undirected)
      assert Graph.num_vertices(g) == 5
      assert Graph.num_edges(g) == 10
      assert Enum.all?(Graph.vertices(g), &(Graph.degree(g, &1) == 4))
    end

    test "directed K3 has 6 edges" do
      g = Generators.complete(3)
      assert g.type == :directed
      assert Graph.num_edges(g) == 6
    end

    test "K1 and K0 are degenerate" do
      assert Graph.num_edges(Generators.complete(0)) == 0
      assert Graph.num_edges(Generators.complete(1)) == 0
    end
  end

  describe "cycle/2" do
    test "C5 has 5 edges and degree 2 everywhere" do
      g = Generators.cycle(5, type: :undirected)
      assert Graph.num_vertices(g) == 5
      assert Graph.num_edges(g) == 5
      assert Enum.all?(Graph.vertices(g), &(Graph.degree(g, &1) == 2))
    end
  end

  describe "path/2" do
    test "P4 has 3 edges; endpoints have degree 1, middle has 2" do
      g = Generators.path(4, type: :undirected)
      assert Graph.num_vertices(g) == 4
      assert Graph.num_edges(g) == 3
      assert Graph.degree(g, 0) == 1
      assert Graph.degree(g, 3) == 1
      assert Graph.degree(g, 1) == 2
      assert Graph.degree(g, 2) == 2
    end
  end

  describe "grid/3" do
    test "3x4 grid has 12 vertices and 17 edges" do
      g = Generators.grid(3, 4)
      assert Graph.num_vertices(g) == 12
      assert Graph.num_edges(g) == 17
      assert Graph.has_vertex?(g, {0, 0})
      assert Graph.has_vertex?(g, {2, 3})
      assert Graph.has_edge?(g, {0, 0}, {1, 0})
      assert Graph.has_edge?(g, {0, 0}, {0, 1})
    end

    test "2x2 grid has 4 edges" do
      g = Generators.grid(2, 2)
      assert Graph.num_vertices(g) == 4
      assert Graph.num_edges(g) == 4
    end
  end

  describe "erdos_renyi/3" do
    test "p = 0.0: zero edges" do
      g = Generators.erdos_renyi(50, 0.0, seed: 1)
      assert Graph.num_vertices(g) == 50
      assert Graph.num_edges(g) == 0
    end

    test "p = 1.0: complete graph" do
      g = Generators.erdos_renyi(50, 1.0, seed: 1, type: :undirected)
      assert Graph.num_edges(g) == div(50 * 49, 2)
    end

    test "fixed seed is deterministic" do
      g1 = Generators.erdos_renyi(40, 0.3, seed: 99)
      g2 = Generators.erdos_renyi(40, 0.3, seed: 99)
      assert Graph.num_edges(g1) == Graph.num_edges(g2)
    end

    test "directed variant: count near n*(n-1)*p" do
      g = Generators.erdos_renyi(20, 0.5, seed: 5)
      # Roughly 20*19*0.5 = 190; just check it's in a sane band.
      assert Graph.num_edges(g) >= 50
      assert Graph.num_edges(g) <= 380
    end
  end

  describe "barabasi_albert/3" do
    test "BA(20, 2) has 20 vertices and 37 edges" do
      g = Generators.barabasi_albert(20, 2, seed: 11, type: :undirected)
      assert Graph.num_vertices(g) == 20
      # Initial K3 has 3 edges; each of 17 added vertices contributes 2 edges.
      assert Graph.num_edges(g) == 3 + 17 * 2
    end

    test "fixed seed gives identical edge count" do
      g1 = Generators.barabasi_albert(30, 3, seed: 7)
      g2 = Generators.barabasi_albert(30, 3, seed: 7)
      assert Graph.num_edges(g1) == Graph.num_edges(g2)
    end
  end

  describe "watts_strogatz/4" do
    test "p = 0.0: ring lattice with exactly n*k/2 edges" do
      g = Generators.watts_strogatz(20, 4, 0.0)
      assert Graph.num_edges(g) == 40
    end

    test "p > 0: edge count is preserved by rewiring" do
      g = Generators.watts_strogatz(30, 4, 0.3, seed: 23)
      assert Graph.num_edges(g) == 60
    end

    test "p = 1.0: still preserves edge count" do
      g = Generators.watts_strogatz(20, 4, 1.0, seed: 99)
      assert Graph.num_edges(g) == 40
    end
  end

  describe "random_regular/3" do
    test "3-regular on 10 vertices has degree 3 everywhere" do
      g = Generators.random_regular(10, 3, seed: 42, type: :undirected)
      assert Graph.num_vertices(g) == 10

      Enum.each(Graph.vertices(g), fn v ->
        assert Graph.degree(g, v) == 3
      end)
    end

    test "0-regular: empty edges" do
      g = Generators.random_regular(5, 0, seed: 1)
      assert Graph.num_edges(g) == 0
    end
  end

  describe "properties" do
    property "complete/2 vertex count matches n" do
      check all(n <- integer(0..8)) do
        g = Generators.complete(n)
        assert Graph.num_vertices(g) == n
      end
    end

    property "cycle/2 has n edges when n >= 2" do
      check all(n <- integer(2..30)) do
        g = Generators.cycle(n)
        assert Graph.num_edges(g) == n
      end
    end

    property "erdos_renyi gives valid graphs" do
      check all(n <- integer(0..10), p <- float(min: 0.0, max: 1.0), seed <- integer(0..999)) do
        g = Generators.erdos_renyi(n, p, seed: seed)
        assert Graph.num_vertices(g) == n
      end
    end
  end
end
