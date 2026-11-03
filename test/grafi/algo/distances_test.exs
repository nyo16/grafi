defmodule Grafi.Algo.DistancesTest do
  use ExUnit.Case, async: true

  alias Grafi.Algo.Distances
  alias Grafi.Graph

  describe "single_source/3" do
    setup do
      %{g: Graph.new() |> Graph.add_edges([{:a, :b}, {:b, :c, weight: 2}])}
    end

    test "follows edge direction, with and without weights", %{g: g} do
      assert Distances.single_source(g, :a, weighted: false, source: :include) ==
               %{a: 0, b: 1, c: 2}

      assert Distances.single_source(g, :a, weighted: true, source: :exclude) ==
               %{b: 1.0, c: 3.0}
    end

    # It used to return `%{ghost => 0}`, inventing the missing vertex.
    test "a source not in the graph raises", %{g: g} do
      for weighted <- [false, true], source <- [:include, :exclude] do
        assert_raise ArgumentError, ~r/not in the graph/, fn ->
          Distances.single_source(g, :ghost, weighted: weighted, source: source)
        end
      end
    end
  end
end
