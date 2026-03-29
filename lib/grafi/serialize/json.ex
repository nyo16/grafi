defmodule Grafi.Serialize.JSON do
  @moduledoc """
  Serialize/deserialize graphs to JSON (adjacency list format).
  Requires `:jason` dependency.
  """

  alias Grafi.Graph

  @spec to_json(Graph.t()) :: String.t()
  def to_json(%Graph{} = g) do
    data = %{
      type: g.type,
      vertices:
        Graph.vertices(g)
        |> Enum.map(fn v ->
          label = Graph.label(g, v)
          %{id: v} |> maybe_put(:label, label)
        end),
      edges:
        Graph.edges(g)
        |> Enum.map(fn e ->
          %{from: e.from, to: e.to, weight: e.weight}
          |> maybe_put(:label, e.label)
        end)
    }

    Jason.encode!(data, pretty: true)
  end

  @spec from_json(String.t()) :: Graph.t()
  def from_json(json) do
    data = Jason.decode!(json)

    type =
      case data["type"] do
        "directed" -> :directed
        "undirected" -> :undirected
        other -> raise ArgumentError, "unknown graph type: #{inspect(other)}"
      end

    g = Graph.new(type: type)

    g =
      Enum.reduce(data["vertices"], g, fn v, acc ->
        opts = if v["label"], do: [label: v["label"]], else: []
        Graph.add_vertex(acc, v["id"], opts)
      end)

    Enum.reduce(data["edges"], g, fn e, acc ->
      opts = [weight: e["weight"] || 1.0]
      opts = if e["label"], do: Keyword.put(opts, :label, e["label"]), else: opts
      Graph.add_edge(acc, e["from"], e["to"], opts)
    end)
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, val), do: Map.put(map, key, val)
end
