defmodule Grafi.Serialize.AdjacencyList do
  @moduledoc """
  Serialize and deserialize graphs to a plain-text adjacency list.

  One line per source vertex:

      source neighbor1 neighbor2 neighbor3 ...

  Tokens are whitespace-separated by default; see the `:separator` option of
  both functions. Lines beginning with `#` are comments.
  Isolated vertices appear as a single-token line (just the vertex id).

  ## Simple ids only

  Vertex ids are written as plain tokens, without quoting or escaping, so
  the encoder raises `ArgumentError` for an id whose text could not be read
  back as the same single token: an empty id, one starting with `#`, one
  containing a line break, leading or trailing whitespace, or the
  separator (any whitespace under the default separator). Use GraphML or
  JSON for arbitrary ids.

  ## Limitations

  This format carries neither edge weights nor edge/vertex labels. For
  weighted graphs use `Grafi.Serialize.EdgeList`; for labels use GraphML
  or JSON. Parallel (multi-) edges between the same pair collapse into a
  single neighbor entry by default; pass `:collapse_multi_edges` to `false`
  on the encoder to emit duplicates (decoder will then re-add them).

  Reference: <https://en.wikipedia.org/wiki/Adjacency_list>
  """

  alias Grafi.Graph
  alias Grafi.Serialize.{LineIds, Util}

  @doc """
  Renders a graph as an adjacency-list string.

  ## Options
    * `:separator` — token separator within a line (default `" "`).
    * `:collapse_multi_edges` — when `true` (default), each unique neighbor
      appears once per line; when `false`, repeated edges between the same
      pair produce repeated neighbor tokens.

  Raises `ArgumentError` for a vertex id that this format cannot carry
  (see "Simple ids only" above).

  ## Examples

      iex> g = Grafi.Graph.new() |> Grafi.Graph.add_edge(:a, :b)
      iex> Grafi.Serialize.AdjacencyList.to_adjacency_list(g) |> String.split("\\n") |> Enum.sort()
      ["a b", "b"]
  """
  @spec to_adjacency_list(Graph.t(), keyword()) :: String.t()
  def to_adjacency_list(%Graph{} = g, opts \\ []) do
    sep = Keyword.get(opts, :separator, " ")
    token = &LineIds.vertex_token!(&1, sep, "an adjacency list")
    collapse? = Keyword.get(opts, :collapse_multi_edges, true)

    Graph.vertices(g)
    |> Enum.map(fn v ->
      neighbors =
        if collapse? do
          Graph.out_neighbors(g, v)
        else
          for {to, edges} <- Map.get(g.out_edges, v, %{}), _e <- edges, do: to
        end

      [token.(v) | Enum.map(neighbors, token)]
      |> Enum.join(sep)
    end)
    |> Enum.join("\n")
  end

  @doc """
  Parses an adjacency-list string into a `Grafi.Graph`.

  ## Options
    * `:directed` — `true` (default) or `false`.
    * `:separator` — token separator. By default tokens are separated by
      any run of whitespace. When given, each line is split on exactly this
      string and every token is trimmed of surrounding whitespace, so
      vertex names may contain spaces. An empty token makes the line
      malformed.
    * `:vertices_as_atoms` — if `true`, a vertex token that names an
      existing atom becomes that atom; any other token stays a string.
      Input never creates atoms (the atom table is not garbage-collected).
      Default `false` (strings).
    * `:max_bytes` — maximum input size in bytes (default 64 MiB, or
      `:infinity`). Larger input returns `{:error, {:too_large, size, max}}`.

  Returns the graph on success or `{:error, reason}`, e.g.
  `{:malformed_line, line}` for an empty token under a custom separator
  (the `line` cut to its first 200 bytes).

  ## Examples

      iex> g = Grafi.Serialize.AdjacencyList.from_adjacency_list("a b\\nb")
      iex> {Grafi.Graph.num_vertices(g), Grafi.Graph.num_edges(g)}
      {2, 1}
  """
  @spec from_adjacency_list(String.t(), keyword()) :: Graph.t() | {:error, term()}
  def from_adjacency_list(text, opts \\ []) when is_binary(text) do
    with :ok <- Util.check_size(text, opts) do
      parse(text, opts)
    end
  end

  # ── Internal ──────────────────────────────────────────────────────────

  defp parse(text, opts) do
    type = if Keyword.get(opts, :directed, true), do: :directed, else: :undirected
    atoms? = Keyword.get(opts, :vertices_as_atoms, false)
    split = Util.field_splitter(Keyword.get(opts, :separator))

    Util.reduce_lines(text, Graph.new(type: type), "#", fn line, g ->
      # A non-empty line always splits into at least one token.
      [source | neighbors] = tokens = split.(line)

      if "" in tokens,
        do: {:halt, {:error, {:malformed_line, Util.excerpt(line)}}},
        else: {:cont, add_line(g, source, neighbors, atoms?)}
    end)
  end

  defp add_line(g, source, neighbors, atoms?) do
    s = Util.cast_vertex(source, atoms?)

    Enum.reduce(neighbors, Graph.add_vertex(g, s), fn n, acc ->
      Graph.add_edge(acc, s, Util.cast_vertex(n, atoms?))
    end)
  end
end
