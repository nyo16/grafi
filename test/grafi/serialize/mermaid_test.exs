defmodule Grafi.Serialize.MermaidTest do
  use ExUnit.Case, async: true

  alias Grafi.Graph
  alias Grafi.Serialize.Mermaid

  doctest Grafi.Serialize.Mermaid

  describe "to_mermaid/2" do
    test "small directed graph produces flowchart TD header and -->" do
      g = Graph.new() |> Graph.add_edges([{:a, :b}, {:a, :c}])
      out = Mermaid.to_mermaid(g)

      assert String.starts_with?(out, "flowchart TD\n")
      assert out =~ "-->"
      # Two edges produce two arrow lines
      arrows = out |> String.split("\n") |> Enum.count(&String.contains?(&1, "-->"))
      assert arrows == 2
    end

    test "undirected uses --- arrows" do
      g = Graph.new(type: :undirected) |> Graph.add_edges([{:a, :b}, {:b, :c}])
      out = Mermaid.to_mermaid(g)

      assert out =~ "---"
      refute out =~ "-->"
    end

    test ":direction option flips the header" do
      g = Graph.new() |> Graph.add_edge(:a, :b)

      assert Mermaid.to_mermaid(g, direction: :lr) |> String.starts_with?("flowchart LR")
      assert Mermaid.to_mermaid(g, direction: :bt) |> String.starts_with?("flowchart BT")
      assert Mermaid.to_mermaid(g, direction: :rl) |> String.starts_with?("flowchart RL")
    end

    test ":graph_type :graph emits legacy keyword" do
      g = Graph.new() |> Graph.add_edge(:a, :b)
      out = Mermaid.to_mermaid(g, graph_type: :graph)
      assert String.starts_with?(out, "graph TD")
    end

    test "weight labels appear as |w| when any edge has non-default weight" do
      g =
        Graph.new()
        |> Graph.add_edge(:a, :b)
        |> Graph.add_edge(:a, :c, weight: 80.0)

      out = Mermaid.to_mermaid(g)
      assert out =~ "|80.0|"
      # The unit-weight edge still gets its weight when auto-detection triggers.
      assert out =~ "|1.0|"
    end

    test ":weights false suppresses weight labels" do
      g = Graph.new() |> Graph.add_edge(:a, :b, weight: 42.0)
      out = Mermaid.to_mermaid(g, weights: false)
      refute out =~ "|42"
    end

    test ":weights true forces labels even on default-weight edges" do
      g = Graph.new() |> Graph.add_edge(:a, :b)
      out = Mermaid.to_mermaid(g, weights: true)
      assert out =~ "|1.0|"
    end

    test "edge :label takes precedence over weight when present" do
      g =
        Graph.new()
        |> Graph.add_edge(:a, :b, label: "knows", weight: 9.0)

      out = Mermaid.to_mermaid(g)
      assert out =~ "|knows|"
      refute out =~ "|9.0|"
    end

    test "custom :vertex_label callback" do
      g = Graph.new() |> Graph.add_edge(:athens, :sparta)
      out = Mermaid.to_mermaid(g, vertex_label: &String.upcase(to_string(&1)))

      assert out =~ "[ATHENS]"
      assert out =~ "[SPARTA]"
    end

    test "invalid :direction raises ArgumentError" do
      g = Graph.new() |> Graph.add_edge(:a, :b)
      assert_raise ArgumentError, fn -> Mermaid.to_mermaid(g, direction: :diagonal) end
    end

    test "invalid :weights raises ArgumentError" do
      g = Graph.new() |> Graph.add_edge(:a, :b)
      assert_raise ArgumentError, fn -> Mermaid.to_mermaid(g, weights: :maybe) end
    end

    test "empty graph still emits a valid header" do
      out = Mermaid.to_mermaid(Graph.new())
      assert out == "flowchart TD"
    end

    test "isolated vertices appear as standalone nodes" do
      g = Graph.new() |> Graph.add_vertices([:a, :b])
      out = Mermaid.to_mermaid(g)
      assert out =~ "[a]"
      assert out =~ "[b]"
      refute out =~ "-->"
    end

    test "vertex IDs are stable v0/v1/v2 in sorted order" do
      g = Graph.new() |> Graph.add_edges([{:b, :c}, {:a, :b}])
      out = Mermaid.to_mermaid(g)
      # :a, :b, :c sort lexicographically -> v0=a, v1=b, v2=c
      assert out =~ "v0[a]"
      assert out =~ "v1[b]"
      assert out =~ "v2[c]"
    end
  end

  describe "label escaping" do
    defp lines(out), do: String.split(out, ["\r\n", "\n", "\r"])

    test "newlines in a node label cannot start a new statement" do
      g = Graph.new() |> Graph.add_edge(:a, :b)
      out = Mermaid.to_mermaid(g, vertex_label: fn _ -> "x]\nv1 --> v0\r\nz\ry" end)

      assert ~s(    v0["x]#10;v1 --> v0#10;z#10;y"]) in lines(out)
      assert length(lines(out)) == 4
    end

    # Mermaid would render `#quot;` as a quote mark if `#` were left alone.
    test "label text that looks like an entity code stays literal" do
      g = Graph.new() |> Graph.add_vertex(:a)
      out = Mermaid.to_mermaid(g, vertex_label: fn _ -> "say #quot;hi" end)

      assert out =~ ~s(v0["say #35;quot;hi"])
    end

    test "backticks, pipes and quotes in node labels become entity codes" do
      g = Graph.new() |> Graph.add_vertex("a`|\"b")
      assert Mermaid.to_mermaid(g) =~ ~s(v0["a#96;#124;#quot;b"])
    end

    test "edge labels escape pipes, quotes, backticks and newlines" do
      g = Graph.new() |> Graph.add_edge(:a, :b, label: "p|q\"r`s\nt")
      assert Mermaid.to_mermaid(g) =~ "v0 -->|p#124;q#quot;r#96;s#10;t| v1"
    end

    test "weights keep their compact display form" do
      g = Graph.new() |> Graph.add_edge(:a, :b, weight: 2.5) |> Graph.add_edge(:b, :c, weight: 3)
      out = Mermaid.to_mermaid(g)
      assert out =~ "|2.5|"
      assert out =~ "|3|"
    end
  end
end
