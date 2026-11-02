defmodule Grafi.Algo.LinkPredictionTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias Grafi.Algo.LinkPrediction
  alias Grafi.Graph

  doctest Grafi.Algo.LinkPrediction

  defp p4 do
    # a — b — c — d
    Graph.new(type: :undirected)
    |> Graph.add_edges([{:a, :b}, {:b, :c}, {:c, :d}])
  end

  defp triangle do
    Graph.new(type: :undirected)
    |> Graph.add_edges([{:a, :b}, {:b, :c}, {:c, :a}])
  end

  describe "Jaccard" do
    test "triangle has no non-edges — default candidates yield empty map" do
      assert LinkPrediction.jaccard(triangle()) == %{}
    end

    test "path P_4: Jaccard(a, c) = 1/2" do
      scores = LinkPrediction.jaccard(p4(), [{:a, :c}])
      assert_in_delta scores[{:a, :c}], 0.5, 1.0e-9
    end

    test "isolated pair yields 0 (empty union)" do
      g = Graph.new() |> Graph.add_vertices([:x, :y])
      scores = LinkPrediction.jaccard(g, [{:x, :y}])
      assert scores[{:x, :y}] == 0.0
    end

    test "default candidates skip already-adjacent pairs" do
      scores = LinkPrediction.jaccard(p4())
      # {:a, :b}, {:b, :c}, {:c, :d} are edges → excluded.
      # Non-edges: {:a, :c}, {:a, :d}, {:b, :d}
      assert MapSet.new(Map.keys(scores)) ==
               MapSet.new([{:a, :c}, {:a, :d}, {:b, :d}])
    end
  end

  describe "Adamic-Adar" do
    test "path P_4: AA(a, c) = 1 / log(2)" do
      scores = LinkPrediction.adamic_adar(p4(), [{:a, :c}])
      assert_in_delta scores[{:a, :c}], 1.0 / :math.log(2), 1.0e-9
    end

    test "common neighbor with degree ≤ 1 is skipped" do
      # b has only the neighbor a → degree 1 → skipped.
      g = Graph.new(type: :undirected) |> Graph.add_edges([{:a, :b}])
      # Add another vertex c also connected only to b: degrees b=2, a=1, c=1.
      g = g |> Graph.add_edge(:b, :c)
      # Score for (a, c): common neighbor is b with degree 2 → 1/log(2).
      scores = LinkPrediction.adamic_adar(g, [{:a, :c}])
      assert_in_delta scores[{:a, :c}], 1.0 / :math.log(2), 1.0e-9
    end
  end

  describe "resource allocation" do
    test "path P_4: RA(a, c) = 1 / degree(b) = 1/2" do
      scores = LinkPrediction.resource_allocation(p4(), [{:a, :c}])
      assert_in_delta scores[{:a, :c}], 0.5, 1.0e-9
    end

    test "no common neighbors → 0" do
      g =
        Graph.new(type: :undirected)
        |> Graph.add_edges([{:a, :b}, {:c, :d}])

      scores = LinkPrediction.resource_allocation(g, [{:a, :c}])
      assert scores[{:a, :c}] == 0.0
    end
  end

  describe "preferential attachment" do
    test "path P_4: PA(a, d) = 1 × 1 = 1" do
      scores = LinkPrediction.preferential_attachment(p4(), [{:a, :d}])
      assert scores[{:a, :d}] == 1.0
    end

    test "star K_{1,3}: PA(leaf, leaf) = 1 × 1; PA(center, missing) excluded" do
      g =
        Graph.new(type: :undirected)
        |> Graph.add_edges([{:c, :x}, {:c, :y}, {:c, :z}])

      scores = LinkPrediction.preferential_attachment(g, [{:x, :y}])
      assert scores[{:x, :y}] == 1.0
    end
  end

  describe "top_k/2" do
    test "returns top-2 in descending score order" do
      scores = %{{:a, :b} => 0.1, {:c, :d} => 0.5, {:e, :f} => 0.3}
      assert LinkPrediction.top_k(scores, 2) == [{{:c, :d}, 0.5}, {{:e, :f}, 0.3}]
    end

    test "k larger than map returns everything" do
      scores = %{{:a, :b} => 1.0}
      assert LinkPrediction.top_k(scores, 10) == [{{:a, :b}, 1.0}]
    end

    test "k = 0 returns empty list" do
      scores = %{{:a, :b} => 1.0}
      assert LinkPrediction.top_k(scores, 0) == []
    end
  end

  describe "properties" do
    property "Jaccard scores live in [0, 1] and are symmetric in u/v" do
      check all(
              n <- integer(3..6),
              edges <- list_of(tuple({integer(0..(n - 1)), integer(0..(n - 1))}), max_length: 8)
            ) do
        edges = edges |> Enum.reject(fn {u, v} -> u == v end) |> Enum.uniq()

        g =
          Enum.reduce(
            edges,
            Graph.new(type: :undirected) |> Graph.add_vertices(0..(n - 1) |> Enum.to_list()),
            fn {u, v}, acc ->
              Graph.add_edge(acc, u, v)
            end
          )

        vs = Graph.vertices(g)

        candidates =
          for u <- vs, v <- vs, u < v, not Graph.has_edge?(g, u, v), do: {u, v}

        scores_uv = LinkPrediction.jaccard(g, candidates)
        scores_vu = LinkPrediction.jaccard(g, Enum.map(candidates, fn {u, v} -> {v, u} end))

        assert Enum.all?(Map.values(scores_uv), fn s -> s >= 0.0 and s <= 1.0 end)

        for {u, v} <- candidates do
          assert_in_delta scores_uv[{u, v}], scores_vu[{v, u}], 1.0e-12
        end
      end
    end
  end

  describe "scaling" do
    # Neighbour sets and degrees are built once, so scoring all leaf pairs
    # of a star is O(pairs): 4x the leaves gives 16x the pairs and about
    # 16x the time. The old code rebuilt the centre's neighbourhood for
    # every pair, O(pairs · leaves) (64x). Best of 3.
    @tag :slow
    test "scoring every non-adjacent pair of a star is linear in the pairs" do
      # One input alive at a time, so timed runs don't GC the other.
      best = fn n ->
        g = Enum.reduce(1..n, Graph.new(type: :undirected), &Graph.add_edge(&2, 0, &1))
        scores = LinkPrediction.adamic_adar(g)
        assert map_size(scores) == div(n * (n - 1), 2)
        assert_in_delta scores[{1, 2}], 1 / :math.log(n), 1.0e-12

        Enum.min(
          for _ <- 1..3 do
            :erlang.garbage_collect()
            elem(:timer.tc(LinkPrediction, :adamic_adar, [g]), 0)
          end
        )
      end

      {t_small, t_large} = {best.(100), best.(400)}
      assert t_large < 32 * t_small, "16x the pairs took #{Float.round(t_large / t_small, 1)}x"
    end
  end
end
