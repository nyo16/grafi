defmodule Grafi.Algo.ConnectivityTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  doctest Grafi.Algo.Connectivity

  alias Grafi.Algo.Connectivity
  alias Grafi.Graph

  # ── Helpers ───────────────────────────────────────────────────────────

  defp undirected(edges) do
    Graph.new(type: :undirected) |> Graph.add_edges(edges)
  end

  defp canon({u, v}) when u <= v, do: {u, v}
  defp canon({u, v}), do: {v, u}

  # Component count via BFS over the underlying undirected graph.
  defp component_count(%Graph{} = g) do
    {n, _} =
      Enum.reduce(Graph.vertices(g), {0, MapSet.new()}, fn v, {n, seen} ->
        if MapSet.member?(seen, v) do
          {n, seen}
        else
          comp = Grafi.bfs(g, v) |> Enum.to_list()

          seen =
            Enum.reduce(comp, seen, fn x, s -> MapSet.put(s, x) end)

          # For a directed graph, BFS only follows out-edges. To get
          # *undirected* components we also need to follow in-edges; do
          # a simple flood-fill instead.
          {n + 1, seen}
        end
      end)

    n
  end

  # Undirected flood-fill that walks both in- and out-neighbors.
  defp undirected_component_count(%Graph{} = g) do
    {n, _} =
      Enum.reduce(Graph.vertices(g), {0, MapSet.new()}, fn v, {n, seen} ->
        if MapSet.member?(seen, v) do
          {n, seen}
        else
          comp = flood(g, [v], MapSet.new([v]))

          {n + 1, comp}
          |> then(fn {nn, c} -> {nn, MapSet.union(seen, c)} end)
        end
      end)

    n
  end

  defp flood(_g, [], seen), do: seen

  defp flood(g, [v | rest], seen) do
    neigh =
      (Graph.out_neighbors(g, v) ++ Graph.in_neighbors(g, v))
      |> Enum.uniq()
      |> Enum.reject(&MapSet.member?(seen, &1))

    seen2 = Enum.reduce(neigh, seen, &MapSet.put(&2, &1))
    flood(g, neigh ++ rest, seen2)
  end

  # ── Tree (P_5) ────────────────────────────────────────────────────────

  describe "tree (path P_5)" do
    setup do
      g = undirected([{1, 2}, {2, 3}, {3, 4}, {4, 5}])
      {:ok, g: g}
    end

    test "every edge is a bridge", %{g: g} do
      assert Connectivity.bridges(g) == [{1, 2}, {2, 3}, {3, 4}, {4, 5}]
    end

    test "every internal vertex is an articulation point", %{g: g} do
      assert Connectivity.articulation_points(g) == MapSet.new([2, 3, 4])
    end

    test "every edge is its own biconnected component", %{g: g} do
      bccs = Connectivity.biconnected_components(g)
      assert length(bccs) == 4
      assert Enum.all?(bccs, &(MapSet.size(&1) == 1))

      flat = Enum.reduce(bccs, MapSet.new(), &MapSet.union/2)
      assert flat == MapSet.new([{1, 2}, {2, 3}, {3, 4}, {4, 5}])
    end

    test "biconnected? is false for a path", %{g: g} do
      refute Connectivity.biconnected?(g)
    end
  end

  # ── Cycle (C_5) ───────────────────────────────────────────────────────

  describe "cycle (C_5)" do
    setup do
      g = undirected([{1, 2}, {2, 3}, {3, 4}, {4, 5}, {5, 1}])
      {:ok, g: g}
    end

    test "no bridges", %{g: g} do
      assert Connectivity.bridges(g) == []
    end

    test "no articulation points", %{g: g} do
      assert Connectivity.articulation_points(g) == MapSet.new()
    end

    test "one biconnected component containing all edges", %{g: g} do
      assert [bcc] = Connectivity.biconnected_components(g)
      assert MapSet.size(bcc) == 5
    end

    test "biconnected? is true", %{g: g} do
      assert Connectivity.biconnected?(g)
    end
  end

  # ── Bowtie (two triangles sharing a vertex) ──────────────────────────

  describe "bowtie (two triangles sharing a vertex)" do
    setup do
      g =
        undirected([
          {:a, :b},
          {:b, :c},
          {:c, :a},
          {:a, :d},
          {:d, :e},
          {:e, :a}
        ])

      {:ok, g: g}
    end

    test "shared vertex is the only articulation point", %{g: g} do
      assert Connectivity.articulation_points(g) == MapSet.new([:a])
    end

    test "no bridges", %{g: g} do
      assert Connectivity.bridges(g) == []
    end

    test "two biconnected components, each with 3 edges", %{g: g} do
      bccs = Connectivity.biconnected_components(g)
      assert length(bccs) == 2
      assert Enum.all?(bccs, &(MapSet.size(&1) == 3))
    end

    test "not biconnected", %{g: g} do
      refute Connectivity.biconnected?(g)
    end
  end

  # ── Two triangles sharing an edge ────────────────────────────────────

  describe "two triangles sharing an edge" do
    setup do
      # K_4 minus one edge: {a,b},{b,c},{c,a},{a,d},{c,d}
      # The shared edge is (a, c).
      g =
        undirected([
          {:a, :b},
          {:b, :c},
          {:c, :a},
          {:a, :d},
          {:c, :d}
        ])

      {:ok, g: g}
    end

    test "no articulation points", %{g: g} do
      assert Connectivity.articulation_points(g) == MapSet.new()
    end

    test "no bridges", %{g: g} do
      assert Connectivity.bridges(g) == []
    end

    test "one biconnected component", %{g: g} do
      assert [bcc] = Connectivity.biconnected_components(g)
      assert MapSet.size(bcc) == 5
    end

    test "is biconnected", %{g: g} do
      assert Connectivity.biconnected?(g)
    end
  end

  # ── Barbell (two K_4 connected by one edge) ──────────────────────────

  describe "barbell (two K_4 joined by a single edge)" do
    setup do
      k4_a =
        for u <- [:a1, :a2, :a3, :a4],
            v <- [:a1, :a2, :a3, :a4],
            u < v,
            do: {u, v}

      k4_b =
        for u <- [:b1, :b2, :b3, :b4],
            v <- [:b1, :b2, :b3, :b4],
            u < v,
            do: {u, v}

      bridge = [{:a1, :b1}]
      {:ok, g: undirected(k4_a ++ k4_b ++ bridge)}
    end

    test "the connecting edge is the only bridge", %{g: g} do
      assert Connectivity.bridges(g) == [{:a1, :b1}]
    end

    test "the two bridge endpoints are articulation points", %{g: g} do
      assert Connectivity.articulation_points(g) == MapSet.new([:a1, :b1])
    end

    test "three biconnected components: two K_4 plus the bridge", %{g: g} do
      bccs = Connectivity.biconnected_components(g)
      assert length(bccs) == 3

      sizes = bccs |> Enum.map(&MapSet.size/1) |> Enum.sort()
      # K_4 has 6 edges; bridge contributes 1.
      assert sizes == [1, 6, 6]
    end

    test "not biconnected", %{g: g} do
      refute Connectivity.biconnected?(g)
    end
  end

  # ── Multi-edges ──────────────────────────────────────────────────────

  describe "multigraphs" do
    test "two parallel edges between u and v: neither is a bridge" do
      g =
        Graph.new(type: :undirected)
        |> Graph.add_edge(:u, :v)
        |> Graph.add_edge(:u, :v)

      assert Connectivity.bridges(g) == []
      assert Connectivity.articulation_points(g) == MapSet.new()
    end

    test "a parallel-edge pair forms a single biconnected component" do
      g =
        Graph.new(type: :undirected)
        |> Graph.add_edge(:u, :v)
        |> Graph.add_edge(:u, :v)

      assert [bcc] = Connectivity.biconnected_components(g)
      assert bcc == MapSet.new([{:u, :v}])
    end

    test "path with a doubled middle edge has only the outer two as bridges" do
      g =
        Graph.new(type: :undirected)
        |> Graph.add_edge(:a, :b)
        |> Graph.add_edge(:b, :c)
        |> Graph.add_edge(:b, :c)
        |> Graph.add_edge(:c, :d)

      assert Connectivity.bridges(g) |> Enum.sort() == [{:a, :b}, {:c, :d}]
      assert Connectivity.articulation_points(g) == MapSet.new([:b, :c])
    end
  end

  # ── Self-loops ───────────────────────────────────────────────────────

  describe "self-loops" do
    test "self-loop on a leaf does not affect bridge/articulation results" do
      g =
        Graph.new(type: :undirected)
        |> Graph.add_edges([{:a, :b}, {:b, :c}])
        |> Graph.add_edge(:c, :c)

      assert Connectivity.bridges(g) |> Enum.sort() == [{:a, :b}, {:b, :c}]
      assert Connectivity.articulation_points(g) == MapSet.new([:b])
    end

    test "self-loop alone produces no bridges, no articulation points, no bccs" do
      g = Graph.new(type: :undirected) |> Graph.add_edge(:v, :v)
      assert Connectivity.bridges(g) == []
      assert Connectivity.articulation_points(g) == MapSet.new()
      assert Connectivity.biconnected_components(g) == []
    end
  end

  # ── Empty / degenerate ───────────────────────────────────────────────

  describe "edge cases" do
    test "empty graph" do
      g = Graph.new(type: :undirected)
      assert Connectivity.bridges(g) == []
      assert Connectivity.articulation_points(g) == MapSet.new()
      assert Connectivity.biconnected_components(g) == []
      refute Connectivity.biconnected?(g)
    end

    test "single isolated vertex" do
      g = Graph.new(type: :undirected) |> Graph.add_vertex(:lonely)
      assert Connectivity.bridges(g) == []
      assert Connectivity.articulation_points(g) == MapSet.new()
      assert Connectivity.biconnected_components(g) == []
      refute Connectivity.biconnected?(g)
    end

    test "two isolated vertices" do
      g = Graph.new(type: :undirected) |> Graph.add_vertices([:a, :b])
      refute Connectivity.biconnected?(g)
    end

    test "single edge between two vertices" do
      g = Graph.new(type: :undirected) |> Graph.add_edge(:a, :b)
      assert Connectivity.bridges(g) == [{:a, :b}]
      assert Connectivity.articulation_points(g) == MapSet.new()
      assert Connectivity.biconnected_components(g) == [MapSet.new([{:a, :b}])]
      # A single edge is a K_2 — by convention K_2 is biconnected.
      assert Connectivity.biconnected?(g)
    end

    test "directed graph is treated as undirected" do
      # Directed cycle a -> b -> c -> a is, undirected, a triangle.
      g = Grafi.new() |> Grafi.add_edges([{:a, :b}, {:b, :c}, {:c, :a}])
      assert Connectivity.bridges(g) == []
      assert Connectivity.articulation_points(g) == MapSet.new()
      assert [bcc] = Connectivity.biconnected_components(g)
      assert MapSet.size(bcc) == 3
    end

    test "disconnected graph: components processed independently" do
      g = undirected([{:a, :b}, {:c, :d}, {:d, :e}])

      assert Connectivity.bridges(g) |> Enum.sort() ==
               [{:a, :b}, {:c, :d}, {:d, :e}]

      assert Connectivity.articulation_points(g) == MapSet.new([:d])
      refute Connectivity.biconnected?(g)
    end
  end

  # ── Properties ───────────────────────────────────────────────────────

  defp random_undirected_graph do
    gen all(
          verts <- uniq_list_of(integer(1..200), min_length: 2, max_length: 12),
          edges <- list_of({member_of(verts), member_of(verts)}, max_length: 25)
        ) do
      Graph.new(type: :undirected) |> Graph.add_vertices(verts) |> Graph.add_edges(edges)
    end
  end

  # Canonical (smaller-first) edge set of the underlying simple graph.
  defp canonical_edge_set(%Graph{} = g) do
    Graph.edges(g)
    |> Enum.reject(fn e -> e.from == e.to end)
    |> Enum.map(fn e -> canon({e.from, e.to}) end)
    |> MapSet.new()
  end

  describe "properties" do
    property "bridges are a subset of all edges (excluding self-loops)" do
      check all(g <- random_undirected_graph()) do
        all_edges = canonical_edge_set(g)

        for b <- Connectivity.bridges(g) do
          assert MapSet.member?(all_edges, b),
                 "bridge #{inspect(b)} not in edge set"
        end
      end
    end

    property "articulation points are a subset of vertices" do
      check all(g <- random_undirected_graph()) do
        vs = MapSet.new(Graph.vertices(g))

        for a <- Connectivity.articulation_points(g) do
          assert MapSet.member?(vs, a),
                 "articulation #{inspect(a)} not a vertex"
        end
      end
    end

    property "removing a bridge increases undirected component count by exactly 1" do
      check all(g <- random_undirected_graph()) do
        before = undirected_component_count(g)

        for {u, v} <- Connectivity.bridges(g) do
          # Remove ALL parallel copies of (u, v) so the underlying simple
          # edge truly disappears. (Our bridge analysis guarantees there
          # is exactly one copy when the edge is a bridge, but be safe.)
          g2 = drop_all_edges(g, u, v)
          after_ = undirected_component_count(g2)

          assert after_ == before + 1,
                 "removing bridge #{inspect({u, v})} changed component count from #{before} to #{after_}"
        end
      end
    end
  end

  defp drop_all_edges(g, u, v) do
    g = drop_loop(g, u, v)
    drop_loop(g, v, u)
  end

  defp drop_loop(g, u, v) do
    case Graph.edges_between(g, u, v) do
      [] -> g
      _list -> drop_loop(Graph.delete_edge(g, u, v), u, v)
    end
  end

  # Sanity check that component_count helper is unused-warning-free.
  test "component_count helper exists" do
    g = undirected([{:a, :b}])
    assert is_integer(component_count(g))
  end
end
