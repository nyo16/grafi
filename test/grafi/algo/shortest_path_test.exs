defmodule Grafi.Algo.ShortestPathTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  doctest Grafi.Algo.ShortestPath

  alias Grafi.Algo.ShortestPath
  alias Grafi.Graph

  # ── Helpers ───────────────────────────────────────────────────────────

  # A directed path 0 → 1 → … → n-1.
  defp path_graph(n) do
    Enum.reduce(1..(n - 1)//1, Graph.new() |> Graph.add_vertex(0), fn i, g ->
      Graph.add_edge(g, i - 1, i, weight: 1.0)
    end)
  end

  defp best_time(fun) do
    :erlang.garbage_collect()
    Enum.min(for _ <- 1..3, do: elem(:timer.tc(fun), 0))
  end

  # ── dijkstra/4 ────────────────────────────────────────────────────────

  describe "dijkstra/4" do
    test "undirected edges are relaxed in both directions" do
      g =
        Graph.new(type: :undirected)
        |> Graph.add_edges([{:a, :b, weight: 1.0}, {:b, :c, weight: 1.0}, {:a, :c, weight: 5.0}])

      assert ShortestPath.dijkstra(g, :c, :a, engine: :elixir) == {:ok, {[:c, :b, :a], 2.0}}
      assert ShortestPath.dijkstra(g, :a, :c, engine: :elixir) == {:ok, {[:a, :b, :c], 2.0}}
    end

    # A near target costs only what is closer than it; the base engine
    # settled the whole graph whatever the target.
    @tag :slow
    test "the Elixir engine stops once the target is settled" do
      n = 20_000
      g = path_graph(n)

      t_near = best_time(fn -> ShortestPath.dijkstra(g, 0, 1, engine: :elixir) end)
      t_far = best_time(fn -> ShortestPath.dijkstra(g, 0, n - 1, engine: :elixir) end)

      assert 3 * t_near < t_far, "near target #{t_near} µs vs far target #{t_far} µs"
    end
  end

  # ── dijkstra_all/3 ────────────────────────────────────────────────────

  describe "dijkstra_all/3" do
    test "costs each edge with the weight fn; the cheapest parallel edge wins" do
      g =
        Graph.new()
        |> Graph.add_edge(:a, :b, weight: 1.0, label: :road)
        |> Graph.add_edge(:a, :b, weight: 9.0, label: :rail)
        |> Graph.add_edge(:b, :c, weight: 1.0, label: :road)

      fare = fn
        %{label: :rail} -> 0.5
        %{weight: w} -> w * 10
      end

      assert ShortestPath.dijkstra_all(g, :a, fare) == %{a: 0.0, b: 0.5, c: 10.5}
      assert ShortestPath.dijkstra_all(g, :a) == %{a: 0.0, b: 1.0, c: 2.0}
    end

    test "undirected edges reach back to the source side" do
      g = Graph.new(type: :undirected) |> Graph.add_edge(:a, :b, weight: 2.0)
      assert ShortestPath.dijkstra_all(g, :b, & &1.weight) == %{a: 2.0, b: 0.0}
    end
  end
end
