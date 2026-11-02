defmodule Grafi.Serialize.DOTTest do
  use ExUnit.Case, async: true

  alias Grafi.Graph
  alias Grafi.Serialize.DOT

  defp header(dot), do: dot |> String.split("\n") |> hd()

  describe ":name" do
    test "defaults to a bare G" do
      assert header(DOT.to_dot(Graph.new())) == "digraph G {"
    end

    test "a plain identifier stays bare" do
      assert header(DOT.to_dot(Graph.new(), name: "my_graph2")) == "digraph my_graph2 {"
    end

    test "a name with DOT syntax is quoted, so it cannot inject statements" do
      dot = DOT.to_dot(Graph.new(), name: "x { y")
      assert header(dot) == ~s(digraph "x { y" {)

      dot = DOT.to_dot(Graph.new(), name: ~s(x" { a -> b } //))
      assert header(dot) == ~s(digraph "x\\" { a -> b } //" {)
      refute dot =~ "a -> b;"
    end

    test "a keyword name is quoted" do
      assert header(DOT.to_dot(Graph.new(), name: "graph")) == ~s(digraph "graph" {)
    end

    test "non-string names" do
      assert header(DOT.to_dot(Graph.new(), name: :g1)) == "digraph g1 {"
      assert header(DOT.to_dot(Graph.new(), name: :"foo bar")) == ~s(digraph "foo bar" {)
      assert header(DOT.to_dot(Graph.new(), name: 7)) == "digraph 7 {"
    end

    test "control characters in the name raise" do
      assert_raise ArgumentError, ~r/cannot contain control characters/, fn ->
        DOT.to_dot(Graph.new(), name: "a\0b")
      end
    end
  end

  describe "attributes" do
    test "vertex labels are quoted and escaped" do
      g = Graph.new() |> Graph.add_vertex(:a, label: ~s(say "hi" \\ bye))
      assert DOT.to_dot(g) =~ ~s(  a [label="say \\"hi\\" \\\\ bye"];)
    end

    test "non-unit weights and edge labels" do
      g =
        Graph.new()
        |> Graph.add_edge(:a, :b, weight: 2.5, label: "x]; c -> d [")
        |> Graph.add_edge(:b, :c, weight: 3)
        |> Graph.add_edge(:c, :d)

      dot = DOT.to_dot(g)
      assert dot =~ ~s(  a -> b [weight=2.5, label="x]; c -> d ["];)
      assert dot =~ "  b -> c [weight=3];"
      assert dot =~ "  c -> d;\n"
    end

    test "control characters in a label raise" do
      g = Graph.new() |> Graph.add_vertex(:a, label: "x\by")
      assert_raise ArgumentError, ~r/cannot contain control characters/, fn -> DOT.to_dot(g) end
    end

    test "tab, newline and carriage return are allowed" do
      g = Graph.new() |> Graph.add_vertex(:a, label: "x\ty\nz\rw")
      assert DOT.to_dot(g) =~ "z\rw"
    end

    # DOT numerals have no exponent, so `weight=1.0e20` would not be one token.
    test "weights in exponent notation are quoted; plain numerals stay bare" do
      g =
        Graph.new()
        |> Graph.add_edge(:a, :b, weight: 1.0e20)
        |> Graph.add_edge(:b, :c, weight: -1.0e-300)
        |> Graph.add_edge(:c, :d, weight: -2.5)

      dot = DOT.to_dot(g)
      assert dot =~ ~s(weight="1.0e20")
      assert dot =~ ~s(weight="-1.0e-300")
      assert dot =~ "weight=-2.5"
      refute dot =~ ~r/weight=[^"\s\]]*e/
    end
  end

  describe "vertex ids" do
    test "integers are bare numerals" do
      g = Graph.new() |> Graph.add_edge(1, -2)
      dot = DOT.to_dot(g)
      assert dot =~ "  1 -> -2;"
    end

    test "atoms needing quotes, keywords, strings and tuples are quoted" do
      g =
        Graph.new()
        |> Graph.add_edge(:"foo bar", :node)
        |> Graph.add_edge("plain", {:a, 1})

      dot = DOT.to_dot(g)
      assert dot =~ ~s(  "foo bar" -> "node";)
      assert dot =~ ~s(  "plain" -> "{:a, 1}";)
    end

    test "control characters in an id raise" do
      g = Graph.new() |> Graph.add_vertex("a\eb")
      assert_raise ArgumentError, ~r/cannot contain control characters/, fn -> DOT.to_dot(g) end
    end
  end

  describe "Graphviz parsing" do
    # Checks the output against a real Graphviz: ids and labels ending in
    # backslashes, or holding `\"`, must not end or escape their quotes.
    @describetag :graphviz
    test "backslash runs cannot end or escape a quoted string" do
      g =
        Graph.new()
        |> Graph.add_edge("a\\", "b\\\\", label: "c\\")
        |> Graph.add_edge("d\\\"", "e", label: ~s(\\"; x -> y [label="))
        |> Graph.add_vertex("f\\\\\\", label: "\\")

      assert {:ok, json} = Grafi.Viz.render(g, :json)
      out = JSON.decode!(json)

      assert length(out["objects"]) == 5
      assert length(out["edges"]) == 2
    end
  end
end
