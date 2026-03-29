defmodule Grafi.Serialize.DOT do
  @moduledoc "Serialize/deserialize graphs to Graphviz DOT format."

  alias Grafi.Graph

  @spec to_dot(Graph.t(), keyword()) :: String.t()
  def to_dot(%Graph{} = g, opts \\ []) do
    name = Keyword.get(opts, :name, "G")
    {keyword, arrow} = if g.type == :directed, do: {"digraph", "->"}, else: {"graph", "--"}

    vertex_lines = Graph.vertices(g) |> Enum.map(fn v ->
      label = Graph.label(g, v)
      attrs = if label, do: " [label=#{inspect(to_string(label))}]", else: ""
      "  #{quote_id(v)}#{attrs};"
    end)

    edge_lines = Graph.edges(g) |> Enum.map(fn e ->
      weight_attr = if e.weight != 1.0, do: "weight=#{e.weight}", else: nil
      label_attr = if e.label, do: "label=#{inspect(to_string(e.label))}", else: nil
      attrs = [weight_attr, label_attr] |> Enum.reject(&is_nil/1) |> Enum.join(", ")
      attrs_str = if attrs != "", do: " [#{attrs}]", else: ""
      "  #{quote_id(e.from)} #{arrow} #{quote_id(e.to)}#{attrs_str};"
    end)

    """
    #{keyword} #{name} {
    #{Enum.join(vertex_lines, "\n")}
    #{Enum.join(edge_lines, "\n")}
    }
    """
    |> String.trim()
  end

  defp quote_id(v) when is_atom(v), do: inspect(v) |> String.trim_leading(":")
  defp quote_id(v) when is_binary(v), do: inspect(v)
  defp quote_id(v), do: inspect(v)
end
