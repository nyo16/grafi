defmodule Grafi.Serialize.AdjacencyList do
  @moduledoc """
  Serialize and deserialize graphs to a plain-text adjacency list.

  One line per source vertex:

      source neighbor1 neighbor2 neighbor3 ...

  Tokens are whitespace-separated. Lines beginning with `#` are comments.
  Isolated vertices appear as a single-token line (just the vertex id).

  ## Limitations

  This format carries neither edge weights nor edge/vertex labels. For
  weighted graphs use `Grafi.Serialize.EdgeList`; for labels use GraphML
  or JSON. Parallel (multi-) edges between the same pair collapse into a
  single neighbor entry by default; pass `:collapse_multi_edges` to `false`
  on the encoder to emit duplicates (decoder will then re-add them).

  Reference: <https://en.wikipedia.org/wiki/Adjacency_list>
  """

  alias Grafi.Graph

  @doc """
  Renders a graph as an adjacency-list string.

  ## Options
    * `:separator` — token separator within a line (default `" "`).
    * `:collapse_multi_edges` — when `true` (default), each unique neighbor
      appears once per line; when `false`, repeated edges between the same
      pair produce repeated neighbor tokens.

  ## Examples

      iex> g = Grafi.Graph.new() |> Grafi.Graph.add_edge(:a, :b)
      iex> Grafi.Serialize.AdjacencyList.to_adjacency_list(g) |> String.split("\\n") |> Enum.sort()
      ["a b", "b"]
  """
  @spec to_adjacency_list(Graph.t(), keyword()) :: String.t()
  def to_adjacency_list(%Graph{} = g, opts \\ []) do
    sep = Keyword.get(opts, :separator, " ")
    collapse? = Keyword.get(opts, :collapse_multi_edges, true)

    Graph.vertices(g)
    |> Enum.map(fn v ->
      neighbors =
        if collapse? do
          Graph.out_neighbors(g, v)
        else
          for {to, edges} <- Map.get(g.out_edges, v, %{}), _e <- edges, do: to
        end

      [to_token(v) | Enum.map(neighbors, &to_token/1)]
      |> Enum.join(sep)
    end)
    |> Enum.join("\n")
  end

  @doc """
  Parses an adjacency-list string into a `Grafi.Graph`.

  ## Options
    * `:directed` — `true` (default) or `false`.
    * `:vertices_as_atoms` — if `true`, cast tokens via `String.to_atom/1`.
      Defaults to `false` to avoid the atom-table attack.

  Returns the graph on success or `{:error, reason}` on parse failure.

  ## Examples

      iex> g = Grafi.Serialize.AdjacencyList.from_adjacency_list("a b\\nb")
      iex> {Grafi.Graph.num_vertices(g), Grafi.Graph.num_edges(g)}
      {2, 1}
  """
  @spec from_adjacency_list(String.t(), keyword()) :: Graph.t() | {:error, term()}
  def from_adjacency_list(text, opts \\ []) when is_binary(text) do
    directed = Keyword.get(opts, :directed, true)
    type = if directed, do: :directed, else: :undirected
    atoms? = Keyword.get(opts, :vertices_as_atoms, false)

    lines =
      text
      |> String.split(["\n", "\r\n"], trim: false)
      |> Enum.map(&String.trim/1)
      |> Enum.reject(&(&1 == "" or String.starts_with?(&1, "#")))

    Enum.reduce_while(lines, Graph.new(type: type), fn line, g ->
      case String.split(line, ~r/\s+/, trim: true) do
        [] ->
          {:cont, g}

        [source | neighbors] ->
          s = cast_vertex(source, atoms?)
          g = Graph.add_vertex(g, s)

          g =
            Enum.reduce(neighbors, g, fn n, acc ->
              Graph.add_edge(acc, s, cast_vertex(n, atoms?))
            end)

          {:cont, g}
      end
    end)
  rescue
    e -> {:error, Exception.message(e)}
  end

  # ── Internal ──────────────────────────────────────────────────────────

  defp to_token(v) when is_binary(v), do: v
  defp to_token(v) when is_atom(v), do: Atom.to_string(v)
  defp to_token(v) when is_integer(v), do: Integer.to_string(v)
  defp to_token(v) when is_float(v), do: Float.to_string(v)
  defp to_token(v), do: inspect(v)

  defp cast_vertex(s, true), do: String.to_atom(s)
  defp cast_vertex(s, false), do: s
end
