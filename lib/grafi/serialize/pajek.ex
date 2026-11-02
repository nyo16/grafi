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

  ## Labels

  Labels are written in double quotes. A backslash, a double quote, a line
  feed and a carriage return inside a label are written as `\\\\`, `\\"`,
  `\\n` and `\\r`, so every label stays on its own line and reads back
  unchanged. When parsing, any other backslash sequence is kept literally,
  and text after the closing quote (coordinates, shape attributes) is
  ignored.

  ## Sections

  Only the `*Vertices`, `*Arcs` and `*Edges` sections are supported (a
  multi-relational header such as `*Arcs :2 "rel"` is read as `*Arcs`).
  Any other section, e.g. `*Matrix`, `*Arcslist` or `*Edgeslist`, is
  rejected with `{:error, {:unsupported_section, line}}`.

  Reference: <https://gephi.org/users/supported-graph-formats/pajek-net-format/>
  and <https://mrvar.fdv.uni-lj.si/pajek/>.
  """

  alias Grafi.Graph
  alias Grafi.Serialize.Util

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
        "#{a} #{b} #{Util.format_weight(e.weight)}"
      end)

    (header ++ vertex_lines ++ [edge_keyword] ++ edge_lines)
    |> Enum.join("\n")
  end

  @doc """
  Parses a Pajek string into a `Grafi.Graph`.

  Vertices are identified by their string labels (without surrounding
  quotes, escapes decoded); a vertex line without a label gets its index as
  the label.

  The graph is undirected when its edge lines all come from `*Edges`
  sections, and directed otherwise. In a directed graph (a file mixing
  `*Arcs` and `*Edges` sections), each `*Edges` line adds an arc in both
  directions (one arc for a self-loop). A missing weight is `1.0`.

  Duplicate labels: Pajek identifies vertices by index, so vertices that
  share a label stay distinct. Each of them gets the id `{label, index}`;
  vertices with a unique label keep the plain label as their id.

  ## Options

    * `:max_bytes` - the largest accepted input, in bytes (default 64 MiB,
      or `:infinity`). Larger input returns `{:error, {:too_large, size, max}}`.

  Returns the graph on success or `{:error, reason}` on parse failure, e.g.
  `{:error, {:unsupported_section, line}}`, `{:error, {:invalid_weight, token}}`,
  `{:error, {:malformed_vertex_line, line}}` or
  `{:error, {:malformed_edge_line, line}}`.
  """
  @spec from_pajek(String.t(), keyword()) :: Graph.t() | {:error, term()}
  def from_pajek(text, opts \\ []) when is_binary(text) do
    with :ok <- Util.check_size(text, opts),
         {:ok, n, rest} <- expect_vertices_header(split_lines(text)),
         {:ok, labels, rest} <- read_vertex_lines(rest, n, n, %{}),
         {:ok, type} <- graph_type(rest) do
      ids = vertex_ids(labels)

      g =
        ids
        |> Enum.sort_by(fn {idx, _} -> idx end)
        |> Enum.reduce(Graph.new(type: type), fn {_idx, id}, g -> Graph.add_vertex(g, id) end)

      read_edge_lines(rest, g, ids, :arcs)
    end
  end

  # ── Parsing helpers ──────────────────────────────────────────────────

  defp split_lines(text) do
    text
    |> String.split(["\n", "\r\n"])
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == "" or String.starts_with?(&1, "%")))
  end

  defp expect_vertices_header([first | rest]) do
    case String.split(first) do
      [head, n_str] ->
        if String.downcase(head) == "*vertices" do
          case Integer.parse(n_str) do
            {n, ""} when n >= 0 -> {:ok, n, rest}
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

  defp read_vertex_lines(rest, 0, _n, acc), do: {:ok, acc, rest}

  defp read_vertex_lines([line | rest], remaining, n, acc) do
    if String.starts_with?(line, "*") do
      {:error, :unexpected_section}
    else
      case parse_vertex_line(line) do
        {:ok, idx, label} when idx in 1..n//1 and not is_map_key(acc, idx) ->
          read_vertex_lines(rest, remaining - 1, n, Map.put(acc, idx, label))

        _ ->
          {:error, {:malformed_vertex_line, line}}
      end
    end
  end

  defp read_vertex_lines([], _remaining, _n, _acc), do: {:error, :unexpected_eof}

  defp parse_vertex_line(line) do
    case Integer.parse(line) do
      {idx, ""} -> {:ok, idx, Integer.to_string(idx)}
      {idx, rest} -> parse_label(rest, idx)
      :error -> :error
    end
  end

  defp parse_label(rest, idx) do
    case String.trim_leading(rest) do
      # No whitespace between the index and the label, e.g. "1x".
      ^rest -> :error
      "\"" <> quoted -> with {:ok, label} <- unescape(quoted, []), do: {:ok, idx, label}
      bare -> {:ok, idx, bare}
    end
  end

  # Decodes a quoted label up to its closing quote; `bin` starts right after
  # the opening quote. Text after the closing quote is ignored.
  defp unescape(bin, acc) do
    case :binary.match(bin, ["\\", "\""]) do
      {pos, 1} ->
        <<chunk::binary-size(^pos), special, rest::binary>> = bin
        unescape_special(special, rest, [acc, chunk])

      :nomatch ->
        :error
    end
  end

  defp unescape_special(?", _trailing, acc), do: {:ok, IO.iodata_to_binary(acc)}
  defp unescape_special(?\\, <<?\\, rest::binary>>, acc), do: unescape(rest, [acc, ?\\])
  defp unescape_special(?\\, <<?", rest::binary>>, acc), do: unescape(rest, [acc, ?"])
  defp unescape_special(?\\, <<?n, rest::binary>>, acc), do: unescape(rest, [acc, ?\n])
  defp unescape_special(?\\, <<?r, rest::binary>>, acc), do: unescape(rest, [acc, ?\r])
  # Unknown escape: keep the backslash literally.
  defp unescape_special(?\\, rest, acc), do: unescape(rest, [acc, ?\\])

  defp vertex_ids(labels) do
    counts = labels |> Map.values() |> Enum.frequencies()

    Map.new(labels, fn {idx, label} ->
      if Map.fetch!(counts, label) > 1, do: {idx, {label, idx}}, else: {idx, label}
    end)
  end

  # Undirected only when every edge line sits in an *Edges section; edge
  # lines before the first section header are arcs.
  defp graph_type(lines) do
    {leading, rest} = Enum.split_while(lines, &(not String.starts_with?(&1, "*")))
    sections = for "*" <> _ = line <- rest, do: section_header(line)

    cond do
      error = Enum.find(sections, &match?({:error, _}, &1)) ->
        error

      leading == [] and {:ok, :edges} in sections and {:ok, :arcs} not in sections ->
        {:ok, :undirected}

      true ->
        {:ok, :directed}
    end
  end

  defp section_header("*" <> _ = line) do
    [keyword | _] = String.split(line)

    case String.downcase(keyword) do
      "*arcs" -> {:ok, :arcs}
      "*edges" -> {:ok, :edges}
      _ -> {:error, {:unsupported_section, line}}
    end
  end

  defp section_header(_line), do: :not_header

  defp read_edge_lines([], g, _ids, _section), do: g

  defp read_edge_lines([line | rest], g, ids, section) do
    case section_header(line) do
      {:ok, new_section} ->
        read_edge_lines(rest, g, ids, new_section)

      {:error, _} = error ->
        error

      :not_header ->
        with {:ok, from, to, w} <- parse_edge_line(line, ids) do
          read_edge_lines(rest, add_edge(g, section, from, to, w), ids, section)
        end
    end
  end

  defp add_edge(%Graph{type: :directed} = g, :edges, from, to, w) when from != to do
    g |> Graph.add_edge(from, to, weight: w) |> Graph.add_edge(to, from, weight: w)
  end

  defp add_edge(g, _section, from, to, w), do: Graph.add_edge(g, from, to, weight: w)

  defp parse_edge_line(line, ids) do
    with [a, b | tail] <- String.split(line),
         {:ok, from} <- fetch_vertex(a, ids),
         {:ok, to} <- fetch_vertex(b, ids),
         {:ok, w} <- edge_weight(tail) do
      {:ok, from, to, w}
    else
      {:error, {:invalid_weight, _}} = error -> error
      _ -> {:error, {:malformed_edge_line, line}}
    end
  end

  defp fetch_vertex(token, ids) do
    case Integer.parse(token) do
      {idx, ""} -> Map.fetch(ids, idx)
      _ -> :error
    end
  end

  defp edge_weight([]), do: {:ok, 1.0}
  defp edge_weight([w | _]), do: Util.parse_weight(w)

  # ── Label formatting ─────────────────────────────────────────────────

  defp quote_label(v) do
    escaped =
      v
      |> Util.vertex_to_string()
      |> String.replace(["\\", "\"", "\n", "\r"], fn
        "\\" -> "\\\\"
        "\"" -> "\\\""
        "\n" -> "\\n"
        "\r" -> "\\r"
      end)

    "\"" <> escaped <> "\""
  end
end
