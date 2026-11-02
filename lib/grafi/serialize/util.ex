defmodule Grafi.Serialize.Util do
  @moduledoc false
  # Helpers shared by the Grafi.Serialize.* encoders and decoders: one
  # definition of how weights and vertex ids become text and back, and the
  # input limits every decoder applies.

  @default_max_bytes 64 * 1024 * 1024

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
  raises: `"1e400"`, a 400-digit integer or trailing garbage give
  `{:error, :bad_number}`.
  """
  @spec parse_number(String.t()) :: {:ok, float()} | {:error, :bad_number}
  def parse_number(s) when is_binary(s) do
    # Float.parse/1 also accepts integer text and returns :error on
    # overflow, so no Integer.parse fallback (whose `* 1.0` would raise).
    case Float.parse(s) do
      {f, ""} -> {:ok, f}
      _ -> {:error, :bad_number}
    end
  end

  @doc "Like `parse_number/1`, tagged for decoders: `{:error, {:invalid_weight, s}}`."
  @spec parse_weight(String.t()) :: {:ok, float()} | {:error, {:invalid_weight, String.t()}}
  def parse_weight(s) when is_binary(s) do
    case parse_number(s) do
      {:ok, w} -> {:ok, w}
      {:error, :bad_number} -> {:error, {:invalid_weight, s}}
    end
  end

  @doc """
  Casts a decoded vertex token. With `atoms? = true` an existing atom is
  used and anything else stays a string: input never creates atoms (the
  atom table is not garbage-collected).
  """
  @spec cast_vertex(String.t(), boolean()) :: atom() | String.t()
  def cast_vertex(s, false), do: s

  def cast_vertex(s, true) do
    String.to_existing_atom(s)
  rescue
    ArgumentError -> s
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
