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

  The decoder is a small tokenizer tailored to the subset emitted by
  `to_graphml/2`: one linear scan for `<node>`/`<edge>` start tags, whose
  attributes (quoted with `"` or `'`) are read by name, plus the `<data>`
  children of each element. It decodes the predefined XML entities and
  numeric character references. It does NOT validate the XML (a malformed
  document can still decode to a graph) and does not handle CDATA sections,
  comments containing tags, `>` inside attribute values, namespaces beyond
  the default `graphml`, or nested `<graph>` elements. Round-trip on our own
  output is the supported use case.

  Reference: <http://graphml.graphdrawing.org/specification.html>
  """

  alias Grafi.Graph
  alias Grafi.Serialize.{Util, XML}

  @graph_tag ~r/<graph\b([^>]*)>/
  @element ~r/<(node|edge)\b([^>]*?)(\/?)>/
  @attribute ~r/([\w.:-]+)\s*=\s*(?:"([^"]*)"|'([^']*)')/
  # `<data ...>` with its `key` captured positionally: the attributes before
  # `key` are skipped whole, so a value such as `id="key='x'"` is not read as
  # the key.
  @data ~r/<data(?:\s+(?!key\b)[\w.:-]+\s*=\s*(?:"[^"]*"|'[^']*'))*\s+key\s*=\s*(?:"([^"]*)"|'([^']*)')[^>]*?(?:\/>|>(.*?)<\/data>)/s

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
        id = v |> Util.vertex_to_string() |> XML.escape()

        case Graph.label(g, v) do
          nil ->
            ~s(    <node id="#{id}"/>)

          label ->
            label_str = label |> to_string() |> data_text()

            ~s(    <node id="#{id}"><data key="vlabel">#{label_str}</data></node>)
        end
      end)

    edge_lines =
      Graph.edges(g)
      |> Enum.with_index()
      |> Enum.map(fn {e, idx} ->
        src = e.from |> Util.vertex_to_string() |> XML.escape()
        tgt = e.to |> Util.vertex_to_string() |> XML.escape()

        data_parts = []

        data_parts =
          if e.weight != nil,
            do: [~s(      <data key="eweight">#{Util.format_weight(e.weight)}</data>) | data_parts],
            else: data_parts

        data_parts =
          if e.label,
            do: [
              ~s(      <data key="elabel">#{data_text(to_string(e.label))}</data>)
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
      ~s(  <graph id="#{XML.escape(name)}" edgedefault="#{edgedefault}">)
    ]
    |> Kernel.++(node_lines)
    |> Kernel.++(edge_lines)
    |> Kernel.++(["  </graph>", "</graphml>"])
    |> Enum.join("\n")
  end

  @doc """
  Parses a GraphML string into a `Grafi.Graph`.

  Returns the graph on success or `{:error, reason}` on parse failure, e.g.
  `{:error, {:invalid_weight, text}}` for a non-numeric `eweight` or
  `{:error, {:unclosed_element, "node" | "edge"}}`. Vertex ids round-trip as
  strings (XML has no atom or integer types). An edge without an `eweight`
  gets weight `1.0`.

  ## Options
    * `:max_bytes` — reject input larger than this many bytes with
      `{:error, {:too_large, size, max}}` before parsing. Defaults to 64 MiB;
      pass `:infinity` to disable the limit.
  """
  @spec from_graphml(String.t(), keyword()) :: Graph.t() | {:error, term()}
  def from_graphml(xml, opts \\ []) when is_binary(xml) do
    with :ok <- Util.check_size(xml, opts),
         {:ok, type} <- detect_edge_default(xml),
         {:ok, nodes, edges} <- tokenize(xml) do
      g =
        Enum.reduce(nodes, Graph.new(type: type), fn {id, label}, acc ->
          opts = if label, do: [label: label], else: []
          Graph.add_vertex(acc, id, opts)
        end)

      Enum.reduce(edges, g, fn {src, tgt, weight, label}, acc ->
        opts = if label, do: [weight: weight, label: label], else: [weight: weight]
        Graph.add_edge(acc, src, tgt, opts)
      end)
    end
  end

  # ── Parsing helpers ──────────────────────────────────────────────────

  defp detect_edge_default(xml) do
    with [_, attrs] <- Regex.run(@graph_tag, xml),
         {:ok, type} <- edge_type(attribute(parse_attributes(attrs), "edgedefault")) do
      {:ok, type}
    else
      _ -> {:error, :missing_graph_element}
    end
  end

  defp edge_type("directed"), do: {:ok, :directed}
  defp edge_type("undirected"), do: {:ok, :undirected}
  defp edge_type(_), do: :error

  # One left-to-right scan for `<node>`/`<edge>` start tags. A bodied
  # element's end tag is found with `:binary.match/3`; start tags inside that
  # body are skipped, so its `<data>` children are never rescanned as elements.
  defp tokenize(xml) do
    @element
    |> Regex.scan(xml, return: :index)
    |> collect_elements(xml, 0, [], [])
  end

  defp collect_elements([], _xml, _resume, nodes, edges),
    do: {:ok, Enum.reverse(nodes), Enum.reverse(edges)}

  defp collect_elements([[{start, _} | _] | rest], xml, resume, nodes, edges)
       when start < resume,
       do: collect_elements(rest, xml, resume, nodes, edges)

  defp collect_elements([match | rest], xml, _resume, nodes, edges) do
    [{start, len}, {tag_at, tag_len}, {attrs_at, attrs_len}, {_, slash_len}] = match
    tag = binary_part(xml, tag_at, tag_len)
    attrs = xml |> binary_part(attrs_at, attrs_len) |> parse_attributes()

    with {:ok, body, resume} <- element_body(xml, tag, start + len, slash_len),
         {:ok, nodes, edges} <- collect(tag, attrs, body, nodes, edges) do
      collect_elements(rest, xml, resume, nodes, edges)
    end
  end

  defp element_body(_xml, _tag, pos, 1), do: {:ok, "", pos}

  defp element_body(xml, tag, pos, 0) do
    case :binary.match(xml, end_tag(tag), scope: {pos, byte_size(xml) - pos}) do
      {at, len} -> {:ok, binary_part(xml, pos, at - pos), at + len}
      :nomatch -> {:error, {:unclosed_element, tag}}
    end
  end

  defp end_tag("node"), do: "</node>"
  defp end_tag("edge"), do: "</edge>"

  defp collect("node", attrs, body, nodes, edges) do
    case attribute(attrs, "id") do
      nil -> {:ok, nodes, edges}
      id -> {:ok, [{id, Map.get(parse_data(body), "vlabel")} | nodes], edges}
    end
  end

  defp collect("edge", attrs, body, nodes, edges) do
    data = parse_data(body)

    with src when src != nil <- attribute(attrs, "source"),
         tgt when tgt != nil <- attribute(attrs, "target"),
         {:ok, weight} <- edge_weight(Map.get(data, "eweight")) do
      {:ok, nodes, [{src, tgt, weight, Map.get(data, "elabel")} | edges]}
    else
      nil -> {:ok, nodes, edges}
      {:error, _} = error -> error
    end
  end

  defp edge_weight(nil), do: {:ok, 1.0}
  defp edge_weight(text), do: Util.parse_weight(text)

  # Attribute name => raw (still escaped) value; read with `attribute/2`.
  defp parse_attributes(""), do: %{}

  defp parse_attributes(text) do
    @attribute
    |> Regex.scan(text, capture: :all_but_first)
    |> Map.new(fn
      [name, double_quoted] -> {name, double_quoted}
      [name, "", single_quoted] -> {name, single_quoted}
    end)
  end

  defp attribute(attrs, name) do
    case attrs do
      %{^name => value} -> XML.unescape(value)
      _ -> nil
    end
  end

  # Escaped `<data>` text. The decoder trims data text (tolerating
  # pretty-printed input), so leading/trailing whitespace is written as
  # character references, which survive the trim and decode back exactly.
  defp data_text(s) do
    {lead, rest} = split_while(s, &whitespace?/1)
    {trail, core} = rest |> String.reverse() |> split_while(&whitespace?/1)

    char_refs(lead) <> XML.escape(String.reverse(core)) <> char_refs(String.reverse(trail))
  end

  defp split_while(s, pred) do
    prefix = s |> String.codepoints() |> Enum.take_while(pred) |> Enum.join()
    {prefix, binary_part(s, byte_size(prefix), byte_size(s) - byte_size(prefix))}
  end

  defp whitespace?(c), do: String.trim(c) == ""

  defp char_refs(s), do: for(<<c::utf8 <- s>>, into: "", do: "&##{c};")

  # `<data key="...">text</data>` children as key => unescaped, trimmed text.
  defp parse_data(""), do: %{}

  defp parse_data(body) do
    @data
    |> Regex.scan(body, capture: :all_but_first)
    |> Map.new(fn [double_quoted | rest] ->
      # Exactly one of the two key groups took part; the other is "".
      key = XML.unescape(double_quoted <> Enum.at(rest, 0, ""))
      text = rest |> Enum.at(1, "") |> String.trim() |> XML.unescape()
      {key, text}
    end)
  end
end
