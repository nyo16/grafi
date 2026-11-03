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

  The decoder is a small linear scanner (shared with `Grafi.Serialize.GEXF`)
  tailored to the subset emitted by `to_graphml/2`: it reads the first
  `<graph>` element's `edgedefault`, the attributes of each `<node>`/`<edge>`
  (quoted with `"` or `'`), and the text of their `<data>` children. It
  decodes the predefined XML entities and numeric character references,
  skips comments and processing instructions, reads CDATA sections inside
  `<data>` as literal text, and rejects `<!DOCTYPE`. It does NOT validate
  the document, and ignores namespaces beyond the default `graphml` and
  nested `<graph>` elements. Round-trip on our own output is the supported
  use case.

  Reference: <http://graphml.graphdrawing.org/specification.html>
  """

  alias Grafi.Graph
  alias Grafi.Serialize.{Util, XML}

  @doc """
  Renders a graph as a GraphML string.

  Raises `ArgumentError` if an id or label (as text) is not valid UTF-8 or
  contains a character XML 1.0 cannot represent (a control character other
  than tab, LF and CR, or U+FFFE/U+FFFF).

  ## Options
    * `:name` — graph identifier written to `<graph id="...">` (default `"G"`).

  ## Examples

      iex> g = Grafi.Graph.new() |> Grafi.Graph.add_edge(:a, :b)
      iex> Grafi.Serialize.GraphML.to_graphml(g) =~ ~s(edgedefault="directed")
      true
  """
  @spec to_graphml(Graph.t(), keyword()) :: String.t()
  def to_graphml(%Graph{} = g, opts \\ []) do
    name = Keyword.validate!(opts, name: "G")[:name]
    edgedefault = if g.type == :directed, do: "directed", else: "undirected"

    node_lines =
      Graph.vertices(g)
      |> Enum.map(fn v ->
        id = v |> Util.vertex_to_string() |> XML.escape_attr()

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
        src = e.from |> Util.vertex_to_string() |> XML.escape_attr()
        tgt = e.to |> Util.vertex_to_string() |> XML.escape_attr()

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
      ~s(  <graph id="#{XML.escape_attr(name)}" edgedefault="#{edgedefault}">)
    ]
    |> Kernel.++(node_lines)
    |> Kernel.++(edge_lines)
    |> Kernel.++(["  </graph>", "</graphml>"])
    |> Enum.join("\n")
  end

  @doc """
  Parses a GraphML string into a `Grafi.Graph`.

  Returns `{:ok, graph}` on success or `{:error, reason}` on parse failure:
    * `{:invalid_weight, text}` for an `eweight` that is not a finite number;
    * `:missing_graph_element` without a `<graph>` whose `edgedefault` is
      `"directed"` or `"undirected"`;
    * `{:unclosed_element, "node" | "edge" | "data"}`;
    * `{:malformed_tag, excerpt}`, `{:duplicate_attribute, name}`,
      `{:unclosed_markup, "<!--" | "<?" | "<![CDATA["}`,
      `{:unsupported_markup, "<!DOCTYPE"}` and `{:invalid_char_ref, ref}`
      for markup the decoder cannot read faithfully.

  Vertex ids round-trip as strings (XML has no atom or integer types). An
  edge without an `eweight` gets weight `1.0`.

  ## Options
    * `:max_bytes` — reject input larger than this many bytes with
      `{:error, {:too_large, size, max}}` before parsing. Defaults to 64 MiB;
      pass `:infinity` to disable the limit.

  Unknown options raise `ArgumentError`.
  """
  @spec from_graphml(String.t(), keyword()) :: {:ok, Graph.t()} | {:error, term()}
  def from_graphml(xml, opts \\ []) when is_binary(xml) do
    opts = Keyword.validate!(opts, [:max_bytes])

    with :ok <- Util.check_size(xml, opts),
         {:ok, type, vertices, edges} <- XML.parse(xml, "edgedefault", &vertex/2, &edge/2) do
      XML.build_graph(type, vertices, edges)
    end
  end

  @doc """
  Like `from_graphml/2`, but returns the graph and raises `ArgumentError`
  with the reason on failure.
  """
  @spec from_graphml!(String.t(), keyword()) :: Graph.t()
  def from_graphml!(xml, opts \\ []), do: xml |> from_graphml(opts) |> Util.unwrap!("GraphML")

  defp vertex(attrs, data), do: {attrs["id"], data["vlabel"]}

  defp edge(attrs, data),
    do: {attrs["source"], attrs["target"], data["eweight"], data["elabel"]}

  # Escaped `<data>` text. The decoder trims data text (tolerating
  # pretty-printed input), so leading/trailing whitespace is written as
  # character references, which survive the trim and decode back exactly.
  # Split by byte sizes: whitespace followed by a combining mark is one
  # grapheme, so nothing grapheme-based (such as `String.reverse/1`) works.
  defp data_text(s) do
    rest = String.trim_leading(s)
    core = String.trim_trailing(rest)
    lead = binary_part(s, 0, byte_size(s) - byte_size(rest))
    trail = binary_part(rest, byte_size(core), byte_size(rest) - byte_size(core))

    XML.char_refs(lead) <> XML.escape(core) <> XML.char_refs(trail)
  end
end
