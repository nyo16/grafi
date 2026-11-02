defmodule Grafi.Serialize.Mermaid do
  @moduledoc """
  Serialize graphs to [Mermaid](https://mermaid.js.org/) `flowchart`/`graph`
  syntax.

  The output is a string that can be pasted into a Markdown code fence
  tagged ` ```mermaid` and rendered by Livebook, GitHub Markdown, Notion,
  or any Mermaid-compatible viewer. `to_markdown/2` produces that fenced
  block.

  ## Livebook

  When the optional `:kino` dependency is installed, a `Grafi.Graph`
  returned from a Livebook cell renders as a Mermaid diagram (through
  `Kino.Mermaid`), with the default options of `to_mermaid/2`. For other
  options, render it yourself:

      g |> Grafi.Serialize.Mermaid.to_mermaid(direction: :lr) |> Kino.Mermaid.new()

  ## Quick reference

  - Directed graphs render with `-->` arrows.
  - Undirected graphs render with `---` lines.
  - Edge weights become `|w|` labels when `:weights` is enabled.
  - Vertex IDs are normalised to `v0`, `v1`, … internally; the visible
    text comes from the user's label callback (default: `inspect/1` of the
    vertex term).
  """

  alias Grafi.Graph
  alias Grafi.Serialize.Util

  # `#` is escaped too, so label text like `#quot;` stays literal. `%`
  # stops `%%` comments and `%%{init: ...}%%` directives, which Mermaid
  # detects anywhere in the text; `<`, `>`, `&` and `'` keep HTML out of
  # labels rendered with `htmlLabels`.
  @escaped ["\r\n", "\r", "\n", "`", "|", "\"", "#", "%", "<", ">", "&", "'"]

  @type direction :: :td | :lr | :bt | :rl
  @type graph_type :: :flowchart | :graph

  @doc """
  Renders a graph as a Mermaid `flowchart` (or `graph`) string.

  ## Options

    * `:direction` — `:td` (top-down, default), `:lr` (left-right),
      `:bt` (bottom-top), `:rl` (right-left).
    * `:graph_type` — `:flowchart` (default, modern syntax) or `:graph`
      (legacy keyword, identical semantics).
    * `:weights` — `true | false | :auto`. When `true`, every edge gets a
      `|weight|` label. When `false`, weights are omitted. The default,
      `:auto`, includes weights only if the graph has at least one edge
      whose weight differs from `1.0`.
    * `:vertex_label` — `(vertex -> String.t())` callback used to produce
      the visible text in a `v_n[label]` node. Defaults to a sensible
      rendering of atoms, strings, and integers.

  In node and edge labels, newlines (`\\n`, `\\r`, `\\r\\n`) become `#10;`,
  backticks `#96;`, `|` `#124;`, `"` `#quot;`, `#` `#35;`, `%` `#37;`,
  `<` `#lt;`, `>` `#gt;`, `&` `#amp;` and `'` `#39;`, so a label cannot end
  its node, its line, or an enclosing Markdown code fence, cannot start a
  `%%` comment or `%%{init: ...}%%` directive, cannot inject HTML, and label
  text that looks like an entity code stays literal. Node labels other than
  plain ASCII letters, digits and `_` are wrapped in double quotes.

  ## Examples

      iex> dot = Grafi.Graph.new()
      ...>   |> Grafi.Graph.add_edges([{:a, :b}, {:a, :c}])
      ...>   |> Grafi.Serialize.Mermaid.to_mermaid()
      iex> String.starts_with?(dot, "flowchart TD")
      true
      iex> dot =~ "-->"
      true
  """
  @spec to_mermaid(Graph.t(), keyword()) :: String.t()
  def to_mermaid(%Graph{} = g, opts \\ []) do
    opts =
      Keyword.validate!(opts,
        direction: :td,
        graph_type: :flowchart,
        weights: :auto,
        vertex_label: &default_label/1
      )

    direction = validate_direction!(opts[:direction])
    graph_type = validate_graph_type!(opts[:graph_type])
    weight_mode = opts[:weights]
    label_fn = opts[:vertex_label]

    show_weights? = resolve_weight_mode(weight_mode, g)

    {keyword, arrow} =
      case {graph_type, g.type} do
        {:flowchart, :directed} -> {"flowchart", "-->"}
        {:flowchart, :undirected} -> {"flowchart", "---"}
        {:graph, :directed} -> {"graph", "-->"}
        {:graph, :undirected} -> {"graph", "---"}
      end

    # Stable id mapping: v0, v1, v2 … in insertion-sorted vertex order.
    # Sorting is by inspect-string so the same graph yields the same
    # output across runs regardless of vertex term ordering.
    vs =
      Graph.vertices(g)
      |> Enum.sort_by(&inspect/1)

    ids =
      vs
      |> Enum.with_index()
      |> Map.new(fn {v, i} -> {v, "v#{i}"} end)

    vertex_lines =
      Enum.map(vs, fn v ->
        "    #{Map.fetch!(ids, v)}[#{escape_label(label_fn.(v))}]"
      end)

    edge_lines =
      Graph.edges(g)
      |> Enum.map(fn e ->
        from = Map.fetch!(ids, e.from)
        to = Map.fetch!(ids, e.to)

        edge_label =
          cond do
            e.label != nil -> "|#{escape_edge_label(to_string(e.label))}|"
            show_weights? -> "|#{Util.format_weight(e.weight)}|"
            true -> ""
          end

        "    #{from} #{arrow}#{edge_label} #{to}"
      end)

    header = "#{keyword} #{direction_keyword(direction)}"

    [header | vertex_lines ++ edge_lines]
    |> Enum.join("\n")
  end

  @doc """
  Renders the graph as a Markdown string holding a fenced ` ```mermaid`
  block. Takes the options of `to_mermaid/2`.

  The output is GitHub-flavoured Markdown, rendered natively by GitHub,
  GitLab, Notion and `Kino.Markdown.new/1`. Labels cannot end the fence:
  backticks in them are escaped (see `to_mermaid/2`).

  ## Examples

      iex> md = Grafi.Graph.new()
      ...>   |> Grafi.Graph.add_edge(:a, :b)
      ...>   |> Grafi.Serialize.Mermaid.to_markdown()
      iex> String.starts_with?(md, "```mermaid\\nflowchart TD\\n")
      true
      iex> String.ends_with?(md, "\\n```")
      true
  """
  @spec to_markdown(Graph.t(), keyword()) :: String.t()
  def to_markdown(%Graph{} = g, opts \\ []) do
    "```mermaid\n" <> to_mermaid(g, opts) <> "\n```"
  end

  # ── Option validation ────────────────────────────────────────────────

  defp validate_direction!(d) when d in [:td, :lr, :bt, :rl], do: d

  defp validate_direction!(d),
    do: raise(ArgumentError, "invalid :direction #{inspect(d)} (expected :td, :lr, :bt, :rl)")

  defp validate_graph_type!(t) when t in [:flowchart, :graph], do: t

  defp validate_graph_type!(t),
    do: raise(ArgumentError, "invalid :graph_type #{inspect(t)} (expected :flowchart or :graph)")

  defp direction_keyword(:td), do: "TD"
  defp direction_keyword(:lr), do: "LR"
  defp direction_keyword(:bt), do: "BT"
  defp direction_keyword(:rl), do: "RL"

  defp resolve_weight_mode(true, _g), do: true
  defp resolve_weight_mode(false, _g), do: false
  defp resolve_weight_mode(:auto, g), do: Graph.edges(g) |> Enum.any?(&(&1.weight != 1.0))

  defp resolve_weight_mode(other, _g),
    do: raise(ArgumentError, "invalid :weights #{inspect(other)} (expected true, false, :auto)")

  # ── Label formatting ─────────────────────────────────────────────────

  defp default_label(v) when is_atom(v), do: Atom.to_string(v)
  defp default_label(v) when is_binary(v), do: v
  defp default_label(v) when is_integer(v), do: Integer.to_string(v)
  defp default_label(v), do: inspect(v)

  # Mermaid node text inside `[...]`. Characters that would end the label,
  # the line or an enclosing Markdown code fence (see `to_markdown/2`) become
  # Mermaid entity codes. Only plain ASCII words stay bare: anything else is
  # quoted, so label text cannot change the node shape (`[/x/]`, `[(x)]`)
  # or end the brackets.
  defp escape_label(s) when is_binary(s) do
    if bare_label?(s), do: s, else: "\"" <> escape_text(s) <> "\""
  end

  defp escape_label(other), do: escape_label(to_string(other))

  defp bare_label?(<<>>), do: false
  defp bare_label?(s), do: bare_chars?(s)

  defp bare_chars?(<<>>), do: true

  defp bare_chars?(<<c, rest::binary>>)
       when c in ?a..?z or c in ?A..?Z or c in ?0..?9 or c == ?_,
       do: bare_chars?(rest)

  defp bare_chars?(_), do: false

  # Edge labels live between `|...|`.
  defp escape_edge_label(s), do: escape_text(s)

  # One pass; `"\r\n"` is matched before its parts (longest match wins).
  defp escape_text(s), do: String.replace(s, @escaped, &entity/1)

  defp entity("\r\n"), do: "#10;"
  defp entity("\r"), do: "#10;"
  defp entity("\n"), do: "#10;"
  defp entity("`"), do: "#96;"
  defp entity("|"), do: "#124;"
  defp entity("\""), do: "#quot;"
  defp entity("#"), do: "#35;"
  defp entity("%"), do: "#37;"
  defp entity("<"), do: "#lt;"
  defp entity(">"), do: "#gt;"
  defp entity("&"), do: "#amp;"
  defp entity("'"), do: "#39;"
end

if Code.ensure_loaded?(Kino.Render) do
  defimpl Kino.Render, for: Grafi.Graph do
    # The layout Kino documents for custom renders: the diagram, plus the
    # default inspect output in a second tab.
    def to_livebook(graph) do
      diagram = graph |> Grafi.Serialize.Mermaid.to_mermaid() |> Kino.Mermaid.new()

      [Graph: diagram, Raw: Kino.Inspect.new(graph)]
      |> Kino.Layout.tabs()
      |> Kino.Render.to_livebook()
    end
  end
end
