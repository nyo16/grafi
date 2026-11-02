defmodule Grafi.Serialize.XML do
  @moduledoc false
  # XML text escaping shared by the GraphML and GEXF serializers.

  @entity ~r/&(lt|gt|quot|apos|amp|#[0-9]+|#x[0-9a-fA-F]+);/

  @doc "Escapes text for use in an XML attribute value or element text."
  @spec escape(String.t()) :: String.t()
  def escape(s) when is_binary(s) do
    for <<c::utf8 <- s>>, into: "" do
      case c do
        ?& -> "&amp;"
        ?< -> "&lt;"
        ?> -> "&gt;"
        ?" -> "&quot;"
        ?' -> "&apos;"
        c -> <<c::utf8>>
      end
    end
  end

  @doc """
  Decodes the five predefined entities and numeric character references in
  one pass (so `&amp;lt;` becomes `&lt;`, not `<`). An unknown or invalid
  reference is kept as is.
  """
  @spec unescape(String.t()) :: String.t()
  def unescape(s) when is_binary(s), do: Regex.replace(@entity, s, &decode/2)

  defp decode(_, "lt"), do: "<"
  defp decode(_, "gt"), do: ">"
  defp decode(_, "quot"), do: "\""
  defp decode(_, "apos"), do: "'"
  defp decode(_, "amp"), do: "&"
  defp decode(whole, "#x" <> hex), do: codepoint(whole, String.to_integer(hex, 16))
  defp decode(whole, "#" <> dec), do: codepoint(whole, String.to_integer(dec))

  defp codepoint(_whole, n) when n in 0..0x10FFFF and n not in 0xD800..0xDFFF, do: <<n::utf8>>
  defp codepoint(whole, _n), do: whole
end
