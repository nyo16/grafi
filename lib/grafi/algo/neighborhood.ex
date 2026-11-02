defmodule Grafi.Algo.Neighborhood do
  @moduledoc false
  # Undirected views of a graph's adjacency, shared by the algorithms that
  # ignore edge direction (Metrics, LinkPrediction, Cliques, KCore,
  # Bipartite, Community). A vertex's undirected neighbourhood is the union
  # of its in- and out-neighbours, each listed once.
  #
  # Callers pick a self-loop policy explicitly:
  #   * `self_loops: :keep` lists `v` among its own neighbours when it has a
  #     self-loop (2-colouring must see it: a self-loop is an odd cycle);
  #   * `self_loops: :drop` never does (triangles, cliques, cores and
  #     similarity scores are defined over distinct vertices).

  alias Grafi.Graph

  @type policy :: [self_loops: :keep | :drop]

  @doc "Distinct undirected neighbours of `v` (`[]` for a missing vertex)."
  @spec neighbors(Graph.t(), Graph.vertex_id(), policy()) :: [Graph.vertex_id()]
  def neighbors(%Graph{} = g, v, self_loops: policy) do
    ns = if g.type == :undirected, do: Graph.out_neighbors(g, v), else: Graph.neighbors(g, v)
    apply_policy(ns, v, policy)
  end

  @doc "`%{v => [neighbour]}` for every vertex, built in one O(V + E) pass."
  @spec lists(Graph.t(), policy()) :: %{Graph.vertex_id() => [Graph.vertex_id()]}
  def lists(%Graph{} = g, policy) do
    Map.new(Graph.vertices(g), &{&1, neighbors(g, &1, policy)})
  end

  @doc "`%{v => MapSet.t(neighbour)}` for every vertex, built in one O(V + E) pass."
  @spec sets(Graph.t(), policy()) :: %{Graph.vertex_id() => MapSet.t()}
  def sets(%Graph{} = g, policy) do
    Map.new(Graph.vertices(g), &{&1, MapSet.new(neighbors(g, &1, policy))})
  end

  defp apply_policy(ns, _v, :keep), do: ns
  defp apply_policy(ns, v, :drop), do: List.delete(ns, v)
end
