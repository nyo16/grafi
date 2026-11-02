defmodule Grafi.Serialize.GEXFTest do
  use ExUnit.Case, async: true

  alias Grafi.Graph
  alias Grafi.Serialize.GEXF

  doctest Grafi.Serialize.GEXF

  describe "to_gexf/2" do
    test "emits XML declaration and gexf root" do
      g = Graph.new() |> Graph.add_edge(:a, :b)
      xml = GEXF.to_gexf(g)

      assert String.starts_with?(xml, "<?xml")
      assert xml =~ "<gexf"
      assert xml =~ "</gexf>"
    end

    test "directed sets defaultedgetype=directed" do
      g = Graph.new() |> Graph.add_edge(:a, :b)
      xml = GEXF.to_gexf(g)
      assert xml =~ ~s(defaultedgetype="directed")
    end

    test "undirected sets defaultedgetype=undirected" do
      g = Graph.new(type: :undirected) |> Graph.add_edge(:a, :b)
      xml = GEXF.to_gexf(g)
      assert xml =~ ~s(defaultedgetype="undirected")
    end

    test "weight attribute is set" do
      g = Graph.new() |> Graph.add_edge(:a, :b, weight: 2.5)
      xml = GEXF.to_gexf(g)
      assert xml =~ ~s(weight="2.5")
    end

    test "label attribute on edge" do
      g = Graph.new() |> Graph.add_edge(:a, :b, label: "loves")
      xml = GEXF.to_gexf(g)
      assert xml =~ ~s(label="loves")
    end

    test "edge ids are sequential integers" do
      g = Graph.new() |> Graph.add_edges([{:a, :b}, {:b, :c}])
      xml = GEXF.to_gexf(g)
      assert xml =~ ~s(id="0")
      assert xml =~ ~s(id="1")
    end

    test "XML-special chars are escaped" do
      g = Graph.new() |> Graph.add_edge("a<b", "c&d")
      xml = GEXF.to_gexf(g)
      assert xml =~ "a&lt;b"
      assert xml =~ "c&amp;d"
    end
  end

  describe "from_gexf/2" do
    test "parses minimal valid GEXF" do
      xml = """
      <?xml version="1.0" encoding="UTF-8"?>
      <gexf xmlns="http://www.gexf.net/1.2draft" version="1.2">
        <graph defaultedgetype="directed">
          <nodes>
            <node id="a"/>
            <node id="b"/>
          </nodes>
          <edges>
            <edge id="0" source="a" target="b" weight="1.0"/>
          </edges>
        </graph>
      </gexf>
      """

      g = GEXF.from_gexf(xml)
      assert g.type == :directed
      assert Graph.has_edge?(g, "a", "b")
    end

    test "decodes XML entities" do
      xml = """
      <?xml version="1.0" encoding="UTF-8"?>
      <gexf>
        <graph defaultedgetype="directed">
          <nodes>
            <node id="a&amp;b"/>
            <node id="c"/>
          </nodes>
          <edges>
            <edge source="a&amp;b" target="c" weight="1.0"/>
          </edges>
        </graph>
      </gexf>
      """

      g = GEXF.from_gexf(xml)
      assert Graph.has_edge?(g, "a&b", "c")
    end

    test "missing graph element returns error" do
      assert {:error, _} = GEXF.from_gexf("<?xml version=\"1.0\"?>\n<bogus/>")
    end

    test "garbage input returns error" do
      assert {:error, _} = GEXF.from_gexf("garbage")
    end
  end

  describe "round-trip" do
    test "directed weighted graph" do
      g =
        Graph.new()
        |> Graph.add_edge("a", "b", weight: 2.5)
        |> Graph.add_edge("b", "c", weight: 3.0)
        |> Graph.add_edge("a", "c", weight: 7.0, label: "diagonal")

      xml = GEXF.to_gexf(g)
      g2 = GEXF.from_gexf(xml)

      assert g2.type == :directed
      assert Graph.num_vertices(g2) == 3
      assert Graph.num_edges(g2) == 3
      [e_ab] = Graph.edges_between(g2, "a", "b")
      assert e_ab.weight == 2.5
      [e_ac] = Graph.edges_between(g2, "a", "c")
      assert e_ac.label == "diagonal"
    end

    test "undirected round-trip" do
      g =
        Graph.new(type: :undirected)
        |> Graph.add_edge("x", "y", weight: 1.5)

      xml = GEXF.to_gexf(g)
      g2 = GEXF.from_gexf(xml)

      assert g2.type == :undirected
      assert Graph.has_edge?(g2, "x", "y")
      assert Graph.has_edge?(g2, "y", "x")
    end

    test "multi-edge round-trip" do
      g =
        Graph.new()
        |> Graph.add_edge("a", "b", weight: 1.0)
        |> Graph.add_edge("a", "b", weight: 2.0)

      xml = GEXF.to_gexf(g)
      g2 = GEXF.from_gexf(xml)

      assert Graph.num_edges(g2) == 2
      assert length(Graph.edges_between(g2, "a", "b")) == 2
    end

    test "vertex with XML special chars round-trips" do
      g = Graph.new() |> Graph.add_edge("a<b", "c&d>e")
      xml = GEXF.to_gexf(g)
      g2 = GEXF.from_gexf(xml)
      assert Graph.has_edge?(g2, "a<b", "c&d>e")
    end

    test "vertex labels round-trip" do
      g = Graph.new() |> Graph.add_vertex("a", label: "Hello & World")
      xml = GEXF.to_gexf(g)
      g2 = GEXF.from_gexf(xml)
      assert Graph.label(g2, "a") == "Hello & World"
    end
  end

  describe "from_gexf/2 tokenizer" do
    test "attribute values containing name= are not read as that attribute" do
      xml = """
      <gexf>
        <graph defaultedgetype="directed">
          <nodes>
            <node label="id='admin'" id="a"/>
            <node id="b"/>
          </nodes>
          <edges>
            <edge label="source='admin' target='admin'" source="a" target="b"/>
          </edges>
        </graph>
      </gexf>
      """

      g = GEXF.from_gexf(xml)
      assert Enum.sort(Graph.vertices(g)) == ["a", "b"]
      assert Graph.label(g, "a") == "id='admin'"
      assert [%{label: "source='admin' target='admin'"}] = Graph.edges_between(g, "a", "b")
    end

    test "defaultedgetype is read from the attribute, not from another value" do
      xml = """
      <gexf>
        <graph defaultedgetype="directed" mode="defaultedgetype='undirected'">
          <nodes><node id="a"/></nodes>
        </graph>
      </gexf>
      """

      assert GEXF.from_gexf(xml).type == :directed
    end

    test "single-quoted attributes and numeric character references" do
      xml = """
      <gexf>
        <graph defaultedgetype='undirected'>
          <nodes><node id='&#x41;1' label='&#66;ee'/></nodes>
        </graph>
      </gexf>
      """

      g = GEXF.from_gexf(xml)
      assert g.type == :undirected
      assert Graph.label(g, "A1") == "Bee"
    end

    test "bodied elements are read from their start tag" do
      xml = """
      <gexf>
        <graph defaultedgetype="directed">
          <nodes>
            <node id="a" label="A"><attvalues></attvalues></node>
            <node id="b"/>
          </nodes>
          <edges>
            <edge source="a" target="b" weight="2"><attvalues/></edge>
          </edges>
        </graph>
      </gexf>
      """

      g = GEXF.from_gexf(xml)
      assert Graph.label(g, "a") == "A"
      assert Graph.label(g, "b") == nil
      assert [%{weight: 2.0}] = Graph.edges_between(g, "a", "b")
    end

    test "a non-numeric weight is an error, not a silent 1.0" do
      xml = """
      <gexf>
        <graph defaultedgetype="directed">
          <edges><edge source="a" target="b" weight="heavy"/></edges>
        </graph>
      </gexf>
      """

      assert GEXF.from_gexf(xml) == {:error, {:invalid_weight, "heavy"}}
    end

    test "an overflowing weight is an error" do
      xml = ~s(<graph defaultedgetype="directed"><edge source="a" target="b" weight="1e400"/>)
      assert GEXF.from_gexf(xml) == {:error, {:invalid_weight, "1e400"}}
    end

    test "an element without its end tag is an error" do
      xml = ~s(<graph defaultedgetype="directed"><node id="a">)
      assert GEXF.from_gexf(xml) == {:error, {:unclosed_element, "node"}}
    end

    test "children of a bodied node, CDATA included, are not read" do
      xml = """
      <gexf>
        <graph defaultedgetype="directed">
          <nodes>
            <node id="a"><attvalues><attvalue for="0" value="&lt;x&gt;"/></attvalues></node>
            <node id="b"><![CDATA[<edge source="a" target="b"/>]]></node>
          </nodes>
        </graph>
      </gexf>
      """

      g = GEXF.from_gexf(xml)
      assert Enum.sort(Graph.vertices(g)) == ["a", "b"]
      assert Graph.num_edges(g) == 0
    end
  end

  describe "to_gexf/2 unrepresentable text" do
    test "invalid UTF-8 raises instead of colliding ids" do
      g = Graph.add_edge(Graph.new(), <<"caf", 0xE9>>, <<"caf", 0xE8>>)
      assert_raise ArgumentError, fn -> GEXF.to_gexf(g) end
    end

    test "characters outside XML 1.0 raise, in ids and labels" do
      for g <- [
            Graph.add_vertex(Graph.new(), "a\u0001b"),
            Graph.add_vertex(Graph.new(), "a", label: <<"x", 0xEF, 0xBF, 0xBF>>),
            Graph.add_edge(Graph.new(), "a", "b", label: "x\f")
          ] do
        assert_raise ArgumentError, fn -> GEXF.to_gexf(g) end
      end
    end

    test "tab, LF and CR in ids and labels are character references" do
      ids = ["a\nb", "a b", "a\tb", "a\rb"]

      g =
        Enum.reduce(ids, Graph.new(), fn id, acc ->
          acc |> Graph.add_vertex(id, label: id) |> Graph.add_edge(id, "z", label: id)
        end)

      xml = GEXF.to_gexf(g)
      refute xml =~ ~r/"a[\t\n\r]b"/

      g2 = GEXF.from_gexf(xml)
      assert Enum.sort(Graph.vertices(g2)) == Enum.sort(["z" | ids])

      for id <- ids do
        assert Graph.label(g2, id) == id
        assert [%{label: ^id}] = Graph.edges_between(g2, id, "z")
      end
    end
  end

  describe "round-trip (tokenizer)" do
    test "mixed labelled and unlabelled vertices and edges" do
      g =
        Graph.new()
        |> Graph.add_vertex("a")
        |> Graph.add_vertex("b", label: "Bee")
        |> Graph.add_vertex("c")
        |> Graph.add_vertex("d", label: "Dee")
        |> Graph.add_edge("a", "b", weight: 2.0)
        |> Graph.add_edge("b", "c", weight: 3.0, label: "bc")
        |> Graph.add_edge("c", "d")

      g2 = g |> GEXF.to_gexf() |> GEXF.from_gexf()

      for v <- ["a", "b", "c", "d"], do: assert(Graph.label(g2, v) == Graph.label(g, v))
      assert [%{weight: 2.0, label: nil}] = Graph.edges_between(g2, "a", "b")
      assert [%{weight: 3.0, label: "bc"}] = Graph.edges_between(g2, "b", "c")
      assert [%{weight: 1.0, label: nil}] = Graph.edges_between(g2, "c", "d")
    end

    # Linear-time decoding: 4x the input should take about 4x as long, not
    # about 16x (the old GEXF parser was quadratic: over 15 minutes at this
    # size). A ratio rather than a wall-clock budget, so slow runners and
    # older Elixir/OTP versions don't fail it; best of 3 to damp GC noise.
    @tag :slow
    test "decoding time grows linearly up to 10k vertices / 50k edges" do
      small = large_graph(2_500, 12_500) |> GEXF.to_gexf()
      large = large_graph(10_000, 50_000) |> GEXF.to_gexf()
      best = fn xml -> Enum.min(for _ <- 1..3, do: elem(:timer.tc(GEXF, :from_gexf, [xml]), 0)) end

      g2 = GEXF.from_gexf(large)
      assert Graph.num_vertices(g2) == 10_000
      assert Graph.num_edges(g2) == 50_000
      assert Graph.label(g2, "v0") == "L0"

      {t_small, t_large} = {best.(small), best.(large)}

      assert t_large < 8 * t_small,
             "4x the input took #{Float.round(t_large / t_small, 1)}x as long"

      assert t_large < 10_000_000, "decoding took #{div(t_large, 1000)} ms"
    end
  end

  describe "from_gexf/2 :max_bytes" do
    test "rejects input larger than the limit before parsing" do
      xml = GEXF.to_gexf(Graph.new() |> Graph.add_edge(:a, :b))
      size = byte_size(xml)
      assert {:error, {:too_large, ^size, 10}} = GEXF.from_gexf(xml, max_bytes: 10)
    end

    test "accepts input within the limit" do
      xml = GEXF.to_gexf(Graph.new() |> Graph.add_edge(:a, :b))
      g = GEXF.from_gexf(xml, max_bytes: byte_size(xml))
      assert Graph.has_edge?(g, "a", "b")
    end

    # Allocates 64 MiB (S8): too heavy for the default async run.
    @tag :slow
    test "defaults to 64 MiB; :infinity lifts the limit" do
      max = 64 * 1024 * 1024
      xml = String.duplicate(" ", max + 1)
      assert {:error, {:too_large, _, ^max}} = GEXF.from_gexf(xml)
      assert {:error, :missing_graph_element} = GEXF.from_gexf(xml, max_bytes: :infinity)
    end
  end

  defp large_graph(n, m) do
    g =
      Enum.reduce(0..(n - 1), Graph.new(), fn i, acc ->
        opts = if rem(i, 2) == 0, do: [label: "L#{i}"], else: []
        Graph.add_vertex(acc, "v#{i}", opts)
      end)

    Enum.reduce(0..(m - 1), g, fn i, acc ->
      opts = if rem(i, 3) == 0, do: [weight: i / 7, label: "e#{i}"], else: [weight: i / 7]
      Graph.add_edge(acc, "v#{rem(i * 7919, n)}", "v#{rem(i * 104_729 + 1, n)}", opts)
    end)
  end
end
