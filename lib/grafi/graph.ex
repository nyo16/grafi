defmodule Grafi.Graph do
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

    unless type in [:directed, :undirected],
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
      out_count = g.out_edges |> Map.get(v, %{}) |> edge_count_in_map()
      in_count = g.in_edges |> Map.get(v, %{}) |> edge_count_in_map()
      reduction = if g.type == :undirected, do: out_count, else: out_count + in_count

      # Distinct neighbors that had an edge involving v (for degree maintenance)
      out_targets = g.out_edges |> Map.get(v, %{}) |> Map.keys()
      in_sources = g.in_edges |> Map.get(v, %{}) |> Map.keys()

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

  @doc "Returns all edges in the graph."
  @spec edges(t()) :: [Edge.t()]
  def edges(%__MODULE__{out_edges: out, type: type}) do
    all = for {_f, targets} <- out, {_t, el} <- targets, e <- el, do: e

    if type == :undirected do
      Enum.uniq_by(all, fn %Edge{from: f, to: t, label: l} ->
        if f <= t, do: {f, t, l}, else: {t, f, l}
      end)
    else
      all
    end
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

  @doc "Returns a subgraph induced by the given list of vertices."
  @spec subgraph(t(), [vertex_id()]) :: t()
  def subgraph(%__MODULE__{} = g, keep) do
    vset = MapSet.new(keep)

    Enum.reduce(keep, new(type: g.type), fn v, acc ->
      if not Map.has_key?(g.vertices, v) do
        acc
      else
        acc = add_vertex(acc, v, label: Map.get(g.vertex_labels, v))

        g.out_edges
        |> Map.get(v, %{})
        |> Enum.reduce(acc, fn {to, el}, a ->
          if MapSet.member?(vset, to),
            do: Enum.reduce(el, a, &add_edge(&2, v, to, weight: &1.weight, label: &1.label)),
            else: a
        end)
      end
    end)
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
  integer indices `[0, n_vertices)`, and `csr_map` has the keys
  `:row_offsets`, `:col_indices`, `:weights`, `:n_vertices`, `:directed`
  consumed by `Grafi.NIF`.
  """
  @spec to_csr(t()) :: {%{vertex_id() => non_neg_integer()}, map()}
  def to_csr(%__MODULE__{} = g) do
    sorted = vertices(g) |> Enum.sort()
    idx = sorted |> Enum.with_index() |> Map.new()

    # Accumulate row_offsets in reverse (cheap, length n+1), and accumulate
    # cols/weights in *reverse* order across all vertices, then reverse once
    # at the end. Avoids the per-vertex Enum.reverse that the old impl did.
    {rev_offsets, rev_cols, rev_weights} =
      Enum.reduce(sorted, {[0], [], []}, fn v, {[prev_off | _] = off, c, w} ->
        out = Map.get(g.out_edges, v, %{})

        pairs =
          Enum.flat_map(out, fn {to, el} ->
            i = Map.fetch!(idx, to)
            Enum.map(el, fn e -> {i, e.weight} end)
          end)
          |> Enum.sort_by(&elem(&1, 0))

        {new_off, c, w} =
          Enum.reduce(pairs, {prev_off, c, w}, fn {i, weight}, {n, c_acc, w_acc} ->
            {n + 1, [i | c_acc], [weight | w_acc]}
          end)

        {[new_off | off], c, w}
      end)

    csr_map = %{
      row_offsets: Enum.reverse(rev_offsets),
      col_indices: Enum.reverse(rev_cols),
      weights: Enum.reverse(rev_weights),
      n_vertices: g.num_vertices,
      directed: g.type == :directed
    }

    {idx, csr_map}
  end

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
