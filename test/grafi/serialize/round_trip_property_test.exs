defmodule Grafi.Serialize.RoundTripPropertyTest do
  @moduledoc """
  Round-trip properties for all 9 serializers, each on the subset of graphs
  its format represents without loss. Graphs come from
  `Grafi.Test.Generators` (self-loops, parallel edges, isolated vertices,
  negative/zero/fractional weights, labels full of quotes, newlines,
  markup and separators).

  | Format | Lossless subset (`from_x(to_x(g))` equivalent to `g`) |
  |---|---|
  | JSON | integer or string ids; type, vertices, edges, weights, vertex and edge labels |
  | GraphML, GEXF | string ids (other ids come back as their text); type, vertices, edges, weights, vertex and edge labels, including leading/trailing whitespace and combining marks. Invalid UTF-8 and XML-illegal control characters raise `ArgumentError` |
  | Pajek | string ids (other ids come back as their text); type, vertices, edges, weights. No labels: the vertex label is the id |
  | Edge list | whitespace-free string ids; edges with weights. Type comes from the `:directed` option; isolated vertices and labels are not represented. Ids that can't round-trip raise `ArgumentError` |
  | Adjacency list | whitespace-free string ids, directed; vertices and the edge *set*, or with `collapse_multi_edges: false` the edge multiset; any separator. No weights or labels |
  | MatrixMarket | integer (including bignum), atom and string ids, including strings with reserved prefixes (`int:`), whitespace and `%`; type, vertices, and the summed weight of each vertex pair (parallel edges add up). No labels |
  | DOT, Mermaid | write-only; their structure is checked in `encoder_structure_property_test.exs` |
  """
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias Grafi.Graph
  alias Grafi.Serialize.{AdjacencyList, EdgeList, GEXF, GraphML, JSON, MatrixMarket, Pajek, Util}
  alias Grafi.Test.Generators

  # ── Equivalence helpers ─────────────────────────────────────────────

  # Undirected edges are compared with their endpoints in term order.
  defp ends(%Graph{type: :undirected}, %{from: f, to: t}) when t < f, do: {t, f}
  defp ends(_g, %{from: f, to: t}), do: {f, t}

  defp vertices(g), do: g |> Graph.vertices() |> Enum.sort()
  defp edges(g, fun), do: g |> Graph.edges() |> Enum.map(&fun.(ends(g, &1), &1)) |> Enum.sort()
  defp vertex_labels(g), do: Map.new(Graph.vertices(g), &{&1, Graph.label(g, &1)})

  # `g` with every vertex id replaced by its text form, as text formats decode it.
  defp stringify(g) do
    Enum.reduce(
      Graph.edges(g),
      Enum.reduce(Graph.vertices(g), Graph.new(type: g.type), fn v, acc ->
        Graph.add_vertex(acc, Util.vertex_to_string(v), label: Graph.label(g, v))
      end),
      fn e, acc ->
        Graph.add_edge(acc, Util.vertex_to_string(e.from), Util.vertex_to_string(e.to),
          weight: e.weight,
          label: e.label
        )
      end
    )
  end

  defp assert_same_graph(decoded, expected, aspects) do
    assert %Graph{} = decoded, "decode failed: #{inspect(decoded)}"
    assert decoded.type == expected.type
    assert vertices(decoded) == vertices(expected)

    edge_fun =
      case aspects do
        :with_labels -> fn ends, e -> {ends, e.weight, e.label} end
        :weights_only -> fn ends, e -> {ends, e.weight} end
      end

    assert edges(decoded, edge_fun) == edges(expected, edge_fun)

    if aspects == :with_labels,
      do: assert(vertex_labels(decoded) == vertex_labels(expected))
  end

  # ── Formats with labels ─────────────────────────────────────────────

  property "JSON round-trips integer- and string-id graphs exactly" do
    check all(
            id_type <- member_of([:integer, :simple_string, :string]),
            g <- Generators.graph(id_type: id_type, vertex_labels: true, edge_labels: true)
          ) do
      assert_same_graph(JSON.from_json!(JSON.to_json(g)), g, :with_labels)
    end
  end

  property "GraphML round-trips graphs exactly, ids as text" do
    check all(g <- Generators.graph(vertex_labels: true, edge_labels: true)) do
      assert_same_graph(GraphML.from_graphml!(GraphML.to_graphml(g)), stringify(g), :with_labels)
    end
  end

  property "GEXF round-trips graphs exactly, ids as text" do
    check all(g <- Generators.graph(vertex_labels: true, edge_labels: true)) do
      assert_same_graph(GEXF.from_gexf!(GEXF.to_gexf(g)), stringify(g), :with_labels)
    end
  end

  # ── Formats without labels ──────────────────────────────────────────

  property "Pajek round-trips type, vertices, edges and weights, ids as text" do
    check all(g <- Generators.graph()) do
      assert_same_graph(Pajek.from_pajek!(Pajek.to_pajek(g)), stringify(g), :weights_only)
    end
  end

  property "the edge list round-trips weighted edges between whitespace-free ids" do
    check all(
            id_type <- member_of([:integer, :atom, :simple_string]),
            g <- Generators.graph(id_type: id_type)
          ) do
      expected = stringify(g)
      {:ok, decoded} = EdgeList.from_edge_list(EdgeList.to_edge_list(g), type: g.type)

      assert %Graph{} = decoded
      assert decoded.type == g.type
      assert edges(decoded, &{&1, &2.weight}) == edges(expected, &{&1, &2.weight})
    end
  end

  property "the adjacency list round-trips directed graphs as vertex and edge sets" do
    check all(
            g <- Generators.graph(type: :directed, id_type: :simple_string, weights: false),
            collapse? <- boolean(),
            sep <- member_of([nil, ",", " | "])
          ) do
      sep_opts = if sep, do: [separator: sep], else: []
      text = AdjacencyList.to_adjacency_list(g, [collapse_multi_edges: collapse?] ++ sep_opts)
      {:ok, decoded} = AdjacencyList.from_adjacency_list(text, sep_opts)

      assert %Graph{} = decoded
      assert vertices(decoded) == vertices(g)

      # Collapsed: the edge set; otherwise every parallel edge survives.
      shape = if collapse?, do: &Enum.uniq/1, else: & &1

      assert shape.(edges(decoded, fn ends, _ -> ends end)) ==
               shape.(edges(g, fn ends, _ -> ends end))
    end
  end

  property "MatrixMarket round-trips integer, atom and string ids and summed pair weights" do
    check all(g <- Generators.graph()) do
      {:ok, decoded} = MatrixMarket.from_matrix_market(MatrixMarket.to_matrix_market(g))

      sums = fn h ->
        Enum.reduce(
          Graph.edges(h),
          %{},
          &Map.update(&2, ends(h, &1), &1.weight, fn w -> w + &1.weight end)
        )
      end

      assert %Graph{} = decoded
      assert decoded.type == g.type
      assert vertices(decoded) == vertices(g)

      expected = sums.(g)
      actual = sums.(decoded)
      assert Enum.sort(Map.keys(actual)) == Enum.sort(Map.keys(expected))

      for {pair, w} <- expected,
          do: assert_in_delta(actual[pair], w, 1.0e-9 * max(1.0, abs(w)), inspect(pair))
    end
  end

  # ── Unrepresentable input ───────────────────────────────────────────

  property "GraphML and GEXF refuse ids that are not valid UTF-8 instead of truncating them" do
    check all(
            prefix <- string(:alphanumeric, max_length: 4),
            bad <- member_of([<<0xE9>>, <<0xFF, 0xFE>>, <<0xC3>>]),
            suffix <- string(:alphanumeric, max_length: 4)
          ) do
      g = Graph.add_edge(Graph.new(), prefix <> bad <> suffix, "ok")
      assert_raise ArgumentError, fn -> GraphML.to_graphml(g) end
      assert_raise ArgumentError, fn -> GEXF.to_gexf(g) end
    end
  end
end
