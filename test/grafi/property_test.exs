defmodule Grafi.PropertyTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias Grafi.Graph

  # Generator for a list of unique atom vertex names
  defp vertex_list do
    gen all(names <- uniq_list_of(atom(:alphanumeric), min_length: 0, max_length: 20)) do
      names
    end
  end

  # Generator for a graph with random vertices and edges
  defp random_graph do
    gen all(
          verts <- uniq_list_of(atom(:alphanumeric), min_length: 1, max_length: 15),
          edge_count <- integer(0..30)
        ) do
      g = Graph.new() |> Graph.add_vertices(verts)

      edges =
        if edge_count > 0 do
          for _ <- 1..edge_count do
            {Enum.random(verts), Enum.random(verts)}
          end
        else
          []
        end

      Graph.add_edges(g, edges)
    end
  end

  describe "invariants" do
    property "num_vertices == length(vertices)" do
      check all(verts <- vertex_list()) do
        g = Graph.new() |> Graph.add_vertices(verts)
        assert Graph.num_vertices(g) == length(Graph.vertices(g))
      end
    end

    property "num_edges == length(edges)" do
      check all(g <- random_graph()) do
        assert Graph.num_edges(g) == length(Graph.edges(g))
      end
    end

    property "transpose(transpose(g)) preserves structure" do
      check all(g <- random_graph()) do
        tt = g |> Graph.transpose() |> Graph.transpose()

        assert Graph.num_vertices(tt) == Graph.num_vertices(g)
        assert Graph.num_edges(tt) == Graph.num_edges(g)

        # Every edge in original must be in double-transposed graph
        for e <- Graph.edges(g) do
          assert Graph.has_edge?(tt, e.from, e.to),
                 "edge #{inspect(e.from)} -> #{inspect(e.to)} lost after double transpose"
        end
      end
    end
  end
end
