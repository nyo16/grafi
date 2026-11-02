defmodule Grafi.Serialize.PajekTest do
  use ExUnit.Case, async: true

  alias Grafi.Graph
  alias Grafi.Serialize.{Pajek, Util}

  doctest Grafi.Serialize.Pajek

  describe "to_pajek/2" do
    test "directed graph emits *Arcs" do
      g = Graph.new() |> Graph.add_edge(:a, :b)
      text = Pajek.to_pajek(g)

      assert text =~ "*Vertices 2"
      assert text =~ "*Arcs"
      refute text =~ "*Edges"
    end

    test "undirected graph emits *Edges" do
      g = Graph.new(type: :undirected) |> Graph.add_edge(:a, :b)
      text = Pajek.to_pajek(g)

      assert text =~ "*Edges"
      refute text =~ "*Arcs"
    end

    test "vertex labels quoted, weights included" do
      g = Graph.new() |> Graph.add_edge(:a, :b, weight: 2.5)
      text = Pajek.to_pajek(g)

      assert text =~ ~s("a")
      assert text =~ ~s("b")
      assert text =~ "2.5"
    end

    test "vertex with double-quote in name is escaped" do
      g = Graph.new() |> Graph.add_vertex("a\"b")
      text = Pajek.to_pajek(g)
      assert text =~ ~s("a\\"b")
    end
  end

  describe "from_pajek/2" do
    test "parses minimal valid input" do
      input = """
      *Vertices 2
      1 "a"
      2 "b"
      *Arcs
      1 2 1.0
      """

      g = Pajek.from_pajek(input)
      assert g.type == :directed
      assert Graph.num_vertices(g) == 2
      assert Graph.has_edge?(g, "a", "b")
    end

    test "parses *Edges as undirected" do
      input = """
      *Vertices 2
      1 "a"
      2 "b"
      *Edges
      1 2 1.0
      """

      g = Pajek.from_pajek(input)
      assert g.type == :undirected
    end

    test "weights are preserved" do
      input = """
      *Vertices 2
      1 "x"
      2 "y"
      *Arcs
      1 2 4.5
      """

      g = Pajek.from_pajek(input)
      [e] = Graph.edges_between(g, "x", "y")
      assert e.weight == 4.5
    end

    test "missing header returns error" do
      assert {:error, _} = Pajek.from_pajek("just garbage\n")
    end

    test "empty input returns error" do
      assert {:error, _} = Pajek.from_pajek("")
    end

    test "malformed edge line returns error" do
      input = """
      *Vertices 1
      1 "a"
      *Arcs
      bogus
      """

      assert {:error, _} = Pajek.from_pajek(input)
    end

    test "rejects input over :max_bytes" do
      input = "*Vertices 1\n1 \"a\"\n"
      size = byte_size(input)

      assert {:error, {:too_large, ^size, 5}} = Pajek.from_pajek(input, max_bytes: 5)
      assert %Graph{} = Pajek.from_pajek(input, max_bytes: :infinity)
    end
  end

  describe "from_pajek/2 sections" do
    test "V6 repro: *Matrix returns an error instead of looping" do
      input = "*Vertices 2\n1 \"a\"\n2 \"b\"\n*Matrix\n0 1\n1 0\n"

      assert {:error, {:unsupported_section, "*Matrix"}} = parse_within(input, 5_000)
    end

    for section <- ["*Matrix", "*Arcslist", "*Edgeslist", "*Network x"] do
      test "unsupported section #{section} after an edge section" do
        input = "*Vertices 2\n1 \"a\"\n2 \"b\"\n*Arcs\n1 2\n#{unquote(section)}\n1 2\n"

        assert {:error, {:unsupported_section, unquote(section)}} =
                 parse_within(input, 5_000)
      end
    end

    test "multi-relational *Arcs header is read as *Arcs" do
      input = "*Vertices 2\n1 \"a\"\n2 \"b\"\n*Arcs :2 \"rel\"\n1 2 3\n"

      g = parse_within(input, 5_000)
      assert g.type == :directed
      assert [%{weight: 3.0}] = Graph.edges_between(g, "a", "b")
    end

    test "*Edges after *Arcs adds arcs in both directions" do
      input = """
      *Vertices 3
      1 "a"
      2 "b"
      3 "c"
      *Arcs
      1 2
      *Edges
      2 3 2.0
      """

      g = Pajek.from_pajek(input)
      assert g.type == :directed
      assert Graph.has_edge?(g, "a", "b")
      refute Graph.has_edge?(g, "b", "a")
      assert [%{weight: 2.0}] = Graph.edges_between(g, "b", "c")
      assert [%{weight: 2.0}] = Graph.edges_between(g, "c", "b")
      assert Graph.num_edges(g) == 3
    end

    test "*Arcs after *Edges makes the graph directed" do
      input = """
      *Vertices 3
      1 "a"
      2 "b"
      3 "c"
      *Edges
      1 2
      2 2
      *Arcs
      2 3
      """

      g = Pajek.from_pajek(input)
      assert g.type == :directed
      assert Graph.has_edge?(g, "a", "b")
      assert Graph.has_edge?(g, "b", "a")
      assert length(Graph.edges_between(g, "b", "b")) == 1
      assert Graph.has_edge?(g, "b", "c")
      refute Graph.has_edge?(g, "c", "b")
    end
  end

  describe "from_pajek/2 errors" do
    test "non-numeric weight" do
      input = "*Vertices 2\n1 \"a\"\n2 \"b\"\n*Arcs\n1 2 abc\n"
      assert {:error, {:invalid_weight, "abc"}} = Pajek.from_pajek(input)
    end

    test "integer weight too large for a float" do
      huge = "1" <> String.duplicate("0", 400)
      input = "*Vertices 2\n1 \"a\"\n2 \"b\"\n*Arcs\n1 2 #{huge}\n"
      assert {:error, {:invalid_weight, token}} = Pajek.from_pajek(input)
      assert token == Util.excerpt(huge)
    end

    test "fewer vertex lines than declared" do
      assert {:error, :unexpected_eof} = Pajek.from_pajek("*Vertices 3\n1 \"a\"\n")
    end

    test "bad *Vertices count" do
      assert {:error, :bad_vertices_header} = Pajek.from_pajek("*Vertices x\n")
      assert {:error, :bad_vertices_header} = Pajek.from_pajek("*Vertices -1\n")
    end

    test "malformed vertex lines" do
      for line <- ["x \"a\"", "1x", "1 \"unterminated", "3 \"c\""] do
        input = "*Vertices 2\n1 \"a\"\n#{line}\n*Arcs\n"
        assert {:error, {:malformed_vertex_line, ^line}} = Pajek.from_pajek(input)
      end
    end

    test "duplicate vertex index" do
      input = "*Vertices 2\n1 \"a\"\n1 \"b\"\n*Arcs\n"
      assert {:error, {:malformed_vertex_line, ~s(1 "b")}} = Pajek.from_pajek(input)
    end

    test "edge to an undeclared index" do
      input = "*Vertices 2\n1 \"a\"\n2 \"b\"\n*Arcs\n1 3\n"
      assert {:error, {:malformed_edge_line, "1 3"}} = Pajek.from_pajek(input)
    end

    test "a section header before all declared vertex lines" do
      input = "*Vertices 2\n1 \"a\"\n*Arcs\n1 1\n"
      assert {:error, :unexpected_section} = Pajek.from_pajek(input)
    end

    test "an overlong *Vertices count is a bad header, not a bignum" do
      input = "*Vertices " <> String.duplicate("9", 1_000_000) <> "\n"
      assert {:error, :bad_vertices_header} = Pajek.from_pajek(input)
    end

    test "overlong vertex and edge indices are malformed lines" do
      long_one = String.duplicate("0", 30) <> "1"

      vertex_input = "*Vertices 1\n#{long_one} \"a\"\n"

      assert {:error, {:malformed_vertex_line, _}} = Pajek.from_pajek(vertex_input)

      edge_input = "*Vertices 1\n1 \"a\"\n*Arcs\n#{long_one} 1\n"
      assert {:error, {:malformed_edge_line, _}} = Pajek.from_pajek(edge_input)
    end

    test "an error carries a bounded excerpt of the line, not the whole line" do
      line = "1 2 " <> String.duplicate("x ", 500_000)
      input = "*Vertices 1\n1 \"a\"\n*Arcs\n" <> line

      assert {:error, {:malformed_edge_line, excerpt}} = Pajek.from_pajek(input)
      assert byte_size(excerpt) < 300
      assert String.starts_with?(line, String.trim_trailing(excerpt, "."))
      assert :binary.referenced_byte_size(excerpt) == byte_size(excerpt)

      assert {:error, {:unsupported_section, excerpt}} =
               Pajek.from_pajek("*Vertices 0\n*Matrix" <> String.duplicate(" x", 500_000))

      assert byte_size(excerpt) < 300
    end

    test "labels do not keep the input alive" do
      # Sub-binaries under 64 bytes may be copied anyway, so use longer labels.
      long = String.duplicate("x", 100)

      input =
        "*Vertices 2\n1 #{long}a\n2 \"#{long}b\"\n*Arcs\n1 2\n" <>
          String.duplicate("% padding\n", 100)

      for v <- Graph.vertices(Pajek.from_pajek(input)) do
        assert :binary.referenced_byte_size(v) == byte_size(v)
      end
    end

    @tag :slow
    test "64 MiB of blank lines decode in bounded memory" do
      for input <- [
            String.duplicate("\n", 64 * 1024 * 1024),
            String.duplicate("\r\n", 32 * 1024 * 1024)
          ] do
        assert {:done, {:error, :empty_input}} = with_heap_cap(fn -> Pajek.from_pajek(input) end)
      end

      edges = String.duplicate("\n", 64 * 1024 * 1024 - 64)
      input = ~s(*Vertices 2\n1 "a"\n2 "b"\n*Edges\n) <> edges <> "1 2\n"
      assert {:done, %Graph{type: :undirected}} = with_heap_cap(fn -> Pajek.from_pajek(input) end)
    end
  end

  describe "duplicate labels" do
    test "vertices sharing a label stay distinct by index" do
      input = """
      *Vertices 3
      1 "a"
      2 "a"
      3 "b"
      *Arcs
      1 3
      2 3 5
      """

      g = Pajek.from_pajek(input)
      assert Graph.num_vertices(g) == 3
      assert Enum.sort(Graph.vertices(g)) == Enum.sort([{"a", 1}, {"a", 2}, "b"])
      assert [%{weight: 1.0}] = Graph.edges_between(g, {"a", 1}, "b")
      assert [%{weight: 5.0}] = Graph.edges_between(g, {"a", 2}, "b")
    end

    test "ids with the same text form survive a round-trip as separate vertices" do
      g = Graph.new() |> Graph.add_edge(:a, "a")
      g2 = g |> Pajek.to_pajek() |> Pajek.from_pajek()

      assert Graph.num_vertices(g2) == 2
      assert Graph.num_edges(g2) == 1
    end
  end

  describe "label escaping" do
    test "labels round-trip unchanged" do
      labels = [
        "a\"b",
        "a\\b",
        "a\\\"b",
        "ends with \\",
        "with spaces",
        "  padded  ",
        "line\nbreak",
        "cr\rlf",
        "a\\nb",
        "",
        "x\n*Arcs\n1 1"
      ]

      g = Enum.reduce(labels, Graph.new(), &Graph.add_vertex(&2, &1))
      g2 = g |> Pajek.to_pajek() |> Pajek.from_pajek()

      assert Enum.sort(Graph.vertices(g2)) == Enum.sort(labels)
      assert Graph.num_edges(g2) == 0
    end

    test "a label cannot inject a section or an edge" do
      label = "x\n*Arcs\n1 1 1\n%"
      text = Graph.new() |> Graph.add_vertex(label) |> Pajek.to_pajek()

      assert length(String.split(text, "\n")) == 3
      g = Pajek.from_pajek(text)
      assert Graph.vertices(g) == [label]
      assert Graph.num_edges(g) == 0
    end

    test "edges between escaped labels round-trip" do
      g = Graph.new() |> Graph.add_edge("a\"b", "c\\d", weight: 2.5)
      g2 = g |> Pajek.to_pajek() |> Pajek.from_pajek()

      assert [%{weight: 2.5}] = Graph.edges_between(g2, "a\"b", "c\\d")
    end

    test "unknown escapes are kept and trailing vertex attributes ignored" do
      input = "*Vertices 1\n1 \"C:\\dir\" 0.1 0.2 0.5\n*Arcs\n"
      assert Graph.vertices(Pajek.from_pajek(input)) == ["C:\\dir"]
    end
  end

  describe "round-trip" do
    test "directed weighted graph" do
      g =
        Graph.new()
        |> Graph.add_edge("a", "b", weight: 2.5)
        |> Graph.add_edge("b", "c", weight: 3.0)
        |> Graph.add_edge("a", "c", weight: 7.0)

      text = Pajek.to_pajek(g)
      g2 = Pajek.from_pajek(text)

      assert g2.type == :directed
      assert Graph.num_vertices(g2) == 3
      assert Graph.num_edges(g2) == 3
      [e_ab] = Graph.edges_between(g2, "a", "b")
      assert e_ab.weight == 2.5
    end

    test "undirected round-trip" do
      g =
        Graph.new(type: :undirected)
        |> Graph.add_edge("x", "y", weight: 1.5)

      text = Pajek.to_pajek(g)
      g2 = Pajek.from_pajek(text)

      assert g2.type == :undirected
      assert Graph.has_edge?(g2, "x", "y")
      assert Graph.has_edge?(g2, "y", "x")
    end

    test "multi-edge round-trip" do
      g =
        Graph.new()
        |> Graph.add_edge("a", "b", weight: 1.0)
        |> Graph.add_edge("a", "b", weight: 2.0)

      text = Pajek.to_pajek(g)
      g2 = Pajek.from_pajek(text)

      assert Graph.num_edges(g2) == 2
      assert length(Graph.edges_between(g2, "a", "b")) == 2
    end

    test "vertices are 1-indexed in output" do
      g = Graph.new() |> Graph.add_vertices([:x, :y, :z])
      text = Pajek.to_pajek(g)
      lines = String.split(text, "\n")
      # First vertex line is "1 ..."
      vertex_lines = Enum.filter(lines, &Regex.match?(~r/^\d+ /, &1))
      assert hd(vertex_lines) =~ ~r/^1 /
    end
  end

  # The base parser looped forever on unknown sections; fail fast instead of
  # waiting for the ExUnit timeout.
  defp parse_within(input, ms) do
    task = Task.async(fn -> Pajek.from_pajek(input) end)

    case Task.yield(task, ms) || Task.shutdown(task, :brutal_kill) do
      {:ok, result} -> result
      nil -> flunk("from_pajek/1 did not return within #{ms} ms")
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
