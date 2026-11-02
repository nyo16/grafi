defmodule Grafi.Test.Generators do
  @moduledoc false
  # StreamData generators shared by the property tests (serializer
  # round-trips here, algorithm properties in algo-correctness-perf A4.1).
  #
  # Every generated graph uses a single vertex-id type (see the
  # `vertex_id` note in Grafi.Graph). Atoms come from a fixed pool, so
  # generation never grows the atom table.

  use ExUnitProperties

  alias Grafi.Graph

  @atom_pool ~w(a b c d e f g h alpha beta gamma delta)a

  # Text that tends to break serializers: whitespace (leading, trailing,
  # non-ASCII), quotes, escapes, markup, separators, non-ASCII and combining
  # marks, MatrixMarket id prefixes, and Pajek/Mermaid/DOT syntax. No
  # XML-illegal control characters (the XML encoders raise on them).
  @special_strings [
    "",
    " ",
    "a b",
    "quo\"te",
    "single'quote",
    "back\\slash",
    "new\nline",
    "car\rriage",
    "tab\tbed",
    "<xml & amp>",
    "&amp;",
    "pipe|bar",
    "`tick`",
    "```",
    "{brace}",
    "[bracket]",
    "#hash",
    "100%",
    "a,b",
    "*Arcs",
    "ünïcödé",
    "😀",
    "  padded  ",
    "x\t",
    "a \u0301",
    "\u00A0nbsp",
    "int:5",
    "atom:a",
    "float:1.0",
    "str:x",
    "%%{init: {}}%%",
    "<img src=x onerror=y>",
    "trail\\",
    "&#0;"
  ]

  @doc "The id types `graph/1` can use."
  def id_types, do: [:integer, :atom, :simple_string, :string]

  @doc """
  A vertex id of the given type:
    * `:integer` — small non-negative integers
    * `:atom` — from a fixed pool (never creates atoms)
    * `:simple_string` — non-empty alphanumeric, no whitespace
    * `:string` — any of the above shapes plus the special strings
  """
  def vertex_id(:integer), do: integer(0..50)
  def vertex_id(:atom), do: member_of(@atom_pool)
  def vertex_id(:simple_string), do: string(:alphanumeric, min_length: 1, max_length: 8)

  def vertex_id(:string),
    do: one_of([vertex_id(:simple_string), member_of(@special_strings -- [""])])

  @doc "A label: nil, plain text or a special string."
  def label do
    one_of([constant(nil), string(:alphanumeric, max_length: 6), member_of(@special_strings)])
  end

  @doc """
  An edge weight: 1.0, zero, negative, fractional or extreme (exponent
  notation, subnormal). Always a float (the decoders read weights back as
  floats).
  """
  def weight do
    one_of([
      constant(1.0),
      constant(0.0),
      map(integer(-10..10), &(&1 * 1.0)),
      float(min: -1.0e6, max: 1.0e6),
      member_of([1.0e300, -1.0e-300, 5.0e-324, 1.0e20, -2.5e-7])
    ])
  end

  @doc """
  A graph. Options (each a fixed value, or omitted for "any"):
    * `:type` — `:directed` or `:undirected`
    * `:id_type` — one of `id_types/0`
    * `:max_vertices` (default 12), `:max_edges` (default 25)
    * `:weights` — `true` (default) for `weight/0`, `false` for all 1.0
    * `:vertex_labels`, `:edge_labels` — `true` to generate labels (default `false`)

  Graphs may be empty, disconnected (isolated vertices), and have
  self-loops and parallel edges.
  """
  def graph(opts \\ []) do
    type_gen = fixed_or(opts[:type], [:directed, :undirected])
    id_type_gen = fixed_or(opts[:id_type], id_types())
    max_v = Keyword.get(opts, :max_vertices, 12)
    max_e = Keyword.get(opts, :max_edges, 25)
    weight_gen = if Keyword.get(opts, :weights, true), do: weight(), else: constant(1.0)
    vlabel_gen = if opts[:vertex_labels], do: label(), else: constant(nil)
    elabel_gen = if opts[:edge_labels], do: label(), else: constant(nil)

    gen all(
          type <- type_gen,
          id_type <- id_type_gen,
          # list_of + uniq rather than uniq_list_of, which gives up on small
          # id spaces (the atom pool, small integers at small sizes).
          ids <- map(list_of(vertex_id(id_type), max_length: max_v), &Enum.uniq/1),
          vlabels <- list_of(vlabel_gen, length: length(ids)),
          edges <- edges(ids, max_e, weight_gen, elabel_gen)
        ) do
      g =
        ids
        |> Enum.zip(vlabels)
        |> Enum.reduce(Graph.new(type: type), fn {v, l}, acc ->
          Graph.add_vertex(acc, v, label: l)
        end)

      Enum.reduce(edges, g, fn {u, v, w, l}, acc ->
        Graph.add_edge(acc, u, v, weight: w, label: l)
      end)
    end
  end

  defp edges([], _max_e, _weight_gen, _label_gen), do: constant([])

  defp edges(ids, max_e, weight_gen, label_gen) do
    list_of(tuple({member_of(ids), member_of(ids), weight_gen, label_gen}), max_length: max_e)
  end

  defp fixed_or(nil, choices), do: member_of(choices)
  defp fixed_or(value, _choices), do: constant(value)
end
