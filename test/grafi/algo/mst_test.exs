defmodule Grafi.Algo.MSTTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  doctest Grafi.Algo.MST

  alias Grafi.Algo.MST
  alias Grafi.DisconnectedError
  alias Grafi.Edge
  alias Grafi.Graph

  # ── Helpers ───────────────────────────────────────────────────────────

  defp edge_key(%Edge{from: f, to: t, weight: w}) do
    {a, b} = if f <= t, do: {f, t}, else: {t, f}
    {a, b, w}
  end

  defp edge_set(edges), do: edges |> Enum.map(&edge_key/1) |> MapSet.new()

  # Build a random connected undirected graph on n vertices. The RNG state is
  # threaded explicitly via :rand.uniform_s/2 (seeded with :rand.seed_s/2)
  # rather than the process-global :rand.seed/2 — the latter mutates shared
  # state and is unsafe under `async: true`. We grow a spanning tree first to
  # guarantee connectivity, then sprinkle in extra random edges.
  defp random_connected_graph(n, extra, seed) when n > 0 do
    rng = :rand.seed_s(:exsss, {seed, seed + 1, seed + 2})
    verts = Enum.to_list(0..(n - 1))

    g0 = Graph.new(type: :undirected) |> Graph.add_vertices(verts)

    # Spanning tree: connect each new vertex to a random earlier one.
    {g_tree, rng} =
      Enum.reduce(1..(n - 1)//1, {g0, rng}, fn i, {acc, r} ->
        {p, r} = rand_int(r, i)
        parent = p - 1
        {w, r} = rand_int(r, 100)
        {Graph.add_edge(acc, parent, i, weight: w / 1), r}
      end)

    # Extra random edges.
    {g, _rng} =
      Enum.reduce(1..extra//1, {g_tree, rng}, fn _, {acc, r} ->
        {u1, r} = rand_int(r, n)
        {v1, r} = rand_int(r, n)
        u = u1 - 1
        v = v1 - 1

        if u == v do
          {acc, r}
        else
          {w, r} = rand_int(r, 100)
          {Graph.add_edge(acc, u, v, weight: w / 1), r}
        end
      end)

    g
  end

  # Draw an integer in 1..max, returning the value and the next RNG state.
  defp rand_int(rng, max) do
    {f, rng} = :rand.uniform_s(rng)
    {trunc(f * max) + 1, rng}
  end

  defp has_cycle?(edges, n_verts) do
    # An undirected forest on V vertices has at most V-1 edges.
    length(edges) > n_verts - 1
  end

  # ── Kruskal: small classics ───────────────────────────────────────────

  describe "kruskal/1" do
    test "triangle 1-2-3 → MST weight 3" do
      g =
        Graph.new(type: :undirected)
        |> Graph.add_edges([
          {:a, :b, weight: 1.0},
          {:b, :c, weight: 2.0},
          {:a, :c, weight: 3.0}
        ])

      {edges, total} = MST.kruskal(g)
      assert length(edges) == 2
      assert total == 3.0

      weights = edges |> Enum.map(& &1.weight) |> Enum.sort()
      assert weights == [1.0, 2.0]
    end

    test "square + diagonal: 4 vertices, known MST" do
      # Square 1-2-3-4 with weights 1, 2, 3, 4 around, diagonal weight 100.
      # MST should be the three lightest edges 1, 2, 3 (total 6).
      g =
        Graph.new(type: :undirected)
        |> Graph.add_edges([
          {:n1, :n2, weight: 1.0},
          {:n2, :n3, weight: 2.0},
          {:n3, :n4, weight: 3.0},
          {:n4, :n1, weight: 4.0},
          {:n1, :n3, weight: 100.0}
        ])

      {edges, total} = MST.kruskal(g)
      assert length(edges) == 3
      assert total == 6.0
    end

    test "empty graph yields {[], 0}" do
      g = Graph.new(type: :undirected)
      assert {[], 0} = MST.kruskal(g)
    end

    test "single-vertex graph yields {[], 0}" do
      g = Graph.new(type: :undirected) |> Graph.add_vertex(:lonely)
      assert {[], 0} = MST.kruskal(g)
    end

    test "disconnected graph returns a spanning forest" do
      g =
        Graph.new(type: :undirected)
        |> Graph.add_edges([
          {:a, :b, weight: 1.0},
          {:c, :d, weight: 2.0}
        ])
        |> Graph.add_vertex(:isolated)

      {edges, total} = MST.kruskal(g)
      # 5 vertices, 3 components ⇒ 2 forest edges.
      assert length(edges) == 2
      assert total == 3.0
    end

    test "multi-edges: uses the minimum-weight parallel edge" do
      g =
        Graph.new(type: :undirected)
        |> Graph.add_edge(:a, :b, weight: 10.0)
        |> Graph.add_edge(:a, :b, weight: 1.0)
        |> Graph.add_edge(:b, :c, weight: 2.0)

      {edges, total} = MST.kruskal(g)
      assert length(edges) == 2
      assert total == 3.0
    end

    test "directed input: treats edges as undirected" do
      g =
        Graph.new(type: :directed)
        |> Graph.add_edges([
          {:a, :b, weight: 1.0},
          {:b, :c, weight: 2.0},
          {:c, :a, weight: 3.0}
        ])

      {edges, total} = MST.kruskal(g)
      assert length(edges) == 2
      assert total == 3.0
    end
  end

  describe "kruskal!/1" do
    test "returns tree on a connected graph" do
      g =
        Graph.new(type: :undirected)
        |> Graph.add_edges([
          {:a, :b, weight: 1.0},
          {:b, :c, weight: 2.0}
        ])

      assert {edges, 3.0} = MST.kruskal!(g)
      assert length(edges) == 2
    end

    test "raises DisconnectedError on a disconnected graph" do
      g =
        Graph.new(type: :undirected)
        |> Graph.add_edges([{:a, :b, weight: 1.0}, {:c, :d, weight: 2.0}])

      assert_raise DisconnectedError, fn -> MST.kruskal!(g) end
    end
  end

  # ── Prim ──────────────────────────────────────────────────────────────

  describe "prim/2" do
    test "triangle 1-2-3 → MST weight 3" do
      g =
        Graph.new(type: :undirected)
        |> Graph.add_edges([
          {:a, :b, weight: 1.0},
          {:b, :c, weight: 2.0},
          {:a, :c, weight: 3.0}
        ])

      {edges, total} = MST.prim(g, :a)
      assert length(edges) == 2
      assert total == 3.0
    end

    test "default start picks an arbitrary vertex" do
      g =
        Graph.new(type: :undirected)
        |> Graph.add_edges([{:a, :b, weight: 1.0}, {:b, :c, weight: 2.0}])

      {edges, total} = MST.prim(g)
      assert length(edges) == 2
      assert total == 3.0
    end

    test "empty graph yields {[], 0}" do
      assert {[], 0} = MST.prim(Graph.new(type: :undirected))
    end

    test "spans only the component containing start" do
      g =
        Graph.new(type: :undirected)
        |> Graph.add_edges([
          {:a, :b, weight: 1.0},
          {:b, :c, weight: 2.0},
          {:x, :y, weight: 99.0}
        ])

      {edges, total} = MST.prim(g, :a)
      assert length(edges) == 2
      assert total == 3.0

      verts = edges |> Enum.flat_map(&[&1.from, &1.to]) |> MapSet.new()
      assert MapSet.equal?(verts, MapSet.new([:a, :b, :c]))
    end

    test "raises on unknown start" do
      g = Graph.new(type: :undirected) |> Graph.add_vertex(:a)
      assert_raise ArgumentError, fn -> MST.prim(g, :nope) end
    end

    test "multi-edges: uses the minimum-weight parallel edge" do
      g =
        Graph.new(type: :undirected)
        |> Graph.add_edge(:a, :b, weight: 10.0)
        |> Graph.add_edge(:a, :b, weight: 1.0)
        |> Graph.add_edge(:b, :c, weight: 2.0)

      {edges, total} = MST.prim(g, :a)
      assert length(edges) == 2
      assert total == 3.0
    end

    test "directed input: treats edges as undirected" do
      g =
        Graph.new(type: :directed)
        |> Graph.add_edges([
          {:a, :b, weight: 1.0},
          {:b, :c, weight: 2.0},
          {:c, :a, weight: 3.0}
        ])

      {edges, total} = MST.prim(g, :a)
      assert length(edges) == 2
      assert total == 3.0
    end
  end

  # ── Cross-check Kruskal vs Prim ───────────────────────────────────────

  describe "Kruskal vs Prim agreement" do
    test "produce same total weight on small connected graphs" do
      # CLRS-style graph with all distinct weights so the MST is unique
      # and Kruskal and Prim must agree exactly on the chosen edges.
      g =
        Graph.new(type: :undirected)
        |> Graph.add_edges([
          {:a, :b, weight: 4.0},
          {:a, :c, weight: 8.0},
          {:b, :c, weight: 11.0},
          {:b, :d, weight: 6.0},
          {:c, :d, weight: 2.0},
          {:c, :e, weight: 7.0},
          {:d, :e, weight: 9.0},
          {:d, :f, weight: 14.0},
          {:e, :f, weight: 10.0}
        ])

      {k_edges, k_total} = MST.kruskal(g)
      {p_edges, p_total} = MST.prim(g, :a)

      assert k_total == p_total
      assert length(k_edges) == length(p_edges)
      # All weights distinct ⇒ MST is unique, so edge sets must match.
      assert edge_set(k_edges) == edge_set(p_edges)
    end
  end

  # ── total_weight ──────────────────────────────────────────────────────

  describe "total_weight/1" do
    test "sums weights" do
      edges = [
        %Edge{from: :a, to: :b, weight: 1.5},
        %Edge{from: :b, to: :c, weight: 2.5},
        %Edge{from: :c, to: :d, weight: 0.5}
      ]

      assert MST.total_weight(edges) == 4.5
    end

    test "empty list is 0" do
      assert MST.total_weight([]) == 0
    end
  end

  # ── Property tests ────────────────────────────────────────────────────

  describe "properties" do
    property "MST of a connected graph has exactly V-1 edges and no cycle" do
      check all(
              n <- integer(3..10),
              extra <- integer(0..15),
              seed <- integer(1..10_000)
            ) do
        g = random_connected_graph(n, extra, seed)

        {k_edges, _k_total} = MST.kruskal(g)
        {p_edges, _p_total} = MST.prim(g, 0)

        assert length(k_edges) == n - 1
        assert length(p_edges) == n - 1

        refute has_cycle?(k_edges, n)
        refute has_cycle?(p_edges, n)
      end
    end

    property "Kruskal total == Prim total on connected graphs" do
      check all(
              n <- integer(3..10),
              extra <- integer(0..15),
              seed <- integer(1..10_000)
            ) do
        g = random_connected_graph(n, extra, seed)

        {_, k_total} = MST.kruskal(g)
        {_, p_total} = MST.prim(g, 0)

        assert k_total == p_total
      end
    end
  end
end
