defmodule Grafi.Serialize.LineIds do
  @moduledoc false
  # Encoder-side checks for the line formats (EdgeList, AdjacencyList), which
  # write vertex ids unescaped: an id must read back as the same single
  # token, so ids that would split, vanish, turn their line into a comment or
  # start a new line raise instead of being written.

  alias Grafi.Serialize.Util

  @doc """
  The text form of `v` for a line format whose encoder separator is `sep`
  (`" "` means the decoder's default whitespace splitting). Raises
  `ArgumentError` when the text could not be read back as the same id.
  """
  @spec vertex_token!(term(), String.t(), String.t()) :: String.t()
  def vertex_token!(v, sep, format) do
    s = Util.vertex_to_string(v)

    case problem(s, sep) do
      nil ->
        s

      reason ->
        raise ArgumentError,
              "cannot write vertex id #{inspect(v)} to #{format}: #{reason}; " <>
                "this format carries simple ids only"
    end
  end

  @doc "Raises `ArgumentError` for a `:comment` option that would span lines."
  @spec comment!(String.t()) :: String.t()
  def comment!(c) when is_binary(c) do
    if String.contains?(c, ["\n", "\r"]),
      do: raise(ArgumentError, "expected :comment to be a single line, got: #{inspect(c)}"),
      else: c
  end

  defp problem("", _sep), do: "it is empty"
  defp problem("#" <> _, _sep), do: "it starts with #, which marks a comment line"

  defp problem(s, sep) do
    cond do
      String.contains?(s, ["\n", "\r"]) -> "it contains a line break"
      String.trim(s) != s -> "it has leading or trailing whitespace"
      sep == " " and String.split(s) != [s] -> "it contains whitespace"
      sep != " " and String.contains?(s, sep) -> "it contains the separator #{inspect(sep)}"
      true -> nil
    end
  end
end
