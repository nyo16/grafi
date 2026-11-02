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

  describe "from_graphml/2 tokenizer" do
    test "attribute values containing name= are not read as that attribute" do
      xml = """
      <graphml>
        <graph id="G" edgedefault="directed">
          <node desc="id='admin'" id="a"/>
          <node id="b"/>
          <edge id="source='admin' target='admin'" source="a" target="b"/>
        </graph>
      </graphml>
      """

      g = GraphML.from_graphml(xml)
      assert Enum.sort(Graph.vertices(g)) == ["a", "b"]
      assert Graph.has_edge?(g, "a", "b")
    end

    test "data keys are read positionally" do
      xml = """
      <graphml>
        <graph id="G" edgedefault="directed">
          <node id="a"><data id="key='vlabel'" key="other">wrong</data></node>
          <node id="b"><data key="vlabel">Bee</data></node>
          <edge source="a" target="b">
            <data id="key='eweight'" key="elabel">x</data>
            <data key='eweight'>4</data>
          </edge>
        </graph>
      </graphml>
      """

      g = GraphML.from_graphml(xml)
      assert Graph.label(g, "a") == nil
      assert Graph.label(g, "b") == "Bee"
      assert [%{weight: 4.0, label: "x"}] = Graph.edges_between(g, "a", "b")
    end

    test "edgedefault is read from the attribute, not from another value" do
      xml = """
      <graphml>
        <graph edgedefault="directed" id="edgedefault='undirected'">
          <node id="a"/>
        </graph>
      </graphml>
      """

      assert GraphML.from_graphml(xml).type == :directed
    end

    test "single-quoted attributes and numeric character references" do
      xml = """
      <graphml>
        <graph id='G' edgedefault='undirected'>
          <node id='&#x41;1'><data key='vlabel'>&#66;ee</data></node>
        </graph>
      </graphml>
      """

      g = GraphML.from_graphml(xml)
      assert g.type == :undirected
      assert Graph.label(g, "A1") == "Bee"
    end

    test "a non-numeric weight is an error, not a silent 1.0" do
      xml = """
      <graphml>
        <graph id="G" edgedefault="directed">
          <edge source="a" target="b"><data key="eweight">heavy</data></edge>
        </graph>
      </graphml>
      """

      assert GraphML.from_graphml(xml) == {:error, {:invalid_weight, "heavy"}}
    end

    test "an overflowing weight is an error" do
      xml = """
      <graph edgedefault="directed">
        <edge source="a" target="b"><data key="eweight">1e400</data></edge>
      </graph>
      """

      assert GraphML.from_graphml(xml) == {:error, {:invalid_weight, "1e400"}}
    end

    test "an element without its end tag is an error" do
      xml = ~s(<graph edgedefault="directed"><edge source="a" target="b">)
      assert GraphML.from_graphml(xml) == {:error, {:unclosed_element, "edge"}}
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

      g2 = g |> GraphML.to_graphml() |> GraphML.from_graphml()

      for v <- ["a", "b", "c", "d"], do: assert(Graph.label(g2, v) == Graph.label(g, v))
      assert [%{weight: 2.0, label: nil}] = Graph.edges_between(g2, "a", "b")
      assert [%{weight: 3.0, label: "bc"}] = Graph.edges_between(g2, "b", "c")
      assert [%{weight: 1.0, label: nil}] = Graph.edges_between(g2, "c", "d")
    end

    # Linear-time decoding: 4x the input should take about 4x as long, not
    # about 16x (the old bodied-regex parsers were quadratic). A ratio rather
    # than a wall-clock budget, so slow runners and older Elixir/OTP versions
    # don't fail it; best of 3 to damp GC noise.
    @tag :slow
    test "decoding time grows linearly up to 10k vertices / 50k edges" do
      small = large_graph(2_500, 12_500) |> GraphML.to_graphml()
      large = large_graph(10_000, 50_000) |> GraphML.to_graphml()

      best = fn xml ->
        Enum.min(for _ <- 1..3, do: elem(:timer.tc(GraphML, :from_graphml, [xml]), 0))
      end

      g2 = GraphML.from_graphml(large)
      assert Graph.num_vertices(g2) == 10_000
      assert Graph.num_edges(g2) == 50_000
      assert Graph.label(g2, "v0") == "L0"

      {t_small, t_large} = {best.(small), best.(large)}

      assert t_large < 8 * t_small,
             "4x the input took #{Float.round(t_large / t_small, 1)}x as long"

      assert t_large < 10_000_000, "decoding took #{div(t_large, 1000)} ms"
    end
  end

  describe "from_graphml/2 :max_bytes" do
    test "rejects input larger than the limit before parsing" do
      xml = GraphML.to_graphml(Graph.new() |> Graph.add_edge(:a, :b))
      size = byte_size(xml)
      assert {:error, {:too_large, ^size, 10}} = GraphML.from_graphml(xml, max_bytes: 10)
    end

    test "accepts input within the limit" do
      xml = GraphML.to_graphml(Graph.new() |> Graph.add_edge(:a, :b))
      g = GraphML.from_graphml(xml, max_bytes: byte_size(xml))
      assert Graph.has_edge?(g, "a", "b")
    end

    test "defaults to 64 MiB; :infinity lifts the limit" do
      max = 64 * 1024 * 1024
      xml = String.duplicate(" ", max + 1)
      assert {:error, {:too_large, _, ^max}} = GraphML.from_graphml(xml)
      assert {:error, :missing_graph_element} = GraphML.from_graphml(xml, max_bytes: :infinity)
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
