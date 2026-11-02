defmodule Grafi.Serialize.EdgeList do
  @moduledoc """
  Serialize and deserialize graphs to a plain-text edge list.

  Each line represents one edge:

      from to            # unweighted
      from to weight     # weighted

  Tokens are whitespace-separated by default; see the `:separator` option of
  both functions. Lines beginning with `#` are treated as comments and
  ignored on decode. The format does not carry edge labels or vertex
  labels — for those, prefer GraphML or JSON.

  Reference: <https://en.wikipedia.org/wiki/Edge_list>
  """

  alias Grafi.Graph
  alias Grafi.Serialize.Util

  @doc """
  Renders a graph as an edge list string.

  ## Options
    * `:weighted` — include a weight column (default `true` if any edge
      weight differs from `1.0`, otherwise `false`).
    * `:separator` — column separator (default `" "`).
    * `:comment` — optional comment line written at the top, prefixed
      with `# `.

  Isolated vertices (no edges) are not preserved by this format.

  ## Examples

      iex> g = Grafi.Graph.new() |> Grafi.Graph.add_edge(:a, :b)
      iex> Grafi.Serialize.EdgeList.to_edge_list(g)
      "a b"
  """
  @spec to_edge_list(Graph.t(), keyword()) :: String.t()
  def to_edge_list(%Graph{} = g, opts \\ []) do
    sep = Keyword.get(opts, :separator, " ")
    edges = Graph.edges(g)

    weighted =
      Keyword.get_lazy(opts, :weighted, fn ->
        Enum.any?(edges, &(&1.weight != 1.0))
      end)

    header =
      case Keyword.get(opts, :comment) do
        nil -> []
        c when is_binary(c) -> ["# " <> c]
      end

    edge_lines =
      Enum.map(edges, fn e ->
        base = [Util.vertex_to_string(e.from), sep, Util.vertex_to_string(e.to)]
        if weighted, do: base ++ [sep, Util.format_weight(e.weight)], else: base
      end)

    (header ++ Enum.map(edge_lines, &IO.iodata_to_binary/1))
    |> Enum.join("\n")
  end

  @doc """
  Parses an edge list string into a `Grafi.Graph`.

  ## Options
    * `:directed` — `true` (default) or `false`.
    * `:separator` — column separator. By default columns are separated by
      any run of whitespace. When given, each line is split on exactly this
      string and every field is trimmed of surrounding whitespace, so
      vertex names may contain spaces (e.g. with `"\\t"` or `","`). An
      empty field makes the line malformed.
    * `:weighted` — how the third column is read. When not given, each line
      is judged on its own: two fields are an unweighted edge (it gets
      `:default_weight`), three fields are an edge whose third field is the
      weight, and more fields are malformed, so weighted and unweighted
      lines may be mixed. `true` requires exactly three fields on every
      line. `false` uses the first two fields and ignores any further
      columns.
    * `:default_weight` — weight of edges without a weight column
      (default `1.0`).
    * `:vertices_as_atoms` — if `true`, a vertex token that names an
      existing atom becomes that atom; any other token stays a string.
      Input never creates atoms (the atom table is not garbage-collected).
      Default `false` (strings).
    * `:max_bytes` — maximum input size in bytes (default 64 MiB, or
      `:infinity`). Larger input returns `{:error, {:too_large, size, max}}`.

  Returns the graph on success or `{:error, reason}`: `{:malformed_line,
  line}` for a line with the wrong number of fields, and `{:invalid_weight,
  token}` for a weight that is not a finite number.

  ## Examples

      iex> Grafi.Serialize.EdgeList.from_edge_list("a b\\nb c")
      ...> |> Grafi.Graph.num_edges()
      2
  """
  @spec from_edge_list(String.t(), keyword()) :: Graph.t() | {:error, term()}
  def from_edge_list(text, opts \\ []) when is_binary(text) do
    with :ok <- Util.check_size(text, opts) do
      parse(text, opts)
    end
  end

  # ── Internal ──────────────────────────────────────────────────────────

  defp parse(text, opts) do
    type = if Keyword.get(opts, :directed, true), do: :directed, else: :undirected
    weighted = Keyword.get(opts, :weighted, :auto)
    default_w = Keyword.get(opts, :default_weight, 1.0)
    atoms? = Keyword.get(opts, :vertices_as_atoms, false)
    split = splitter(Keyword.get(opts, :separator))

    text
    |> String.split(["\n", "\r\n"])
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == "" or String.starts_with?(&1, "#")))
    |> Enum.reduce_while(Graph.new(type: type), fn line, g ->
      case parse_line(line, split.(line), weighted, default_w) do
        {:ok, from, to, w} ->
          from = Util.cast_vertex(from, atoms?)
          to = Util.cast_vertex(to, atoms?)
          {:cont, Graph.add_edge(g, from, to, weight: w)}

        {:error, _} = error ->
          {:halt, error}
      end
    end)
  end

  defp splitter(nil), do: &String.split/1

  defp splitter(sep) when is_binary(sep) and sep != "" do
    fn line -> line |> String.split(sep) |> Enum.map(&String.trim/1) end
  end

  defp splitter(other),
    do: raise(ArgumentError, "expected :separator to be a non-empty string, got: #{inspect(other)}")

  defp parse_line(line, fields, weighted, default_w) do
    if "" in fields,
      do: {:error, {:malformed_line, line}},
      else: parse_fields(line, fields, weighted, default_w)
  end

  defp parse_fields(_line, [a, b, w], weighted, _default_w) when weighted in [true, :auto] do
    with {:ok, weight} <- Util.parse_weight(w), do: {:ok, a, b, weight}
  end

  defp parse_fields(_line, [a, b], weighted, default_w) when weighted in [false, :auto],
    do: {:ok, a, b, default_w}

  # Tolerate extra columns when weighted: false was forced.
  defp parse_fields(_line, [a, b | _], false, default_w), do: {:ok, a, b, default_w}

  defp parse_fields(line, _fields, _weighted, _default_w), do: {:error, {:malformed_line, line}}
end
