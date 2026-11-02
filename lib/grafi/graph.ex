defmodule Grafi.Graph do
  @dialyzer :no_opaque

  @moduledoc """
  An immutable graph data structure — the heart of Grafi.

  Supports directed/undirected, weighted, labelled, multi-edge graphs.
  All operations return a new graph.

  ## Internal structure

  Uses adjacency maps for fast mutation and traversal. For heavy algorithms
  the graph is converted to CSR format and dispatched to igraph via NIF.

      iex> Grafi.Graph.new()
      ...>   |> Grafi.Graph.add_edges([{:a, :b}, {:b, :c}, {:c, :a}])
      #Grafi.Graph<directed, V: 3, E: 3>
  """

  alias Grafi.Edge

  # A vertex id may be any term, but prefer one id type per graph (all atoms,
  # all integers, or all binaries). Vertices are map keys, matched exactly,
  # while undirected edges and `to_csr/1` order endpoints by Erlang term
  # order, so ids that compare equal but differ (`1` and `1.0`) are distinct
  # vertices, and an undirected edge between them is listed once with an
  # unspecified orientation.
  @type vertex_id :: any()
  @type t :: %__MODULE__{
          vertices: %{vertex_id() => true},
          vertex_labels: %{vertex_id() => any()},
          out_edges: %{vertex_id() => %{vertex_id() => [Edge.t()]}},
          in_edges: %{vertex_id() => %{vertex_id() => [Edge.t()]}},
          out_degrees: %{vertex_id() => non_neg_integer()},
          in_degrees: %{vertex_id() => non_neg_integer()},
          num_edges: non_neg_integer(),
          num_vertices: non_neg_integer(),
          type: :directed | :undirected
        }

  defstruct vertices: %{},
            vertex_labels: %{},
            out_edges: %{},
            in_edges: %{},
            out_degrees: %{},
            in_degrees: %{},
            num_edges: 0,
            num_vertices: 0,
            type: :directed

  # ── Construction ──────────────────────────────────────────────────────

  @doc """
  Creates a new empty graph.

  ## Options
    * `:type` — `:directed` (default) or `:undirected`

  ## Examples

      iex> g = Grafi.Graph.new()
      iex> {g.type, Grafi.Graph.num_vertices(g), Grafi.Graph.num_edges(g)}
      {:directed, 0, 0}

      iex> Grafi.Graph.new(type: :undirected).type
      :undirected
  """
  @spec new(keyword()) :: t()
  def new(opts \\ []) do
    type = Keyword.get(opts, :type, :directed)

    if type not in [:directed, :undirected],
      do: raise(ArgumentError, "type must be :directed or :undirected")

    %__MODULE__{type: type}
  end

  # ── Vertices ──────────────────────────────────────────────────────────

  @doc "Adds a vertex to the graph, optionally with a label."
  @spec add_vertex(t(), vertex_id(), keyword()) :: t()
  def add_vertex(%__MODULE__{} = g, v, opts \\ []) do
    if Map.has_key?(g.vertices, v) do
      maybe_set_label(g, v, opts)
    else
      g = %{
        g
        | vertices: Map.put(g.vertices, v, true),
          out_edges: Map.put_new(g.out_edges, v, %{}),
          in_edges: Map.put_new(g.in_edges, v, %{}),
          out_degrees: Map.put_new(g.out_degrees, v, 0),
          in_degrees: Map.put_new(g.in_degrees, v, 0),
          num_vertices: g.num_vertices + 1
      }

      maybe_set_label(g, v, opts)
    end
  end

  @doc "Adds multiple vertices to the graph."
  @spec add_vertices(t(), [vertex_id() | {vertex_id(), keyword()}]) :: t()
  def add_vertices(%__MODULE__{} = g, vs) when is_list(vs) do
    Enum.reduce(vs, g, fn
      {v, opts}, acc -> add_vertex(acc, v, opts)
      v, acc -> add_vertex(acc, v)
    end)
  end

  @doc "Removes a vertex and all its incident edges from the graph."
  @spec delete_vertex(t(), vertex_id()) :: t()
  def delete_vertex(%__MODULE__{} = g, v) do
    if not Map.has_key?(g.vertices, v) do
      g
    else
      out = Map.get(g.out_edges, v, %{})
      ine = Map.get(g.in_edges, v, %{})
      # Self-loops at v appear in both maps (directed) or twice in the
      # out-list (undirected); subtract the double count.
      loops = out |> Map.get(v, []) |> length()

      reduction =
        if g.type == :undirected,
          do: edge_count_in_map(out) - div(loops, 2),
          else: edge_count_in_map(out) + edge_count_in_map(ine) - loops

      # Distinct neighbors that had an edge involving v (for degree maintenance)
      out_targets = Map.keys(out)
      in_sources = Map.keys(ine)

      out_edges = g.out_edges |> Map.delete(v) |> strip_target(v)
      in_edges = g.in_edges |> Map.delete(v) |> strip_target(v)

      # For directed: each out-target loses an in-edge from v; each in-source loses an out-edge to v.
      # For undirected: out_targets == in_sources; decrement both sides once.
      out_degrees =
        in_sources
        |> Enum.reduce(g.out_degrees, fn s, acc ->
          Map.update(acc, s, 0, &max(&1 - 1, 0))
        end)
        |> Map.delete(v)

      in_degrees =
        out_targets
        |> Enum.reduce(g.in_degrees, fn t, acc ->
          Map.update(acc, t, 0, &max(&1 - 1, 0))
        end)
        |> Map.delete(v)

      %{
        g
        | vertices: Map.delete(g.vertices, v),
          vertex_labels: Map.delete(g.vertex_labels, v),
          out_edges: out_edges,
          in_edges: in_edges,
          out_degrees: out_degrees,
          in_degrees: in_degrees,
          num_edges: g.num_edges - reduction,
          num_vertices: g.num_vertices - 1
      }
    end
  end

  # ── Edges ─────────────────────────────────────────────────────────────

  @doc """
  Add an edge from `v1` to `v2`. Auto-creates missing vertices.

  Edges are multi-edges: adding `(:a, :b)` twice yields two edges. Out/in
  degrees count distinct neighbors, not multi-edges.

  ## Options
    * `:weight` — numeric weight (default `1.0`)
    * `:label` — arbitrary label

  ## Examples

      iex> g = Grafi.Graph.new() |> Grafi.Graph.add_edge(:x, :y)
      iex> {Grafi.Graph.has_vertex?(g, :x), Grafi.Graph.has_vertex?(g, :y),
      ...>  Grafi.Graph.has_edge?(g, :x, :y), Grafi.Graph.num_edges(g)}
      {true, true, true, 1}
  """
  @spec add_edge(t(), vertex_id(), vertex_id(), keyword()) :: t()
  def add_edge(%__MODULE__{} = g, v1, v2, opts \\ []) do
    weight = Keyword.get(opts, :weight, 1.0)
    label = Keyword.get(opts, :label)
    edge = %Edge{from: v1, to: v2, weight: weight, label: label}

    g = g |> add_vertex(v1) |> add_vertex(v2)

    new_neighbor? = not has_neighbor_entry?(g.out_edges, v1, v2)

    g = push_edge(g, :out_edges, v1, v2, edge)
    g = push_edge(g, :in_edges, v2, v1, edge)

    g =
      if new_neighbor? do
        %{
          g
          | out_degrees: Map.update(g.out_degrees, v1, 1, &(&1 + 1)),
            in_degrees: Map.update(g.in_degrees, v2, 1, &(&1 + 1))
        }
      else
        g
      end

    g =
      if g.type == :undirected do
        rev = %Edge{from: v2, to: v1, weight: weight, label: label}
        new_rev? = not has_neighbor_entry?(g.out_edges, v2, v1)
        g = g |> push_edge(:out_edges, v2, v1, rev) |> push_edge(:in_edges, v1, v2, rev)

        if new_rev? do
          %{
            g
            | out_degrees: Map.update(g.out_degrees, v2, 1, &(&1 + 1)),
              in_degrees: Map.update(g.in_degrees, v1, 1, &(&1 + 1))
          }
        else
          g
        end
      else
        g
      end

    %{g | num_edges: g.num_edges + 1}
  end

  @doc "Adds multiple edges to the graph."
  @spec add_edges(t(), [{vertex_id(), vertex_id()} | {vertex_id(), vertex_id(), keyword()}]) :: t()
  def add_edges(%__MODULE__{} = g, edges) when is_list(edges) do
    Enum.reduce(edges, g, fn
      {v1, v2}, acc -> add_edge(acc, v1, v2)
      {v1, v2, opts}, acc -> add_edge(acc, v1, v2, opts)
    end)
  end

  @doc "Removes one edge from v1 to v2 (the most recently added)."
  @spec delete_edge(t(), vertex_id(), vertex_id()) :: t()
  def delete_edge(%__MODULE__{} = g, v1, v2) do
    case get_in(g.out_edges, [v1, v2]) do
      nil ->
        g

      [_ | rest] ->
        g = put_in_edge(g, :out_edges, v1, v2, rest)
        g = remove_first_in(g, :in_edges, v2, v1)

        g =
          if rest == [] do
            %{
              g
              | out_degrees: Map.update(g.out_degrees, v1, 0, &max(&1 - 1, 0)),
                in_degrees: Map.update(g.in_degrees, v2, 0, &max(&1 - 1, 0))
            }
          else
            g
          end

        g =
          if g.type == :undirected do
            rev_list = get_in(g.out_edges, [v2, v1]) || []
            g = g |> remove_first_in(:out_edges, v2, v1) |> remove_first_in(:in_edges, v1, v2)

            case rev_list do
              [_only] ->
                %{
                  g
                  | out_degrees: Map.update(g.out_degrees, v2, 0, &max(&1 - 1, 0)),
                    in_degrees: Map.update(g.in_degrees, v1, 0, &max(&1 - 1, 0))
                }

              _ ->
                g
            end
          else
            g
          end

        %{g | num_edges: g.num_edges - 1}
    end
  end

  # ── Queries ───────────────────────────────────────────────────────────

  @doc "Returns true if the vertex exists in the graph."
  @spec has_vertex?(t(), vertex_id()) :: boolean()
  def has_vertex?(%__MODULE__{vertices: vs}, v), do: Map.has_key?(vs, v)

  @doc "Returns true if an edge from v1 to v2 exists."
  @spec has_edge?(t(), vertex_id(), vertex_id()) :: boolean()
  def has_edge?(%__MODULE__{out_edges: out}, v1, v2) do
    case Map.get(out, v1) do
      nil -> false
      targets -> Map.has_key?(targets, v2) and Map.get(targets, v2) != []
    end
  end

  @doc "Returns all vertices in the graph."
  @spec vertices(t()) :: [vertex_id()]
  def vertices(%__MODULE__{vertices: vs}), do: Map.keys(vs)

  @doc """
  Returns all edges in the graph, each exactly once.

  Parallel edges and self-loops are included, so
  `length(edges(g)) == num_edges(g)`. On undirected graphs each edge is
  returned in the orientation stored under its lower endpoint, so
  `from <= to` in Erlang term order.
  """
  @spec edges(t()) :: [Edge.t()]
  def edges(%__MODULE__{out_edges: out, type: type}) do
    directed? = type == :directed

    for {f, targets} <- out, {t, el} <- targets, e <- stored_copies(el, directed?, f, t), do: e
  end

  @doc "Returns the outgoing neighbors of a vertex."
  @spec out_neighbors(t(), vertex_id()) :: [vertex_id()]
  def out_neighbors(%__MODULE__{out_edges: out}, v),
    do: out |> Map.get(v, %{}) |> Enum.reject(fn {_, el} -> el == [] end) |> Enum.map(&elem(&1, 0))

  @doc "Returns the incoming neighbors of a vertex."
  @spec in_neighbors(t(), vertex_id()) :: [vertex_id()]
  def in_neighbors(%__MODULE__{in_edges: ine}, v),
    do: ine |> Map.get(v, %{}) |> Enum.reject(fn {_, el} -> el == [] end) |> Enum.map(&elem(&1, 0))

  @doc "Returns all neighbors (in and out) of a vertex, deduplicated."
  @spec neighbors(t(), vertex_id()) :: [vertex_id()]
  def neighbors(%__MODULE__{} = g, v),
    do: (out_neighbors(g, v) ++ in_neighbors(g, v)) |> Enum.uniq()

  @doc """
  Returns the number of distinct outgoing neighbors of a vertex.

  Cached on the struct for O(log n) lookup. Returns `0` for missing vertices.
  """
  @spec out_degree(t(), vertex_id()) :: non_neg_integer()
  def out_degree(%__MODULE__{out_degrees: od}, v), do: Map.get(od, v, 0)

  @doc """
  Returns the number of distinct incoming neighbors of a vertex.

  Cached on the struct for O(log n) lookup. Returns `0` for missing vertices.
  """
  @spec in_degree(t(), vertex_id()) :: non_neg_integer()
  def in_degree(%__MODULE__{in_degrees: id}, v), do: Map.get(id, v, 0)

  @doc "Returns the total degree of a vertex."
  @spec degree(t(), vertex_id()) :: non_neg_integer()
  def degree(%__MODULE__{type: :undirected} = g, v), do: out_degree(g, v)
  def degree(%__MODULE__{} = g, v), do: out_degree(g, v) + in_degree(g, v)

  @doc "Returns the number of vertices in the graph."
  @spec num_vertices(t()) :: non_neg_integer()
  def num_vertices(%__MODULE__{num_vertices: n}), do: n

  @doc "Returns the number of edges in the graph."
  @spec num_edges(t()) :: non_neg_integer()
  def num_edges(%__MODULE__{num_edges: n}), do: n

  @doc "Returns true if the graph has no vertices."
  @spec empty?(t()) :: boolean()
  def empty?(%__MODULE__{num_vertices: 0}), do: true
  def empty?(_), do: false

  @doc "Returns the label of a vertex, or nil if none."
  @spec label(t(), vertex_id()) :: any()
  def label(%__MODULE__{vertex_labels: l}, v), do: Map.get(l, v)

  @doc "Returns all edges between two vertices."
  @spec edges_between(t(), vertex_id(), vertex_id()) :: [Edge.t()]
  def edges_between(%__MODULE__{out_edges: out}, v1, v2),
    do: get_in(out, [v1, v2]) || []

  # ── Transforms ────────────────────────────────────────────────────────

  @doc """
  Returns a subgraph induced by the given list of vertices.

  Vertex labels, edge weights and labels, and the order of parallel edges
  are preserved. Ids not in `g` are ignored.
  """
  @spec subgraph(t(), [vertex_id()]) :: t()
  def subgraph(%__MODULE__{} = g, keep) do
    vset = keep |> Enum.filter(&Map.has_key?(g.vertices, &1)) |> MapSet.new()
    directed? = g.type == :directed

    acc =
      Enum.reduce(vset, new(type: g.type), fn v, acc ->
        add_vertex(acc, v, label: Map.get(g.vertex_labels, v))
      end)

    # Only the kept vertices' adjacency is visited. Stored lists are newest
    # first and `add_edge/4` prepends, so re-adding oldest first keeps the
    # order (and `delete_edge/3`'s "most recent" choice) intact.
    for v <- vset,
        {t, el} <- Map.get(g.out_edges, v, %{}),
        MapSet.member?(vset, t),
        e <- el |> stored_copies(directed?, v, t) |> Enum.reverse(),
        reduce: acc do
      acc -> add_edge(acc, v, t, weight: e.weight, label: e.label)
    end
  end

  @doc "Returns the transpose (edge-reversed) graph."
  @spec transpose(t()) :: t()
  def transpose(%__MODULE__{type: :undirected} = g), do: g

  def transpose(%__MODULE__{} = g) do
    edges(g)
    |> Enum.reduce(new(type: :directed) |> add_vertices(vertices(g)), fn e, acc ->
      add_edge(acc, e.to, e.from, weight: e.weight, label: e.label)
    end)
  end

  # ── CSR conversion (for NIF dispatch) ─────────────────────────────────

  @doc """
  Converts to CSR (Compressed Sparse Row) format for the igraph NIF engine.

  Returns `{index_map, csr_map}` where `index_map` maps vertex_ids to
  integer indices `[0, n_vertices)`, and `csr_map` has the keys consumed by
  `Grafi.NIF`:

    * `:row_offsets` — `n_vertices + 1` offsets into the edge arrays
    * `:col_indices` — target vertex index of each edge
    * `:weights` — weight of each edge
    * `:n_vertices`, `:directed`

  plus `:vertices`, a tuple whose element `i` is the vertex id at index `i`
  (the reverse of `index_map`).

  The three arrays are native-endian binaries (`signed-native-64` integers,
  `float-native-64` weights) that the NIF reads without decoding terms
  element by element. Decode them with, for example,
  `for <<i::signed-native-64 <- csr.col_indices>>, do: i`.

  Every edge appears exactly once, so `byte_size(col_indices) == 8 * num_edges(g)`.
  For undirected graphs an edge is listed in the row of its lower-index
  endpoint.
  """
  @spec to_csr(t()) :: {%{vertex_id() => non_neg_integer()}, map()}
  def to_csr(%__MODULE__{} = g) do
    sorted = vertices(g) |> Enum.sort()
    idx = sorted |> Enum.with_index() |> Map.new()
    directed? = g.type == :directed

    # Build the three arrays as iodata in CSR order and flatten each once.
    {offsets, cols, weights, _count} =
      sorted
      |> Enum.with_index()
      |> Enum.reduce({[<<0::signed-native-64>>], [], [], 0}, fn {v, iv}, {off, c, w, count} ->
        {c, w, count} =
          g.out_edges
          |> Map.get(v, %{})
          |> Enum.flat_map(fn {to, el} ->
            i = Map.fetch!(idx, to)
            el |> stored_copies(directed?, iv, i) |> Enum.map(&{i, &1.weight})
          end)
          |> Enum.sort_by(&elem(&1, 0))
          |> Enum.reduce({c, w, count}, fn {i, weight}, {c, w, k} ->
            {[c, <<i::signed-native-64>>], [w, <<weight::float-native-64>>], k + 1}
          end)

        {[off, <<count::signed-native-64>>], c, w, count}
      end)

    csr_map = %{
      row_offsets: IO.iodata_to_binary(offsets),
      col_indices: IO.iodata_to_binary(cols),
      weights: IO.iodata_to_binary(weights),
      n_vertices: g.num_vertices,
      directed: directed?,
      vertices: List.to_tuple(sorted)
    }

    {idx, csr_map}
  end

  # An undirected edge {u, v} is stored under both endpoints, and an
  # undirected self-loop twice under its vertex. Keep exactly one copy of
  # each edge: the copy stored under the lower endpoint, and one copy of each
  # self-loop. `add_edge/4` prepends each undirected loop as the adjacent
  # pair `[rev, e]` and `delete_edge/3` removes both elements of the pair, so
  # every other element is exactly one copy of each loop.
  #
  # `to_csr/1` calls this with vertex indices and `edges/1` with vertex ids.
  # Both keep one copy of every edge. They pick the same copy because
  # `to_csr/1` indexes vertices in sorted term order, so `index(u) < index(v)`
  # iff `u < v`, except for ids that compare equal but differ (`1` and
  # `1.0`): neither is `<` the other and the repeated-variable clause needs
  # an exact match, so a deterministic tie-break keeps exactly one copy.
  defp stored_copies(el, true = _directed?, _from, _to), do: el
  defp stored_copies(el, false, from, to) when from < to, do: el
  defp stored_copies(el, false, same, same), do: Enum.take_every(el, 2)

  defp stored_copies(el, false, from, to) when from == to do
    if :erlang.term_to_binary(from, [:deterministic]) <
         :erlang.term_to_binary(to, [:deterministic]),
       do: el,
       else: []
  end

  defp stored_copies(_el, false, _from, _to), do: []

  # ── Internal helpers ──────────────────────────────────────────────────

  defp maybe_set_label(g, v, opts) do
    case Keyword.get(opts, :label) do
      nil -> g
      l -> %{g | vertex_labels: Map.put(g.vertex_labels, v, l)}
    end
  end

  defp push_edge(g, field, from, to, edge) do
    map = Map.get(g, field)

    map =
      map
      |> Map.put_new(from, %{})
      |> Map.update!(from, fn targets ->
        Map.update(targets, to, [edge], &[edge | &1])
      end)

    Map.put(g, field, map)
  end

  defp put_in_edge(g, field, from, to, edges) do
    map = Map.get(g, field)

    map =
      if edges == [] do
        update_in(map, [from], &Map.delete(&1, to))
      else
        put_in(map, [from, to], edges)
      end

    Map.put(g, field, map)
  end

  defp remove_first_in(g, field, from, to) do
    map = Map.get(g, field)

    case get_in(map, [from, to]) do
      nil ->
        g

      [] ->
        g

      [_ | rest] ->
        map =
          if rest == [] do
            update_in(map, [from], &Map.delete(&1, to))
          else
            put_in(map, [from, to], rest)
          end

        Map.put(g, field, map)
    end
  end

  defp edge_count_in_map(map) do
    Enum.reduce(map, 0, fn {_, el}, acc -> acc + length(el) end)
  end

  defp strip_target(map, v) do
    Map.new(map, fn {from, targets} -> {from, Map.delete(targets, v)} end)
  end

  defp has_neighbor_entry?(adj, from, to) do
    case adj do
      %{^from => %{^to => [_ | _]}} -> true
      _ -> false
    end
  end

  # ── Protocols ─────────────────────────────────────────────────────────

  defimpl Inspect do
    def inspect(%Grafi.Graph{} = g, _opts) do
      "#Grafi.Graph<#{g.type}, V: #{g.num_vertices}, E: #{g.num_edges}>"
    end
  end

  defimpl Enumerable do
    def count(%Grafi.Graph{num_vertices: n}), do: {:ok, n}
    def member?(%Grafi.Graph{} = g, v), do: {:ok, Grafi.Graph.has_vertex?(g, v)}

    def reduce(%Grafi.Graph{} = g, acc, fun),
      do: Grafi.Graph.vertices(g) |> Enumerable.List.reduce(acc, fun)

    def slice(_), do: {:error, __MODULE__}
  end
end
