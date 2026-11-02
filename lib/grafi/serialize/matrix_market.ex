defmodule Grafi.Serialize.MatrixMarket do
  @moduledoc """
  Serialize and deserialize graphs as a sparse matrix in Matrix Market
  coordinate format.

  Header:

      %%MatrixMarket matrix coordinate real general    # directed
      %%MatrixMarket matrix coordinate real symmetric  # undirected

  Body:

      rows cols nnz
      i j v
      i j v
      ...

  Indices are 1-based. The vertex-id ↔ row-index mapping is written into
  a comment block (lines beginning with `%`) so the decoder can recover
  the original ids on round-trip:

      %GRAFI_VERTEX 1 a
      %GRAFI_VERTEX 2 b

  ## Limitations

  Matrix Market coordinate format stores a single value per (i, j) cell.
  Parallel multi-edges between the same pair collapse: their weights are
  summed on the encoder side, which is the conventional reading of an
  adjacency matrix. Edge labels are dropped.

  Reference: <https://math.nist.gov/MatrixMarket/formats.html>
  """

  alias Grafi.Graph
  alias Grafi.Serialize.Util

  @default_max_vertices 10_000_000

  @doc """
  Renders a graph as a Matrix Market string.

  ## Examples

      iex> g = Grafi.Graph.new() |> Grafi.Graph.add_edge(:a, :b, weight: 2.5)
      iex> mm = Grafi.Serialize.MatrixMarket.to_matrix_market(g)
      iex> String.starts_with?(mm, "%%MatrixMarket matrix coordinate real general")
      true
  """
  @spec to_matrix_market(Graph.t(), keyword()) :: String.t()
  def to_matrix_market(%Graph{} = g, _opts \\ []) do
    vertices = Graph.vertices(g)
    n = length(vertices)
    index = vertices |> Enum.with_index(1) |> Map.new()

    symmetry = if g.type == :directed, do: "general", else: "symmetric"
    header = "%%MatrixMarket matrix coordinate real #{symmetry}"

    id_lines =
      Enum.map(vertices, fn v ->
        i = Map.fetch!(index, v)
        "%GRAFI_VERTEX #{i} #{encode_id(v)}"
      end)

    # Collapse multi-edges by summing weights into a single cell.
    cells =
      Graph.edges(g)
      |> Enum.reduce(%{}, fn e, acc ->
        i = Map.fetch!(index, e.from)
        j = Map.fetch!(index, e.to)

        key =
          if g.type == :undirected and i > j do
            {j, i}
          else
            {i, j}
          end

        Map.update(acc, key, e.weight, &(&1 + e.weight))
      end)

    nnz = map_size(cells)
    size_line = "#{n} #{n} #{nnz}"

    body_lines =
      cells
      |> Enum.sort_by(fn {{i, j}, _} -> {i, j} end)
      |> Enum.map(fn {{i, j}, w} -> "#{i} #{j} #{Util.format_weight(w)}" end)

    ([header] ++ id_lines ++ [size_line] ++ body_lines)
    |> Enum.join("\n")
  end

  @doc """
  Parses a Matrix Market string into a `Grafi.Graph`.

  Recovers vertex ids from `%GRAFI_VERTEX i ID` comment lines when present.
  Otherwise falls back to integer ids `1..n`.

  Returns the graph on success or `{:error, reason}` on parse failure:

    * `{:too_large, size, max}`: the input exceeds `:max_bytes`.
    * `:missing_header` / `:bad_header`: no `%%MatrixMarket` line, or one
      that is not a `coordinate` matrix with `general` or `symmetric`
      symmetry (`array`, `skew-symmetric` and `hermitian` are unsupported).
    * `:bad_vertex_comment` / `{:bad_vertex_comment, index}`: a malformed
      `%GRAFI_VERTEX` line.
    * `:missing_size_line` / `:bad_size_line`: no `rows cols nnz` line, or
      one that is not three non-negative integers.
    * `{:too_many_vertices, n}`: `rows` or `cols` exceeds `:max_vertices`.
      Checked before any vertex is allocated.
    * `{:malformed_entry, line}`: an entry that is not `i j [value]`.
    * `{:invalid_weight, value}`: a value that is not a finite number.
    * `{:index_out_of_range, i}`: an index outside `1..rows` / `1..cols`.
    * `{:nnz_mismatch, declared, seen}`: the entry count differs from `nnz`.

  ## Options

    * `:max_bytes` - maximum input size in bytes (default 64 MiB, or
      `:infinity`).
    * `:max_vertices` - maximum `rows`/`cols` (default 10_000_000, or
      `:infinity`). A header declaring a huge matrix would otherwise
      allocate that many vertices.
  """
  @spec from_matrix_market(String.t(), keyword()) :: Graph.t() | {:error, term()}
  def from_matrix_market(text, opts \\ []) when is_binary(text) do
    max_vertices = max_vertices!(opts)

    with :ok <- Util.check_size(text, opts),
         lines = split_lines(text),
         {:ok, type, rest} <- parse_header(lines),
         {:ok, id_map, rest} <- collect_id_comments(rest, %{}),
         rest = drop_remaining_comments(rest),
         {:ok, rows, cols, nnz, rest} <- parse_size_line(rest),
         :ok <- check_vertex_count(rows, cols, max_vertices) do
      build_from_entries(type, {rows, cols, nnz}, id_map, rest)
    end
  end

  # ── Internal ──────────────────────────────────────────────────────────

  defp max_vertices!(opts) do
    case Keyword.get(opts, :max_vertices, @default_max_vertices) do
      :infinity ->
        :infinity

      max when is_integer(max) and max >= 0 ->
        max

      other ->
        raise ArgumentError,
              "expected :max_vertices to be a non-negative integer or :infinity, " <>
                "got: #{inspect(other)}"
    end
  end

  defp split_lines(text) do
    text
    |> String.split(["\n", "\r\n"], trim: false)
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
  end

  defp check_vertex_count(_rows, _cols, :infinity), do: :ok

  defp check_vertex_count(rows, cols, max) do
    n = max(rows, cols)
    if n > max, do: {:error, {:too_many_vertices, n}}, else: :ok
  end

  defp parse_header(["%%MatrixMarket" <> rest | tail]) do
    parts = rest |> String.split() |> Enum.map(&String.downcase/1)

    case parts do
      ["matrix", "coordinate", _field, sym] when sym in ["general", "symmetric"] ->
        type = if sym == "symmetric", do: :undirected, else: :directed
        {:ok, type, tail}

      _ ->
        {:error, :bad_header}
    end
  end

  defp parse_header(_), do: {:error, :missing_header}

  defp collect_id_comments(["%GRAFI_VERTEX " <> rest | tail], acc) do
    case String.split(rest, " ", parts: 2) do
      [idx_str, id_str] ->
        case Integer.parse(idx_str) do
          {idx, ""} ->
            collect_id_comments(tail, Map.put(acc, idx, decode_id(id_str)))

          _ ->
            {:error, {:bad_vertex_comment, idx_str}}
        end

      _ ->
        {:error, :bad_vertex_comment}
    end
  end

  defp collect_id_comments(["%" <> _ | tail], acc) do
    # Skip non-GRAFI_VERTEX comments while continuing to scan for them.
    collect_id_comments(tail, acc)
  end

  defp collect_id_comments(lines, acc), do: {:ok, acc, lines}

  defp drop_remaining_comments(lines),
    do: Enum.drop_while(lines, &String.starts_with?(&1, "%"))

  defp parse_size_line([line | rest]) do
    case String.split(line) do
      [r, c, nnz] ->
        with {ri, ""} when ri >= 0 <- Integer.parse(r),
             {ci, ""} when ci >= 0 <- Integer.parse(c),
             {ni, ""} when ni >= 0 <- Integer.parse(nnz) do
          {:ok, ri, ci, ni, rest}
        else
          _ -> {:error, :bad_size_line}
        end

      _ ->
        {:error, :bad_size_line}
    end
  end

  defp parse_size_line([]), do: {:error, :missing_size_line}

  defp build_from_entries(type, {rows, cols, nnz}, id_map, body_lines) do
    # Initialize vertices in canonical 1..n order so isolated rows remain.
    g =
      Enum.reduce(1..max(rows, cols)//1, Graph.new(type: type), fn i, acc ->
        Graph.add_vertex(acc, Map.get(id_map, i, i))
      end)

    result =
      Enum.reduce_while(body_lines, {g, 0}, fn line, {g, seen} ->
        with {:ok, i, j, w} <- parse_entry(line),
             :ok <- check_index(i, rows),
             :ok <- check_index(j, cols) do
          from = Map.get(id_map, i, i)
          to = Map.get(id_map, j, j)
          {:cont, {Graph.add_edge(g, from, to, weight: w), seen + 1}}
        else
          {:error, _} = error -> {:halt, error}
        end
      end)

    case result do
      {:error, _} = error -> error
      {g, ^nnz} -> g
      {_g, seen} -> {:error, {:nnz_mismatch, nnz, seen}}
    end
  end

  defp check_index(i, max) when i >= 1 and i <= max, do: :ok
  defp check_index(i, _max), do: {:error, {:index_out_of_range, i}}

  defp parse_entry(line) do
    case String.split(line) do
      [i, j | value] when length(value) <= 1 ->
        with {ii, ""} <- Integer.parse(i),
             {jj, ""} <- Integer.parse(j),
             {:ok, weight} <- parse_value(value) do
          {:ok, ii, jj, weight}
        else
          {:error, {:invalid_weight, _}} = error -> error
          _ -> {:error, {:malformed_entry, line}}
        end

      _ ->
        {:error, {:malformed_entry, line}}
    end
  end

  # Pattern matrices omit the value; the entry is an unweighted edge.
  defp parse_value([]), do: {:ok, 1.0}
  defp parse_value([w]), do: Util.parse_weight(w)

  defp encode_id(v) when is_binary(v), do: percent_encode(v)
  defp encode_id(v) when is_atom(v), do: "atom:" <> percent_encode(Atom.to_string(v))
  defp encode_id(v) when is_integer(v), do: "int:" <> Integer.to_string(v)
  defp encode_id(v) when is_float(v), do: "float:" <> Float.to_string(v)
  defp encode_id(v), do: percent_encode(inspect(v))

  # Use `to_existing_atom` so a malicious file cannot exhaust the atom table
  # (atoms are never garbage-collected). Ids whose atom was never created in
  # this VM degrade to their string form rather than minting a new atom.
  defp decode_id("atom:" <> rest) do
    rest |> percent_decode() |> Util.cast_vertex(true)
  end

  defp decode_id("int:" <> rest) do
    case Integer.parse(rest) do
      {i, ""} -> i
      _ -> rest
    end
  end

  defp decode_id("float:" <> rest) do
    case Float.parse(rest) do
      {f, ""} -> f
      _ -> rest
    end
  end

  defp decode_id(s), do: percent_decode(s)

  # Minimal percent-escape for whitespace/newlines/percent so the single-line
  # `%GRAFI_VERTEX i id` format is unambiguous.
  defp percent_encode(s) do
    for <<c <- s>>, into: <<>> do
      case c do
        ?% -> "%25"
        ?\s -> "%20"
        ?\t -> "%09"
        ?\n -> "%0A"
        ?\r -> "%0D"
        _ -> <<c>>
      end
    end
  end

  defp percent_decode(s) do
    do_decode(s, <<>>)
  end

  defp do_decode(<<>>, acc), do: acc

  defp do_decode(<<"%", a, b, rest::binary>>, acc) do
    case Integer.parse(<<a, b>>, 16) do
      {n, ""} -> do_decode(rest, acc <> <<n>>)
      _ -> do_decode(rest, acc <> <<?%, a, b>>)
    end
  end

  defp do_decode(<<c, rest::binary>>, acc), do: do_decode(rest, acc <> <<c>>)
end
