defmodule Grafi.EdgeCasesTest do
  use ExUnit.Case, async: true

  alias Grafi.Graph

  describe "empty graph" do
    setup do
      %{g: Grafi.new()}
    end

    test "vertices and edges are empty", %{g: g} do
      assert Graph.vertices(g) == []
      assert Graph.edges(g) == []
    end

    test "num_vertices is 0", %{g: g} do
      assert Graph.num_vertices(g) == 0
    end

    test "has_cycle? returns false", %{g: g} do
      refute Grafi.has_cycle?(g)
    end

    test "pagerank returns empty map", %{g: g} do
      assert Grafi.pagerank(g) == %{}
    end
  end

  describe "single vertex" do
    setup do
      %{g: Grafi.new() |> Grafi.add_vertex(:solo)}
    end

    test "BFS returns [vertex]", %{g: g} do
      assert Grafi.bfs(g, :solo) |> Enum.to_list() == [:solo]
    end

    test "DFS returns [vertex]", %{g: g} do
      assert Grafi.dfs(g, :solo) |> Enum.to_list() == [:solo]
    end
  end

  describe "self-loop on regular Graph" do
    test "add_edge(:a, :a) should work" do
      g = Grafi.new() |> Grafi.add_edge(:a, :a)
      assert Graph.has_edge?(g, :a, :a)
      assert Graph.num_edges(g) == 1
      assert Graph.num_vertices(g) == 1
    end

    test "self-loop makes has_cycle? true" do
      g = Grafi.new() |> Grafi.add_edge(:a, :a)
      assert Grafi.has_cycle?(g)
    end
  end

  describe "disconnected graph" do
    test "components returns separate groups (undirected)" do
      g =
        Grafi.new(type: :undirected)
        |> Grafi.add_edges([{:a, :b}, {:c, :d}])

      comps = Grafi.connected_components(g)
      assert length(comps) == 2

      comp_sets = Enum.map(comps, &MapSet.new/1)
      assert MapSet.new([:a, :b]) in comp_sets
      assert MapSet.new([:c, :d]) in comp_sets
    end

    test "shortest_path returns {:error, :no_path} across components" do
      g =
        Grafi.new()
        |> Grafi.add_edges([{:a, :b}, {:c, :d}])

      assert Grafi.dijkstra(g, :a, :d) == {:error, :no_path}
    end
  end

  describe "delete non-existent elements" do
    test "delete non-existent vertex returns unchanged graph" do
      g = Grafi.new() |> Grafi.add_vertex(:a)
      g2 = Graph.delete_vertex(g, :z)

      assert Graph.num_vertices(g2) == 1
      assert Graph.has_vertex?(g2, :a)
    end

    test "delete non-existent edge returns unchanged graph" do
      g = Grafi.new() |> Grafi.add_edge(:a, :b)
      g2 = Graph.delete_edge(g, :x, :y)

      assert Graph.num_edges(g2) == 1
      assert Graph.has_edge?(g2, :a, :b)
    end
  end

  describe "Dijkstra source == target" do
    test "returns path of one vertex with zero distance" do
      g = Grafi.new() |> Grafi.add_edge(:a, :b, weight: 1.0)
      assert {:ok, {[:a], dist}} = Grafi.dijkstra(g, :a, :a)
      assert dist == 0.0
    end
  end

  describe "Dijkstra with missing vertices" do
    test "missing source returns {:error, :no_such_vertex}" do
      g = Grafi.new() |> Grafi.add_edge(:a, :b)
      assert Grafi.dijkstra(g, :missing, :b) == {:error, :no_such_vertex}
    end

    test "missing target returns {:error, :no_such_vertex}" do
      g = Grafi.new() |> Grafi.add_edge(:a, :b)
      assert Grafi.dijkstra(g, :a, :missing) == {:error, :no_such_vertex}
    end

    test "A* missing endpoints returns {:error, :no_such_vertex}" do
      g = Grafi.new() |> Grafi.add_edge(:a, :b)
      assert Grafi.a_star(g, :missing, :b, fn _ -> 0 end) == {:error, :no_such_vertex}
      assert Grafi.a_star(g, :a, :missing, fn _ -> 0 end) == {:error, :no_such_vertex}
    end
  end

  describe "closeness on tiny graphs" do
    test "empty graph returns %{}" do
      assert Grafi.closeness(Grafi.new()) == %{}
    end

    test "single vertex returns %{}" do
      g = Grafi.new() |> Grafi.add_vertex(:solo)
      assert Grafi.closeness(g) == %{}
    end
  end

  describe "CSR structural validation" do
    defp csr(row_offsets, col_indices, weights, n) do
      %{
        row_offsets: for(i <- row_offsets, into: <<>>, do: <<i::signed-native-64>>),
        col_indices: for(i <- col_indices, into: <<>>, do: <<i::signed-native-64>>),
        weights: for(w <- weights, into: <<>>, do: <<w::float-native-64>>),
        n_vertices: n,
        directed: true
      }
    end

    test "valid CSR passes" do
      assert Grafi.NIF.validate_csr!(csr([0, 1, 1], [1], [1.0], 2)) == :ok
    end

    test "Graph.to_csr/1 output passes" do
      g = Graph.new(type: :undirected) |> Graph.add_edges([{:a, :b}, {:b, :b}, {:b, :c}])
      {_idx, csr} = Graph.to_csr(g)
      assert Grafi.NIF.validate_csr!(csr) == :ok
    end

    test "rejects row_offsets not starting at 0" do
      assert_raise ArgumentError, ~r/row_offsets\[0\]/, fn ->
        Grafi.NIF.validate_csr!(csr([1, 2], [0], [1.0], 1))
      end
    end

    test "rejects non-monotonic row_offsets" do
      assert_raise ArgumentError, ~r/monotonically/, fn ->
        Grafi.NIF.validate_csr!(csr([0, 2, 1], [0, 1], [1.0, 1.0], 2))
      end
    end

    test "rejects out-of-bounds col_indices" do
      assert_raise ArgumentError, ~r/out of bounds/, fn ->
        Grafi.NIF.validate_csr!(csr([0, 1], [5], [1.0], 1))
      end
    end

    test "rejects last offset != number of col_indices" do
      assert_raise ArgumentError, ~r/last row_offset/, fn ->
        Grafi.NIF.validate_csr!(csr([0, 1], [0, 0], [1.0, 1.0], 1))
      end
    end

    test "rejects a truncated array" do
      bad = %{csr([0, 1], [0], [1.0], 1) | col_indices: <<0::signed-native-32>>}

      assert_raise ArgumentError, ~r/multiple of 8/, fn -> Grafi.NIF.validate_csr!(bad) end
    end

    test "rejects NaN weights" do
      nan = <<0x7FF8000000000001::unsigned-native-64>>
      bad = %{csr([0, 1], [0], [1.0], 1) | weights: nan}

      assert_raise ArgumentError, ~r/finite/, fn -> Grafi.NIF.validate_csr!(bad) end
    end
  end

  describe "DAG add_edge with auto-inserted vertices" do
    test "cycle detected even when vertices are inserted by add_edge" do
      # First edge auto-inserts both :a and :b; then :b -> :a should raise
      dag = Grafi.DAG.new() |> Grafi.DAG.add_edge(:a, :b)

      assert_raise Grafi.CycleError, fn ->
        Grafi.DAG.add_edge(dag, :b, :a)
      end
    end
  end
end
