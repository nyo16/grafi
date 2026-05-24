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
end
