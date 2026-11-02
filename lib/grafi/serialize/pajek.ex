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
  def to_pajek(%Graph{} = g, opts \\ []) do
    Keyword.validate!(opts, [])
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

  Returns `{:ok, graph}` on success or `{:error, reason}` on parse failure, e.g.
  `{:error, {:unsupported_section, line}}`, `{:error, {:invalid_weight, token}}`,
  `{:error, {:malformed_vertex_line, line}}`,
  `{:error, {:malformed_edge_line, line}}`, `{:error, :unexpected_section}`
  (a section header before all declared vertex lines) or
  `{:error, :unexpected_eof}` (fewer vertex lines than declared). The
  `line` or `token` in an error is cut to its first 200 bytes. Unknown
  options raise `ArgumentError`.
  """
  @spec from_pajek(String.t(), keyword()) :: {:ok, Graph.t()} | {:error, term()}
  def from_pajek(text, opts \\ []) when is_binary(text) do
    opts = Keyword.validate!(opts, [:max_bytes])

    # Two passes over the lines: the graph type depends on every section
    # header, so the first pass reads the vertices and the sections, and
    # the second one adds the edges.
    with :ok <- Util.check_size(text, opts),
         {:ok, n, labels, type} <- scan(text) do
      ids = vertex_ids(labels)

      g =
        Enum.reduce(1..n//1, Graph.new(type: type), fn idx, g ->
          Graph.add_vertex(g, Map.fetch!(ids, idx))
        end)

      read_edges(text, n, g, ids)
    end
  end

  @doc """
  Like `from_pajek/2`, but returns the graph and raises `ArgumentError`
  with the reason on failure.
  """
  @spec from_pajek!(String.t(), keyword()) :: Graph.t()
  def from_pajek!(text, opts \\ []), do: text |> from_pajek(opts) |> Util.unwrap!("Pajek")

  # ── Parsing helpers ──────────────────────────────────────────────────

  # First pass, a state machine over the lines:
  #   :header → {:vertices, remaining, n, labels} → {:edges, n, labels, seen}
  # where `seen` records the section kinds met (and :leading for edge lines
  # before any section header).
  defp scan(text) do
    case Util.reduce_lines(text, :header, "%", &scan_line/2) do
      {:error, _} = error -> error
      :header -> {:error, :empty_input}
      {:vertices, _remaining, _n, _labels} -> {:error, :unexpected_eof}
      {:edges, n, labels, seen} -> {:ok, n, labels, graph_type(seen)}
    end
  end

  defp scan_line(line, :header) do
    case vertices_header(line) do
      {:ok, n} -> {:cont, vertex_state(n, n, %{})}
      error -> {:halt, error}
    end
  end

  defp scan_line("*" <> _, {:vertices, _remaining, _n, _labels}),
    do: {:halt, {:error, :unexpected_section}}

  defp scan_line(line, {:vertices, remaining, n, labels}) do
    case parse_vertex_line(line) do
      {:ok, idx, label} when idx in 1..n//1 and not is_map_key(labels, idx) ->
        {:cont, vertex_state(remaining - 1, n, Map.put(labels, idx, label))}

      _ ->
        {:halt, {:error, {:malformed_vertex_line, Util.excerpt(line)}}}
    end
  end

  defp scan_line("*" <> _ = line, {:edges, n, labels, seen}) do
    case section_header(line) do
      {:ok, section} -> {:cont, {:edges, n, labels, Map.put(seen, section, true)}}
      error -> {:halt, error}
    end
  end

  # An edge line before any section header is an arc.
  defp scan_line(_line, {:edges, n, labels, seen}) when map_size(seen) == 0,
    do: {:cont, {:edges, n, labels, %{leading: true}}}

  defp scan_line(_line, state), do: {:cont, state}

  defp vertex_state(0, n, labels), do: {:edges, n, labels, %{}}
  defp vertex_state(remaining, n, labels), do: {:vertices, remaining, n, labels}

  # Undirected only when every edge line sits in an *Edges section.
  defp graph_type(seen) when seen == %{edges: true}, do: :undirected
  defp graph_type(_seen), do: :directed

  defp vertices_header(line) do
    with [head, n_str] <- String.split(line),
         "*vertices" <- String.downcase(head) do
      case Util.parse_int(n_str) do
        {:ok, n} when n >= 0 -> {:ok, n}
        _ -> {:error, :bad_vertices_header}
      end
    else
      _ -> {:error, :missing_vertices_header}
    end
  end

  defp parse_vertex_line(line) do
    {token, rest} = split_index(line)

    case Util.parse_int(token) do
      {:ok, idx} when rest == "" -> {:ok, idx, Integer.to_string(idx)}
      {:ok, idx} -> parse_label(rest, idx)
      :error -> :error
    end
  end

  # Splits off the leading run of sign and digit characters (the index).
  defp split_index(line) do
    size = index_size(line, 0)
    <<token::binary-size(^size), rest::binary>> = line
    {token, rest}
  end

  defp index_size(<<c, rest::binary>>, size) when c in ?0..?9 or c in [?+, ?-],
    do: index_size(rest, size + 1)

  defp index_size(_rest, size), do: size

  defp parse_label(rest, idx) do
    case String.trim_leading(rest) do
      # No whitespace between the index and the label, e.g. "1x".
      ^rest -> :error
      "\"" <> quoted -> with {:ok, label} <- unescape(quoted, []), do: {:ok, idx, label}
      bare -> {:ok, idx, Util.own(bare)}
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

  defp unescape_special(?", _trailing, acc), do: {:ok, Util.own(IO.iodata_to_binary(acc))}
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

  defp section_header(line) do
    [keyword | _] = String.split(line)

    case String.downcase(keyword) do
      "*arcs" -> {:ok, :arcs}
      "*edges" -> {:ok, :edges}
      _ -> {:error, {:unsupported_section, Util.excerpt(line)}}
    end
  end

  # Second pass: skips the header and vertex lines (the first pass checked
  # them, and every section header), then adds the edges.
  defp read_edges(text, n, g, ids) do
    text
    |> Util.reduce_lines({n + 1, :arcs, g}, "%", fn
      _line, {skip, section, g} when skip > 0 ->
        {:cont, {skip - 1, section, g}}

      "*" <> _ = line, {0, _section, g} ->
        {:ok, section} = section_header(line)
        {:cont, {0, section, g}}

      line, {0, section, g} ->
        case parse_edge_line(line, ids) do
          {:ok, from, to, w} -> {:cont, {0, section, add_edge(g, section, from, to, w)}}
          error -> {:halt, error}
        end
    end)
    |> case do
      {0, _section, g} -> {:ok, g}
      {:error, _} = error -> error
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
      _ -> {:error, {:malformed_edge_line, Util.excerpt(line)}}
    end
  end

  defp fetch_vertex(token, ids) do
    case Util.parse_int(token) do
      {:ok, idx} -> Map.fetch(ids, idx)
      :error -> :error
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
