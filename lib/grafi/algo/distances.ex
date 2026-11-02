defmodule Grafi.Algo.Distances do
  @moduledoc false
  # Single-source shortest-path distances shared by Centrality (harmonic)
  # and Metrics (eccentricity and friends). Unreachable vertices are absent
  # from the result. Distances follow edge direction.
  #
  # Options (both required, so every caller states its policy):
  #   * `weighted: true` runs `ShortestPath.dijkstra_all/2` (edge weights are
  #     lengths); `false` runs a BFS (every edge has length 1);
  #   * `source: :include` keeps `source => 0` in the map; `:exclude` drops it.

  alias Grafi.Algo.ShortestPath
  alias Grafi.Graph

  @spec single_source(Graph.t(), Graph.vertex_id(),
          weighted: boolean(),
          source: :include | :exclude
        ) :: %{Graph.vertex_id() => number()}
  def single_source(%Graph{} = g, source, opts) do
    dists =
      if Keyword.fetch!(opts, :weighted),
        do: ShortestPath.dijkstra_all(g, source),
        else: bfs(g, source)

    case Keyword.fetch!(opts, :source) do
      :include -> dists
      :exclude -> Map.delete(dists, source)
    end
  end

  defp bfs(g, source), do: do_bfs(:queue.from_list([source]), %{source => 0}, g)

  defp do_bfs(q, dist, g) do
    case :queue.out(q) do
      {:empty, _} ->
        dist

      {{:value, v}, rest} ->
        dv1 = Map.fetch!(dist, v) + 1

        {dist, q} =
          Enum.reduce(Graph.out_neighbors(g, v), {dist, rest}, fn w, {d, q_acc} ->
            if Map.has_key?(d, w),
              do: {d, q_acc},
              else: {Map.put(d, w, dv1), :queue.in(w, q_acc)}
          end)

        do_bfs(q, dist, g)
    end
  end
end
