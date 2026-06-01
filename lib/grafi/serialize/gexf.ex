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

  Like the GraphML decoder, this is a small line-oriented parser tuned to
  the subset emitted by `to_gexf/2`. It does not handle CDATA, processing
  instructions beyond the XML declaration, or `<attvalues>` elements;
  weights and labels are read directly from element attributes.

  Reference: <https://gexf.net/format.html>
  """

  alias Grafi.Graph

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
        id = vertex_to_string(v) |> xml_escape_attr()

        label_attr =
          case Graph.label(g, v) do
            nil -> ""
            l -> ~s( label="#{xml_escape_attr(to_string(l))}")
          end

        ~s(      <node id="#{id}"#{label_attr}/>)
      end)

    edge_lines =
      Graph.edges(g)
      |> Enum.with_index()
      |> Enum.map(fn {e, idx} ->
        src = vertex_to_string(e.from) |> xml_escape_attr()
        tgt = vertex_to_string(e.to) |> xml_escape_attr()
        w_attr = ~s( weight="#{format_weight(e.weight)}")

        label_attr =
          if e.label,
            do: ~s( label="#{xml_escape_attr(to_string(e.label))}"),
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

  Returns the graph on success or `{:error, reason}` on parse failure.
  Vertex ids round-trip as strings.

  ## Options
    * `:max_bytes` — reject input larger than this many bytes with
      `{:error, :input_too_large}` before parsing. Defaults to `:infinity`
      (no limit). Set this when decoding untrusted input to bound the work
      the regex-based parser will do.
  """
  @spec from_gexf(String.t(), keyword()) :: Graph.t() | {:error, term()}
  def from_gexf(xml, opts \\ []) when is_binary(xml) do
    with :ok <- check_size(xml, Keyword.get(opts, :max_bytes, :infinity)),
         {:ok, type} <- detect_edgetype(xml),
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
    _ -> {:error, :malformed_gexf}
  end

  # ── Parsing helpers ──────────────────────────────────────────────────

  defp check_size(_xml, :infinity), do: :ok

  defp check_size(xml, max) when is_integer(max) do
    if byte_size(xml) > max, do: {:error, :input_too_large}, else: :ok
  end

  defp detect_edgetype(xml) do
    case Regex.run(~r/<graph\b[^>]*\bdefaultedgetype\s*=\s*(["'])(directed|undirected)\1/, xml) do
      [_, _, "directed"] -> {:ok, :directed}
      [_, _, "undirected"] -> {:ok, :undirected}
      _ -> {:error, :missing_graph_element}
    end
  end

  defp extract_nodes(xml) do
    self_closed =
      Regex.scan(~r/<node\b([^>]*?)\/>/s, xml)
      |> Enum.map(fn [_, attrs] ->
        {parse_attr(attrs, "id"), parse_attr(attrs, "label")}
      end)

    bodied =
      Regex.scan(~r/<node\b([^>]*?)>(.*?)<\/node>/s, xml)
      |> Enum.map(fn [_, attrs, _body] ->
        {parse_attr(attrs, "id"), parse_attr(attrs, "label")}
      end)

    nodes = Enum.reject(self_closed ++ bodied, fn {id, _} -> id == nil end)
    {:ok, nodes}
  rescue
    _ -> {:error, :malformed_nodes}
  end

  defp extract_edges(xml) do
    self_closed =
      Regex.scan(~r/<edge\b([^>]*?)\/>/s, xml)
      |> Enum.map(&edge_from_attrs(&1))

    bodied =
      Regex.scan(~r/<edge\b([^>]*?)>(.*?)<\/edge>/s, xml)
      |> Enum.map(fn [_, attrs, _body] ->
        edge_from_attrs([nil, attrs])
      end)

    edges =
      (self_closed ++ bodied)
      |> Enum.reject(fn {s, t, _, _} -> s == nil or t == nil end)

    {:ok, edges}
  rescue
    _ -> {:error, :malformed_edges}
  end

  defp edge_from_attrs([_, attrs]) do
    src = parse_attr(attrs, "source")
    tgt = parse_attr(attrs, "target")
    w = attrs |> parse_attr("weight") |> parse_number()
    label = parse_attr(attrs, "label")
    {src, tgt, w, label}
  end

  defp parse_attr(attrs, name) do
    case Regex.run(~r/\b#{Regex.escape(name)}\s*=\s*(["'])(.*?)\1/s, attrs) do
      [_, _, value] -> xml_unescape(value)
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
