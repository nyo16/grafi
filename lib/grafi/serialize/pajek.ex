defmodule Grafi.Serialize.Pajek do
  @moduledoc """
  Serialize and deserialize graphs in Pajek `.net` text format.

  Layout:

      *Vertices N
      1 "label_1"
      2 "label_2"
      ...
      *Arcs            (directed) or *Edges (undirected)
      from to weight
      ...

  Vertex ids are 1-indexed integer positions; the original vertex id is
  written in the label column. Multi-edges are preserved as repeated lines.

  Reference: <https://gephi.org/users/supported-graph-formats/pajek-net-format/>
  and <https://mrvar.fdv.uni-lj.si/pajek/>.
  """

  alias Grafi.Graph

  @doc """
  Renders a graph as a Pajek `.net` string. Line terminator is `\\n`.

  ## Examples

      iex> g = Grafi.Graph.new() |> Grafi.Graph.add_edge(:a, :b)
      iex> Grafi.Serialize.Pajek.to_pajek(g) =~ "*Vertices 2"
      true
  """
  @spec to_pajek(Graph.t(), keyword()) :: String.t()
  def to_pajek(%Graph{} = g, _opts \\ []) do
    vertices = Graph.vertices(g)
    n = length(vertices)
    index = vertices |> Enum.with_index(1) |> Map.new()

    header = ["*Vertices #{n}"]

    vertex_lines =
      Enum.map(vertices, fn v ->
        i = Map.fetch!(index, v)
        "#{i} #{quote_label(v)}"
      end)

    edge_keyword = if g.type == :directed, do: "*Arcs", else: "*Edges"

    edge_lines =
      Graph.edges(g)
      |> Enum.map(fn e ->
        a = Map.fetch!(index, e.from)
        b = Map.fetch!(index, e.to)
        "#{a} #{b} #{format_weight(e.weight)}"
      end)

    (header ++ vertex_lines ++ [edge_keyword] ++ edge_lines)
    |> Enum.join("\n")
  end

  @doc """
  Parses a Pajek string into a `Grafi.Graph`.

  Vertices preserve their string labels (without surrounding quotes). The
  graph type follows the section keyword: `*Arcs` → directed,
  `*Edges` → undirected. If both appear, the first encountered wins.

  Returns the graph on success or `{:error, reason}` on parse failure.
  """
  @spec from_pajek(String.t(), keyword()) :: Graph.t() | {:error, term()}
  def from_pajek(text, _opts \\ []) when is_binary(text) do
    lines =
      text
      |> String.split(["\n", "\r\n"], trim: false)
      |> Enum.map(&String.trim/1)
      |> Enum.reject(&(&1 == "" or String.starts_with?(&1, "%")))

    with {:ok, expected_n, rest} <- expect_vertices_header(lines),
         {:ok, label_map, rest} <- read_vertex_lines(rest, expected_n, %{}) do
      parse_edges_section(rest, label_map)
    end
  rescue
    e -> {:error, Exception.message(e)}
  end

  # ── Parsing helpers ──────────────────────────────────────────────────

  defp expect_vertices_header([first | rest]) do
    case String.split(first, ~r/\s+/, trim: true) do
      [head, n_str] ->
        if String.downcase(head) == "*vertices" do
          case Integer.parse(n_str) do
            {n, ""} -> {:ok, n, rest}
            _ -> {:error, :bad_vertices_header}
          end
        else
          {:error, :missing_vertices_header}
        end

      _ ->
        {:error, :missing_vertices_header}
    end
  end

  defp expect_vertices_header([]), do: {:error, :empty_input}

  defp read_vertex_lines(rest, 0, acc), do: {:ok, acc, rest}

  defp read_vertex_lines([line | rest], remaining, acc) do
    cond do
      starts_with_section?(line) ->
        {:error, :unexpected_section}

      true ->
        case parse_vertex_line(line) do
          {:ok, idx, label} ->
            read_vertex_lines(rest, remaining - 1, Map.put(acc, idx, label))

          :error ->
            {:error, {:malformed_vertex_line, line}}
        end
    end
  end

  defp read_vertex_lines([], _remaining, _acc), do: {:error, :unexpected_eof}

  defp parse_vertex_line(line) do
    case String.split(line, ~r/\s+/, parts: 2, trim: true) do
      [idx_str, rest] ->
        case Integer.parse(idx_str) do
          {idx, ""} -> {:ok, idx, unquote_label(String.trim(rest))}
          _ -> :error
        end

      [idx_str] ->
        case Integer.parse(idx_str) do
          {idx, ""} -> {:ok, idx, Integer.to_string(idx)}
          _ -> :error
        end

      _ ->
        :error
    end
  end

  defp parse_edges_section(lines, label_map) do
    {type, body} = detect_edge_section(lines)
    g = build_graph_with_vertices(type, label_map)
    read_edge_lines(body, g, label_map, type)
  end

  defp detect_edge_section([]), do: {:directed, []}

  defp detect_edge_section([line | rest]) do
    case String.downcase(line) do
      "*arcs" -> {:directed, rest}
      "*edges" -> {:undirected, rest}
      _ -> {:directed, [line | rest]}
    end
  end

  defp build_graph_with_vertices(type, label_map) do
    label_map
    |> Enum.sort_by(fn {idx, _} -> idx end)
    |> Enum.reduce(Graph.new(type: type), fn {_idx, label}, g ->
      Graph.add_vertex(g, label)
    end)
  end

  defp read_edge_lines([], g, _label_map, _type), do: g

  defp read_edge_lines([line | rest], g, label_map, type) do
    cond do
      starts_with_section?(line) ->
        # Switch section mid-stream (e.g., another *Arcs/*Edges block)
        {new_type, new_rest} = detect_edge_section([line | rest])
        read_edge_lines(new_rest, g, label_map, new_type)

      true ->
        case parse_edge_line(line, label_map) do
          {:ok, from, to, w} ->
            g = Graph.add_edge(g, from, to, weight: w)
            read_edge_lines(rest, g, label_map, type)

          :error ->
            {:error, {:malformed_edge_line, line}}
        end
    end
  end

  defp parse_edge_line(line, label_map) do
    case String.split(line, ~r/\s+/, trim: true) do
      [a, b | tail] ->
        with {ai, ""} <- Integer.parse(a),
             {bi, ""} <- Integer.parse(b),
             from when not is_nil(from) <- Map.get(label_map, ai),
             to when not is_nil(to) <- Map.get(label_map, bi) do
          weight =
            case tail do
              [w | _] ->
                case Float.parse(w) do
                  {f, ""} ->
                    f

                  _ ->
                    case Integer.parse(w) do
                      {i, ""} -> i * 1.0
                      _ -> 1.0
                    end
                end

              [] ->
                1.0
            end

          {:ok, from, to, weight}
        else
          _ -> :error
        end

      _ ->
        :error
    end
  end

  defp starts_with_section?(line), do: String.starts_with?(line, "*")

  # ── Label formatting ─────────────────────────────────────────────────

  defp quote_label(v) do
    s = vertex_to_string(v)
    escaped = String.replace(s, "\"", "\\\"")
    "\"" <> escaped <> "\""
  end

  defp vertex_to_string(v) when is_binary(v), do: v
  defp vertex_to_string(v) when is_atom(v), do: Atom.to_string(v)
  defp vertex_to_string(v) when is_integer(v), do: Integer.to_string(v)
  defp vertex_to_string(v) when is_float(v), do: Float.to_string(v)
  defp vertex_to_string(v), do: inspect(v)

  defp unquote_label("\"" <> rest) do
    case String.split(rest, "\"", parts: 2) do
      [inner, _trailing] -> String.replace(inner, "\\\"", "\"")
      [only] -> only
    end
  end

  defp unquote_label(s), do: s

  defp format_weight(w) when is_float(w), do: Float.to_string(w)
  defp format_weight(w) when is_integer(w), do: Integer.to_string(w)
  defp format_weight(w), do: to_string(w)
end
