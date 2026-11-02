defmodule Grafi.Algo.TraversalTest do
  use ExUnit.Case, async: true
  doctest Grafi.Algo.Traversal

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

  describe "missing vertices" do
    test "bfs, dfs and dfs_post raise for a missing start" do
      g = line_graph()

      for f <- [&Traversal.bfs/2, &Traversal.dfs/2, &Traversal.dfs_post/2, &Traversal.weak_bfs/2] do
        assert_raise ArgumentError, ~r/not in the graph/, fn -> f.(g, :zz) end
      end
    end

    test "reachable? raises for a missing source or target" do
      g = line_graph()
      assert_raise ArgumentError, ~r/not in the graph/, fn -> Traversal.reachable?(g, :zz, :a) end
      assert_raise ArgumentError, ~r/not in the graph/, fn -> Traversal.reachable?(g, :a, :zz) end
    end

    test "reachable_from raises for a missing source" do
      assert_raise ArgumentError, ~r/not in the graph/, fn ->
        Traversal.reachable_from(line_graph(), :zz)
      end
    end
  end

  describe "weak_bfs/2" do
    test "follows edges in both directions" do
      g = Graph.new() |> Graph.add_edges([{:b, :a}, {:c, :a}])
      assert g |> Traversal.weak_bfs(:b) |> Enum.sort() == [:a, :b, :c]
    end
  end

  describe "topological_sort/1" do
    test "breaks ties by vertex term order" do
      g = Graph.new() |> Graph.add_edges([{:z, :m}, {:y, :m}, {:x, :a}, {:a, :m}])
      assert Traversal.topological_sort(g) == {:ok, [:x, :y, :z, :a, :m]}
    end

    test "reports a cycle" do
      g = Graph.new() |> Graph.add_edges([{:a, :b}, {:b, :a}])
      assert Traversal.topological_sort(g) == {:error, :has_cycle}
    end

    test "orders every vertex of a random DAG after its predecessors" do
      er = Grafi.Generators.erdos_renyi(40, 0.1, seed: 7)
      # Keep only edges i -> j with j > i, but relabel so term order != topo order.
      g =
        er
        |> Graph.edges()
        |> Enum.filter(&(&1.from < &1.to))
        |> Enum.reduce(Graph.add_vertices(Graph.new(), Enum.map(0..39, &(-&1))), fn e, acc ->
          Graph.add_edge(acc, -e.to, -e.from)
        end)

      assert {:ok, order} = Traversal.topological_sort(g)
      pos = order |> Enum.with_index() |> Map.new()
      assert map_size(pos) == Graph.num_vertices(g)
      assert Enum.all?(Graph.edges(g), &(pos[&1.from] < pos[&1.to]))
    end
  end

  defp index(list, elem), do: Enum.find_index(list, &(&1 == elem))
end
