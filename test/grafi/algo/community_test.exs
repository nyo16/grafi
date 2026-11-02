defmodule Grafi.Algo.CommunityTest do
  use ExUnit.Case, async: true

  alias Grafi.Algo.Community
  alias Grafi.Graph

  doctest Grafi.Algo.Community

  # `label_propagation_simple/2` is pure Elixir; the igraph-backed functions
  # have no Elixir engine.
  describe "label_propagation_simple/2" do
    test "empty graph yields no communities" do
      result = Community.label_propagation_simple(Graph.new(type: :undirected))

      assert result.membership == %{}
      assert result.communities == %{}
      assert result.n_communities == 0
    end

    test "single vertex yields exactly one community containing it" do
      g = Graph.new(type: :undirected) |> Graph.add_vertex(:a)
      result = Community.label_propagation_simple(g)

      assert result.n_communities == 1
      assert Map.keys(result.membership) == [:a]
    end

    test "membership covers exactly the vertex set" do
      g =
        Graph.new(type: :undirected)
        |> Graph.add_edges([{:a, :b}, {:b, :c}, {:x, :y}])

      result = Community.label_propagation_simple(g)

      assert MapSet.new(Map.keys(result.membership)) ==
               MapSet.new(Graph.vertices(g))
    end

    test "communities partition the vertex set" do
      g =
        Graph.new(type: :undirected)
        |> Graph.add_edges([{:a, :b}, {:b, :c}, {:c, :a}, {:x, :y}, {:y, :z}, {:z, :x}])

      result = Community.label_propagation_simple(g)

      members = result.communities |> Map.values() |> List.flatten()
      # Every vertex appears exactly once across all communities.
      assert Enum.sort(members) == Enum.sort(Graph.vertices(g))
      assert length(members) == length(Enum.uniq(members))
      assert result.n_communities == map_size(result.communities)
    end

    test "two disjoint cliques resolve to (at least) two communities" do
      # Disconnected components can never share a label, so the count is
      # deterministic despite the internal Enum.shuffle.
      g =
        Graph.new(type: :undirected)
        |> Graph.add_edges([{:a, :b}, {:b, :c}, {:c, :a}, {:x, :y}, {:y, :z}, {:z, :x}])

      result = Community.label_propagation_simple(g)

      assert result.n_communities >= 2
      # a/b/c must not share a community with x/y/z.
      abc_labels = Enum.map([:a, :b, :c], &result.membership[&1]) |> MapSet.new()
      xyz_labels = Enum.map([:x, :y, :z], &result.membership[&1]) |> MapSet.new()
      assert MapSet.disjoint?(abc_labels, xyz_labels)
    end

    # A sweep that changes nothing ends propagation; the old loop always ran
    # every sweep, so a huge cap took hours instead of milliseconds.
    @tag timeout: 10_000
    test "stops at the first sweep with no change, however large :iterations is" do
      g =
        Graph.new(type: :undirected)
        |> Graph.add_edges([{:a, :b}, {:b, :c}, {:c, :a}, {:c, :d}, {:x, :y}, {:y, :z}, {:z, :x}])
        |> Graph.add_vertex(:lonely)

      result = Community.label_propagation_simple(g, iterations: 100_000_000)

      # The result is a fixpoint: every vertex with neighbours holds a label
      # that is most common among them, which forces each triangle to agree.
      for v <- Graph.vertices(g), ns = Graph.neighbors(g, v), ns != [] do
        freqs = Enum.frequencies_by(ns, &result.membership[&1])
        assert freqs[result.membership[v]] == Enum.max(Map.values(freqs))
      end

      assert result.n_communities == 3
      assert result.membership[:a] == result.membership[:b]
      assert result.membership[:x] == result.membership[:z]
    end
  end

  describe "NIF-backed functions without the NIF engine" do
    test "engine: :elixir returns {:error, :nif_not_available}" do
      g = Graph.new(type: :undirected) |> Graph.add_edges([{:a, :b}, {:b, :c}])

      assert Community.louvain(g, engine: :elixir) == {:error, :nif_not_available}
      assert Community.leiden(g, engine: :elixir) == {:error, :nif_not_available}
      assert Community.label_propagation(g, engine: :elixir) == {:error, :nif_not_available}
    end
  end

  describe "NIF-backed functions on two disjoint K4s" do
    @describetag :nif

    setup do
      k4 = fn off -> for i <- 0..2, j <- (i + 1)..3, do: {i + off, j + off} end
      %{g: Graph.new(type: :undirected) |> Graph.add_edges(k4.(0) ++ k4.(10))}
    end

    # Two equal disjoint cliques, each with half of the 12 edges and half of
    # the total degree: Q = 2 · (6/12 − (12/24)²) = 0.5.
    @expected_modularity 0.5
    @expected_partition MapSet.new([MapSet.new(0..3), MapSet.new(10..13)])

    defp partition(%{communities: communities}),
      do: communities |> Map.values() |> MapSet.new(&MapSet.new/1)

    test "louvain finds the two cliques", %{g: g} do
      assert {:ok, result} = Community.louvain(g)
      assert result.n_communities == 2
      assert partition(result) == @expected_partition
      assert_in_delta result.modularity, @expected_modularity, 1.0e-12
    end

    test "leiden (modularity) finds the two cliques", %{g: g} do
      assert {:ok, result} = Community.leiden(g)
      assert result.n_communities == 2
      assert partition(result) == @expected_partition
      assert_in_delta result.modularity, @expected_modularity, 1.0e-12
    end

    test "leiden (cpm) finds the two cliques and reports modularity", %{g: g} do
      assert {:ok, result} = Community.leiden(g, objective: :cpm, resolution: 0.5)
      assert partition(result) == @expected_partition
      assert_in_delta result.modularity, @expected_modularity, 1.0e-12
    end

    test "label propagation never merges disconnected cliques", %{g: g} do
      assert {:ok, result} = Community.label_propagation(g)

      for community <- partition(result) do
        assert MapSet.subset?(community, MapSet.new(0..3)) or
                 MapSet.subset?(community, MapSet.new(10..13))
      end
    end

    test "label propagation runs on a directed graph without merging the cliques" do
      k4 = fn off -> for i <- 0..3, j <- 0..3, i != j, do: {i + off, j + off} end
      g = Graph.new(type: :directed) |> Graph.add_edges(k4.(0) ++ k4.(10))

      assert {:ok, %{membership: m} = result} = Community.label_propagation(g)
      assert Enum.sort(Map.keys(m)) == Enum.to_list(0..3) ++ Enum.to_list(10..13)

      for community <- partition(result) do
        assert MapSet.subset?(community, MapSet.new(0..3)) or
                 MapSet.subset?(community, MapSet.new(10..13))
      end
    end

    test "label propagation on one-directional directed cycles keeps the components apart" do
      cycle = fn off -> for i <- 0..3, do: {i + off, rem(i + 1, 4) + off} end
      g = Graph.new(type: :directed) |> Graph.add_edges(cycle.(0) ++ cycle.(10))

      assert {:ok, %{membership: m} = result} = Community.label_propagation(g)
      assert Enum.sort(Map.keys(m)) == Enum.to_list(0..3) ++ Enum.to_list(10..13)

      for community <- partition(result) do
        assert MapSet.subset?(community, MapSet.new(0..3)) or
                 MapSet.subset?(community, MapSet.new(10..13))
      end
    end
  end
end
