defmodule Grafi.Serialize.Mermaid do
  @moduledoc """
  Serialize graphs to [Mermaid](https://mermaid.js.org/) `flowchart`/`graph`
  syntax.

  The output is a string that can be pasted into a Markdown code fence
  tagged ` ```mermaid` and rendered by Livebook, GitHub Markdown, Notion,
  or any Mermaid-compatible viewer. See `Grafi.Kino` for a thin wrapper
  that produces a Markdown-ready block.

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

  # `#` is escaped too, so label text like `#quot;` stays literal.
  @escaped ["\r\n", "\r", "\n", "`", "|", "\"", "#"]

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
  backticks `#96;`, `|` `#124;`, `"` `#quot;` and `#` `#35;`, so a label
  cannot end its node, its line, or an enclosing Markdown code fence, and
  label text that looks like an entity code stays literal.

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
    direction = Keyword.get(opts, :direction, :td) |> validate_direction!()
    graph_type = Keyword.get(opts, :graph_type, :flowchart) |> validate_graph_type!()
    weight_mode = Keyword.get(opts, :weights, :auto)
    label_fn = Keyword.get(opts, :vertex_label, &default_label/1)

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
            show_weights? -> "|#{format_weight(e.weight)}|"
            true -> ""
          end

        "    #{from} #{arrow}#{edge_label} #{to}"
      end)

    header = "#{keyword} #{direction_keyword(direction)}"

    [header | vertex_lines ++ edge_lines]
    |> Enum.join("\n")
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
  # the line or an enclosing Markdown code fence (see `Grafi.Kino`) become
  # Mermaid entity codes; labels with any special character or space are
  # wrapped in quotes, which is the safest cross-version choice.
  defp escape_label(s) when is_binary(s) do
    if String.contains?(s, ["[", "]", "(", ")", "{", "}", "<", ">", " " | @escaped]) do
      "\"" <> escape_text(s) <> "\""
    else
      s
    end
  end

  defp escape_label(other), do: escape_label(to_string(other))

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

  # Compact display for whole floats (`80.0`), `Util.format_weight/1`
  # otherwise, which raises for a non-number.
  defp format_weight(w) when is_float(w) and w == trunc(w),
    do: :erlang.float_to_binary(w, [:compact, decimals: 1])

  defp format_weight(w), do: Util.format_weight(w)
end
