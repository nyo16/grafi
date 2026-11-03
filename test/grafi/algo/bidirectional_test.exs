defmodule Grafi.Algo.BidirectionalTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  doctest Grafi.Algo.Bidirectional

  alias Grafi.Algo.Bidirectional
  alias Grafi.Algo.ShortestPath
  alias Grafi.Graph

  # ── Helpers ───────────────────────────────────────────────────────────

  defp random_graph(n, edge_prob, seed) when n > 0 do
    :rand.seed(:exsss, {seed, seed + 1, seed + 2})
    verts = Enum.to_list(0..(n - 1))
    g0 = Graph.new(type: :directed) |> Graph.add_vertices(verts)

    for u <- verts, v <- verts, u != v, reduce: g0 do
      acc ->
        if :rand.uniform() < edge_prob do
          Graph.add_edge(acc, u, v, weight: :rand.uniform(20) / 1)
        else
          acc
        end
    end
  end

  defp path_weight(_g, [_only]), do: 0.0

  defp path_weight(g, [u, v | rest]) do
    w = g |> Graph.edges_between(u, v) |> Enum.map(& &1.weight) |> Enum.min()
    w + path_weight(g, [v | rest])
  end

  defp path_weight(_g, []), do: 0.0

  defp valid_path?(_g, [_only]), do: true
  defp valid_path?(g, [u, v | rest]), do: Graph.has_edge?(g, u, v) and valid_path?(g, [v | rest])
  defp valid_path?(_g, []), do: true

  # ── Basic ─────────────────────────────────────────────────────────────

  describe "dijkstra/4" do
    test "vertex ids compare strictly: 1 and 1.0 are distinct" do
      g = Graph.new() |> Graph.add_edges([{1, 1.0, weight: 2.0}])
      assert Grafi.Algo.Bidirectional.dijkstra(g, 1, 1.0) == {:ok, {[1, 1.0], 2.0}}
      assert Grafi.Algo.Bidirectional.dijkstra(g, 1.0, 1) == {:error, :no_path}
    end

    test "matches classical Dijkstra weight on a small directed graph" do
      g =
        Graph.new()
        |> Graph.add_edges([
          {:a, :b, weight: 1.0},
          {:b, :c, weight: 2.0},
          {:a, :c, weight: 5.0},
          {:c, :d, weight: 1.0}
        ])

      assert {:ok, {path, w}} = Bidirectional.dijkstra(g, :a, :d)
      assert {:ok, {_classic_path, classic_w}} = ShortestPath.dijkstra(g, :a, :d)
      assert w == classic_w
      assert hd(path) == :a
      assert List.last(path) == :d
      assert valid_path?(g, path)
    end

    test "matches classical Dijkstra on an undirected graph" do
      g =
        Graph.new(type: :undirected)
        |> Graph.add_edges([
          {:a, :b, weight: 1.0},
          {:b, :c, weight: 2.0},
          {:a, :c, weight: 5.0},
          {:c, :d, weight: 1.0}
        ])

      assert {:ok, {_, w}} = Bidirectional.dijkstra(g, :a, :d)
      assert {:ok, {_, classic_w}} = ShortestPath.dijkstra(g, :a, :d)
      assert w == classic_w
    end

    test "{:error, :no_path} when disconnected" do
      g = Graph.new() |> Graph.add_vertices([:a, :b])
      assert {:error, :no_path} = Bidirectional.dijkstra(g, :a, :b)
    end

    test "unknown options raise ArgumentError" do
      g = Graph.new() |> Graph.add_edge(:a, :b)

      assert_raise ArgumentError, ~r/unknown keys \[:engine\]/, fn ->
        Bidirectional.dijkstra(g, :a, :b, engine: :elixir)
      end
    end

    test "{:error, :no_such_vertex} when source missing" do
      g = Graph.new() |> Graph.add_vertex(:b)
      assert {:error, :no_such_vertex} = Bidirectional.dijkstra(g, :a, :b)
    end

    test "{:error, :no_such_vertex} when target missing" do
      g = Graph.new() |> Graph.add_vertex(:a)
      assert {:error, :no_such_vertex} = Bidirectional.dijkstra(g, :a, :b)
    end

    test "source == target returns trivial path with weight 0.0" do
      g = Graph.new() |> Graph.add_vertex(:a)
      assert {:ok, {[:a], w}} = Bidirectional.dijkstra(g, :a, :a)
      assert w == 0.0
    end

    test "longer directed chain" do
      g =
        Graph.new()
        |> Graph.add_edges([
          {1, 2, weight: 1.0},
          {2, 3, weight: 1.0},
          {3, 4, weight: 1.0},
          {4, 5, weight: 1.0},
          {5, 6, weight: 1.0},
          {1, 6, weight: 100.0}
        ])

      assert {:ok, {path, 5.0}} = Bidirectional.dijkstra(g, 1, 6)
      assert hd(path) == 1
      assert List.last(path) == 6
      assert valid_path?(g, path)
    end

    test "multi-edges: picks the minimum-weight parallel edge" do
      g =
        Graph.new()
        |> Graph.add_edge(:a, :b, weight: 10.0)
        |> Graph.add_edge(:a, :b, weight: 1.0)
        |> Graph.add_edge(:b, :c, weight: 1.0)

      assert {:ok, {[:a, :b, :c], 2.0}} = Bidirectional.dijkstra(g, :a, :c)
    end
  end

  # ── Property tests ────────────────────────────────────────────────────

  describe "properties" do
    property "weight matches classical Dijkstra on random positive-weight directed graphs" do
      check all(
              n <- integer(3..8),
              prob <- float(min: 0.3, max: 0.8),
              seed <- integer(1..10_000)
            ) do
        g = random_graph(n, prob, seed)
        src = 0
        tgt = n - 1

        case ShortestPath.dijkstra(g, src, tgt) do
          {:ok, {_, classic_w}} ->
            assert {:ok, {path, bidi_w}} = Bidirectional.dijkstra(g, src, tgt)
            assert_in_delta bidi_w, classic_w, 1.0e-9
            assert hd(path) == src
            assert List.last(path) == tgt
            assert valid_path?(g, path)
            assert_in_delta path_weight(g, path), bidi_w, 1.0e-9

          {:error, :no_path} ->
            assert {:error, :no_path} = Bidirectional.dijkstra(g, src, tgt)
        end
      end
    end

    property "weight matches classical Dijkstra on random undirected graphs" do
      check all(
              n <- integer(3..8),
              prob <- float(min: 0.3, max: 0.8),
              seed <- integer(1..10_000)
            ) do
        :rand.seed(:exsss, {seed, seed + 1, seed + 2})
        verts = Enum.to_list(0..(n - 1))
        g0 = Graph.new(type: :undirected) |> Graph.add_vertices(verts)

        g =
          for u <- verts, v <- verts, u < v, reduce: g0 do
            acc ->
              if :rand.uniform() < prob,
                do: Graph.add_edge(acc, u, v, weight: :rand.uniform(20) / 1),
                else: acc
          end

        src = 0
        tgt = n - 1

        case ShortestPath.dijkstra(g, src, tgt) do
          {:ok, {_, classic_w}} ->
            assert {:ok, {_path, bidi_w}} = Bidirectional.dijkstra(g, src, tgt)
            assert_in_delta bidi_w, classic_w, 1.0e-9

          {:error, :no_path} ->
            assert {:error, :no_path} = Bidirectional.dijkstra(g, src, tgt)
        end
      end
    end
  end
end
