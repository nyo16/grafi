defmodule Grafi.Serialize.GraphMLTest do
  use ExUnit.Case, async: true

  alias Grafi.Graph
  alias Grafi.Serialize.GraphML

  doctest Grafi.Serialize.GraphML

  describe "to_graphml/2" do
    test "emits XML declaration and graphml root" do
      g = Graph.new() |> Graph.add_edge(:a, :b)
      xml = GraphML.to_graphml(g)

      assert String.starts_with?(xml, "<?xml")
      assert xml =~ "<graphml"
      assert xml =~ "</graphml>"
    end

    test "directed graph gets edgedefault=directed" do
      g = Graph.new() |> Graph.add_edge(:a, :b)
      xml = GraphML.to_graphml(g)
      assert xml =~ ~s(edgedefault="directed")
    end

    test "undirected graph gets edgedefault=undirected" do
      g = Graph.new(type: :undirected) |> Graph.add_edge(:a, :b)
      xml = GraphML.to_graphml(g)
      assert xml =~ ~s(edgedefault="undirected")
    end

    test "vertex labels written as data" do
      g = Graph.new() |> Graph.add_vertex(:a, label: "Alpha")
      xml = GraphML.to_graphml(g)
      assert xml =~ "vlabel"
      assert xml =~ "Alpha"
    end

    test "edge weight and label written as data" do
      g = Graph.new() |> Graph.add_edge(:a, :b, weight: 3.14, label: "love")
      xml = GraphML.to_graphml(g)
      assert xml =~ "3.14"
      assert xml =~ "love"
    end

    test "XML-special chars in vertex ids are escaped" do
      g = Graph.new() |> Graph.add_edge("a<b", "c&d")
      xml = GraphML.to_graphml(g)

      assert xml =~ "a&lt;b"
      assert xml =~ "c&amp;d"
      refute xml =~ ~s(id="a<b")
    end

    test "name option sets graph id" do
      g = Graph.new() |> Graph.add_vertex(:a)
      xml = GraphML.to_graphml(g, name: "MyGraph")
      assert xml =~ ~s(id="MyGraph")
    end
  end

  describe "from_graphml/2" do
    test "parses minimal valid GraphML" do
      xml = """
      <?xml version="1.0" encoding="UTF-8"?>
      <graphml xmlns="http://graphml.graphdrawing.org/xmlns">
        <graph id="G" edgedefault="directed">
          <node id="a"/>
          <node id="b"/>
          <edge id="e0" source="a" target="b"/>
        </graph>
      </graphml>
      """

      g = GraphML.from_graphml(xml)
      assert g.type == :directed
      assert Graph.has_edge?(g, "a", "b")
    end

    test "decodes XML entities in attributes" do
      xml = """
      <?xml version="1.0" encoding="UTF-8"?>
      <graphml>
        <graph id="G" edgedefault="directed">
          <node id="a&amp;b"/>
          <node id="c"/>
          <edge source="a&amp;b" target="c"/>
        </graph>
      </graphml>
      """

      g = GraphML.from_graphml(xml)
      assert Graph.has_vertex?(g, "a&b")
      assert Graph.has_edge?(g, "a&b", "c")
    end

    test "missing graph element returns error" do
      assert {:error, _} = GraphML.from_graphml("<?xml version=\"1.0\"?>\n<bogus/>")
    end

    test "garbage input returns error" do
      assert {:error, _} = GraphML.from_graphml("not xml at all")
    end
  end

  describe "round-trip" do
    test "directed weighted graph" do
      g =
        Graph.new()
        |> Graph.add_edge("a", "b", weight: 2.5)
        |> Graph.add_edge("b", "c", weight: 3.0)
        |> Graph.add_edge("a", "c", weight: 7.0, label: "diagonal")

      xml = GraphML.to_graphml(g)
      g2 = GraphML.from_graphml(xml)

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

      xml = GraphML.to_graphml(g)
      g2 = GraphML.from_graphml(xml)

      assert g2.type == :undirected
      assert Graph.has_edge?(g2, "x", "y")
      assert Graph.has_edge?(g2, "y", "x")
    end

    test "multi-edge round-trip" do
      g =
        Graph.new()
        |> Graph.add_edge("a", "b", weight: 1.0)
        |> Graph.add_edge("a", "b", weight: 2.0)

      xml = GraphML.to_graphml(g)
      g2 = GraphML.from_graphml(xml)

      assert Graph.num_edges(g2) == 2
      assert length(Graph.edges_between(g2, "a", "b")) == 2
    end

    test "vertex with XML special chars round-trips" do
      g =
        Graph.new()
        |> Graph.add_edge("a<b", "c&d>e")

      xml = GraphML.to_graphml(g)
      g2 = GraphML.from_graphml(xml)

      assert Graph.has_edge?(g2, "a<b", "c&d>e")
    end

    test "vertex labels round-trip" do
      g = Graph.new() |> Graph.add_vertex("a", label: "Hello & World")
      xml = GraphML.to_graphml(g)
      g2 = GraphML.from_graphml(xml)

      assert Graph.label(g2, "a") == "Hello & World"
    end
  end

  describe "from_graphml/2 :max_bytes" do
    test "rejects input larger than the limit before parsing" do
      xml = GraphML.to_graphml(Graph.new() |> Graph.add_edge(:a, :b))
      assert {:error, :input_too_large} = GraphML.from_graphml(xml, max_bytes: 10)
    end

    test "accepts input within the limit" do
      xml = GraphML.to_graphml(Graph.new() |> Graph.add_edge(:a, :b))
      g = GraphML.from_graphml(xml, max_bytes: byte_size(xml))
      assert Graph.has_edge?(g, "a", "b")
    end

    test "defaults to no limit" do
      xml = GraphML.to_graphml(Graph.new() |> Graph.add_edge(:a, :b))
      assert Graph.has_edge?(GraphML.from_graphml(xml), "a", "b")
    end
  end
end
