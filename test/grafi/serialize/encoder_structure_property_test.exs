defmodule Grafi.Serialize.EncoderStructurePropertyTest do
  @moduledoc """
  Structural properties of the write-only encoders. Whatever the ids,
  labels and weights, DOT output lexes (by Graphviz's own rules) into
  exactly one statement per vertex and edge, with every quoted string
  closed and each token carrying the text it was written from. Mermaid
  output has one well-formed line per vertex and edge, and label text
  cannot start a directive or inject HTML.
  """
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias Grafi.Graph
  alias Grafi.Serialize.{DOT, Mermaid, Util}
  alias Grafi.Test.Generators

  # ── DOT ─────────────────────────────────────────────────────────────

  # Tokens as Graphviz's lexer (lib/cgraph/scan.l, 2.38 to current) reads
  # them. Inside a quoted string `\\"` is a literal quote, `\\\\` is one unit,
  # `\\` before a newline is dropped, and a bare `"` ends the string.
  # Quoted strings come back decoded (`\\"` → `"`, `\\\\` → `\\`).
  defp lex(<<>>, acc), do: {:ok, Enum.reverse(acc)}
  defp lex(<<c, rest::binary>>, acc) when c in [?\s, ?\t, ?\n, ?\r], do: lex(rest, acc)

  defp lex(<<?", rest::binary>>, acc) do
    case qstring(rest, "") do
      {:ok, s, rest} -> lex(rest, [{:q, s} | acc])
      :unterminated -> {:error, :unterminated}
    end
  end

  defp lex(<<"->", rest::binary>>, acc), do: lex(rest, [:arrow | acc])
  defp lex(<<"--", rest::binary>>, acc), do: lex(rest, [:arrow | acc])
  defp lex(<<c, rest::binary>>, acc) when c in ~c"{}[];,=", do: lex(rest, [<<c>> | acc])

  defp lex(bin, acc) do
    case Regex.run(~r/^[A-Za-z0-9_.\-]+/, bin) do
      [word] ->
        lex(binary_part(bin, byte_size(word), byte_size(bin) - byte_size(word)), [word | acc])

      nil ->
        {:error, {:unexpected, bin}}
    end
  end

  defp qstring(<<>>, _acc), do: :unterminated
  defp qstring(<<?", rest::binary>>, acc), do: {:ok, acc, rest}
  defp qstring(<<?\\, ?", rest::binary>>, acc), do: qstring(rest, acc <> "\"")
  defp qstring(<<?\\, ?\\, rest::binary>>, acc), do: qstring(rest, acc <> "\\")
  defp qstring(<<?\\, ?\n, rest::binary>>, acc), do: qstring(rest, acc)
  defp qstring(<<c, rest::binary>>, acc), do: qstring(rest, acc <> <<c>>)

  defp text({:q, s}), do: s
  defp text(word) when is_binary(word), do: word

  # `[k = v, ...]` → %{k => token}
  defp attrs([]), do: %{}

  defp attrs(["[" | rest]) do
    ["]" | inner] = Enum.reverse(rest)

    inner
    |> Enum.reverse()
    |> Enum.chunk_by(&(&1 == ","))
    |> Enum.reject(&(&1 == [","]))
    |> Map.new(fn [k, "=", v] -> {k, v} end)
  end

  defp dot_numeral?(s), do: s =~ ~r/^-?(\.[0-9]+|[0-9]+(\.[0-9]*)?)$/

  # Lexes `dot` and checks it against `g`, statement by statement.
  defp assert_dot_structure(g, dot) do
    assert {:ok, tokens} = lex(dot, []), "every quoted string is terminated"

    outside = Enum.filter(tokens, &is_binary/1)
    assert Enum.count(outside, &(&1 == "{")) == 1
    assert Enum.count(outside, &(&1 == "}")) == 1
    assert Enum.count(outside, &(&1 == ";")) == Graph.num_vertices(g) + Graph.num_edges(g)

    keyword = if g.type == :directed, do: "digraph", else: "graph"
    assert [^keyword, "G", "{" | body] = tokens
    assert "}" = List.last(body)

    statements = body |> Enum.drop(-1) |> Enum.chunk_by(&(&1 == ";")) |> Enum.take_every(2)
    {vertex_stmts, edge_stmts} = Enum.split(statements, Graph.num_vertices(g))

    for {v, [id | rest]} <- Enum.zip(Graph.vertices(g), vertex_stmts) do
      assert text(id) == Util.vertex_to_string(v)

      case Graph.label(g, v) do
        nil -> assert rest == []
        label -> assert %{"label" => {:q, ^label}} = attrs(rest)
      end
    end

    for {e, [from, :arrow, to | rest]} <- Enum.zip(Graph.edges(g), edge_stmts) do
      assert text(from) == Util.vertex_to_string(e.from)
      assert text(to) == Util.vertex_to_string(e.to)
      attrs = attrs(rest)

      if e.weight == 1.0 do
        refute Map.has_key?(attrs, "weight")
      else
        weight = Map.fetch!(attrs, "weight")
        assert text(weight) == Util.format_weight(e.weight)
        assert match?({:q, _}, weight) or dot_numeral?(weight)
      end

      if e.label, do: assert(text(attrs["label"]) == to_string(e.label))
    end
  end

  property "DOT: one terminated statement per vertex and edge, tokens intact" do
    check all(g <- Generators.graph(vertex_labels: true, edge_labels: true)) do
      assert_dot_structure(g, DOT.to_dot(g))
    end
  end

  property "DOT: weights in any notation stay a single token" do
    weight =
      one_of([
        Generators.weight(),
        member_of([1.0e300, -1.0e-300, 5.0e-324, 1.0e20, 1.0e-5, 3, -7, 10 ** 30])
      ])

    check all(edges <- list_of(tuple({integer(0..4), integer(0..4), weight}), max_length: 10)) do
      g =
        Enum.reduce(edges, Graph.new(), fn {u, v, w}, acc ->
          Graph.add_edge(acc, u, v, weight: w)
        end)

      assert_dot_structure(g, DOT.to_dot(g))
    end
  end

  test "DOT: ids and labels ending in backslashes cannot end or escape their quotes" do
    nasty = ["\\", "a\\", "a\\\\", "a\\\\\\", "\\\"", "a\\\n", ~s(\\"; x -> y [label=")]

    g =
      Enum.reduce(nasty, Graph.new(), fn s, acc ->
        acc
        |> Graph.add_vertex(s, label: s)
        |> Graph.add_edge(s, "z", label: s)
      end)

    assert_dot_structure(g, DOT.to_dot(g))
  end

  test "the DOT checker catches a string whose closing quote is escaped" do
    assert lex(~S(digraph G { "a\"; }), []) == {:error, :unterminated}
  end

  # ── Mermaid ─────────────────────────────────────────────────────────

  @node_line ~r/^\s*v\d+\[("[^"]*"|[A-Za-z0-9_]+)\]$/
  @edge_line ~r/^\s*v\d+ (-->|---)(\|[^|]*\|)? v\d+$/

  # Label text as written: inside a node's brackets or an edge's pipes.
  defp label_text(line) do
    case Regex.run(~r/\[(.*)\]$|\|(.*)\|/, line) do
      [_, node] -> node
      [_, "", edge] -> edge
      nil -> ""
    end
  end

  property "Mermaid: well-formed node and edge lines, labels neutralised" do
    check all(g <- Generators.graph(vertex_labels: true, edge_labels: true)) do
      out = Mermaid.to_mermaid(g, vertex_label: &(Graph.label(g, &1) || inspect(&1)))

      refute out =~ "\r"
      refute out =~ "%"
      refute out =~ "<"
      # The only `>` left is each directed edge's arrow.
      assert out |> String.graphemes() |> Enum.count(&(&1 == ">")) ==
               if(g.type == :directed, do: Graph.num_edges(g), else: 0)

      [header | lines] = String.split(out, "\n")
      assert header =~ ~r/^(flowchart|graph) (TD|LR|BT|RL)$/

      {node_lines, edge_lines} = Enum.split(lines, Graph.num_vertices(g))
      assert length(edge_lines) == Graph.num_edges(g)

      for line <- node_lines do
        assert line =~ @node_line
        quotes = line |> String.graphemes() |> Enum.count(&(&1 == "\""))
        assert quotes == 2 or line =~ ~r/\[[A-Za-z0-9_]+\]$/
      end

      for line <- edge_lines, do: assert(line =~ @edge_line)

      for line <- lines do
        label = label_text(line) |> String.trim("\"")
        refute label =~ ~r/["'`&%<>|]/
        # Every `#` starts an entity code.
        refute label =~ ~r/#(?![0-9]+;|quot;|lt;|gt;|amp;)/
      end
    end
  end
end
