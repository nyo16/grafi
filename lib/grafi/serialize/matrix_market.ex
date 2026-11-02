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

  ## Vertex ids

  Each id is written with its type:

    * integers as `int:7`, floats as `float:2.5` and atoms as `atom:name`;
    * strings as they are, except that a string starting with `int:`,
      `atom:`, `float:` or `str:` (or an empty string) is written as
      `str:` followed by the string, so it reads back as the same string;
    * any other term (e.g. a tuple) as its `inspect/1` text, which reads
      back as a string: `{:a, 1}` becomes `"{:a, 1}"`.

  In string and atom text, `%` and every whitespace character are
  percent-encoded (`%25`, `%20`, `%C2%A0`, ...), so an id stays on its
  line and survives line trimming. Atoms are only read back when they
  already exist; otherwise they become strings. Integer ids longer than
  19 characters read back as strings.

  ## Limitations

  Matrix Market coordinate format stores a single value per (i, j) cell.
  Parallel multi-edges between the same pair collapse: their weights are
  summed on the encoder side, which is the conventional reading of an
  adjacency matrix. Edge labels are dropped.

  Reference: <https://math.nist.gov/MatrixMarket/formats.html>
  """

  alias Grafi.Graph
  alias Grafi.Serialize.Util

  @default_max_vertices 1_000_000

  # A string starting with one of these would read back as another id type.
  @reserved_prefixes ["int:", "atom:", "float:", "str:"]
  @max_int_id_bytes 1024

  # The codepoints String.trim/1 removes (Unicode White_Space): percent-
  # encoded in ids, since every line is trimmed on decode.
  @whitespace Enum.concat([
                [0x09, 0x0A, 0x0B, 0x0C, 0x0D, 0x20, 0x85, 0xA0, 0x1680],
                Enum.to_list(0x2000..0x200A),
                [0x2028, 0x2029, 0x202F, 0x205F, 0x3000]
              ])

  defguardp is_hex(c) when c in ?0..?9 or c in ?a..?f or c in ?A..?F

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
      `%GRAFI_VERTEX` line, a repeated index, or an id that another
      vertex already has (including the integer id `i` of a row without
      a comment).
    * `:missing_size_line` / `:bad_size_line`: no `rows cols nnz` line, or
      one that is not three non-negative integers.
    * `{:too_many_vertices, n}`: `rows` or `cols` exceeds `:max_vertices`.
      Checked before any vertex is allocated.
    * `{:malformed_entry, line}`: an entry that is not `i j [value]`.
    * `{:invalid_weight, value}`: a value that is not a finite number.
    * `{:index_out_of_range, i}`: an index outside `1..rows` / `1..cols`.
    * `{:nnz_mismatch, declared, seen}`: the entry count differs from `nnz`.

  Input text in an error (`line`, `value`, a bad `index`) is cut to its
  first 200 bytes.

  ## Options

    * `:max_bytes` - maximum input size in bytes (default 64 MiB, or
      `:infinity`).
    * `:max_vertices` - maximum `rows`/`cols` (default 1_000_000, or
      `:infinity`). The graph gets `max(rows, cols)` vertices whatever the
      number of entries, so a short header can declare a huge graph. Each
      vertex takes about 250 bytes once built (more while building), so
      the default allows a graph of about 250 MB from a one-line header.
  """
  @spec from_matrix_market(String.t(), keyword()) :: Graph.t() | {:error, term()}
  def from_matrix_market(text, opts \\ []) when is_binary(text) do
    max_vertices = max_vertices!(opts)

    with :ok <- Util.check_size(text, opts) do
      text
      |> Util.reduce_lines(:header, nil, &parse_line(&1, &2, max_vertices))
      |> finish()
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

  # A state machine over the lines (`%` lines carry data, so none are
  # skipped as comments):
  #   :header → {:ids, type, id_map, taken} → {:entries, g, dims, id_map, seen}
  # `taken` maps each decoded id back to its index, to reject collisions.
  defp parse_line(line, :header, _max) do
    case parse_header(line) do
      {:ok, type} -> {:cont, {:ids, type, %{}, %{}}}
      error -> {:halt, error}
    end
  end

  defp parse_line("%GRAFI_VERTEX " <> rest, {:ids, type, id_map, taken}, _max) do
    case vertex_comment(rest, id_map, taken) do
      {:ok, idx, id} ->
        {:cont, {:ids, type, Map.put(id_map, idx, id), Map.put(taken, id, idx)}}

      error ->
        {:halt, error}
    end
  end

  # Skip other comments while continuing to scan for GRAFI_VERTEX ones.
  defp parse_line("%" <> _, {:ids, _type, _id_map, _taken} = state, _max), do: {:cont, state}

  defp parse_line(line, {:ids, type, id_map, _taken}, max) do
    with {:ok, rows, cols, nnz} <- parse_size_line(line),
         n = max(rows, cols),
         :ok <- check_vertex_count(n, max),
         :ok <- check_fallback_ids(id_map, n) do
      {:cont, {:entries, initial_graph(type, n, id_map), {rows, cols, nnz}, id_map, 0}}
    else
      error -> {:halt, error}
    end
  end

  defp parse_line(line, {:entries, g, {rows, cols, _nnz} = dims, id_map, seen}, _max) do
    with {:ok, i, j, w} <- parse_entry(line),
         :ok <- check_index(i, rows),
         :ok <- check_index(j, cols) do
      from = Map.get(id_map, i, i)
      to = Map.get(id_map, j, j)
      {:cont, {:entries, Graph.add_edge(g, from, to, weight: w), dims, id_map, seen + 1}}
    else
      error -> {:halt, error}
    end
  end

  defp finish({:error, _} = error), do: error
  defp finish(:header), do: {:error, :missing_header}
  defp finish({:ids, _type, _id_map, _taken}), do: {:error, :missing_size_line}
  defp finish({:entries, g, {_rows, _cols, nnz}, _id_map, nnz}), do: g

  defp finish({:entries, _g, {_rows, _cols, nnz}, _id_map, seen}),
    do: {:error, {:nnz_mismatch, nnz, seen}}

  defp parse_header("%%MatrixMarket" <> rest) do
    parts = rest |> String.split() |> Enum.map(&String.downcase/1)

    case parts do
      ["matrix", "coordinate", _field, sym] when sym in ["general", "symmetric"] ->
        type = if sym == "symmetric", do: :undirected, else: :directed
        {:ok, type}

      _ ->
        {:error, :bad_header}
    end
  end

  defp parse_header(_line), do: {:error, :missing_header}

  defp vertex_comment(rest, id_map, taken) do
    case String.split(rest, " ", parts: 2) do
      [idx_str, id_str] ->
        case Util.parse_int(idx_str) do
          {:ok, idx} ->
            id = decode_id(id_str)

            if is_map_key(id_map, idx) or is_map_key(taken, id),
              do: {:error, {:bad_vertex_comment, idx}},
              else: {:ok, idx, id}

          :error ->
            {:error, {:bad_vertex_comment, Util.excerpt(idx_str)}}
        end

      _ ->
        {:error, :bad_vertex_comment}
    end
  end

  # A row without a comment gets its index as id, so a comment id equal to
  # such an index would merge two rows.
  defp check_fallback_ids(id_map, n) do
    Enum.find_value(id_map, :ok, fn {idx, id} ->
      if idx in 1..n//1 and is_integer(id) and id in 1..n//1 and id != idx and
           not is_map_key(id_map, id),
         do: {:error, {:bad_vertex_comment, idx}}
    end)
  end

  defp check_vertex_count(_n, :infinity), do: :ok
  defp check_vertex_count(n, max) when n > max, do: {:error, {:too_many_vertices, n}}
  defp check_vertex_count(_n, _max), do: :ok

  # Vertices in canonical 1..n order so isolated rows remain.
  defp initial_graph(type, n, id_map) do
    Enum.reduce(1..n//1, Graph.new(type: type), fn i, acc ->
      Graph.add_vertex(acc, Map.get(id_map, i, i))
    end)
  end

  defp parse_size_line(line) do
    with [r, c, nnz] <- String.split(line),
         {:ok, ri} when ri >= 0 <- Util.parse_int(r),
         {:ok, ci} when ci >= 0 <- Util.parse_int(c),
         {:ok, ni} when ni >= 0 <- Util.parse_int(nnz) do
      {:ok, ri, ci, ni}
    else
      _ -> {:error, :bad_size_line}
    end
  end

  defp check_index(i, max) when i >= 1 and i <= max, do: :ok
  defp check_index(i, _max), do: {:error, {:index_out_of_range, i}}

  defp parse_entry(line) do
    with [i, j | value] when length(value) <= 1 <- String.split(line),
         {:ok, ii} <- Util.parse_int(i),
         {:ok, jj} <- Util.parse_int(j),
         {:ok, weight} <- parse_value(value) do
      {:ok, ii, jj, weight}
    else
      {:error, {:invalid_weight, _}} = error -> error
      _ -> {:error, {:malformed_entry, Util.excerpt(line)}}
    end
  end

  # Pattern matrices omit the value; the entry is an unweighted edge.
  defp parse_value([]), do: {:ok, 1.0}
  defp parse_value([w]), do: Util.parse_weight(w)

  defp encode_id(v) when is_binary(v) do
    if v == "" or String.starts_with?(v, @reserved_prefixes),
      do: "str:" <> percent_encode(v),
      else: percent_encode(v)
  end

  defp encode_id(v) when is_atom(v), do: "atom:" <> percent_encode(Atom.to_string(v))
  defp encode_id(v) when is_integer(v), do: "int:" <> Integer.to_string(v)
  defp encode_id(v) when is_float(v), do: "float:" <> Float.to_string(v)
  defp encode_id(v), do: encode_id(inspect(v))

  defp decode_id("str:" <> rest), do: percent_decode(rest)

  # Use `to_existing_atom` so a malicious file cannot exhaust the atom table
  # (atoms are never garbage-collected). Ids whose atom was never created in
  # this VM degrade to their string form rather than minting a new atom.
  defp decode_id("atom:" <> rest), do: rest |> percent_decode() |> Util.cast_vertex(true)

  # Integer ids may legitimately be bignums (Util.parse_int's 19-character
  # cap is for indices and sizes); the bound only stops a hostile
  # multi-megabyte digit run.
  defp decode_id("int:" <> rest) when byte_size(rest) <= @max_int_id_bytes do
    case Integer.parse(rest) do
      {i, ""} -> i
      _ -> Util.own(rest)
    end
  end

  defp decode_id("int:" <> rest), do: Util.own(rest)

  defp decode_id("float:" <> rest) do
    case Util.parse_number(rest) do
      {:ok, f} -> f
      {:error, :bad_number} -> Util.own(rest)
    end
  end

  defp decode_id(s), do: percent_decode(s)

  # Percent-escapes `%` and whitespace so the single-line
  # `%GRAFI_VERTEX i id` format is unambiguous and survives trimming.
  defp percent_encode(s), do: s |> percent_encode([]) |> IO.iodata_to_binary()

  defp percent_encode(<<c::utf8, rest::binary>>, acc) when c in @whitespace do
    bytes = <<c::utf8>>
    escaped = for <<b <- bytes>>, do: ["%", Base.encode16(<<b>>)]
    percent_encode(rest, [acc | escaped])
  end

  defp percent_encode(<<?%, rest::binary>>, acc), do: percent_encode(rest, [acc | "%25"])
  defp percent_encode(<<c, rest::binary>>, acc), do: percent_encode(rest, [acc, c])
  defp percent_encode(<<>>, acc), do: acc

  # `%` followed by two hex digits is an escape; anything else is literal.
  defp percent_decode(s), do: s |> percent_decode([]) |> IO.iodata_to_binary()

  defp percent_decode(<<?%, a, b, rest::binary>>, acc) when is_hex(a) and is_hex(b),
    do: percent_decode(rest, [acc, String.to_integer(<<a, b>>, 16)])

  defp percent_decode(<<c, rest::binary>>, acc), do: percent_decode(rest, [acc, c])
  defp percent_decode(<<>>, acc), do: acc
end
