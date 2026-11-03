defmodule Grafi.Algo.APSPTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  doctest Grafi.Algo.APSP

  alias Grafi.Algo.APSP
  alias Grafi.Algo.ShortestPath
  alias Grafi.Test.Generators

  # ── Fixtures ─────────────────────────────────────────────────────────

  defp triangle do
    Grafi.new()
    |> Grafi.add_edges([
      {:a, :b, weight: 1.0},
      {:b, :c, weight: 2.0},
      {:a, :c, weight: 5.0}
    ])
  end

  defp square_with_diag do
    Grafi.new()
    |> Grafi.add_edges([
      {:a, :b, weight: 1.0},
      {:b, :c, weight: 1.0},
      {:c, :d, weight: 1.0},
      {:a, :d, weight: 5.0},
      {:a, :c, weight: 2.5}
    ])
  end

  defp k4 do
    edges =
      for u <- [:a, :b, :c, :d], v <- [:a, :b, :c, :d], u != v do
        {u, v, [weight: 1.0 + :erlang.phash2({u, v}, 5)]}
      end

    Grafi.new() |> Grafi.add_edges(edges)
  end

  defp neg_edge_graph do
    # Has negative edges but no negative cycle.
    Grafi.new()
    |> Grafi.add_edges([
      {:a, :b, weight: 4.0},
      {:a, :c, weight: 5.0},
      {:b, :c, weight: -3.0},
      {:c, :d, weight: 2.0},
      {:b, :d, weight: 6.0}
    ])
  end

  defp neg_cycle_graph do
    # -1, -1, -1 triangle: total -3 < 0.
    Grafi.new()
    |> Grafi.add_edges([
      {:a, :b, weight: -1.0},
      {:b, :c, weight: -1.0},
      {:c, :a, weight: -1.0},
      # plus a disconnected sink for variety
      {:x, :y, weight: 2.0}
    ])
  end

  # Compute APSP via dijkstra_all from every vertex; reference for positive-
  # weight cases.
  defp dijkstra_apsp(g) do
    for v <- Grafi.vertices(g), into: %{} do
      {v, ShortestPath.dijkstra_all(g, v)}
    end
  end

  defp assert_dist_matrices_equal(m1, m2, delta \\ 1.0e-9) do
    keys1 = m1 |> Map.keys() |> MapSet.new()
    keys2 = m2 |> Map.keys() |> MapSet.new()
    assert keys1 == keys2

    for u <- Map.keys(m1) do
      row1 = m1[u]
      row2 = m2[u]
      ks1 = row1 |> Map.keys() |> MapSet.new()
      ks2 = row2 |> Map.keys() |> MapSet.new()
      assert ks1 == ks2, "row keys differ for #{inspect(u)}: #{inspect(ks1)} vs #{inspect(ks2)}"

      for v <- Map.keys(row1) do
        assert_in_delta row1[v], row2[v], delta
      end
    end
  end

  # ── Floyd-Warshall ────────────────────────────────────────────────────

  describe "floyd_warshall/1" do
    test "triangle: relaxes a->c via b" do
      {:ok, d} = APSP.floyd_warshall(triangle())
      assert d[:a][:c] == 3.0
      assert d[:a][:b] == 1.0
      assert d[:b][:c] == 2.0
      assert d[:a][:a] == 0.0
      assert d[:c][:c] == 0.0
      # No path c -> a in directed graph
      refute Map.has_key?(d[:c], :a)
    end

    test "square + diagonal" do
      {:ok, d} = APSP.floyd_warshall(square_with_diag())
      assert d[:a][:d] == 3.0
      assert d[:a][:c] == 2.0
      assert d[:b][:d] == 2.0
    end

    test "K4: agrees with dijkstra_all from each vertex" do
      g = k4()
      {:ok, d} = APSP.floyd_warshall(g)
      assert_dist_matrices_equal(d, dijkstra_apsp(g))
    end

    test "handles negative edges (no cycle)" do
      g = neg_edge_graph()
      {:ok, d} = APSP.floyd_warshall(g)
      # a -> b -> c = 4 + -3 = 1, beats a -> c = 5
      assert d[:a][:c] == 1.0
      # a -> b -> c -> d = 4 + -3 + 2 = 3, beats a -> b -> d = 10
      assert d[:a][:d] == 3.0
    end

    test "detects negative cycle" do
      assert APSP.floyd_warshall(neg_cycle_graph()) == {:error, :negative_cycle}
    end

    test "empty graph returns {:ok, %{}}" do
      assert {:ok, d} = APSP.floyd_warshall(Grafi.new())
      assert d == %{}
    end

    test "single vertex: only the trivial 0-distance self-loop" do
      g = Grafi.new() |> Grafi.add_vertex(:only)
      {:ok, d} = APSP.floyd_warshall(g)
      assert d == %{only: %{only: 0.0}}
    end

    test "agrees with dijkstra on positive-weight graph (no path means key absent)" do
      g =
        Grafi.new()
        |> Grafi.add_edges([
          {:a, :b, weight: 1.0},
          {:c, :d, weight: 1.0}
        ])

      {:ok, d} = APSP.floyd_warshall(g)
      assert_dist_matrices_equal(d, dijkstra_apsp(g))
      refute Map.has_key?(d[:a], :c)
      refute Map.has_key?(d[:a], :d)
    end
  end

  # ── Path reconstruction ───────────────────────────────────────────────

  describe "floyd_warshall_with_paths/1 + reconstruct_path/3" do
    test "reconstructs multi-hop path on triangle" do
      g = triangle()
      {:ok, _d, p} = APSP.floyd_warshall_with_paths(g)
      assert APSP.reconstruct_path(p, :a, :c) == {:ok, [:a, :b, :c]}
      assert APSP.reconstruct_path(p, :a, :b) == {:ok, [:a, :b]}
    end

    test "trivial from == to" do
      g = triangle()
      {:ok, _d, p} = APSP.floyd_warshall_with_paths(g)
      assert APSP.reconstruct_path(p, :a, :a) == {:ok, [:a]}
    end

    test "vertex ids compare strictly: 1 and 1.0 are distinct" do
      g = Grafi.new() |> Grafi.add_edges([{1, 1.0, weight: 2.0}, {1.0, 1, weight: -1.0}])
      {:ok, d, p} = APSP.floyd_warshall_with_paths(g)
      assert APSP.reconstruct_path(p, 1, 1.0) == {:ok, [1, 1.0]}
      assert d[1][1] == 0.0
      assert d[1][1.0] == 2.0
    end

    test "no path" do
      g =
        Grafi.new()
        |> Grafi.add_edges([{:a, :b, weight: 1.0}])
        |> Grafi.add_vertex(:c)

      {:ok, _d, p} = APSP.floyd_warshall_with_paths(g)
      assert APSP.reconstruct_path(p, :a, :c) == {:error, :no_path}
    end

    test "matches Grafi.dijkstra/3 on positive-weight graph" do
      g = square_with_diag()
      {:ok, d, p} = APSP.floyd_warshall_with_paths(g)

      for u <- Grafi.vertices(g), v <- Grafi.vertices(g), u != v do
        case Grafi.dijkstra(g, u, v) do
          {:ok, {_path, dist}} ->
            assert {:ok, fw_path} = APSP.reconstruct_path(p, u, v)
            assert_in_delta dist, d[u][v], 1.0e-9
            # Sum the path weight via the reconstructed path; must match.
            fw_dist = path_weight(g, fw_path)
            assert_in_delta dist, fw_dist, 1.0e-9

          {:error, :no_path} ->
            refute Map.has_key?(d[u], v)
            assert APSP.reconstruct_path(p, u, v) == {:error, :no_path}
        end
      end
    end

    test "a vertex missing from the matrix returns {:error, :no_such_vertex}" do
      g = triangle()
      {:ok, _d, p} = APSP.floyd_warshall_with_paths(g)
      assert APSP.reconstruct_path(p, :ghost, :a) == {:error, :no_such_vertex}
      assert APSP.reconstruct_path(p, :a, :ghost) == {:error, :no_such_vertex}
      assert APSP.reconstruct_path(p, :ghost, :ghost) == {:error, :no_such_vertex}
    end
  end

  defp path_weight(_g, [_]), do: 0.0

  defp path_weight(g, [u, v | rest]) do
    w = Grafi.Graph.edges_between(g, u, v) |> Enum.map(& &1.weight) |> Enum.min()
    w + path_weight(g, [v | rest])
  end

  # ── Johnson's algorithm ──────────────────────────────────────────────

  describe "johnson/1" do
    test "triangle: agrees with floyd_warshall" do
      g = triangle()
      {:ok, j} = APSP.johnson(g)
      {:ok, fw} = APSP.floyd_warshall(g)
      assert_dist_matrices_equal(j, fw)
    end

    test "K4: agrees with floyd_warshall and dijkstra_all" do
      g = k4()
      {:ok, j} = APSP.johnson(g)
      {:ok, fw} = APSP.floyd_warshall(g)
      assert_dist_matrices_equal(j, fw)
      assert_dist_matrices_equal(j, dijkstra_apsp(g))
    end

    test "handles negative edges via reweighting" do
      g = neg_edge_graph()
      {:ok, j} = APSP.johnson(g)
      {:ok, fw} = APSP.floyd_warshall(g)
      assert_dist_matrices_equal(j, fw)
      assert j[:a][:c] == 1.0
      assert j[:a][:d] == 3.0
    end

    test "detects negative cycle" do
      assert APSP.johnson(neg_cycle_graph()) == {:error, :negative_cycle}
    end

    test "empty graph" do
      assert {:ok, d} = APSP.johnson(Grafi.new())
      assert d == %{}
    end

    test "isolated vertices: each row has only the self-loop" do
      g = Grafi.new() |> Grafi.add_vertices([:a, :b, :c])
      {:ok, d} = APSP.johnson(g)
      assert d == %{a: %{a: 0.0}, b: %{b: 0.0}, c: %{c: 0.0}}
    end
  end

  # ── Transitive closure ──────────────────────────────────────────────

  describe "transitive_closure/1" do
    test "chain" do
      g = Grafi.new() |> Grafi.add_edges([{:a, :b}, {:b, :c}, {:c, :d}])
      tc = APSP.transitive_closure(g)
      assert MapSet.equal?(tc[:a], MapSet.new([:a, :b, :c, :d]))
      assert MapSet.equal?(tc[:b], MapSet.new([:b, :c, :d]))
      assert MapSet.equal?(tc[:c], MapSet.new([:c, :d]))
      assert MapSet.equal?(tc[:d], MapSet.new([:d]))
    end

    test "branching graph" do
      g =
        Grafi.new()
        |> Grafi.add_edges([
          {:r, :a},
          {:r, :b},
          {:a, :c},
          {:b, :c},
          {:c, :d}
        ])

      tc = APSP.transitive_closure(g)
      assert MapSet.equal?(tc[:r], MapSet.new([:r, :a, :b, :c, :d]))
      assert MapSet.equal?(tc[:a], MapSet.new([:a, :c, :d]))
      assert MapSet.equal?(tc[:d], MapSet.new([:d]))
    end

    test "disconnected components" do
      g = Grafi.new() |> Grafi.add_edges([{:a, :b}, {:c, :d}])
      tc = APSP.transitive_closure(g)
      refute MapSet.member?(tc[:a], :c)
      refute MapSet.member?(tc[:c], :a)
      assert MapSet.equal?(tc[:a], MapSet.new([:a, :b]))
      assert MapSet.equal?(tc[:c], MapSet.new([:c, :d]))
    end
  end

  # ── Property test ────────────────────────────────────────────────────

  # Endpoints and weights are drawn from StreamData generators (not
  # Enum.random/:rand) so failures shrink reproducibly. Weight w/100 with
  # w in 1..1001 gives a positive range of ~0.01..10.01.
  defp positive_weight_graph do
    gen all(
          # list_of + uniq: uniq_list_of gives up on the small atom pool.
          verts <-
            map(list_of(Generators.vertex_id(:atom), min_length: 1, max_length: 8), &Enum.uniq/1),
          raw <-
            list_of({member_of(verts), member_of(verts), integer(1..1001)}, max_length: 20)
        ) do
      edges = Enum.map(raw, fn {u, v, w} -> {u, v, weight: w / 100} end)
      Grafi.new() |> Grafi.add_vertices(verts) |> Grafi.add_edges(edges)
    end
  end

  # Negative weights without a negative cycle: w(u, v) = p[v] - p[u] + s
  # with slack s > 0, so every cycle weighs the sum of its slacks. The
  # potentials are sevenths, so the reweighting runs on rounded floats and
  # must still hand Dijkstra only non-negative costs.
  defp potential_weight_graph do
    gen all(
          verts <- map(list_of(integer(0..30), min_length: 1, max_length: 8), &Enum.uniq/1),
          potentials <- fixed_list(Enum.map(verts, fn _ -> integer(-50..50) end)),
          raw <- list_of({member_of(verts), member_of(verts), integer(1..20)}, max_length: 20)
        ) do
      p = verts |> Enum.zip(potentials) |> Map.new(fn {v, q} -> {v, q / 7} end)

      edges =
        Enum.map(raw, fn {u, v, s} -> {u, v, weight: p[v] - p[u] + s / 10} end)

      Grafi.new() |> Grafi.add_vertices(verts) |> Grafi.add_edges(edges)
    end
  end

  describe "property: floyd_warshall == johnson == dijkstra_all from each v" do
    property "agreement on random positive-weight graphs" do
      check all(g <- positive_weight_graph()) do
        {:ok, fw} = APSP.floyd_warshall(g)
        {:ok, jo} = APSP.johnson(g)
        dj = dijkstra_apsp(g)

        assert_dist_matrices_equal(fw, jo, 1.0e-6)
        assert_dist_matrices_equal(fw, dj, 1.0e-6)
      end
    end

    property "johnson agrees with floyd_warshall on negative weights without negative cycles" do
      check all(g <- potential_weight_graph()) do
        {:ok, fw} = APSP.floyd_warshall(g)
        {:ok, jo} = APSP.johnson(g)

        assert_dist_matrices_equal(fw, jo, 1.0e-6)
      end
    end
  end
end
