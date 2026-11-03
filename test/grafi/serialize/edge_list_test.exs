defmodule Grafi.Serialize.EdgeListTest do
  use ExUnit.Case, async: true

  alias Grafi.Graph
  alias Grafi.Serialize.{EdgeList, Util}

  doctest Grafi.Serialize.EdgeList

  describe "to_edge_list/2" do
    test "unweighted directed graph" do
      g = Graph.new() |> Graph.add_edges([{:a, :b}, {:b, :c}])
      text = EdgeList.to_edge_list(g)

      assert text =~ "a b"
      assert text =~ "b c"
    end

    test "weighted graph includes weight column when weight differs from 1.0" do
      g = Graph.new() |> Graph.add_edge(:a, :b, weight: 2.5)
      text = EdgeList.to_edge_list(g)

      assert text =~ "a b 2.5"
    end

    test "forced :weighted true always emits weight column" do
      g = Graph.new() |> Graph.add_edge(:a, :b)
      text = EdgeList.to_edge_list(g, weighted: true)

      assert text =~ "a b 1.0"
    end

    test "comment header is included" do
      g = Graph.new() |> Graph.add_edge(:a, :b)
      text = EdgeList.to_edge_list(g, comment: "my graph")

      assert String.starts_with?(text, "# my graph\n")
    end

    test "custom separator" do
      g = Graph.new() |> Graph.add_edge(:a, :b)
      text = EdgeList.to_edge_list(g, separator: "\t")
      assert text =~ "a\tb"
    end

    test "an id with a line break raises instead of injecting an edge" do
      g = Graph.add_edge(Graph.new(), "x\nadmin root", "y")

      assert_raise ArgumentError, fn -> EdgeList.to_edge_list(g) end
      assert_raise ArgumentError, fn -> EdgeList.to_edge_list(g, separator: ",") end
      assert_raise ArgumentError, fn -> EdgeList.to_edge_list(Graph.add_edge(g, "a\rb", "c")) end
    end

    test "ids that would not read back as one token raise" do
      for id <- ["", "#x", "a b", "a\tb", " a", "a\u00A0", {:a, 1}] do
        g = Graph.add_edge(Graph.new(), id, "y")
        assert_raise ArgumentError, fn -> EdgeList.to_edge_list(g) end
      end

      for id <- ["a,b", " a", "a ", "", "#x"] do
        g = Graph.add_edge(Graph.new(), "y", id)
        assert_raise ArgumentError, fn -> EdgeList.to_edge_list(g, separator: ",") end
      end
    end

    test "a :comment with a line break raises" do
      g = Graph.add_edge(Graph.new(), :a, :b)

      assert_raise ArgumentError, ~r/:comment/, fn ->
        EdgeList.to_edge_list(g, comment: "x\nadmin root")
      end
    end
  end

  describe "from_edge_list/2" do
    test "parses unweighted directed by default" do
      {:ok, g} = EdgeList.from_edge_list("a b\nb c")

      assert g.type == :directed
      assert Graph.num_vertices(g) == 3
      assert Graph.num_edges(g) == 2
      assert Graph.has_edge?(g, "a", "b")
      assert Graph.has_edge?(g, "b", "c")
    end

    test "parses weighted lines" do
      {:ok, g} = EdgeList.from_edge_list("a b 2.5\nb c 3.0")

      [e1] = Graph.edges_between(g, "a", "b")
      assert e1.weight == 2.5
    end

    test "parses undirected graph" do
      {:ok, g} = EdgeList.from_edge_list("a b\nb c", type: :undirected)

      assert g.type == :undirected
      assert Graph.has_edge?(g, "a", "b")
      assert Graph.has_edge?(g, "b", "a")
    end

    test "vertices_as_atoms option" do
      {:ok, g} = EdgeList.from_edge_list("a b", vertices_as_atoms: true)
      assert Graph.has_edge?(g, :a, :b)
    end

    test "ignores comment lines and blank lines" do
      {:ok, g} = EdgeList.from_edge_list("# header\na b\n\nb c\n")
      assert Graph.num_edges(g) == 2
    end

    test "default_weight option" do
      {:ok, g} = EdgeList.from_edge_list("a b", default_weight: 7.0)
      [e] = Graph.edges_between(g, "a", "b")
      assert e.weight == 7.0
    end

    test "malformed line returns error" do
      assert {:error, {:malformed_line, _}} = EdgeList.from_edge_list("a")
    end

    test "a non-numeric weight returns {:invalid_weight, token}" do
      assert EdgeList.from_edge_list("a b notanumber", weighted: true) ==
               {:error, {:invalid_weight, "notanumber"}}

      assert EdgeList.from_edge_list("a b 1.0\nb c 2x") == {:error, {:invalid_weight, "2x"}}
    end

    test "an out-of-range weight is an error, not an exception" do
      huge = String.duplicate("9", 400)

      assert EdgeList.from_edge_list("a b " <> huge) ==
               {:error, {:invalid_weight, Util.excerpt(huge)}}

      assert EdgeList.from_edge_list("a b 1e400") == {:error, {:invalid_weight, "1e400"}}
    end

    test "weight detection runs per line: a weight after an unweighted first line" do
      {:ok, g} = EdgeList.from_edge_list("a b\nb c 2.5")

      assert [%{weight: 1.0}] = Graph.edges_between(g, "a", "b")
      assert [%{weight: 2.5}] = Graph.edges_between(g, "b", "c")
    end

    test "weight detection runs per line: an unweighted line after a weighted one" do
      {:ok, g} = EdgeList.from_edge_list("a b 2.5\nb c", default_weight: 4.0)

      assert [%{weight: 2.5}] = Graph.edges_between(g, "a", "b")
      assert [%{weight: 4.0}] = Graph.edges_between(g, "b", "c")
    end

    test "without :weighted, four or more columns are malformed" do
      assert EdgeList.from_edge_list("a b 1 2") == {:error, {:malformed_line, "a b 1 2"}}
    end

    test "weighted: true requires a weight on every line" do
      assert EdgeList.from_edge_list("a b 1\nb c", weighted: true) ==
               {:error, {:malformed_line, "b c"}}
    end

    test "weighted: false ignores extra columns" do
      {:ok, g} = EdgeList.from_edge_list("a b 9 extra", weighted: false)
      assert [%{weight: 1.0}] = Graph.edges_between(g, "a", "b")
    end

    test ":separator splits on the string and trims fields, allowing spaces in names" do
      {:ok, g} = EdgeList.from_edge_list("New York , Boston, 2.5\nBoston,Albany", separator: ",")

      assert [%{weight: 2.5}] = Graph.edges_between(g, "New York", "Boston")
      assert [%{weight: 1.0}] = Graph.edges_between(g, "Boston", "Albany")
      assert Graph.num_vertices(g) == 3
    end

    test ":separator makes an empty field malformed" do
      assert EdgeList.from_edge_list("a,,2", separator: ",") ==
               {:error, {:malformed_line, "a,,2"}}
    end

    test ":max_bytes rejects larger input" do
      assert EdgeList.from_edge_list("a b", max_bytes: 2) == {:error, {:too_large, 3, 2}}
      assert {:ok, %Graph{}} = EdgeList.from_edge_list("a b", max_bytes: 3)
      assert {:ok, %Graph{}} = EdgeList.from_edge_list("a b", max_bytes: :infinity)
    end

    test "an error carries a bounded excerpt of the line, not the whole line" do
      line = String.duplicate("a", 1_000_000)

      assert {:error, {:malformed_line, excerpt}} = EdgeList.from_edge_list("a b\n" <> line)
      assert byte_size(excerpt) < 300
      assert String.starts_with?(line, String.trim_trailing(excerpt, "."))
      assert :binary.referenced_byte_size(excerpt) < byte_size(line)
    end

    test "decoded ids do not keep the input alive" do
      # Sub-binaries under 64 bytes may be copied anyway, so use longer ids.
      long = String.duplicate("x", 100)
      input = "#{long}a #{long}b\n" <> String.duplicate("# padding\n", 100)

      for v <- Graph.vertices(EdgeList.from_edge_list!(input)) do
        assert :binary.referenced_byte_size(v) < byte_size(input)
      end
    end

    @tag :slow
    test "64 MiB of blank lines decode in bounded memory" do
      for input <- [
            String.duplicate("\n", 64 * 1024 * 1024),
            String.duplicate("\r\n", 32 * 1024 * 1024)
          ] do
        assert {:done, {:ok, %Graph{} = g}} =
                 with_heap_cap(fn -> EdgeList.from_edge_list(input) end)

        assert Graph.num_vertices(g) == 0
      end
    end
  end

  describe "round-trip" do
    test "directed weighted graph round-trips" do
      g =
        Graph.new()
        |> Graph.add_edge("a", "b", weight: 2.5)
        |> Graph.add_edge("b", "c", weight: 3.0)
        |> Graph.add_edge("a", "c", weight: 7.0)

      text = EdgeList.to_edge_list(g)
      {:ok, g2} = EdgeList.from_edge_list(text)

      assert Graph.num_edges(g2) == 3
      assert Graph.num_vertices(g2) == 3

      [e_ab] = Graph.edges_between(g2, "a", "b")
      assert e_ab.weight == 2.5
    end

    test "undirected round-trip" do
      g =
        Graph.new(type: :undirected)
        |> Graph.add_edge("x", "y", weight: 1.5)
        |> Graph.add_edge("y", "z", weight: 4.0)

      text = EdgeList.to_edge_list(g)
      {:ok, g2} = EdgeList.from_edge_list(text, type: :undirected)

      assert g2.type == :undirected
      assert Graph.has_edge?(g2, "x", "y")
      assert Graph.has_edge?(g2, "y", "x")
      [e] = Graph.edges_between(g2, "x", "y")
      assert e.weight == 1.5
    end

    test "multi-edge round-trip" do
      g =
        Graph.new()
        |> Graph.add_edge("a", "b", weight: 1.0)
        |> Graph.add_edge("a", "b", weight: 2.0)

      text = EdgeList.to_edge_list(g, weighted: true)
      {:ok, g2} = EdgeList.from_edge_list(text, weighted: true)

      assert Graph.num_edges(g2) == 2
      assert length(Graph.edges_between(g2, "a", "b")) == 2
    end

    test "separator: \",\" round-trips, including vertex names with spaces" do
      g =
        Graph.new()
        |> Graph.add_edge("New York", "Boston", weight: 2.5)
        |> Graph.add_edge("Boston", "a b c", weight: -1.0)

      text = EdgeList.to_edge_list(g, separator: ",")
      assert text =~ "New York,Boston,2.5"

      {:ok, g2} = EdgeList.from_edge_list(text, separator: ",")

      assert Enum.sort(Graph.vertices(g2)) == ["Boston", "New York", "a b c"]
      assert [%{weight: 2.5}] = Graph.edges_between(g2, "New York", "Boston")
      assert [%{weight: -1.0}] = Graph.edges_between(g2, "Boston", "a b c")
    end

    test "mixed weighted and unweighted lines round-trip through per-line detection" do
      {:ok, g} = EdgeList.from_edge_list("a,b\nb,c,3.0", separator: ",")
      text = EdgeList.to_edge_list(g, separator: ",")
      {:ok, g2} = EdgeList.from_edge_list(text, separator: ",")

      assert [%{weight: 1.0}] = Graph.edges_between(g2, "a", "b")
      assert [%{weight: 3.0}] = Graph.edges_between(g2, "b", "c")
    end
  end

  # Runs `fun` in a process whose heap may not exceed 32 MB (the input is a
  # shared binary, so it does not count): materialising the lines of a
  # 64 MiB input as a list gets the process killed.
  defp with_heap_cap(fun) do
    {pid, ref} =
      spawn_monitor(fn ->
        Process.flag(:max_heap_size, %{size: 4_000_000, kill: true, error_logger: false})
        exit({:done, fun.()})
      end)

    receive do
      {:DOWN, ^ref, :process, ^pid, reason} -> reason
    end
  end
end
