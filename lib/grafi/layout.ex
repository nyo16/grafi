defmodule Grafi.Layout do
  @moduledoc """
  Layered graph layout algorithms.

  Currently provides a simplified Sugiyama-style layout for DAGs. The
  algorithm assigns each vertex an `(x, y)` position where `y` is the
  layer index (longest path from any source) and `x` is the horizontal
  position within that layer.

  ## Phases (Sugiyama framework)

  A full Sugiyama pipeline has four phases:

    1. Cycle removal — reverse edges to break cycles.
    2. Layer assignment — assign each vertex to a horizontal layer.
    3. Vertex ordering / crossing reduction — permute vertices in each
       layer to minimise edge crossings.
    4. Coordinate assignment — pick `(x, y)` positions.

  This v0.1.0 implementation:

    * **Phase 1** is skipped — `sugiyama/2` requires a DAG (or an
      undirected forest, oriented away from the smallest vertex of each
      tree) and returns `{:error, :has_cycle}` for cyclic input.
    * **Phase 2** uses longest-path layering: each vertex's layer is
      `1 + max(layer of predecessors)`, with sources at layer 0.
    * **Phase 3** uses the **barycenter method** with up to four
      down/up sweeps (configurable via `:crossings`).
    * **Phase 4** assigns equal horizontal spacing within each layer.

  > This is a simplified Sugiyama; for production layout quality,
  > render via Graphviz `dot` using `Grafi.Viz`.

  ## Examples

      iex> g =
      ...>   Grafi.new()
      ...>   |> Grafi.add_edges([{:a, :b}, {:b, :c}])
      iex> {:ok, pos} = Grafi.Layout.sugiyama(g)
      iex> {_, ya} = pos[:a]
      iex> {_, yb} = pos[:b]
      iex> {_, yc} = pos[:c]
      iex> {ya, yb, yc}
      {0.0, 1.0, 2.0}
  """

  alias Grafi.Algo.Traversal
  alias Grafi.Graph

  @type vertex :: any()
  @type position :: {float(), float()}
  @type layout :: %{vertex() => position()}

  @default_layer_spacing 1.0
  @default_vertex_spacing 1.0
  @sweep_passes 4

  # ── Public API ────────────────────────────────────────────────────────

  @doc """
  Compute a Sugiyama-style layered layout for a DAG.

  Returns `{:ok, %{vertex => {x, y}}}` where `x` is the horizontal
  position within a layer and `y` is the layer index (0 = top) times
  `:layer_spacing`.

  Returns `{:error, :has_cycle}` if the graph contains a cycle (for an
  undirected graph: anything but a forest).

  ## Options

    * `:layer_spacing` — vertical spacing between layers (default `1.0`).
    * `:vertex_spacing` — horizontal spacing between vertices within a
      layer (default `1.0`).
    * `:crossings` — `:default` (run barycenter sweeps, the default) or
      `:none` (skip crossing reduction).

  ## Examples

      iex> g =
      ...>   Grafi.new()
      ...>   |> Grafi.add_edges([{:a, :b}, {:a, :c}, {:b, :d}, {:c, :d}])
      iex> {:ok, pos} = Grafi.Layout.sugiyama(g)
      iex> {_, ya} = pos[:a]
      iex> {_, yd} = pos[:d]
      iex> {ya, yd}
      {0.0, 2.0}
  """
  @spec sugiyama(Graph.t(), keyword()) ::
          {:ok, layout()} | {:error, :has_cycle}
  def sugiyama(%Graph{} = g, opts \\ []) do
    opts =
      Keyword.validate!(opts,
        layer_spacing: @default_layer_spacing,
        vertex_spacing: @default_vertex_spacing,
        crossings: :default
      )

    if Grafi.Algo.Cycles.has_cycle?(g) do
      {:error, :has_cycle}
    else
      layer_spacing = opts[:layer_spacing]
      vertex_spacing = opts[:vertex_spacing]
      crossings = opts[:crossings]

      g = orient(g)
      layer_of = longest_path_layers(g)
      layers = group_by_layer(layer_of)

      ordered =
        case crossings do
          :none -> layers
          _ -> reduce_crossings(g, layers)
        end

      {:ok, assign_coordinates(ordered, vertex_spacing, layer_spacing)}
    end
  end

  @doc """
  Return only the layer assignment for a DAG as `%{vertex => layer_index}`.

  Returns `{:error, :has_cycle}` if the graph contains a cycle. An
  undirected forest is laid out from the smallest vertex of each tree.

  ## Examples

      iex> g =
      ...>   Grafi.new()
      ...>   |> Grafi.add_edges([{:a, :b}, {:b, :c}])
      iex> Grafi.Layout.levels(g)
      {:ok, %{a: 0, b: 1, c: 2}}
  """
  @spec levels(Graph.t()) ::
          {:ok, %{vertex() => non_neg_integer()}} | {:error, :has_cycle}
  def levels(%Graph{} = g) do
    if Grafi.Algo.Cycles.has_cycle?(g) do
      {:error, :has_cycle}
    else
      {:ok, g |> orient() |> longest_path_layers()}
    end
  end

  # ── Phase 2: layer assignment (longest path) ──────────────────────────

  # An acyclic undirected graph is a forest. Orient it away from the
  # smallest vertex (term order) of each tree, so roots sit at layer 0 and
  # every vertex's layer is its BFS depth.
  defp orient(%Graph{type: :directed} = g), do: g

  defp orient(%Graph{} = g) do
    base = Enum.reduce(Graph.vertices(g), Graph.new(type: :directed), &Graph.add_vertex(&2, &1))

    g
    |> Graph.vertices()
    |> Enum.sort()
    |> Enum.reduce({base, MapSet.new()}, fn root, {dg, seen} ->
      if MapSet.member?(seen, root),
        do: {dg, seen},
        else: orient_tree(g, :queue.from_list([root]), dg, MapSet.put(seen, root))
    end)
    |> elem(0)
  end

  defp orient_tree(g, q, dg, seen) do
    case :queue.out(q) do
      {:empty, _} ->
        {dg, seen}

      {{:value, v}, q} ->
        {q, dg, seen} =
          g
          |> Graph.out_neighbors(v)
          |> Enum.reject(&MapSet.member?(seen, &1))
          |> Enum.reduce({q, dg, seen}, fn n, {q, dg, seen} ->
            {:queue.in(n, q), Graph.add_edge(dg, v, n), MapSet.put(seen, n)}
          end)

        orient_tree(g, q, dg, seen)
    end
  end

  defp longest_path_layers(g) do
    # Topologically sort the vertices, then assign each vertex's layer
    # as `1 + max(layer of predecessors)`. Sources have layer 0. The
    # callers have already rejected cyclic graphs.
    {:ok, sorted} = Traversal.topological_sort(g)

    Enum.reduce(sorted, %{}, fn v, acc ->
      layer =
        case Graph.in_neighbors(g, v) do
          [] -> 0
          preds -> 1 + Enum.max(Enum.map(preds, &Map.fetch!(acc, &1)))
        end

      Map.put(acc, v, layer)
    end)
  end

  # Vertices within a layer start in term order (barycenter sweeps reorder
  # them afterwards).
  defp group_by_layer(layer_of) do
    layer_of
    |> Enum.sort()
    |> Enum.group_by(&elem(&1, 1), &elem(&1, 0))
  end

  # ── Phase 3: crossing reduction (barycenter method) ───────────────────

  defp reduce_crossings(_g, layers) when map_size(layers) <= 1, do: layers

  defp reduce_crossings(g, layers) do
    max_layer = layers |> Map.keys() |> Enum.max()

    # Up to @sweep_passes alternating down/up sweeps. Stop early if a
    # full down+up pass leaves the ordering unchanged.
    Enum.reduce_while(1..@sweep_passes, layers, fn pass, current ->
      after_down = sweep_down(g, current, max_layer)
      after_up = sweep_up(g, after_down, max_layer)

      if after_up == current and pass > 1,
        do: {:halt, after_up},
        else: {:cont, after_up}
    end)
  end

  # Top→bottom: order each layer by barycenter of predecessor positions
  # in the layer above.
  defp sweep_down(g, layers, max_layer) do
    Enum.reduce(1..max_layer, layers, fn l, acc ->
      above = Map.get(acc, l - 1, [])
      pos_above = positions_in(above)

      reordered =
        Map.get(acc, l, [])
        |> sort_by_barycenter(fn v -> Graph.in_neighbors(g, v) end, pos_above)

      Map.put(acc, l, reordered)
    end)
  end

  # Bottom→top: order each layer by barycenter of successor positions
  # in the layer below.
  defp sweep_up(_g, layers, 0), do: layers

  defp sweep_up(g, layers, max_layer) do
    Enum.reduce((max_layer - 1)..0//-1, layers, fn l, acc ->
      below = Map.get(acc, l + 1, [])
      pos_below = positions_in(below)

      reordered =
        Map.get(acc, l, [])
        |> sort_by_barycenter(fn v -> Graph.out_neighbors(g, v) end, pos_below)

      Map.put(acc, l, reordered)
    end)
  end

  defp positions_in(vertices) do
    vertices |> Enum.with_index() |> Map.new()
  end

  defp sort_by_barycenter(vertices, neighbors_fun, neighbor_positions) do
    # Pair each vertex with its barycenter, then sort stably. Vertices
    # without any neighbours in the reference layer keep their relative
    # order (we fall back to their original index).
    vertices
    |> Enum.with_index()
    |> Enum.map(fn {v, original_idx} ->
      ns =
        neighbors_fun.(v)
        |> Enum.map(&Map.get(neighbor_positions, &1))
        |> Enum.reject(&is_nil/1)

      bary =
        case ns do
          [] -> original_idx * 1.0
          _ -> Enum.sum(ns) / length(ns)
        end

      {v, bary, original_idx}
    end)
    |> Enum.sort_by(fn {_v, b, i} -> {b, i} end)
    |> Enum.map(fn {v, _b, _i} -> v end)
  end

  # ── Phase 4: coordinate assignment (equal spacing) ────────────────────

  defp assign_coordinates(layers, vertex_spacing, layer_spacing) do
    Enum.reduce(layers, %{}, fn {layer_idx, vs}, acc ->
      y = layer_idx * 1.0 * layer_spacing
      n = length(vs)
      # Centre each layer around x = 0 for visual symmetry.
      offset = (n - 1) * vertex_spacing / 2.0

      vs
      |> Enum.with_index()
      |> Enum.reduce(acc, fn {v, i}, a ->
        x = i * vertex_spacing - offset
        Map.put(a, v, {x, y})
      end)
    end)
  end
end
