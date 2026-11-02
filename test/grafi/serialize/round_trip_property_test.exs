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
  | GraphML, GEXF | string ids (other ids come back as their text); type, vertices, edges, weights, vertex and edge labels |
  | Pajek | string ids (other ids come back as their text); type, vertices, edges, weights. No labels: the vertex label is the id |
  | Edge list | whitespace-free string ids; edges with weights. Type comes from the `:directed` option; isolated vertices and labels are not represented |
  | Adjacency list | whitespace-free string ids, directed; vertices and the edge *set* (parallel edges collapse by default). No weights or labels |
  | MatrixMarket | any id type; type, vertices, and the summed weight of each vertex pair (parallel edges add up). No labels |
  | DOT, Mermaid | write-only: encoding never raises, and every Mermaid statement stays on its own line |
  """
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias Grafi.Graph
  alias Grafi.Serialize.{AdjacencyList, DOT, EdgeList, GEXF, GraphML, JSON, MatrixMarket, Mermaid}
  alias Grafi.Serialize.{Pajek, Util}
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
      assert_same_graph(JSON.from_json(JSON.to_json(g)), g, :with_labels)
    end
  end

  property "GraphML round-trips graphs exactly, ids as text" do
    check all(g <- Generators.graph(vertex_labels: true, edge_labels: true)) do
      assert_same_graph(GraphML.from_graphml(GraphML.to_graphml(g)), stringify(g), :with_labels)
    end
  end

  property "GEXF round-trips graphs exactly, ids as text" do
    check all(g <- Generators.graph(vertex_labels: true, edge_labels: true)) do
      assert_same_graph(GEXF.from_gexf(GEXF.to_gexf(g)), stringify(g), :with_labels)
    end
  end

  # ── Formats without labels ──────────────────────────────────────────

  property "Pajek round-trips type, vertices, edges and weights, ids as text" do
    check all(g <- Generators.graph()) do
      assert_same_graph(Pajek.from_pajek(Pajek.to_pajek(g)), stringify(g), :weights_only)
    end
  end

  property "the edge list round-trips weighted edges between whitespace-free ids" do
    check all(
            id_type <- member_of([:integer, :atom, :simple_string]),
            g <- Generators.graph(id_type: id_type)
          ) do
      expected = stringify(g)
      decoded = EdgeList.from_edge_list(EdgeList.to_edge_list(g), directed: g.type == :directed)

      assert %Graph{} = decoded
      assert decoded.type == g.type
      assert edges(decoded, &{&1, &2.weight}) == edges(expected, &{&1, &2.weight})
    end
  end

  property "the adjacency list round-trips directed graphs as vertex and edge sets" do
    check all(g <- Generators.graph(type: :directed, id_type: :simple_string, weights: false)) do
      decoded = AdjacencyList.from_adjacency_list(AdjacencyList.to_adjacency_list(g))

      assert %Graph{} = decoded
      assert vertices(decoded) == vertices(g)

      assert Enum.uniq(edges(decoded, fn ends, _ -> ends end)) ==
               Enum.uniq(edges(g, fn ends, _ -> ends end))
    end
  end

  property "MatrixMarket round-trips ids of any type and summed pair weights" do
    check all(g <- Generators.graph()) do
      decoded = MatrixMarket.from_matrix_market(MatrixMarket.to_matrix_market(g))

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

  # ── Write-only formats ──────────────────────────────────────────────

  property "DOT encodes any graph, whatever its labels" do
    check all(g <- Generators.graph(vertex_labels: true, edge_labels: true)) do
      assert is_binary(DOT.to_dot(g))
    end
  end

  property "Mermaid keeps every vertex and edge statement on its own line" do
    check all(g <- Generators.graph(vertex_labels: true, edge_labels: true)) do
      # Edge labels come from the edges themselves; vertex labels via the option.
      lines =
        g
        |> Mermaid.to_mermaid(vertex_label: &(Graph.label(g, &1) || inspect(&1)))
        |> String.split(["\r\n", "\n", "\r"])
        |> Enum.reject(&(&1 == ""))

      assert length(lines) == 1 + Graph.num_vertices(g) + Graph.num_edges(g)
    end
  end
end
