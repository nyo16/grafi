defmodule Grafi.KinoTest do
  use ExUnit.Case, async: true

  alias Grafi.Graph
  alias Grafi.Kino, as: GKino
  alias Grafi.Serialize.Mermaid

  doctest Grafi.Kino

  describe "to_kino/2" do
    test "wraps mermaid in a fenced markdown block" do
      g = Graph.new() |> Graph.add_edge(:a, :b)
      md = GKino.to_kino(g)

      assert String.starts_with?(md, "```mermaid\n")
      assert String.ends_with?(md, "\n```")
      assert md =~ "flowchart TD"
      assert md =~ "-->"
    end

    test "the inner mermaid matches Serialize.Mermaid.to_mermaid/2" do
      g =
        Graph.new()
        |> Graph.add_edges([{:athens, :sparta, weight: 210.0}, {:athens, :corinth}])

      md = GKino.to_kino(g, direction: :lr)

      inner =
        md
        |> String.trim_leading("```mermaid\n")
        |> String.trim_trailing("\n```")

      assert inner == Mermaid.to_mermaid(g, direction: :lr)
    end

    test "options are forwarded to Mermaid (direction)" do
      g = Graph.new() |> Graph.add_edge(:a, :b)
      md = GKino.to_kino(g, direction: :lr)
      assert md =~ "flowchart LR"
    end

    test "to_mermaid_block/2 is an alias" do
      g = Graph.new() |> Graph.add_edge(:a, :b)
      assert GKino.to_mermaid_block(g) == GKino.to_kino(g)
    end

    test "does NOT introduce a hard kino dependency at runtime" do
      # kino is intentionally NOT in mix.exs; the module should still load
      # and run without it.
      refute Code.ensure_loaded?(Kino.Markdown)
    end

    test "a label containing a code fence cannot close the markdown fence" do
      g =
        Graph.new()
        |> Graph.add_vertex("x\n```\n# injected")
        |> Graph.add_edge(:a, :b, label: "```")

      md = GKino.to_kino(g)
      fence_lines = md |> String.split(["\r\n", "\n", "\r"]) |> Enum.filter(&(&1 =~ "```"))

      assert fence_lines == ["```mermaid", "```"]
    end
  end
end
