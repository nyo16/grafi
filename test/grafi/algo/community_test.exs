defmodule Grafi.Algo.CommunityTest do
  use ExUnit.Case, async: true

  alias Grafi.Algo.Community
  alias Grafi.Graph

  doctest Grafi.Algo.Community

  # Only the pure-Elixir `label_propagation_simple/2` is always available.
  # The NIF-backed functions are exercised in the NIF integration tests.
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
  end

  describe "NIF-backed functions when NIF unavailable" do
    @describetag :nif_optional

    test "return {:error, :nif_not_available} or {:ok, result}, never crash" do
      g = Graph.new(type: :undirected) |> Graph.add_edges([{:a, :b}, {:b, :c}])

      for fun <- [&Community.louvain/1, &Community.label_propagation/1] do
        assert match?({:ok, _}, fun.(g)) or fun.(g) == {:error, :nif_not_available}
      end

      assert match?({:ok, _}, Community.leiden(g)) or
               Community.leiden(g) == {:error, :nif_not_available}
    end
  end
end
