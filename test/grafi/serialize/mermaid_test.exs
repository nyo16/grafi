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
end
