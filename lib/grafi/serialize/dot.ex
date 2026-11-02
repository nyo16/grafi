defmodule Grafi.Serialize.DOT do
  @moduledoc """
  Serialize graphs to Graphviz DOT format.

  Use `to_dot/2` for export. The output is suitable for piping into the
  `dot` command-line tool.
  """

  alias Grafi.Graph
  alias Grafi.Serialize.Util

  @doc """
  Renders a graph as a Graphviz DOT string.

  ## Options
    * `:name` — the graph identifier (default `"G"`). Embedded in the
      `digraph NAME { ... }` header; a name that is not a plain DOT
      identifier (letters, digits and `_`, not starting with a digit and not
      a DOT keyword) is quoted like a vertex ID.

  Vertex IDs are quoted with embedded `"` and backslashes escaped; tabs and
  newlines are kept inside the quotes. Other control characters in IDs,
  labels or the name raise `ArgumentError`, because DOT cannot represent
  them.
  """
  @spec to_dot(Graph.t(), keyword()) :: String.t()
  def to_dot(%Graph{} = g, opts \\ []) do
    name = opts |> Keyword.get(:name, "G") |> quote_name()
    {keyword, arrow} = if g.type == :directed, do: {"digraph", "->"}, else: {"graph", "--"}

    vertex_lines =
      Graph.vertices(g)
      |> Enum.map(fn v ->
        label = Graph.label(g, v)
        attrs = if label, do: " [label=#{quote_string(to_string(label))}]", else: ""
        "  #{quote_id(v)}#{attrs};"
      end)

    edge_lines =
      Graph.edges(g)
      |> Enum.map(fn e ->
        weight_attr =
          if e.weight != 1.0, do: "weight=#{Util.format_weight(e.weight)}", else: nil

        label_attr = if e.label, do: "label=#{quote_string(to_string(e.label))}", else: nil
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

  # ── Internal ──────────────────────────────────────────────────────────

  # The graph name: a plain identifier string stays bare (`digraph G {`),
  # anything else is quoted exactly like a vertex ID.
  defp quote_name(name) when is_binary(name) do
    if simple_id?(name), do: name, else: quote_id(name)
  end

  defp quote_name(name), do: quote_id(name)

  defp quote_id(v) when is_atom(v) do
    s = Atom.to_string(v)

    if simple_id?(s) do
      s
    else
      quote_string(s)
    end
  end

  defp quote_id(v) when is_binary(v), do: quote_string(v)
  defp quote_id(v) when is_integer(v), do: Integer.to_string(v)
  defp quote_id(v), do: quote_string(inspect(v))

  # DOT keywords are case-insensitive and cannot be bare identifiers.
  @keywords ~w(node edge graph digraph subgraph strict)

  defp simple_id?(s), do: simple_id_chars?(s) and String.downcase(s) not in @keywords

  defp simple_id_chars?(<<c, rest::binary>>)
       when c in ?a..?z or c in ?A..?Z or c == ?_ do
    simple_id_rest?(rest)
  end

  defp simple_id_chars?(_), do: false

  defp simple_id_rest?(<<>>), do: true

  defp simple_id_rest?(<<c, rest::binary>>)
       when c in ?a..?z or c in ?A..?Z or c in ?0..?9 or c == ?_ do
    simple_id_rest?(rest)
  end

  defp simple_id_rest?(_), do: false

  defp quote_string(s) when is_binary(s) do
    reject_control_chars!(s)
    escaped = s |> String.replace("\\", "\\\\") |> String.replace("\"", "\\\"")
    "\"" <> escaped <> "\""
  end

  defp reject_control_chars!(s) do
    if String.contains?(s, control_chars()) do
      raise ArgumentError,
            "DOT identifiers/labels cannot contain control characters: #{inspect(s)}"
    end

    :ok
  end

  defp control_chars do
    for c <- 0..31, c not in [?\t, ?\n, ?\r], do: <<c>>
  end
end
