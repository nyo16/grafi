defmodule Grafi.Serialize.GEXF do
  @moduledoc """
  Serialize and deserialize graphs in GEXF (Graph Exchange XML Format),
  the native format of Gephi.

  Output layout:

      <?xml version="1.0" encoding="UTF-8"?>
      <gexf xmlns="http://www.gexf.net/1.2draft" version="1.2">
        <graph defaultedgetype="directed">
          <nodes>
            <node id="a" label="Alpha"/>
            <node id="b"/>
          </nodes>
          <edges>
            <edge id="0" source="a" target="b" weight="2.5" label="Likes"/>
          </edges>
        </graph>
      </gexf>

  The decoder is the linear scanner shared with `Grafi.Serialize.GraphML`,
  tuned to the subset emitted by `to_gexf/2`: it reads the first `<graph>`
  element's `defaultedgetype` and the attributes of each `<node>`/`<edge>`
  (quoted with `"` or `'`). Weights and labels come straight from those
  attributes. It decodes the predefined XML entities and numeric character
  references, skips comments, processing instructions and CDATA, and
  rejects `<!DOCTYPE`. It does NOT validate the document, and ignores
  `<attvalues>` elements and hierarchical (nested) nodes.

  Reference: <https://gexf.net/format.html>
  """

  alias Grafi.Graph
  alias Grafi.Serialize.{Util, XML}

  @doc """
  Renders a graph as a GEXF string.

  Raises `ArgumentError` if an id or label (as text) is not valid UTF-8 or
  contains a character XML 1.0 cannot represent (a control character other
  than tab, LF and CR, or U+FFFE/U+FFFF).

  ## Examples

      iex> g = Grafi.Graph.new() |> Grafi.Graph.add_edge(:a, :b)
      iex> Grafi.Serialize.GEXF.to_gexf(g) =~ ~s(defaultedgetype="directed")
      true
  """
  @spec to_gexf(Graph.t(), keyword()) :: String.t()
  def to_gexf(%Graph{} = g, _opts \\ []) do
    edgetype = if g.type == :directed, do: "directed", else: "undirected"

    node_lines =
      Graph.vertices(g)
      |> Enum.map(fn v ->
        id = v |> Util.vertex_to_string() |> XML.escape_attr()

        label_attr =
          case Graph.label(g, v) do
            nil -> ""
            l -> ~s( label="#{XML.escape_attr(to_string(l))}")
          end

        ~s(      <node id="#{id}"#{label_attr}/>)
      end)

    edge_lines =
      Graph.edges(g)
      |> Enum.with_index()
      |> Enum.map(fn {e, idx} ->
        src = e.from |> Util.vertex_to_string() |> XML.escape_attr()
        tgt = e.to |> Util.vertex_to_string() |> XML.escape_attr()
        w_attr = ~s( weight="#{Util.format_weight(e.weight)}")

        label_attr =
          if e.label,
            do: ~s( label="#{XML.escape_attr(to_string(e.label))}"),
            else: ""

        ~s(      <edge id="#{idx}" source="#{src}" target="#{tgt}"#{w_attr}#{label_attr}/>)
      end)

    [
      ~s(<?xml version="1.0" encoding="UTF-8"?>),
      ~s(<gexf xmlns="http://www.gexf.net/1.2draft" version="1.2">),
      ~s(  <graph defaultedgetype="#{edgetype}">),
      ~s(    <nodes>)
    ]
    |> Kernel.++(node_lines)
    |> Kernel.++([~s(    </nodes>), ~s(    <edges>)])
    |> Kernel.++(edge_lines)
    |> Kernel.++([~s(    </edges>), ~s(  </graph>), ~s(</gexf>)])
    |> Enum.join("\n")
  end

  @doc """
  Parses a GEXF string into a `Grafi.Graph`.

  Returns the graph on success or `{:error, reason}` on parse failure:
    * `{:invalid_weight, text}` for a `weight` attribute that is not a
      finite number;
    * `:missing_graph_element` without a `<graph>` whose `defaultedgetype`
      is `"directed"` or `"undirected"`;
    * `{:unclosed_element, "node" | "edge"}`;
    * `{:malformed_tag, excerpt}`, `{:duplicate_attribute, name}`,
      `{:unclosed_markup, "<!--" | "<?" | "<![CDATA["}`,
      `{:unsupported_markup, "<!DOCTYPE"}` and `{:invalid_char_ref, ref}`
      for markup the decoder cannot read faithfully.

  Vertex ids round-trip as strings. An edge without a `weight` attribute
  gets weight `1.0`.

  ## Options
    * `:max_bytes` — reject input larger than this many bytes with
      `{:error, {:too_large, size, max}}` before parsing. Defaults to 64 MiB;
      pass `:infinity` to disable the limit.
  """
  @spec from_gexf(String.t(), keyword()) :: Graph.t() | {:error, term()}
  def from_gexf(xml, opts \\ []) when is_binary(xml) do
    with :ok <- Util.check_size(xml, opts),
         {:ok, type, vertices, edges} <-
           XML.parse(xml, "defaultedgetype", &vertex/2, &edge/2) do
      XML.build_graph(type, vertices, edges)
    end
  end

  defp vertex(attrs, _data), do: {attrs["id"], attrs["label"]}

  defp edge(attrs, _data),
    do: {attrs["source"], attrs["target"], attrs["weight"], attrs["label"]}
end
