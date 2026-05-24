defmodule Grafi.Serialize.EdgeList do
  @moduledoc """
  Serialize and deserialize graphs to a plain-text edge list.

  Each line represents one edge:

      from to            # unweighted
      from to weight     # weighted

  Tokens are whitespace-separated. Lines beginning with `#` are treated as
  comments and ignored on decode. The format does not carry edge labels or
  vertex labels — for those, prefer GraphML or JSON.

  Reference: <https://en.wikipedia.org/wiki/Edge_list>
  """

  alias Grafi.Graph

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
        base = [to_token(e.from), sep, to_token(e.to)]
        if weighted, do: base ++ [sep, format_weight(e.weight)], else: base
      end)

    (header ++ Enum.map(edge_lines, &IO.iodata_to_binary/1))
    |> Enum.join("\n")
  end

  @doc """
  Parses an edge list string into a `Grafi.Graph`.

  ## Options
    * `:directed` — `true` (default) or `false`.
    * `:weighted` — `true` if a third weight column is present (auto-detected
      from the first non-comment line when not given).
    * `:default_weight` — fallback weight when `:weighted` is `false`
      (default `1.0`).
    * `:vertices_as_atoms` — if `true`, vertex tokens are cast to atoms via
      `String.to_atom/1`. Default `false` (strings) to avoid the atom-table
      attack.

  Returns the graph on success or `{:error, reason}` on parse failure.

  ## Examples

      iex> Grafi.Serialize.EdgeList.from_edge_list("a b\\nb c")
      ...> |> Grafi.Graph.num_edges()
      2
  """
  @spec from_edge_list(String.t(), keyword()) :: Graph.t() | {:error, term()}
  def from_edge_list(text, opts \\ []) when is_binary(text) do
    directed = Keyword.get(opts, :directed, true)
    type = if directed, do: :directed, else: :undirected
    default_w = Keyword.get(opts, :default_weight, 1.0)
    atoms? = Keyword.get(opts, :vertices_as_atoms, false)

    lines =
      text
      |> String.split(["\n", "\r\n"], trim: false)
      |> Enum.map(&String.trim/1)
      |> Enum.reject(&(&1 == "" or String.starts_with?(&1, "#")))

    weighted = Keyword.get_lazy(opts, :weighted, fn -> detect_weighted(lines) end)

    Enum.reduce_while(lines, Graph.new(type: type), fn line, g ->
      case parse_line(line, weighted, default_w, atoms?) do
        {:ok, from, to, w} ->
          {:cont, Graph.add_edge(g, from, to, weight: w)}

        :error ->
          {:halt, {:error, {:malformed_line, line}}}
      end
    end)
  end

  # ── Internal ──────────────────────────────────────────────────────────

  defp to_token(v) when is_binary(v), do: v
  defp to_token(v) when is_atom(v), do: Atom.to_string(v)
  defp to_token(v) when is_integer(v), do: Integer.to_string(v)
  defp to_token(v) when is_float(v), do: Float.to_string(v)
  defp to_token(v), do: inspect(v)

  defp format_weight(w) when is_float(w), do: Float.to_string(w)
  defp format_weight(w) when is_integer(w), do: Integer.to_string(w)
  defp format_weight(w), do: to_string(w)

  defp detect_weighted([line | _]) do
    case String.split(line, ~r/\s+/, trim: true) do
      [_, _, _ | _] -> true
      _ -> false
    end
  end

  defp detect_weighted([]), do: false

  defp parse_line(line, weighted, default_w, atoms?) do
    tokens = String.split(line, ~r/\s+/, trim: true)

    case {weighted, tokens} do
      {true, [a, b, w]} ->
        case parse_weight(w) do
          {:ok, weight} -> {:ok, cast_vertex(a, atoms?), cast_vertex(b, atoms?), weight}
          :error -> :error
        end

      {false, [a, b]} ->
        {:ok, cast_vertex(a, atoms?), cast_vertex(b, atoms?), default_w}

      {false, [a, b | _]} ->
        # Tolerate extra columns when weighted=false was forced.
        {:ok, cast_vertex(a, atoms?), cast_vertex(b, atoms?), default_w}

      _ ->
        :error
    end
  end

  defp parse_weight(s) do
    case Float.parse(s) do
      {f, ""} ->
        {:ok, f}

      _ ->
        case Integer.parse(s) do
          {i, ""} -> {:ok, i * 1.0}
          _ -> :error
        end
    end
  end

  defp cast_vertex(s, true), do: String.to_atom(s)
  defp cast_vertex(s, false), do: s
end
