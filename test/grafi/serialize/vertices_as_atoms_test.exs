defmodule Grafi.Serialize.VerticesAsAtomsTest do
  # async: false so no concurrently running test changes the atom count
  # between the two readings.
  use ExUnit.Case, async: false

  alias Grafi.Graph
  alias Grafi.Serialize.{AdjacencyList, EdgeList}

  for {name, decode} <- [
        {"EdgeList", &EdgeList.from_edge_list/2},
        {"AdjacencyList", &AdjacencyList.from_adjacency_list/2}
      ] do
    describe "#{name} with vertices_as_atoms: true" do
      @decode decode

      test "a never-seen token stays a string and creates no atom" do
        token = "grafi_unseen_vertex_#{System.unique_integer([:positive])}"
        # Load the decoder and its helpers before counting.
        _ = @decode.("warm up", vertices_as_atoms: true)

        before = :erlang.system_info(:atom_count)
        g = @decode.("ok " <> token, vertices_as_atoms: true)
        after_count = :erlang.system_info(:atom_count)

        assert after_count == before
        assert Graph.has_edge?(g, :ok, token)
        assert_raise ArgumentError, fn -> String.to_existing_atom(token) end
      end
    end
  end
end
