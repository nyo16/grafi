defmodule Grafi.Serialize.XMLTest do
  use ExUnit.Case, async: true

  alias Grafi.Graph
  alias Grafi.Serialize.{GEXF, GraphML, XML}

  @illegal ["a\u0001b", "\v", "x\fy", "nul\0", <<0xEF, 0xBF, 0xBE>>, <<0xEF, 0xBF, 0xBF>>]

  describe "escape/1 and escape_attr/1" do
    test "raise on invalid UTF-8 instead of truncating" do
      for escape <- [&XML.escape/1, &XML.escape_attr/1], s <- [<<"ab", 0xE9, "cd">>, <<0xFF>>] do
        assert_raise ArgumentError, fn -> escape.(s) end
      end
    end

    test "raise on characters outside XML 1.0 Char" do
      for escape <- [&XML.escape/1, &XML.escape_attr/1, &XML.char_refs/1], s <- @illegal do
        assert_raise ArgumentError, fn -> escape.(s) end
      end
    end

    test "text keeps tab and LF but writes CR as a reference" do
      assert XML.escape("a\tb\nc\rd") == "a\tb\nc&#13;d"
    end

    test "attribute values write tab, LF and CR as references" do
      escaped = XML.escape_attr("a\tb\nc\rd")
      refute escaped =~ ~r/[\t\n\r]/
      assert XML.unescape(escaped) == {:ok, "a\tb\nc\rd"}
    end

    test "both escape the markup characters" do
      for escape <- [&XML.escape/1, &XML.escape_attr/1] do
        assert XML.unescape(escape.(~s(<a href="x">&'</a>))) == {:ok, ~s(<a href="x">&'</a>)}
        refute escape.(~s(<"&'>)) =~ ~r/[<>"']/
      end
    end
  end

  describe "unescape/1" do
    test "decodes entities and bounded character references" do
      assert XML.unescape("&amp;lt; &#65;&#x42;&#0000067; &#x10FFFF;") ==
               {:ok, "&lt; ABC \u{10FFFF}"}
    end

    test "keeps an unknown entity or a bare ampersand" do
      assert XML.unescape("a & b &nbsp;") == {:ok, "a & b &nbsp;"}
    end

    test "rejects references to characters outside XML 1.0 Char" do
      for ref <- ["&#0;", "&#11;", "&#xD800;", "&#xFFFE;", "&#x110000;", "&#1114112;"] do
        assert {:error, {:invalid_char_ref, _}} = XML.unescape("a" <> ref <> "b")
      end
    end

    test "rejects malformed or unbounded character references" do
      for ref <- ["&#;", "&#x;", "&#65", "&#X41;", "&#00000065;", "&#x0000041;"] do
        assert {:error, {:invalid_char_ref, _}} = XML.unescape(ref <> " tail")
      end
    end

    test "a huge digit run is rejected with a bounded payload" do
      s = "&#" <> String.duplicate("1", 1_000_000) <> ";"
      assert {:error, {:invalid_char_ref, ref}} = XML.unescape(s)
      assert byte_size(ref) <= 203
    end

    test "returns a binary that does not reference the input" do
      input = String.duplicate("x", 10_000)

      for part <- [binary_part(input, 100, 100), binary_part(input <> "&amp;", 9_900, 105)] do
        {:ok, decoded} = XML.unescape(part)
        assert :binary.referenced_byte_size(decoded) < byte_size(input)
      end
    end
  end

  # The scanner is shared: every case runs against both decoders.
  for format <- [:graphml, :gexf] do
    describe "#{format} decoder differentials" do
      @format format

      test "markup inside CDATA is not read as elements" do
        xml =
          doc(
            @format,
            ~s(<node id="a"><data key="note"><![CDATA[</node><edge source="a" target="admin"/>]]></data></node>)
          )

        g = decode(@format, xml)
        assert Graph.vertices(g) == ["a"]
        assert Graph.num_edges(g) == 0
      end

      test "comments and processing instructions are skipped" do
        xml =
          ~s(<!-- <graph #{type_attr(@format)}="undirected"> -->) <>
            doc(@format, ~s(<!-- <node id="ghost"/> --><?pi <node id="pi"/> ?><node id="a"/>))

        g = decode(@format, xml)
        assert g.type == :directed
        assert Graph.vertices(g) == ["a"]
      end

      test "an element name must end at whitespace, / or >" do
        xml =
          doc(
            @format,
            ~s(<node-meta id="x"/><node.x id="y"/><node:x id="z"/><nodeé id="w"/><edges/>) <>
              ~s(<edge-x source="x" target="y"/><node\tid="a"/>)
          )

        g = decode(@format, xml)
        assert Graph.vertices(g) == ["a"]
        assert Graph.num_edges(g) == 0
      end

      test "attribute names are whole XML names" do
        xml = doc(@format, ~s(<edge source="a" target="b" ñtarget="admin" x.target="c"/>))
        g = decode(@format, xml)
        assert Enum.sort(Graph.vertices(g)) == ["a", "b"]
        assert Graph.has_edge?(g, "a", "b")
      end

      test "a duplicate attribute is an error" do
        xml = doc(@format, ~s(<edge source="a" target="b" target="admin"/>))
        assert decode(@format, xml) == {:error, {:duplicate_attribute, "target"}}
      end

      test "> inside a quoted attribute value is part of the value" do
        xml = doc(@format, ~s(<edge note=">" source="x" target='y>'/>))
        assert Graph.has_edge?(decode(@format, xml), "x", "y>")
      end

      test "<!DOCTYPE is rejected" do
        xml = ~s(<!DOCTYPE g [<!ENTITY e "x">]>) <> doc(@format, ~s(<node id="&e;"/>))
        assert decode(@format, xml) == {:error, {:unsupported_markup, "<!DOCTYPE"}}
      end

      test "a malformed start tag is an error with a bounded excerpt" do
        for bad <- [
              ~s(<node id="a" foo/>),
              ~s(<node id="a"id="b"/>),
              ~s(<node id=a/>),
              ~s(<node id="a<b"/>),
              ~s(<node id="a/>),
              "<node " <> String.duplicate("x", 1_000)
            ] do
          assert {:error, {:malformed_tag, excerpt}} = decode(@format, doc(@format, bad))
          assert String.starts_with?(excerpt, "<node")
          assert byte_size(excerpt) <= 203
        end
      end

      test "unterminated comments, CDATA and processing instructions are errors" do
        for open <- ["<!--", "<?", "<![CDATA["] do
          xml = doc(@format, ~s(<node id="a"/>)) <> open <> "<node id='b'/>"
          assert decode(@format, xml) == {:error, {:unclosed_markup, open}}
        end
      end

      test "a reference to an illegal character is an error, not a NUL" do
        xml = doc(@format, ~s(<node id="a&#0;"/>))
        assert decode(@format, xml) == {:error, {:invalid_char_ref, "&#0;"}}
      end

      test "a mismatched end tag inside an element is an error" do
        xml = doc(@format, ~s(<node id="a"><foo></bar></graph>))
        assert decode(@format, xml) == {:error, {:unclosed_element, "node"}}
      end

      test "decoded ids do not reference the input" do
        id = String.duplicate("v", 100)
        xml = doc(@format, ~s(<node id="#{id}"/>) <> String.duplicate(" ", 100_000))
        [decoded] = Graph.vertices(decode(@format, xml))
        assert decoded == id
        assert :binary.referenced_byte_size(decoded) < 100_000
      end
    end

    describe "#{format} decoding time on hostile input" do
      @format format

      # The scaling of each input from the parser-hardening review: 4x the
      # input must take less than 8x as long (best of 3). Inputs that are
      # rejected at once take microseconds whatever their size, so the
      # small run is floored at 1 ms to keep timer noise out of the ratio.
      @tag :slow
      test "is linear for the hostile inputs" do
        hostile = [
          unclosed_data: fn n ->
            doc(@format, ~s(<node id="a">) <> String.duplicate(~s(<data key="k">), n) <> "</node>")
          end,
          unclosed_node: &String.duplicate("<node ", &1),
          attribute_name_run: fn n ->
            doc(@format, ~s(<node id="x" ) <> String.duplicate("a", 20 * n) <> "=/>")
          end,
          graph_tag_run: &String.duplicate("<graph", &1),
          unclosed_comment: fn n -> doc(@format, String.duplicate("<!-- <node id='a'/> ", n)) end,
          char_ref_run: fn n ->
            doc(@format, ~s(<node id="&#) <> String.duplicate("1", 20 * n) <> ~s(;"/>))
          end
        ]

        for {name, build} <- hostile do
          {small, large} = {build.(50_000), build.(200_000)}
          assert {:error, _} = decode(@format, large)
          {t_small, t_large} = {best_time(@format, small), best_time(@format, large)}

          assert t_large < 8 * max(t_small, 1_000),
                 "#{name}: 4x the input took #{t_large} µs vs #{t_small} µs"
        end
      end
    end
  end

  defp type_attr(:graphml), do: "edgedefault"
  defp type_attr(:gexf), do: "defaultedgetype"

  defp doc(format, body), do: ~s(<graph #{type_attr(format)}="directed">#{body}</graph>)

  defp decode(:graphml, xml), do: GraphML.from_graphml(xml)
  defp decode(:gexf, xml), do: GEXF.from_gexf(xml)

  defp best_time(format, xml),
    do: Enum.min(for _ <- 1..3, do: elem(:timer.tc(fn -> decode(format, xml) end), 0))
end
