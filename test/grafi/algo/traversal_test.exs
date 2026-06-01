defmodule Grafi.Algo.TraversalTest do
  use ExUnit.Case, async: true

  alias Grafi.Algo.Traversal
  alias Grafi.Graph

  defp line_graph do
    # a -> b -> c -> d
    Graph.new() |> Graph.add_edges([{:a, :b}, {:b, :c}, {:c, :d}])
  end

  describe "bfs/2" do
    test "emits the start vertex first" do
      g = line_graph()
      assert [:a | _] = Enum.to_list(Traversal.bfs(g, :a))
    end

    test "visits every reachable vertex exactly once" do
      g = line_graph()
      order = Enum.to_list(Traversal.bfs(g, :a))
      assert Enum.sort(order) == [:a, :b, :c, :d]
      assert length(order) == length(Enum.uniq(order))
    end

    test "breadth-first order: closer vertices come before farther ones" do
      # a -> b, a -> c, b -> d
      g = Graph.new() |> Graph.add_edges([{:a, :b}, {:a, :c}, {:b, :d}])
      order = Enum.to_list(Traversal.bfs(g, :a))

      assert hd(order) == :a
      assert index(order, :b) < index(order, :d)
      assert index(order, :c) < index(order, :d)
    end

    test "follows out-edges only (direction matters)" do
      g = line_graph()
      # Nothing is reachable from :d going forward.
      assert Enum.to_list(Traversal.bfs(g, :d)) == [:d]
    end

    test "is lazy — can take a prefix of an unbounded-looking walk" do
      g = Graph.new() |> Graph.add_edges([{:a, :b}, {:b, :c}, {:c, :d}])
      assert Traversal.bfs(g, :a) |> Enum.take(2) == [:a, :b]
    end
  end

  describe "dfs/2" do
    test "emits the start vertex first and visits each once" do
      g = line_graph()
      order = Enum.to_list(Traversal.dfs(g, :a))
      assert hd(order) == :a
      assert Enum.sort(order) == [:a, :b, :c, :d]
      assert length(order) == length(Enum.uniq(order))
    end

    test "goes deep before wide" do
      # a -> b -> c ; a -> d
      g = Graph.new() |> Graph.add_edges([{:a, :b}, {:b, :c}, {:a, :d}])
      order = Enum.to_list(Traversal.dfs(g, :a))
      # b's subtree (c) is fully explored before backtracking; b precedes c.
      assert index(order, :b) < index(order, :c)
    end
  end

  describe "dfs_post/2" do
    test "returns reverse post-order: a parent precedes its descendants" do
      g = line_graph()
      post = Traversal.dfs_post(g, :a)
      assert post == [:a, :b, :c, :d]
      assert index(post, :a) < index(post, :b)
      assert index(post, :b) < index(post, :c)
      assert index(post, :c) < index(post, :d)
    end

    test "is a valid topological order for a DAG" do
      # a -> b -> d, a -> c -> d
      g = Graph.new() |> Graph.add_edges([{:a, :b}, {:b, :d}, {:a, :c}, {:c, :d}])
      post = Traversal.dfs_post(g, :a)

      # Every edge u -> v must have u before v in the ordering.
      for {u, v} <- [{:a, :b}, {:b, :d}, {:a, :c}, {:c, :d}] do
        assert index(post, u) < index(post, v),
               "expected #{u} before #{v} in #{inspect(post)}"
      end
    end
  end

  describe "reachable?/3 and reachable_from/2" do
    test "reachable? respects edge direction" do
      g = line_graph()
      assert Traversal.reachable?(g, :a, :d)
      refute Traversal.reachable?(g, :d, :a)
    end

    test "reachable_from includes the source and all descendants" do
      g = line_graph()
      assert Traversal.reachable_from(g, :b) == MapSet.new([:b, :c, :d])
    end

    test "a vertex reaches itself" do
      g = line_graph()
      assert Traversal.reachable?(g, :a, :a)
    end
  end

  defp index(list, elem), do: Enum.find_index(list, &(&1 == elem))
end
