defmodule Grafi.Algo.CyclesTest do
  use ExUnit.Case, async: true
  doctest Grafi.Algo.Cycles

  alias Grafi.Algo.Cycles
  alias Grafi.Graph

  defp closed_walk?(g, [first | _] = cycle) do
    List.last(cycle) == first and
      Enum.all?(Enum.zip(cycle, tl(cycle)), fn {u, v} -> Graph.has_edge?(g, u, v) end)
  end

  describe "undirected cycles" do
    test "a single edge is not a cycle" do
      g = Graph.new(type: :undirected) |> Graph.add_edge(:a, :b)
      refute Cycles.has_cycle?(g)
      assert Cycles.find_cycle(g) == {:error, :no_cycle}
    end

    test "a tree is not a cycle" do
      g = Grafi.Generators.path(6, type: :undirected) |> Graph.add_edge(2, 10)
      refute Cycles.has_cycle?(g)
    end

    test "a triangle is a cycle" do
      g = Graph.new(type: :undirected) |> Graph.add_edges([{:a, :b}, {:b, :c}, {:c, :a}])
      assert Cycles.has_cycle?(g)
      assert {:ok, cycle} = Cycles.find_cycle(g)
      assert length(cycle) == 4
      assert closed_walk?(g, cycle)
    end

    test "a parallel pair is a cycle" do
      g = Graph.new(type: :undirected) |> Graph.add_edge(:a, :b) |> Graph.add_edge(:a, :b)
      assert Cycles.has_cycle?(g)
      assert {:ok, [_, _, _] = cycle} = Cycles.find_cycle(g)
      assert closed_walk?(g, cycle)
    end

    test "a self-loop is a cycle" do
      g = Graph.new(type: :undirected) |> Graph.add_edge(:a, :a)
      assert Cycles.find_cycle(g) == {:ok, [:a, :a]}
    end
  end

  describe "find_cycle/1 on directed graphs" do
    test "returns {:error, :no_cycle} for a DAG" do
      g = Graph.new() |> Graph.add_edges([{:a, :b}, {:b, :c}, {:a, :c}])
      assert Cycles.find_cycle(g) == {:error, :no_cycle}
    end

    test "returns a closed walk along real edges" do
      g = Graph.new() |> Graph.add_edges([{:x, :a}, {:a, :b}, {:b, :c}, {:c, :a}])
      assert {:ok, cycle} = Cycles.find_cycle(g)
      assert Enum.sort(tl(cycle)) == [:a, :b, :c]
      assert closed_walk?(g, cycle)
    end
  end

  describe "connected_components/1" do
    test "directed graphs use weak connectivity" do
      g = Graph.new() |> Graph.add_edges([{:b, :a}, {:c, :a}])
      assert Cycles.connected_components(g) == [[:a, :b, :c]]
      assert Grafi.components(g) == [[:a, :b, :c]]
    end

    test "output is canonical" do
      g = Graph.new() |> Graph.add_edges([{:z, :y}, {:d, :c}, {:b, :a}]) |> Graph.add_vertex(:m)
      assert Cycles.connected_components(g) == [[:a, :b], [:c, :d], [:m], [:y, :z]]
    end
  end

  describe "condensation/1" do
    test "vertices are integer SCC indices labelled with sorted members" do
      g = Graph.new() |> Graph.add_edges([{:c, :b}, {:b, :c}, {:a, :b}, {:c, :d}])
      cg = Cycles.condensation(g)

      assert Enum.sort(Graph.vertices(cg)) == [0, 1, 2]
      assert Enum.map(0..2, &Graph.label(cg, &1)) == [[:a], [:b, :c], [:d]]
      assert cg |> Graph.edges() |> Enum.map(&{&1.from, &1.to}) |> Enum.sort() == [{0, 1}, {1, 2}]
    end
  end

  describe "strongly_connected_components/2" do
    test "rejects unknown options" do
      assert_raise ArgumentError, fn ->
        Cycles.strongly_connected_components(Graph.new(), bogus: 1)
      end
    end
  end
end
