defmodule Grafi.Algo.KShortestPathTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  doctest Grafi.Algo.KShortestPath

  alias Grafi.Algo.KShortestPath
  alias Grafi.Graph

  # ── Helpers ───────────────────────────────────────────────────────────

  defp loopless?(path), do: length(path) == path |> MapSet.new() |> MapSet.size()

  defp valid_path?(g, [only]), do: Graph.has_vertex?(g, only)

  defp valid_path?(g, [u, v | rest]) do
    Graph.has_edge?(g, u, v) and valid_path?(g, [v | rest])
  end

  defp valid_path?(_g, []), do: true

  defp path_weight(_g, [_only]), do: 0.0

  defp path_weight(g, [u, v | rest]) do
    w = g |> Graph.edges_between(u, v) |> Enum.map(& &1.weight) |> Enum.min()
    w + path_weight(g, [v | rest])
  end

  defp path_weight(_g, []), do: 0.0

  # Build a random small graph on n vertices with random positive weights.
  defp random_graph(n, edge_prob, seed, type \\ :directed) when n > 0 do
    :rand.seed(:exsss, {seed, seed + 1, seed + 2})
    verts = Enum.to_list(0..(n - 1))
    g0 = Graph.new(type: type) |> Graph.add_vertices(verts)

    for u <- verts, v <- verts, u != v, type == :directed or u < v, reduce: g0 do
      acc ->
        if :rand.uniform() < edge_prob do
          Graph.add_edge(acc, u, v, weight: :rand.uniform(20) / 1)
        else
          acc
        end
    end
  end

  # Every simple path from the head of `rev` to `target`, by exhaustive DFS.
  defp simple_paths(_g, target, [target | _] = rev, _seen), do: [Enum.reverse(rev)]

  defp simple_paths(g, target, [u | _] = rev, seen) do
    for v <- Graph.out_neighbors(g, u),
        not MapSet.member?(seen, v),
        path <- simple_paths(g, target, [v | rev], MapSet.put(seen, v)),
        do: path
  end

  # ── Basic correctness ────────────────────────────────────────────────

  describe "yen/5" do
    test "single-path graph: returns just one path" do
      g =
        Graph.new()
        |> Graph.add_edges([
          {:a, :b, weight: 1.0},
          {:b, :c, weight: 1.0}
        ])

      assert {:ok, results} = KShortestPath.yen(g, :a, :c, 3)
      assert length(results) == 1
      assert [{[:a, :b, :c], 2.0}] = results
    end

    test "diamond a→b→d, a→c→d with k=2 returns both paths in order" do
      g =
        Graph.new()
        |> Graph.add_edges([
          {:a, :b, weight: 1.0},
          {:b, :d, weight: 1.0},
          {:a, :c, weight: 2.0},
          {:c, :d, weight: 2.0}
        ])

      assert {:ok, [{p1, w1}, {p2, w2}]} = KShortestPath.yen(g, :a, :d, 2)
      assert p1 == [:a, :b, :d]
      assert w1 == 2.0
      assert p2 == [:a, :c, :d]
      assert w2 == 4.0
    end

    test "undirected diamond a–b–d, a–c–d with k=2 returns both paths" do
      g =
        Graph.new(type: :undirected)
        |> Graph.add_edges([
          {:a, :b, weight: 1.0},
          {:b, :d, weight: 1.0},
          {:a, :c, weight: 2.0},
          {:c, :d, weight: 2.0}
        ])

      assert KShortestPath.yen(g, :a, :d, 2) ==
               {:ok, [{[:a, :b, :d], 2.0}, {[:a, :c, :d], 4.0}]}
    end

    test "undirected: a forbidden edge stays forbidden in both directions" do
      # Square a–b–d–c–a plus the chord b–c. Four simple a→d paths exist.
      g =
        Graph.new(type: :undirected)
        |> Graph.add_edges([
          {:a, :b, weight: 1.0},
          {:b, :d, weight: 1.0},
          {:a, :c, weight: 2.0},
          {:c, :d, weight: 2.0},
          {:b, :c, weight: 1.0}
        ])

      assert {:ok, results} = KShortestPath.yen(g, :a, :d, 10)

      assert Enum.sort(results) ==
               Enum.sort([
                 {[:a, :b, :d], 2.0},
                 {[:a, :c, :d], 4.0},
                 {[:a, :b, :c, :d], 4.0},
                 {[:a, :c, :b, :d], 4.0}
               ])
    end

    test "negative weights: {:error, :negative_weight}" do
      g = Graph.new() |> Graph.add_edge(:a, :b, weight: -1.0)
      assert KShortestPath.yen(g, :a, :b, 2) == {:error, :negative_weight}
    end

    test "unknown options raise ArgumentError" do
      g = Graph.new() |> Graph.add_edge(:a, :b)

      assert_raise ArgumentError, ~r/unknown keys \[:engine\]/, fn ->
        KShortestPath.yen(g, :a, :b, 2, engine: :elixir)
      end
    end

    test "5-vertex graph, top 3 paths in ascending weight order" do
      # source :s -> :a -> :t (cheap), :s -> :b -> :t, :s -> :c -> :t (expensive)
      g =
        Graph.new()
        |> Graph.add_edges([
          {:s, :a, weight: 1.0},
          {:a, :t, weight: 1.0},
          {:s, :b, weight: 2.0},
          {:b, :t, weight: 2.0},
          {:s, :c, weight: 3.0},
          {:c, :t, weight: 3.0}
        ])

      assert {:ok, results} = KShortestPath.yen(g, :s, :t, 3)
      assert length(results) == 3
      weights = Enum.map(results, fn {_, w} -> w end)
      assert weights == Enum.sort(weights)
      assert weights == [2.0, 4.0, 6.0]

      # All distinct paths
      paths = Enum.map(results, fn {p, _} -> p end)
      assert length(Enum.uniq(paths)) == 3
    end

    test "no path: returns {:error, :no_path}" do
      g = Graph.new() |> Graph.add_vertices([:a, :b])
      assert {:error, :no_path} = KShortestPath.yen(g, :a, :b, 3)
    end

    test "missing source: {:error, :no_such_vertex}" do
      g = Graph.new() |> Graph.add_vertex(:b)
      assert {:error, :no_such_vertex} = KShortestPath.yen(g, :a, :b, 1)
    end

    test "missing target: {:error, :no_such_vertex}" do
      g = Graph.new() |> Graph.add_vertex(:a)
      assert {:error, :no_such_vertex} = KShortestPath.yen(g, :a, :b, 1)
    end

    test "source == target: returns trivial path" do
      g = Graph.new() |> Graph.add_vertex(:a)
      assert {:ok, [{[:a], w}]} = KShortestPath.yen(g, :a, :a, 3)
      assert w == 0.0
    end

    test "cyclic graph: returned paths are loopless" do
      # a -> b -> c -> a (cycle), plus c -> d
      g =
        Graph.new()
        |> Graph.add_edges([
          {:a, :b, weight: 1.0},
          {:b, :c, weight: 1.0},
          {:c, :a, weight: 1.0},
          {:c, :d, weight: 1.0},
          {:a, :d, weight: 10.0}
        ])

      assert {:ok, results} = KShortestPath.yen(g, :a, :d, 5)

      for {path, _w} <- results do
        assert loopless?(path), "got non-loopless path: #{inspect(path)}"
      end
    end

    test "k larger than number of loopless paths: returns all available" do
      g =
        Graph.new()
        |> Graph.add_edges([
          {:a, :b, weight: 1.0},
          {:b, :c, weight: 1.0}
        ])

      assert {:ok, results} = KShortestPath.yen(g, :a, :c, 10)
      assert length(results) == 1
    end

    test "results are in ascending weight order" do
      g =
        Graph.new()
        |> Graph.add_edges([
          {:a, :b, weight: 1.0},
          {:a, :c, weight: 5.0},
          {:a, :d, weight: 3.0},
          {:b, :z, weight: 10.0},
          {:c, :z, weight: 1.0},
          {:d, :z, weight: 4.0}
        ])

      assert {:ok, results} = KShortestPath.yen(g, :a, :z, 3)
      weights = Enum.map(results, fn {_, w} -> w end)
      assert weights == Enum.sort(weights)
    end
  end

  # ── Property tests ────────────────────────────────────────────────────

  describe "properties" do
    property "every returned path is loopless and traversable in the graph" do
      check all(
              n <- integer(3..7),
              prob <- float(min: 0.2, max: 0.7),
              k <- integer(1..5),
              seed <- integer(1..10_000)
            ) do
        g = random_graph(n, prob, seed)
        src = 0
        tgt = n - 1

        case KShortestPath.yen(g, src, tgt, k) do
          {:ok, results} ->
            for {path, w} <- results do
              assert loopless?(path), "non-loopless: #{inspect(path)}"
              assert valid_path?(g, path), "invalid path: #{inspect(path)}"
              assert hd(path) == src
              assert List.last(path) == tgt
              # Computed weight matches the reported weight.
              assert_in_delta path_weight(g, path), w, 1.0e-9
            end

            # Sorted by weight ascending.
            weights = Enum.map(results, fn {_, w} -> w end)
            assert weights == Enum.sort(weights)

          {:error, :no_path} ->
            :ok
        end
      end
    end

    property "returns the k lightest simple paths (directed and undirected)" do
      check all(
              type <- member_of([:directed, :undirected]),
              n <- integer(3..6),
              prob <- float(min: 0.2, max: 0.8),
              k <- integer(1..6),
              seed <- integer(1..10_000)
            ) do
        g = random_graph(n, prob, seed, type)
        {src, tgt} = {0, n - 1}

        expected =
          g
          |> simple_paths(tgt, [src], MapSet.new([src]))
          |> Enum.map(&path_weight(g, &1))
          |> Enum.sort()
          |> Enum.take(k)

        case KShortestPath.yen(g, src, tgt, k) do
          {:ok, results} ->
            assert Enum.map(results, &elem(&1, 1)) == expected
            assert results |> Enum.map(&elem(&1, 0)) |> Enum.uniq() |> length() == length(results)

          {:error, :no_path} ->
            assert expected == []
        end
      end
    end
  end
end
