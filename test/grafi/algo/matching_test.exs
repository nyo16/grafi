defmodule Grafi.Algo.MatchingTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias Grafi.Algo.Matching
  alias Grafi.Graph

  doctest Grafi.Algo.Matching

  # ── Hopcroft–Karp ────────────────────────────────────────────────────

  describe "hopcroft_karp/3" do
    test "empty graph has matching size 0" do
      g = Graph.new(type: :undirected)
      assert {:ok, %{matching: m, size: 0}} = Matching.hopcroft_karp(g, [])
      assert m == %{}
    end

    test "single edge is a perfect matching of size 1" do
      g = Graph.new(type: :undirected) |> Graph.add_edge(:l, :r)
      assert {:ok, %{matching: m, size: 1}} = Matching.hopcroft_karp(g, [:l])
      assert m[:l] == :r
      assert m[:r] == :l
    end

    test "path P_4 has max matching size 2" do
      # 1 — 2 — 3 — 4; bipartition {1, 3} | {2, 4}.
      # Max matching {1—2, 3—4} of size 2 (not 1, which would be just {2—3}).
      g =
        Graph.new(type: :undirected)
        |> Graph.add_edges([{1, 2}, {2, 3}, {3, 4}])

      assert {:ok, %{matching: m, size: 2}} = Matching.hopcroft_karp(g, [1, 3])

      # Both left vertices matched, bidirectionally.
      assert m[1] in [2]
      assert m[3] in [4]
      assert m[m[1]] == 1
      assert m[m[3]] == 3
    end

    test "K_{3,3} has a perfect matching of size 3" do
      g =
        Graph.new(type: :undirected)
        |> Graph.add_edges(for(u <- [:u1, :u2, :u3], v <- [:v1, :v2, :v3], do: {u, v}))

      assert {:ok, %{matching: m, size: 3}} = Matching.hopcroft_karp(g, [:u1, :u2, :u3])

      # Each :u_i matched to a distinct :v_j.
      matched_vs = Enum.map([:u1, :u2, :u3], &Map.fetch!(m, &1))
      assert Enum.sort(matched_vs) == [:v1, :v2, :v3]

      # Bidirectional invariant.
      for u <- [:u1, :u2, :u3], do: assert(m[m[u]] == u)
    end

    test "K_{2,3} matches the smaller side (size 2)" do
      g =
        Graph.new(type: :undirected)
        |> Graph.add_edges(for(u <- [:u1, :u2], v <- [:v1, :v2, :v3], do: {u, v}))

      assert {:ok, %{size: 2, matching: m}} = Matching.hopcroft_karp(g, [:u1, :u2])

      assert Map.has_key?(m, :u1) and Map.has_key?(m, :u2)
      matched_vs = Enum.map([:u1, :u2], &Map.fetch!(m, &1))
      assert MapSet.new(matched_vs) |> MapSet.size() == 2
    end

    test "disconnected bipartite graph: matching sums over components" do
      # Component A: l1-r1, l1-r2, l2-r1  → matching of size 2.
      # Component B: l3-r3              → matching of size 1.
      # Total: 3.
      g =
        Graph.new(type: :undirected)
        |> Graph.add_edges([
          {:l1, :r1},
          {:l1, :r2},
          {:l2, :r1},
          {:l3, :r3}
        ])

      assert {:ok, %{size: 3, matching: m}} =
               Matching.hopcroft_karp(g, [:l1, :l2, :l3])

      assert Map.has_key?(m, :l1)
      assert Map.has_key?(m, :l2)
      assert m[:l3] == :r3
    end

    test "non-bipartite graph returns :not_bipartite" do
      # Triangle is not bipartite.
      g =
        Graph.new(type: :undirected)
        |> Graph.add_edges([{:a, :b}, {:b, :c}, {:c, :a}])

      assert {:error, :not_bipartite} = Matching.hopcroft_karp(g, [:a])
    end

    test "accepts a MapSet for left_side" do
      g = Graph.new(type: :undirected) |> Graph.add_edges([{:l1, :r1}, {:l2, :r2}])

      assert {:ok, %{size: 2}} =
               Matching.hopcroft_karp(g, MapSet.new([:l1, :l2]))
    end

    test "isolated left vertices stay unmatched" do
      g =
        Graph.new(type: :undirected)
        |> Graph.add_edge(:l1, :r1)
        |> Graph.add_vertex(:l2)

      assert {:ok, %{size: 1, matching: m}} = Matching.hopcroft_karp(g, [:l1, :l2])
      assert m[:l1] == :r1
      refute Map.has_key?(m, :l2)
    end

    test "matching has no two left vertices on the same right vertex (validity)" do
      g =
        Graph.new(type: :undirected)
        |> Graph.add_edges(for(u <- [:u1, :u2, :u3], v <- [:v1, :v2], do: {u, v}))

      assert {:ok, %{matching: m, size: size}} =
               Matching.hopcroft_karp(g, [:u1, :u2, :u3])

      assert size == 2

      matched_left = Enum.filter([:u1, :u2, :u3], &Map.has_key?(m, &1))
      rs = Enum.map(matched_left, &Map.fetch!(m, &1))
      assert length(Enum.uniq(rs)) == length(rs)
    end
  end

  # ── Hungarian ────────────────────────────────────────────────────────

  describe "hungarian/2" do
    test "trivial empty matrix" do
      assert {:ok, %{assignment: [], cost: 0, unmatched: []}} = Matching.hungarian([])
    end

    test "1×1 matrix" do
      assert {:ok, %{assignment: [0], cost: 7}} = Matching.hungarian([[7]])
    end

    test "3×3 sequential matrix: identity is optimal" do
      m = [[1, 2, 3], [4, 5, 6], [7, 8, 9]]
      assert {:ok, %{assignment: [0, 1, 2], cost: 15, unmatched: []}} = Matching.hungarian(m)
    end

    test "3×3 with unique off-diagonal optimum" do
      # Each row has a unique minimum-1 in a different column.
      m = [
        [5, 5, 1],
        [1, 5, 5],
        [5, 1, 5]
      ]

      assert {:ok, %{assignment: [2, 0, 1], cost: 3}} = Matching.hungarian(m)
    end

    test "4×4 textbook example (cost 49)" do
      # Classic Hungarian-method textbook matrix; optimal value 49.
      m = [
        [10, 19, 8, 15],
        [10, 18, 7, 17],
        [13, 16, 9, 14],
        [12, 19, 8, 18]
      ]

      assert {:ok, %{assignment: a, cost: 49}} = Matching.hungarian(m)
      assert length(a) == 4
      # Assignment must be a permutation of 0..3.
      assert Enum.sort(a) == [0, 1, 2, 3]
    end

    test "maximize flips the optimum" do
      # On [[1,2,3],[4,5,6],[7,8,9]] every permutation sums to 15, so use
      # a matrix where the maximum differs from the minimum.
      m = [
        [1, 4, 5],
        [5, 7, 6],
        [5, 8, 8]
      ]

      assert {:ok, %{cost: c_min}} = Matching.hungarian(m, maximize: false)
      assert {:ok, %{cost: c_max}} = Matching.hungarian(m, maximize: true)
      assert c_min < c_max

      # The maximum here is 4 + 6 + 8 = 18 (row 0 → 1, row 1 → 2, row 2 → 1?)
      # Verify by exhaustion.
      best =
        for a <- 0..2, b <- 0..2, c <- 0..2, length(Enum.uniq([a, b, c])) == 3 do
          Enum.at(Enum.at(m, 0), a) + Enum.at(Enum.at(m, 1), b) + Enum.at(Enum.at(m, 2), c)
        end

      assert c_max == Enum.max(best)
      assert c_min == Enum.min(best)
    end

    test "rectangular 2×3 (extra column): matches all rows" do
      m = [[3, 1, 2], [1, 4, 5]]
      assert {:ok, %{assignment: a, cost: c, unmatched: []}} = Matching.hungarian(m)
      assert length(a) == 2
      assert c == 2
      # No padded-column matches.
      assert Enum.all?(a, fn j -> not is_nil(j) and j < 3 end)
    end

    test "rectangular 3×2 (extra row): one row is unmatched" do
      m = [[1, 2], [3, 4], [5, 6]]
      assert {:ok, %{assignment: a, cost: c, unmatched: u}} = Matching.hungarian(m)
      assert length(a) == 3
      assert length(u) == 1
      assert Enum.at(a, hd(u)) == nil

      # The two matched rows must use distinct real columns; cost is their
      # sum.
      matched =
        a
        |> Enum.with_index()
        |> Enum.reject(fn {j, _} -> is_nil(j) end)

      cols = Enum.map(matched, &elem(&1, 0))
      assert length(Enum.uniq(cols)) == length(cols)

      assert c == Enum.sum(Enum.map(matched, fn {j, i} -> Enum.at(Enum.at(m, i), j) end))
    end

    property "for random square matrices, reported cost equals the assignment sum" do
      check all(
              n <- integer(1..5),
              rows <- list_of(list_of(integer(0..20), length: n), length: n)
            ) do
        {:ok, %{assignment: a, cost: c}} = Matching.hungarian(rows)
        assert length(a) == n
        # All entries are real (square matrix), so no nil.
        assert Enum.all?(a, &is_integer/1)
        # Assignment is a permutation of 0..n-1.
        assert Enum.sort(a) == Enum.to_list(0..(n - 1))

        # Sum back through the matrix matches the reported cost.
        sum =
          a
          |> Enum.with_index()
          |> Enum.reduce(0, fn {j, i}, acc -> acc + Enum.at(Enum.at(rows, i), j) end)

        assert sum == c
      end
    end

    property "reported cost is the true optimum (small brute-force check)" do
      check all(
              n <- integer(1..4),
              rows <- list_of(list_of(integer(0..15), length: n), length: n)
            ) do
        {:ok, %{cost: c}} = Matching.hungarian(rows)

        best =
          0..(n - 1)
          |> Enum.to_list()
          |> permutations()
          |> Enum.map(fn perm ->
            perm
            |> Enum.with_index()
            |> Enum.reduce(0, fn {j, i}, acc -> acc + Enum.at(Enum.at(rows, i), j) end)
          end)
          |> Enum.min()

        assert c == best
      end
    end

    # c[i][j] = i·j makes every row displace the previous ones, so each row
    # needs many scans. 8x the size takes about 350x as long (O(n³) bounds
    # it at 512x); the old element-wise `put_elem/3` updates took about
    # 2000x (O(n⁴)). Best of 3, after a GC.
    @tag :slow
    test "solve time grows as O(n³)" do
      best = fn n ->
        m = for i <- 1..n, do: for(j <- 1..n, do: i * j)

        Enum.min(
          for _ <- 1..3 do
            :erlang.garbage_collect()
            {t, {:ok, _}} = :timer.tc(fn -> Matching.hungarian(m) end)
            max(t, 1_000)
          end
        )
      end

      {t_small, t_large} = {best.(60), best.(480)}

      assert t_large < 1_000 * t_small,
             "8x the size took #{Float.round(t_large / t_small, 1)}x as long"
    end

    property "reported cost is the optimum of rectangular matrices up to 7×7" do
      check all(
              n_rows <- integer(1..7),
              n_cols <- integer(1..7),
              rows <- list_of(list_of(integer(-20..50), length: n_cols), length: n_rows),
              maximize <- boolean()
            ) do
        {:ok, %{assignment: a, cost: c, unmatched: u}} =
          Matching.hungarian(rows, maximize: maximize)

        matched = for {j, i} <- Enum.with_index(a), j != nil, do: {i, j}
        assert length(matched) == min(n_rows, n_cols)
        assert matched |> Enum.map(&elem(&1, 1)) |> Enum.uniq() |> length() == length(matched)
        assert u == for({nil, i} <- Enum.with_index(a), do: i)
        assert c == Enum.sum(for {i, j} <- matched, do: rows |> Enum.at(i) |> Enum.at(j))

        expected =
          if maximize,
            do: -best_assignment(Enum.map(rows, fn row -> Enum.map(row, &(-&1)) end)),
            else: best_assignment(rows)

        assert c == expected
      end
    end
  end

  # ── Weighted bipartite matching ──────────────────────────────────────

  describe "weighted_bipartite_matching/3" do
    test "small bipartite graph: max-weight matching is correct" do
      # l1—r1 (5), l1—r2 (1), l2—r1 (2), l2—r2 (4)
      # Max-weight perfect matching: l1—r1, l2—r2 = 9
      g =
        Graph.new(type: :undirected)
        |> Graph.add_edges([
          {:l1, :r1, weight: 5.0},
          {:l1, :r2, weight: 1.0},
          {:l2, :r1, weight: 2.0},
          {:l2, :r2, weight: 4.0}
        ])

      assert {:ok, %{matching: m, weight: 9.0}} =
               Matching.weighted_bipartite_matching(g, [:l1, :l2])

      assert m[:l1] == :r1
      assert m[:l2] == :r2
    end

    test "minimization flips the chosen pairs" do
      g =
        Graph.new(type: :undirected)
        |> Graph.add_edges([
          {:l1, :r1, weight: 5.0},
          {:l1, :r2, weight: 1.0},
          {:l2, :r1, weight: 2.0},
          {:l2, :r2, weight: 4.0}
        ])

      assert {:ok, %{matching: m, weight: 3.0}} =
               Matching.weighted_bipartite_matching(g, [:l1, :l2], maximize: false)

      assert m[:l1] == :r2
      assert m[:l2] == :r1
    end

    test "missing edges are not matched" do
      # Only l1—r1 and l2—r2 exist as edges; matching weight = 1 + 1.
      g =
        Graph.new(type: :undirected)
        |> Graph.add_edges([
          {:l1, :r1, weight: 1.0},
          {:l2, :r2, weight: 1.0}
        ])
        # Add r-vertex with no edges so it is part of the right side.
        |> Graph.add_vertex(:r3)

      assert {:ok, %{matching: m, weight: 2.0}} =
               Matching.weighted_bipartite_matching(g, [:l1, :l2])

      assert m[:l1] == :r1
      assert m[:l2] == :r2
      refute Map.has_key?(m, :r3)
    end

    test "empty graph returns empty matching" do
      g = Graph.new(type: :undirected)

      assert {:ok, %{matching: m, weight: w}} = Matching.weighted_bipartite_matching(g, [])
      assert m == %{}
      assert w == 0.0
    end

    test "uneven sides: more left than right, leaves one unmatched" do
      g =
        Graph.new(type: :undirected)
        |> Graph.add_edges([
          {:l1, :r1, weight: 3.0},
          {:l2, :r1, weight: 2.0},
          {:l3, :r1, weight: 1.0}
        ])

      assert {:ok, %{matching: m, weight: 3.0}} =
               Matching.weighted_bipartite_matching(g, [:l1, :l2, :l3])

      assert m[:l1] == :r1
      assert map_size(m) == 1
    end

    test "non-bipartite graph returns :not_bipartite" do
      g =
        Graph.new(type: :undirected)
        |> Graph.add_edges([{:a, :b}, {:b, :c}, {:c, :a}])

      assert {:error, :not_bipartite} =
               Matching.weighted_bipartite_matching(g, [:a])
    end
  end

  # ── Helpers ──────────────────────────────────────────────────────────

  # Minimum-cost assignment of min(rows, cols) pairs, by dynamic programming
  # over the sets of used columns (transposing so rows <= cols).
  defp best_assignment(rows) do
    rows = if length(rows) > length(hd(rows)), do: Enum.zip_with(rows, & &1), else: rows

    rows
    |> Enum.reduce(%{0 => 0}, fn row, dp ->
      for {mask, cost} <- dp,
          {c, j} <- Enum.with_index(row),
          Bitwise.band(mask, Bitwise.bsl(1, j)) == 0,
          reduce: %{} do
        acc -> Map.update(acc, Bitwise.bor(mask, Bitwise.bsl(1, j)), cost + c, &min(&1, cost + c))
      end
    end)
    |> Map.values()
    |> Enum.min()
  end

  defp permutations([]), do: [[]]

  defp permutations(list) do
    for x <- list, rest <- permutations(list -- [x]), do: [x | rest]
  end
end
