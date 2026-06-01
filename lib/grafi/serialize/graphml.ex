defmodule Grafi.Serialize.GraphML do
  @moduledoc """
  Serialize and deserialize graphs in GraphML (XML) format.

  Output layout:

      <?xml version="1.0" encoding="UTF-8"?>
      <graphml xmlns="http://graphml.graphdrawing.org/xmlns">
        <key id="vlabel" for="node" attr.name="label" attr.type="string"/>
        <key id="eweight" for="edge" attr.name="weight" attr.type="double"/>
        <key id="elabel"  for="edge" attr.name="label"  attr.type="string"/>
        <graph id="G" edgedefault="directed">
          <node id="a"><data key="vlabel">Alpha</data></node>
          <node id="b"/>
          <edge source="a" target="b">
            <data key="eweight">2.5</data>
          </edge>
        </graph>
      </graphml>

  The decoder is a small line-oriented parser tailored to the subset emitted
  by `to_graphml/2`. It handles XML entity escaping (`&lt; &gt; &amp; &quot;
  &apos;`) and accepts attribute values quoted with either `"` or `'`. It
  does NOT handle CDATA sections, processing instructions, namespaces beyond
  the default `graphml`, or nested `<graph>` elements. Round-trip on our own
  output is the supported use case.

  Reference: <http://graphml.graphdrawing.org/specification.html>
  """

  alias Grafi.Graph

  @doc """
  Renders a graph as a GraphML string.

  ## Options
    * `:name` — graph identifier written to `<graph id="...">` (default `"G"`).

  ## Examples

      iex> g = Grafi.Graph.new() |> Grafi.Graph.add_edge(:a, :b)
      iex> Grafi.Serialize.GraphML.to_graphml(g) =~ ~s(edgedefault="directed")
      true
  """
  @spec to_graphml(Graph.t(), keyword()) :: String.t()
  def to_graphml(%Graph{} = g, opts \\ []) do
    name = Keyword.get(opts, :name, "G")
    edgedefault = if g.type == :directed, do: "directed", else: "undirected"

    node_lines =
      Graph.vertices(g)
      |> Enum.map(fn v ->
        id = vertex_to_string(v) |> xml_escape_attr()

        case Graph.label(g, v) do
          nil ->
            ~s(    <node id="#{id}"/>)

          label ->
            label_str = label |> to_string() |> xml_escape_text()

            ~s(    <node id="#{id}"><data key="vlabel">#{label_str}</data></node>)
        end
      end)

    edge_lines =
      Graph.edges(g)
      |> Enum.with_index()
      |> Enum.map(fn {e, idx} ->
        src = vertex_to_string(e.from) |> xml_escape_attr()
        tgt = vertex_to_string(e.to) |> xml_escape_attr()

        data_parts = []

        data_parts =
          if e.weight != nil,
            do: [~s(      <data key="eweight">#{format_weight(e.weight)}</data>) | data_parts],
            else: data_parts

        data_parts =
          if e.label,
            do: [
              ~s(      <data key="elabel">#{xml_escape_text(to_string(e.label))}</data>)
              | data_parts
            ],
            else: data_parts

        case data_parts do
          [] ->
            ~s(    <edge id="e#{idx}" source="#{src}" target="#{tgt}"/>)

          parts ->
            ~s(    <edge id="e#{idx}" source="#{src}" target="#{tgt}">\n) <>
              Enum.join(Enum.reverse(parts), "\n") <> "\n    </edge>"
        end
      end)

    [
      ~s(<?xml version="1.0" encoding="UTF-8"?>),
      ~s(<graphml xmlns="http://graphml.graphdrawing.org/xmlns">),
      ~s(  <key id="vlabel" for="node" attr.name="label" attr.type="string"/>),
      ~s(  <key id="eweight" for="edge" attr.name="weight" attr.type="double"/>),
      ~s(  <key id="elabel" for="edge" attr.name="label" attr.type="string"/>),
      ~s(  <graph id="#{xml_escape_attr(name)}" edgedefault="#{edgedefault}">)
    ]
    |> Kernel.++(node_lines)
    |> Kernel.++(edge_lines)
    |> Kernel.++(["  </graph>", "</graphml>"])
    |> Enum.join("\n")
  end

  @doc """
  Parses a GraphML string into a `Grafi.Graph`.

  Returns the graph on success or `{:error, reason}` on parse failure.
  Vertex ids round-trip as strings (XML has no atom or integer types).

  ## Options
    * `:max_bytes` — reject input larger than this many bytes with
      `{:error, :input_too_large}` before parsing. Defaults to `:infinity`
      (no limit). Set this when decoding untrusted input to bound the work
      the regex-based parser will do.
  """
  @spec from_graphml(String.t(), keyword()) :: Graph.t() | {:error, term()}
  def from_graphml(xml, opts \\ []) when is_binary(xml) do
    with :ok <- check_size(xml, Keyword.get(opts, :max_bytes, :infinity)),
         {:ok, type} <- detect_edge_default(xml),
         {:ok, nodes} <- extract_nodes(xml),
         {:ok, edges} <- extract_edges(xml) do
      g = Graph.new(type: type)

      g =
        Enum.reduce(nodes, g, fn {id, label}, acc ->
          opts = if label, do: [label: label], else: []
          Graph.add_vertex(acc, id, opts)
        end)

      Enum.reduce(edges, g, fn {src, tgt, weight, label}, acc ->
        opts = [weight: weight || 1.0]
        opts = if label, do: Keyword.put(opts, :label, label), else: opts
        Graph.add_edge(acc, src, tgt, opts)
      end)
    end
  rescue
    _ -> {:error, :malformed_graphml}
  end

  # ── Parsing helpers ──────────────────────────────────────────────────

  defp check_size(_xml, :infinity), do: :ok

  defp check_size(xml, max) when is_integer(max) do
    if byte_size(xml) > max, do: {:error, :input_too_large}, else: :ok
  end

  defp detect_edge_default(xml) do
    case Regex.run(~r/<graph\b[^>]*\bedgedefault\s*=\s*(["'])(directed|undirected)\1/, xml) do
      [_, _, "directed"] -> {:ok, :directed}
      [_, _, "undirected"] -> {:ok, :undirected}
      _ -> {:error, :missing_graph_element}
    end
  end

  defp extract_nodes(xml) do
    # Self-closing: <node id="..."/>
    self_closed =
      Regex.scan(~r/<node\b([^>]*?)\/>/s, xml)
      |> Enum.map(fn [_, attrs] -> {parse_id(attrs), nil} end)

    # With body: <node id="...">...</node>
    bodied =
      Regex.scan(~r/<node\b([^>]*?)>(.*?)<\/node>/s, xml)
      |> Enum.map(fn [_, attrs, body] ->
        label = extract_data(body, "vlabel")
        {parse_id(attrs), label}
      end)

    nodes =
      (self_closed ++ bodied)
      |> Enum.reject(fn {id, _} -> id == nil end)

    {:ok, nodes}
  rescue
    _ -> {:error, :malformed_nodes}
  end

  defp extract_edges(xml) do
    self_closed =
      Regex.scan(~r/<edge\b([^>]*?)\/>/s, xml)
      |> Enum.map(fn [_, attrs] ->
        {parse_attr(attrs, "source"), parse_attr(attrs, "target"), nil, nil}
      end)

    bodied =
      Regex.scan(~r/<edge\b([^>]*?)>(.*?)<\/edge>/s, xml)
      |> Enum.map(fn [_, attrs, body] ->
        src = parse_attr(attrs, "source")
        tgt = parse_attr(attrs, "target")
        weight = body |> extract_data("eweight") |> parse_number()
        label = extract_data(body, "elabel")
        {src, tgt, weight, label}
      end)

    edges =
      (self_closed ++ bodied)
      |> Enum.reject(fn {s, t, _, _} -> s == nil or t == nil end)

    {:ok, edges}
  rescue
    _ -> {:error, :malformed_edges}
  end

  defp parse_id(attrs), do: parse_attr(attrs, "id")

  defp parse_attr(attrs, name) do
    case Regex.run(~r/\b#{Regex.escape(name)}\s*=\s*(["'])(.*?)\1/s, attrs) do
      [_, _, value] -> xml_unescape(value)
      _ -> nil
    end
  end

  defp extract_data(body, key) do
    case Regex.run(
           ~r/<data\b[^>]*\bkey\s*=\s*(["'])#{Regex.escape(key)}\1[^>]*>(.*?)<\/data>/s,
           body
         ) do
      [_, _, text] -> xml_unescape(String.trim(text))
      _ -> nil
    end
  end

  defp parse_number(nil), do: nil

  defp parse_number(s) do
    case Float.parse(s) do
      {f, ""} ->
        f

      _ ->
        case Integer.parse(s) do
          {i, ""} -> i * 1.0
          _ -> nil
        end
    end
  end

  # ── XML escaping ─────────────────────────────────────────────────────

  defp xml_escape_attr(s) do
    s
    |> String.replace("&", "&amp;")
    |> String.replace("<", "&lt;")
    |> String.replace(">", "&gt;")
    |> String.replace("\"", "&quot;")
    |> String.replace("'", "&apos;")
  end

  defp xml_escape_text(s) do
    s
    |> String.replace("&", "&amp;")
    |> String.replace("<", "&lt;")
    |> String.replace(">", "&gt;")
  end

  defp xml_unescape(s) do
    s
    |> String.replace("&lt;", "<")
    |> String.replace("&gt;", ">")
    |> String.replace("&quot;", "\"")
    |> String.replace("&apos;", "'")
    |> String.replace("&amp;", "&")
  end

  defp vertex_to_string(v) when is_binary(v), do: v
  defp vertex_to_string(v) when is_atom(v), do: Atom.to_string(v)
  defp vertex_to_string(v) when is_integer(v), do: Integer.to_string(v)
  defp vertex_to_string(v) when is_float(v), do: Float.to_string(v)
  defp vertex_to_string(v), do: inspect(v)

  defp format_weight(w) when is_float(w), do: Float.to_string(w)
  defp format_weight(w) when is_integer(w), do: Integer.to_string(w)
  defp format_weight(w), do: to_string(w)
end
