defmodule Grafi.Serialize.Util do
  @moduledoc false
  # Helpers shared by the Grafi.Serialize.* encoders and decoders: one
  # definition of how weights and vertex ids become text and back, and the
  # input limits every decoder applies.

  @default_max_bytes 64 * 1024 * 1024
  @max_number_bytes 256
  @max_int_bytes 19
  @max_excerpt_bytes 200

  @doc """
  Formats an edge weight for output. Weights are numbers (see
  `Grafi.Graph.add_edge/4`); anything else raises `ArgumentError`.
  """
  @spec format_weight(number()) :: String.t()
  def format_weight(w) when is_float(w), do: Float.to_string(w)
  def format_weight(w) when is_integer(w), do: Integer.to_string(w)

  def format_weight(w),
    do: raise(ArgumentError, "expected a numeric edge weight, got: #{inspect(w)}")

  @doc "The text form of a vertex id (strings as-is, other terms via their natural text)."
  @spec vertex_to_string(term()) :: String.t()
  def vertex_to_string(v) when is_binary(v), do: v
  def vertex_to_string(v) when is_atom(v), do: Atom.to_string(v)
  def vertex_to_string(v) when is_integer(v), do: Integer.to_string(v)
  def vertex_to_string(v) when is_float(v), do: Float.to_string(v)
  def vertex_to_string(v), do: inspect(v)

  @doc """
  Parses a whole string as a finite number, returned as a float. Never
  raises: `"1e400"`, a 400-digit integer, trailing garbage or text longer
  than #{@max_number_bytes} bytes give `{:error, :bad_number}`.
  """
  @spec parse_number(String.t()) :: {:ok, float()} | {:error, :bad_number}
  def parse_number(s) when is_binary(s) and byte_size(s) > @max_number_bytes,
    do: {:error, :bad_number}

  def parse_number(s) when is_binary(s) do
    # Float.parse/1 also accepts integer text, so no Integer.parse fallback
    # (whose `* 1.0` would raise on overflow).
    case Float.parse(s) do
      {f, ""} -> {:ok, f}
      _ -> {:error, :bad_number}
    end
  rescue
    # Elixir < 1.20 raises (instead of returning :error) when the digits
    # overflow a float, e.g. a 400-digit integer.
    ArgumentError -> {:error, :bad_number}
  end

  @doc """
  Parses a whole string as an integer of at most #{@max_int_bytes}
  characters (sign included), so a hostile digit run is rejected before any
  bignum work.
  """
  @spec parse_int(String.t()) :: {:ok, integer()} | :error
  def parse_int(s) when is_binary(s) and byte_size(s) <= @max_int_bytes do
    case Integer.parse(s) do
      {n, ""} -> {:ok, n}
      _ -> :error
    end
  end

  def parse_int(s) when is_binary(s), do: :error

  @doc """
  Like `parse_number/1`, tagged for decoders: `{:error, {:invalid_weight,
  text}}`, where `text` is an `excerpt/1` of the token.
  """
  @spec parse_weight(String.t()) :: {:ok, float()} | {:error, {:invalid_weight, String.t()}}
  def parse_weight(s) when is_binary(s) do
    case parse_number(s) do
      {:ok, w} -> {:ok, w}
      {:error, :bad_number} -> {:error, {:invalid_weight, excerpt(s)}}
    end
  end

  @doc """
  Casts a decoded vertex token. With `atoms? = true` an existing atom is
  used and anything else stays a string: input never creates atoms (the
  atom table is not garbage-collected).
  """
  @spec cast_vertex(String.t(), boolean()) :: atom() | String.t()
  def cast_vertex(s, false), do: own(s)

  def cast_vertex(s, true) do
    String.to_existing_atom(s)
  rescue
    # SystemLimitError: longer than any atom can be.
    _ in [ArgumentError, SystemLimitError] -> own(s)
  end

  @doc """
  A decoded token as its own binary. Tokens are sub-binaries of the input;
  keeping one (as a vertex id or label) would otherwise keep the whole
  input alive.
  """
  @spec own(binary()) :: binary()
  def own(s) when is_binary(s) do
    if :binary.referenced_byte_size(s) > byte_size(s), do: :binary.copy(s), else: s
  end

  @doc """
  Input text for an error payload: an owned copy of at most
  #{@max_excerpt_bytes} bytes, so errors neither pin the input nor carry
  megabytes into logs.
  """
  @spec excerpt(binary()) :: binary()
  def excerpt(s) when is_binary(s) and byte_size(s) > @max_excerpt_bytes,
    do: :binary.copy(binary_part(s, 0, @max_excerpt_bytes)) <> "..."

  def excerpt(s) when is_binary(s), do: own(s)

  @doc """
  Reduces over the lines of `text` (split on `\\n`, trimmed, so `\\r\\n`
  works too) without materialising them: memory stays bounded by one line,
  whatever the input. Blank lines are skipped, and so are lines starting
  with `comment` unless it is `nil`. `fun` returns `{:cont, acc}` or
  `{:halt, result}`; the result is the final `acc` or the halted value.
  """
  @spec reduce_lines(binary(), acc, String.t() | nil, (String.t(), acc ->
                                                         {:cont, acc} | {:halt, term()})) ::
          term()
        when acc: term()
  def reduce_lines(text, acc, comment, fun) when is_binary(text),
    do: reduce_lines(text, 0, byte_size(text), acc, comment, fun)

  defp reduce_lines(_text, pos, size, acc, _comment, _fun) when pos >= size, do: acc

  # Fast path: leading ASCII whitespace and empty lines (trimmed anyway).
  defp reduce_lines(text, pos, size, acc, comment, fun)
       when :erlang.binary_part(text, pos, 1) in ["\n", "\r", " ", "\t"],
       do: reduce_lines(text, pos + 1, size, acc, comment, fun)

  defp reduce_lines(text, pos, size, acc, comment, fun) do
    stop =
      case :binary.match(text, "\n", scope: {pos, size - pos}) do
        {i, 1} -> i
        :nomatch -> size
      end

    result =
      case String.trim(binary_part(text, pos, stop - pos)) do
        "" ->
          {:cont, acc}

        line ->
          if comment && String.starts_with?(line, comment),
            do: {:cont, acc},
            else: fun.(line, acc)
      end

    case result do
      {:cont, acc} -> reduce_lines(text, stop + 1, size, acc, comment, fun)
      {:halt, value} -> value
    end
  end

  @doc """
  Applies the `:max_bytes` option (default 64 MiB, or `:infinity`) to a
  decoder's input. Raises `ArgumentError` for an invalid option value.
  """
  @spec check_size(binary(), keyword()) ::
          :ok | {:error, {:too_large, non_neg_integer(), pos_integer()}}
  def check_size(text, opts) when is_binary(text) do
    case Keyword.get(opts, :max_bytes, @default_max_bytes) do
      :infinity ->
        :ok

      max when is_integer(max) and max > 0 ->
        if byte_size(text) <= max, do: :ok, else: {:error, {:too_large, byte_size(text), max}}

      other ->
        raise ArgumentError,
              "expected :max_bytes to be a positive integer or :infinity, got: #{inspect(other)}"
    end
  end

  @doc """
  A line-splitting function for the `:separator` option: `nil` splits on
  runs of whitespace; a string splits on exactly that string and trims each
  field (so fields may contain spaces). Raises `ArgumentError` otherwise.
  """
  @spec field_splitter(String.t() | nil) :: (String.t() -> [String.t()])
  def field_splitter(nil), do: &String.split/1

  def field_splitter(sep) when is_binary(sep) and sep != "" do
    fn line -> line |> String.split(sep) |> Enum.map(&String.trim/1) end
  end

  def field_splitter(other),
    do: raise(ArgumentError, "expected :separator to be a non-empty string, got: #{inspect(other)}")
end
