defmodule Grafi.Serialize.XML do
  @moduledoc false
  # XML escaping and the decoder shared by the GraphML and GEXF serializers.
  #
  # The decoder is one left-to-right scan driven by `:binary.match/3`, so it
  # runs in linear time on any input: every search starts at the current
  # offset and the scan resumes past what it found, or stops with an error.
  # Comments and processing instructions are skipped, CDATA sections are
  # literal text (never markup), quoted attribute values may contain `>`,
  # and `<!DOCTYPE` is rejected (no entity expansion). It does not validate
  # the document beyond what it reads.

  alias Grafi.Graph
  alias Grafi.Serialize.Util

  @type attrs :: %{String.t() => String.t()}
  @type data :: %{String.t() => String.t()}

  # XML 1.0 `Char`, plus the UTF-8 encodings of the characters outside it.
  # In valid UTF-8 these byte sequences occur only as those characters.
  defguardp is_xml_char(c)
            when c in [0x9, 0xA, 0xD] or c in 0x20..0xD7FF or c in 0xE000..0xFFFD or
                   c in 0x10000..0x10FFFF

  @illegal Enum.map(Enum.to_list(0..0x1F) -- [0x9, 0xA, 0xD], &<<&1>>) ++
             [<<0xEF, 0xBF, 0xBE>>, <<0xEF, 0xBF, 0xBF>>]

  @text_specials ["&", "<", ">", "\"", "'", "\r"]
  @attr_specials ["\t", "\n" | @text_specials]

  # XML 1.0 (5th ed.) NameStartChar and NameChar.
  defguardp is_name_start(c)
            when c in ?a..?z or c in ?A..?Z or c in [?_, ?:] or c in 0xC0..0xD6 or
                   c in 0xD8..0xF6 or c in 0xF8..0x2FF or c in 0x370..0x37D or
                   c in 0x37F..0x1FFF or c in 0x200C..0x200D or c in 0x2070..0x218F or
                   c in 0x2C00..0x2FEF or c in 0x3001..0xD7FF or c in 0xF900..0xFDCF or
                   c in 0xFDF0..0xFFFD or c in 0x10000..0xEFFFF

  defguardp is_name_char(c)
            when is_name_start(c) or c in ?0..?9 or c in [?-, ?., 0xB7] or c in 0x300..0x36F or
                   c in 0x203F..0x2040

  defguardp is_ws(c) when c in [?\s, ?\t, ?\n, ?\r]

  # ── Encoding ─────────────────────────────────────────────────────────

  @doc """
  Escapes element text: the five predefined entities, plus `&#13;` for CR
  (which an XML parser would otherwise normalise to LF). Raises
  `ArgumentError` on invalid UTF-8 or a character XML 1.0 cannot represent.
  """
  @spec escape(String.t()) :: String.t()
  def escape(s) when is_binary(s), do: escape(s, @text_specials)

  @doc """
  Like `escape/1`, for an attribute value: TAB and LF are also written as
  character references, because XML parsers normalise them to spaces.
  """
  @spec escape_attr(String.t()) :: String.t()
  def escape_attr(s) when is_binary(s), do: escape(s, @attr_specials)

  @doc """
  Every character of `s` as a numeric character reference (for whitespace
  that must survive a trimming reader). Raises like `escape/1`.
  """
  @spec char_refs(String.t()) :: String.t()
  def char_refs(s) when is_binary(s) do
    check_chars!(s)
    for <<c::utf8 <- s>>, into: "", do: "&##{c};"
  end

  defp escape(s, specials) do
    check_chars!(s)

    case :binary.match(s, specials) do
      :nomatch -> s
      _ -> String.replace(s, specials, &entity/1)
    end
  end

  defp entity("&"), do: "&amp;"
  defp entity("<"), do: "&lt;"
  defp entity(">"), do: "&gt;"
  defp entity("\""), do: "&quot;"
  defp entity("'"), do: "&apos;"
  defp entity("\t"), do: "&#9;"
  defp entity("\n"), do: "&#10;"
  defp entity("\r"), do: "&#13;"

  defp check_chars!(s) do
    cond do
      not String.valid?(s) ->
        raise ArgumentError, "XML text must be valid UTF-8, got: #{inspect(Util.excerpt(s))}"

      :binary.match(s, @illegal) != :nomatch ->
        raise ArgumentError,
              "XML 1.0 text cannot contain control characters or U+FFFE/U+FFFF, " <>
                "got: #{inspect(Util.excerpt(s))}"

      true ->
        :ok
    end
  end

  # ── Decoding: references ─────────────────────────────────────────────

  @doc """
  Decodes the five predefined entities and numeric character references in
  one pass (so `&amp;lt;` becomes `&lt;`, not `<`). Any other `&` is kept as
  is. A numeric reference must be `&#` plus 1–7 decimal digits or `&#x`
  plus 1–6 hex digits, then `;`, naming an XML 1.0 `Char`; otherwise the
  result is `{:error, {:invalid_char_ref, ref}}`. The decoded text is its
  own binary (it never references `s`).
  """
  @spec unescape(binary()) :: {:ok, String.t()} | {:error, {:invalid_char_ref, binary()}}
  def unescape(s) when is_binary(s) do
    case :binary.match(s, "&") do
      :nomatch -> {:ok, Util.own(s)}
      {at, 1} -> unescape(s, at, [binary_part(s, 0, at)])
    end
  end

  defp unescape(s, amp, acc) do
    case reference(binary_part(s, amp, byte_size(s) - amp)) do
      {:ok, text, len} -> unescape_from(s, amp + len, [acc, text])
      :literal -> unescape_from(s, amp + 1, [acc, "&"])
      {:error, _} = error -> error
    end
  end

  defp unescape_from(s, pos, acc) do
    case :binary.match(s, "&", scope: {pos, byte_size(s) - pos}) do
      :nomatch -> {:ok, IO.iodata_to_binary([acc, binary_part(s, pos, byte_size(s) - pos)])}
      {at, 1} -> unescape(s, at, [acc, binary_part(s, pos, at - pos)])
    end
  end

  defp reference("&lt;" <> _), do: {:ok, "<", 4}
  defp reference("&gt;" <> _), do: {:ok, ">", 4}
  defp reference("&amp;" <> _), do: {:ok, "&", 5}
  defp reference("&quot;" <> _), do: {:ok, "\"", 6}
  defp reference("&apos;" <> _), do: {:ok, "'", 6}
  defp reference("&#x" <> _ = ref), do: char_ref(ref, 3, 16, 6)
  defp reference("&#" <> _ = ref), do: char_ref(ref, 2, 10, 7)
  defp reference(_), do: :literal

  # `skip` bytes of `&#`/`&#x`, then at most `max` digits (counting stops at
  # max + 1, so a hostile digit run costs nothing) and `;`.
  defp char_ref(ref, skip, base, max) do
    n = count_digits(ref, skip, base, 0, max + 1)

    with true <- n >= 1 and n <= max,
         <<_::binary-size(^skip), digits::binary-size(^n), ?;, _::binary>> <- ref,
         c when is_xml_char(c) <- String.to_integer(digits, base) do
      {:ok, <<c::utf8>>, skip + n + 1}
    else
      _ ->
        len = min(skip + n + 1, byte_size(ref))
        {:error, {:invalid_char_ref, Util.excerpt(binary_part(ref, 0, len))}}
    end
  end

  defp count_digits(ref, pos, base, n, limit) when n < limit do
    case ref do
      <<_::binary-size(^pos), c, _::binary>> when c in ?0..?9 ->
        count_digits(ref, pos + 1, base, n + 1, limit)

      <<_::binary-size(^pos), c, _::binary>> when base == 16 and (c in ?a..?f or c in ?A..?F) ->
        count_digits(ref, pos + 1, base, n + 1, limit)

      _ ->
        n
    end
  end

  defp count_digits(_ref, _pos, _base, n, _limit), do: n

  # ── Decoding: document ───────────────────────────────────────────────

  @doc """
  Scans a GraphML/GEXF document for its first top-level `<graph>` element
  (whose `type_attribute` must be `"directed"` or `"undirected"`) and the
  `<node>`/`<edge>` elements outside other nodes and edges, in document
  order. Each element is passed to `vertex` or `edge` with its unescaped
  attributes and the trimmed, unescaped text of its direct `<data
  key="...">` children (CDATA content is literal); only their results are
  kept. Elements nested in a node or edge are skipped.

  Errors: `{:error, :missing_graph_element}`,
  `{:error, {:unclosed_element, "node" | "edge" | "data"}}`,
  `{:error, {:malformed_tag, excerpt}}`,
  `{:error, {:duplicate_attribute, name}}`,
  `{:error, {:unclosed_markup, "<!--" | "<?" | "<![CDATA["}}`,
  `{:error, {:unsupported_markup, "<!DOCTYPE"}}` and
  `{:error, {:invalid_char_ref, ref}}`.
  """
  @spec parse(binary(), String.t(), (attrs(), data() -> v), (attrs(), data() -> e)) ::
          {:ok, :directed | :undirected, [v], [e]} | {:error, term()}
        when v: term(), e: term()
  def parse(xml, type_attribute, vertex, edge) when is_binary(xml) do
    state = %{
      type: nil,
      type_attribute: type_attribute,
      mode: :top,
      vertex: vertex,
      edge: edge,
      nodes: [],
      edges: []
    }

    with {:ok, state} <- scan(xml, 0, state) do
      finish(state)
    end
  end

  @doc """
  Builds the graph from `{id, label}` vertices and `{source, target,
  weight_text, label}` edges. A vertex without an id or an edge without
  both ends is skipped; an edge without a weight gets `1.0`; a weight that
  is not a finite number is `{:error, {:invalid_weight, text}}`.
  """
  @spec build_graph(:directed | :undirected, [{String.t() | nil, String.t() | nil}], [
          {String.t() | nil, String.t() | nil, String.t() | nil, String.t() | nil}
        ]) :: {:ok, Graph.t()} | {:error, {:invalid_weight, String.t()}}
  def build_graph(type, vertices, edges) do
    g =
      Enum.reduce(vertices, Graph.new(type: type), fn
        {nil, _label}, acc -> acc
        {id, nil}, acc -> Graph.add_vertex(acc, id)
        {id, label}, acc -> Graph.add_vertex(acc, id, label: label)
      end)

    Enum.reduce_while(edges, {:ok, g}, fn
      {src, tgt, _, _}, acc when src == nil or tgt == nil ->
        {:cont, acc}

      {src, tgt, weight_text, label}, {:ok, acc} ->
        case edge_weight(weight_text) do
          {:ok, weight} ->
            opts = if label, do: [weight: weight, label: label], else: [weight: weight]
            {:cont, {:ok, Graph.add_edge(acc, src, tgt, opts)}}

          {:error, _} = error ->
            {:halt, error}
        end
    end)
  end

  defp edge_weight(nil), do: {:ok, 1.0}
  defp edge_weight(text), do: Util.parse_weight(text)

  defp finish(%{mode: {:element, tag, _, _, _}}), do: {:error, {:unclosed_element, tag}}
  defp finish(%{mode: {:data, _, _, _, _}}), do: {:error, {:unclosed_element, "data"}}

  defp finish(%{type: {:ok, type}} = state),
    do: {:ok, type, Enum.reverse(state.nodes), Enum.reverse(state.edges)}

  defp finish(_state), do: {:error, :missing_graph_element}

  defp scan(xml, pos, state) do
    case :binary.match(xml, "<", scope: {pos, byte_size(xml) - pos}) do
      :nomatch ->
        {:ok, text(state, xml, pos, byte_size(xml) - pos)}

      {lt, 1} ->
        state = text(state, xml, pos, lt - pos)

        with {:ok, event, next} <- markup(xml, lt),
             {:ok, state} <- step(event, state) do
          scan(xml, next, state)
        end
    end
  end

  # Character data matters only directly inside a `<data>` element.
  defp text(%{mode: {:data, element, key, 0, segments}} = state, xml, pos, len) when len > 0,
    do: %{state | mode: {:data, element, key, 0, [{:text, binary_part(xml, pos, len)} | segments]}}

  defp text(state, _xml, _pos, _len), do: state

  # ── Lexer: one markup construct starting at `lt` ──

  defp markup(xml, lt) do
    case xml do
      <<_::binary-size(^lt), "<!--", _::binary>> ->
        skip_to(xml, lt + 4, "-->", "<!--")

      <<_::binary-size(^lt), "<?", _::binary>> ->
        skip_to(xml, lt + 2, "?>", "<?")

      <<_::binary-size(^lt), "<![CDATA[", _::binary>> ->
        cdata(xml, lt + 9)

      <<_::binary-size(^lt), "<!DOCTYPE", _::binary>> ->
        {:error, {:unsupported_markup, "<!DOCTYPE"}}

      <<_::binary-size(^lt), "</", _::binary>> ->
        end_tag(xml, lt)

      _ ->
        start_tag(xml, lt)
    end
  end

  defp skip_to(xml, pos, close, open) do
    case :binary.match(xml, close, scope: {pos, byte_size(xml) - pos}) do
      {at, len} -> {:ok, :skip, at + len}
      :nomatch -> {:error, {:unclosed_markup, open}}
    end
  end

  defp cdata(xml, pos) do
    case :binary.match(xml, "]]>", scope: {pos, byte_size(xml) - pos}) do
      {at, 3} -> {:ok, {:cdata, binary_part(xml, pos, at - pos)}, at + 3}
      :nomatch -> {:error, {:unclosed_markup, "<![CDATA["}}
    end
  end

  defp end_tag(xml, lt) do
    stop = name_end(xml, lt + 2)
    close = skip_ws(xml, stop)

    case xml do
      <<_::binary-size(^close), ?>, _::binary>> when stop > lt + 2 ->
        {:ok, {:end, binary_part(xml, lt + 2, stop - lt - 2)}, close + 1}

      _ ->
        malformed(xml, lt)
    end
  end

  defp start_tag(xml, lt) do
    case name_end(xml, lt + 1) do
      stop when stop > lt + 1 ->
        attributes(xml, lt, binary_part(xml, lt + 1, stop - lt - 1), stop, %{})

      _ ->
        malformed(xml, lt)
    end
  end

  # The element name must be followed by whitespace, `/>` or `>`, and each
  # attribute must start after whitespace.
  defp attributes(xml, lt, name, pos, attrs) do
    next = skip_ws(xml, pos)

    case xml do
      <<_::binary-size(^next), ?>, _::binary>> -> {:ok, {:start, name, attrs, false}, next + 1}
      <<_::binary-size(^next), "/>", _::binary>> -> {:ok, {:start, name, attrs, true}, next + 2}
      _ when next > pos -> attribute(xml, lt, name, next, attrs)
      _ -> malformed(xml, lt)
    end
  end

  defp attribute(xml, lt, name, pos, attrs) do
    case attribute_value(xml, pos) do
      {:ok, key, raw, next} ->
        with :ok <- unique_attribute(attrs, key),
             {:ok, value} <- unescape(raw) do
          attributes(xml, lt, name, next, Map.put(attrs, key, value))
        end

      :error ->
        malformed(xml, lt)
    end
  end

  # `name = "value"` or `name = 'value'`; a value may contain `>` but not `<`.
  defp attribute_value(xml, pos) do
    stop = name_end(xml, pos)
    eq = skip_ws(xml, stop)

    with true <- stop > pos,
         <<_::binary-size(^eq), ?=, _::binary>> <- xml,
         open = skip_ws(xml, eq + 1),
         <<_::binary-size(^open), delim, _::binary>> when delim in [?", ?'] <- xml,
         {close, 1} <- :binary.match(xml, <<delim>>, scope: {open + 1, byte_size(xml) - open - 1}),
         raw = binary_part(xml, open + 1, close - open - 1),
         :nomatch <- :binary.match(raw, "<") do
      {:ok, binary_part(xml, pos, stop - pos), raw, close + 1}
    else
      _ -> :error
    end
  end

  defp unique_attribute(attrs, key) do
    if Map.has_key?(attrs, key),
      do: {:error, {:duplicate_attribute, Util.excerpt(key)}},
      else: :ok
  end

  defp malformed(xml, lt),
    do: {:error, {:malformed_tag, Util.excerpt(binary_part(xml, lt, byte_size(xml) - lt))}}

  defp name_end(xml, pos) do
    case xml do
      <<_::binary-size(^pos), c::utf8, _::binary>> when is_name_start(c) ->
        name_rest(xml, pos + utf8_size(c))

      _ ->
        pos
    end
  end

  defp name_rest(xml, pos) do
    case xml do
      <<_::binary-size(^pos), c::utf8, _::binary>> when is_name_char(c) ->
        name_rest(xml, pos + utf8_size(c))

      _ ->
        pos
    end
  end

  defp utf8_size(c) when c < 0x80, do: 1
  defp utf8_size(c) when c < 0x800, do: 2
  defp utf8_size(c) when c < 0x10000, do: 3
  defp utf8_size(_c), do: 4

  defp skip_ws(xml, pos) do
    case xml do
      <<_::binary-size(^pos), c, _::binary>> when is_ws(c) -> skip_ws(xml, pos + 1)
      _ -> pos
    end
  end

  # ── Element collection ──
  #
  # Modes: `:top`; `{:element, tag, attrs, depth, data}` inside a bodied
  # node or edge; `{:data, element, key, depth, segments}` inside one of its
  # `<data>` children. `depth` counts open elements nested below those.

  defp step(:skip, state), do: {:ok, state}
  defp step(event, %{mode: :top} = state), do: top(event, state)
  defp step(event, %{mode: {:element, _, _, _, _}} = state), do: in_element(event, state)
  defp step(event, %{mode: {:data, _, _, _, _}} = state), do: in_data(event, state)

  defp top({:start, "graph", attrs, _empty?}, %{type: nil} = state),
    do: {:ok, %{state | type: graph_type(Map.get(attrs, state.type_attribute))}}

  defp top({:start, tag, attrs, true}, state) when tag in ["node", "edge"],
    do: {:ok, add_element(state, tag, attrs, %{})}

  defp top({:start, tag, attrs, false}, state) when tag in ["node", "edge"],
    do: {:ok, %{state | mode: {:element, tag, attrs, 0, %{}}}}

  defp top(_event, state), do: {:ok, state}

  defp graph_type("directed"), do: {:ok, :directed}
  defp graph_type("undirected"), do: {:ok, :undirected}
  defp graph_type(_), do: :invalid

  defp in_element(event, %{mode: {:element, tag, attrs, depth, data} = element} = state) do
    case event do
      {:start, "data", %{"key" => key}, false} when depth == 0 ->
        {:ok, %{state | mode: {:data, element, key, 0, []}}}

      {:start, "data", %{"key" => key}, true} when depth == 0 ->
        {:ok, %{state | mode: {:element, tag, attrs, 0, Map.put(data, key, "")}}}

      {:start, _name, _attrs, false} ->
        {:ok, %{state | mode: {:element, tag, attrs, depth + 1, data}}}

      {:end, _name} when depth > 0 ->
        {:ok, %{state | mode: {:element, tag, attrs, depth - 1, data}}}

      {:end, ^tag} ->
        {:ok, add_element(%{state | mode: :top}, tag, attrs, data)}

      {:end, _name} ->
        {:error, {:unclosed_element, tag}}

      _ ->
        {:ok, state}
    end
  end

  defp in_data(event, %{mode: {:data, element, key, depth, segments}} = state) do
    case event do
      {:cdata, text} when depth == 0 ->
        {:ok, %{state | mode: {:data, element, key, 0, [{:cdata, text} | segments]}}}

      {:start, _name, _attrs, false} ->
        {:ok, %{state | mode: {:data, element, key, depth + 1, segments}}}

      {:end, _name} when depth > 0 ->
        {:ok, %{state | mode: {:data, element, key, depth - 1, segments}}}

      {:end, "data"} ->
        {:element, tag, attrs, 0, data} = element

        with {:ok, text} <- data_text(segments) do
          {:ok, %{state | mode: {:element, tag, attrs, 0, Map.put(data, key, text)}}}
        end

      {:end, _name} ->
        {:error, {:unclosed_element, "data"}}

      _ ->
        {:ok, state}
    end
  end

  defp add_element(state, "node", attrs, data),
    do: %{state | nodes: [state.vertex.(attrs, data) | state.nodes]}

  defp add_element(state, "edge", attrs, data),
    do: %{state | edges: [state.edge.(attrs, data) | state.edges]}

  # `segments` are newest first. The text is trimmed at both ends (outside
  # CDATA), tolerating pretty-printed input; character references survive
  # the trim.
  defp data_text(segments) do
    segments
    |> trim_first(&String.trim_trailing/1)
    |> Enum.reverse()
    |> trim_first(&String.trim_leading/1)
    |> Enum.reduce_while({:ok, []}, fn
      {:cdata, text}, {:ok, acc} ->
        {:cont, {:ok, [acc, text]}}

      {:text, raw}, {:ok, acc} ->
        case unescape(raw) do
          {:ok, text} -> {:cont, {:ok, [acc, text]}}
          {:error, _} = error -> {:halt, error}
        end
    end)
    |> case do
      {:ok, iodata} -> {:ok, Util.own(IO.iodata_to_binary(iodata))}
      {:error, _} = error -> error
    end
  end

  defp trim_first([{:text, raw} | rest], trim), do: [{:text, trim.(raw)} | rest]
  defp trim_first(segments, _trim), do: segments
end
