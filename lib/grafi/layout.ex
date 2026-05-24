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

    * **Phase 1** is skipped — `sugiyama/2` requires a DAG and returns
      `{:error, :has_cycle}` for cyclic input.
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

  Returns `{:error, :has_cycle}` if the graph contains a cycle.

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
    if Grafi.Algo.Cycles.has_cycle?(g) do
      {:error, :has_cycle}
    else
      layer_spacing = Keyword.get(opts, :layer_spacing, @default_layer_spacing)
      vertex_spacing = Keyword.get(opts, :vertex_spacing, @default_vertex_spacing)
      crossings = Keyword.get(opts, :crossings, :default)

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

  Returns `{:error, :has_cycle}` if the graph contains a cycle.

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
      {:ok, longest_path_layers(g)}
    end
  end

  # ── Phase 2: layer assignment (longest path) ──────────────────────────

  defp longest_path_layers(g) do
    # Topologically sort the vertices, then assign each vertex's layer
    # as `1 + max(layer of predecessors)`. Sources have layer 0.
    case topological_sort(g) do
      {:ok, sorted} ->
        Enum.reduce(sorted, %{}, fn v, acc ->
          preds = Graph.in_neighbors(g, v)

          layer =
            case preds do
              [] -> 0
              _ -> 1 + Enum.max(Enum.map(preds, &Map.get(acc, &1, 0)))
            end

          Map.put(acc, v, layer)
        end)

      _ ->
        # Should never happen — has_cycle?/1 already passed.
        %{}
    end
  end

  defp topological_sort(g) do
    in_deg =
      Graph.vertices(g)
      |> Map.new(&{&1, Graph.in_degree(g, &1)})

    queue = for {v, 0} <- in_deg, do: v
    kahn(g, :queue.from_list(queue), in_deg, [])
  end

  defp kahn(g, q, in_deg, result) do
    case :queue.out(q) do
      {:empty, _} ->
        if Enum.any?(in_deg, fn {_, d} -> d > 0 end),
          do: {:error, :has_cycle},
          else: {:ok, Enum.reverse(result)}

      {{:value, v}, rest_q} ->
        {adds, in_deg} =
          Graph.out_neighbors(g, v)
          |> Enum.reduce({[], in_deg}, fn n, {a, d} ->
            nd = d[n] - 1
            d = Map.put(d, n, nd)
            if nd == 0, do: {[n | a], d}, else: {a, d}
          end)

        new_q = Enum.reduce(Enum.reverse(adds), rest_q, fn n, q -> :queue.in(n, q) end)
        kahn(g, new_q, Map.put(in_deg, v, -1), [v | result])
    end
  end

  defp group_by_layer(layer_of) do
    layer_of
    |> Enum.reduce(%{}, fn {v, l}, acc ->
      Map.update(acc, l, [v], &(&1 ++ [v]))
    end)
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

      cond do
        after_up == current and pass > 1 -> {:halt, after_up}
        true -> {:cont, after_up}
      end
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
