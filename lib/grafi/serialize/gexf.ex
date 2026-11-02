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

  Like the GraphML decoder, this is a small tokenizer tuned to the subset
  emitted by `to_gexf/2`: one linear scan for `<node>`/`<edge>` start tags,
  whose attributes (quoted with `"` or `'`) are read by name. Weights and
  labels come straight from those attributes. It does NOT validate the XML
  (a malformed document can still decode to a graph) and does not handle
  CDATA, comments containing tags, `>` inside attribute values,
  `<attvalues>` elements or hierarchical (nested) nodes.

  Reference: <https://gexf.net/format.html>
  """

  alias Grafi.Graph
  alias Grafi.Serialize.{Util, XML}

  @graph_tag ~r/<graph\b([^>]*)>/
  @element ~r/<(node|edge)\b([^>]*?)(\/?)>/
  @attribute ~r/([\w.:-]+)\s*=\s*(?:"([^"]*)"|'([^']*)')/

  @doc """
  Renders a graph as a GEXF string.

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
        id = v |> Util.vertex_to_string() |> XML.escape()

        label_attr =
          case Graph.label(g, v) do
            nil -> ""
            l -> ~s( label="#{XML.escape(to_string(l))}")
          end

        ~s(      <node id="#{id}"#{label_attr}/>)
      end)

    edge_lines =
      Graph.edges(g)
      |> Enum.with_index()
      |> Enum.map(fn {e, idx} ->
        src = e.from |> Util.vertex_to_string() |> XML.escape()
        tgt = e.to |> Util.vertex_to_string() |> XML.escape()
        w_attr = ~s( weight="#{Util.format_weight(e.weight)}")

        label_attr =
          if e.label,
            do: ~s( label="#{XML.escape(to_string(e.label))}"),
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

  Returns the graph on success or `{:error, reason}` on parse failure, e.g.
  `{:error, {:invalid_weight, text}}` for a non-numeric `weight` attribute
  or `{:error, {:unclosed_element, "node" | "edge"}}`. Vertex ids round-trip
  as strings. An edge without a `weight` attribute gets weight `1.0`.

  ## Options
    * `:max_bytes` — reject input larger than this many bytes with
      `{:error, {:too_large, size, max}}` before parsing. Defaults to 64 MiB;
      pass `:infinity` to disable the limit.
  """
  @spec from_gexf(String.t(), keyword()) :: Graph.t() | {:error, term()}
  def from_gexf(xml, opts \\ []) when is_binary(xml) do
    with :ok <- Util.check_size(xml, opts),
         {:ok, type} <- detect_edgetype(xml),
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

  defp detect_edgetype(xml) do
    with [_, attrs] <- Regex.run(@graph_tag, xml),
         {:ok, type} <- edge_type(attribute(parse_attributes(attrs), "defaultedgetype")) do
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
  # body are skipped (its content is not read).
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

    with {:ok, resume} <- skip_body(xml, tag, start + len, slash_len),
         {:ok, nodes, edges} <- collect(tag, attrs, nodes, edges) do
      collect_elements(rest, xml, resume, nodes, edges)
    end
  end

  defp skip_body(_xml, _tag, pos, 1), do: {:ok, pos}

  defp skip_body(xml, tag, pos, 0) do
    case :binary.match(xml, end_tag(tag), scope: {pos, byte_size(xml) - pos}) do
      {at, len} -> {:ok, at + len}
      :nomatch -> {:error, {:unclosed_element, tag}}
    end
  end

  defp end_tag("node"), do: "</node>"
  defp end_tag("edge"), do: "</edge>"

  defp collect("node", attrs, nodes, edges) do
    case attribute(attrs, "id") do
      nil -> {:ok, nodes, edges}
      id -> {:ok, [{id, attribute(attrs, "label")} | nodes], edges}
    end
  end

  defp collect("edge", attrs, nodes, edges) do
    with src when src != nil <- attribute(attrs, "source"),
         tgt when tgt != nil <- attribute(attrs, "target"),
         {:ok, weight} <- edge_weight(attribute(attrs, "weight")) do
      {:ok, nodes, [{src, tgt, weight, attribute(attrs, "label")} | edges]}
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
      %{^name => value} -> unescape(value)
      _ -> nil
    end
  end

  # Most values hold no entity; skip the regex pass for those.
  defp unescape(text) do
    case :binary.match(text, "&") do
      :nomatch -> text
      _ -> XML.unescape(text)
    end
  end
end
