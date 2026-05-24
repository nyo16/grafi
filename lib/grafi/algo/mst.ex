defmodule Grafi.DisconnectedError do
  @moduledoc """
  Raised by `Grafi.Algo.MST.kruskal!/1` (and friends) when a minimum
  spanning *tree* is requested but the input graph has more than one
  connected component (i.e. only a spanning *forest* exists).
  """
  defexception [:message]

  @impl true
  def exception(opts) when is_list(opts) do
    %__MODULE__{message: Keyword.get(opts, :message, "graph is disconnected")}
  end

  def exception(msg) when is_binary(msg), do: %__MODULE__{message: msg}
end

defmodule Grafi.Algo.MST do
  @moduledoc """
  Minimum Spanning Tree / Forest algorithms — Kruskal's and Prim's.

  Both algorithms treat the input graph as **undirected** regardless of
  its `:type`. For a directed `Grafi.Graph`, each directed edge
  contributes once: parallel edges between the same `(u, v)` pair
  collapse to the minimum-weight edge for the purposes of the spanning
  tree.

  Both functions return `{forest_edges, total_weight}` where
  `forest_edges` is a list of `%Grafi.Edge{}` values. On a connected
  graph this is a spanning *tree* of exactly `V - 1` edges; on a
  disconnected graph Kruskal returns a spanning *forest* across all
  components, and Prim returns a spanning tree of the component
  containing the start vertex.

  Use the `kruskal!/1` variant if you want a hard error on
  disconnected input.
  """

  alias Grafi.Algo.MinHeap
  alias Grafi.DisconnectedError
  alias Grafi.Edge
  alias Grafi.Graph
  alias Grafi.UnionFind

  @doc """
  Computes a minimum spanning tree (or forest) using Kruskal's algorithm.

  Returns `{forest_edges, total_weight}`. The graph is treated as
  undirected; parallel edges are reduced to the minimum-weight edge.
  If the graph is disconnected, returns the union of MSTs over each
  connected component — i.e. a minimum spanning *forest* — with
  `length(forest_edges) == V - components`.

  ## Examples

      iex> g = Grafi.new(type: :undirected) |> Grafi.add_edges([
      ...>   {:a, :b, weight: 1.0},
      ...>   {:b, :c, weight: 2.0},
      ...>   {:a, :c, weight: 3.0}
      ...> ])
      iex> {edges, total} = Grafi.Algo.MST.kruskal(g)
      iex> {length(edges), total}
      {2, 3.0}
  """
  @spec kruskal(Graph.t()) :: {[Edge.t()], number()}
  def kruskal(%Graph{} = g) do
    vs = Graph.vertices(g)
    uf = UnionFind.new(vs)

    sorted_edges =
      g
      |> unique_undirected_edges()
      |> Enum.sort_by(& &1.weight)

    {forest, uf} =
      Enum.reduce(sorted_edges, {[], uf}, fn edge, {acc, uf_acc} ->
        {ru, uf_acc} = UnionFind.find(uf_acc, edge.from)
        {rv, uf_acc} = UnionFind.find(uf_acc, edge.to)

        if ru == rv do
          {acc, uf_acc}
        else
          {[edge | acc], UnionFind.union(uf_acc, edge.from, edge.to)}
        end
      end)

    _ = uf
    forest = Enum.reverse(forest)
    {forest, total_weight(forest)}
  end

  @doc """
  Like `kruskal/1` but raises `Grafi.DisconnectedError` when the input
  graph is disconnected (i.e. the result is a forest, not a tree).

  Returns `{tree_edges, total_weight}` on success.
  """
  @spec kruskal!(Graph.t()) :: {[Edge.t()], number()}
  def kruskal!(%Graph{} = g) do
    {forest, total} = kruskal(g)
    v = Graph.num_vertices(g)

    cond do
      v == 0 ->
        {forest, total}

      length(forest) == v - 1 ->
        {forest, total}

      true ->
        raise DisconnectedError,
          message:
            "graph is disconnected: spanning forest has #{length(forest)} edges " <>
              "(expected #{v - 1} for a spanning tree over #{v} vertices)"
    end
  end

  @doc """
  Computes a minimum spanning tree using Prim's algorithm starting from
  `start_vertex`. If `start_vertex` is `nil`, an arbitrary vertex is
  chosen (the first one returned by `Grafi.Graph.vertices/1`).

  Only spans the connected component containing `start_vertex`. For a
  disconnected graph, the result is the MST of that one component;
  use `kruskal/1` if you want a forest over all components.

  Returns `{tree_edges, total_weight}`. On an empty graph returns
  `{[], 0}`.
  """
  @spec prim(Graph.t(), any() | nil) :: {[Edge.t()], number()}
  def prim(graph, start_vertex \\ nil)

  def prim(%Graph{num_vertices: 0}, _), do: {[], 0}

  def prim(%Graph{} = g, nil) do
    [start | _] = Graph.vertices(g)
    prim(g, start)
  end

  def prim(%Graph{} = g, start) do
    unless Graph.has_vertex?(g, start) do
      raise ArgumentError, "start vertex #{inspect(start)} is not in the graph"
    end

    in_tree = MapSet.new([start])
    heap = push_crossing_edges(MinHeap.new(), g, start)

    do_prim(g, heap, in_tree, [])
  end

  defp do_prim(g, heap, in_tree, acc) do
    case MinHeap.pop(heap) do
      :empty ->
        forest = Enum.reverse(acc)
        {forest, total_weight(forest)}

      {:ok, {_w, edge}, rest} ->
        target = edge.to

        if MapSet.member?(in_tree, target) do
          do_prim(g, rest, in_tree, acc)
        else
          in_tree = MapSet.put(in_tree, target)
          heap = push_crossing_edges(rest, g, target)
          do_prim(g, heap, in_tree, [edge | acc])
        end
    end
  end

  # Push every minimum-weight edge from `v` to its (undirected)
  # neighbours onto the heap, regardless of whether the neighbour is
  # already in the tree — we filter on pop. This keeps insertion O(deg)
  # and matches the canonical "lazy Prim" formulation.
  defp push_crossing_edges(heap, g, v) do
    g
    |> neighbour_edges(v)
    |> Enum.reduce(heap, fn edge, h -> MinHeap.insert(h, {edge.weight, edge}) end)
  end

  @doc """
  Sums the `:weight` of every edge in `edges`. Useful for sanity-checking
  an externally produced spanning tree.

  ## Examples

      iex> Grafi.Algo.MST.total_weight([
      ...>   %Grafi.Edge{from: :a, to: :b, weight: 1.5},
      ...>   %Grafi.Edge{from: :b, to: :c, weight: 2.5}
      ...> ])
      4.0
  """
  @spec total_weight([Edge.t()]) :: number()
  def total_weight(edges) when is_list(edges) do
    Enum.reduce(edges, 0, fn %Edge{weight: w}, acc -> acc + w end)
  end

  # ── Internal helpers ──────────────────────────────────────────────────

  # Returns one minimum-weight edge per unordered {u, v} pair, walking
  # the raw adjacency map directly so that parallel multi-edges are
  # observed (the public `Graph.edges/1` dedupes by `{from, to, label}`
  # and would mask cheaper duplicates). For undirected graphs the
  # reverse copy is dropped via `unordered_key/2`; for directed graphs
  # both directions contribute and the cheaper one wins. Self-loops are
  # ignored — they can never be in a spanning tree.
  defp unique_undirected_edges(%Graph{out_edges: out}) do
    Enum.reduce(out, %{}, fn {from, targets}, acc ->
      Enum.reduce(targets, acc, fn {to, edges}, acc2 ->
        if from == to do
          acc2
        else
          key = unordered_key(from, to)
          best = Enum.min_by(edges, & &1.weight)

          case Map.get(acc2, key) do
            nil -> Map.put(acc2, key, best)
            %Edge{weight: w} when best.weight < w -> Map.put(acc2, key, best)
            _ -> acc2
          end
        end
      end)
    end)
    |> Map.values()
  end

  # Returns the cheapest edge to each undirected neighbour of `v`,
  # oriented as `v -> neighbour`. Used by Prim.
  defp neighbour_edges(%Graph{} = g, v) do
    out =
      g
      |> Graph.out_neighbors(v)
      |> Enum.reject(&(&1 == v))
      |> Enum.map(fn n ->
        w = g |> Graph.edges_between(v, n) |> Enum.map(& &1.weight) |> Enum.min()
        %Edge{from: v, to: n, weight: w}
      end)

    inc =
      g
      |> Graph.in_neighbors(v)
      |> Enum.reject(&(&1 == v))
      |> Enum.map(fn n ->
        w = g |> Graph.edges_between(n, v) |> Enum.map(& &1.weight) |> Enum.min()
        %Edge{from: v, to: n, weight: w}
      end)

    (out ++ inc)
    |> Enum.reduce(%{}, fn %Edge{to: n} = e, acc ->
      case Map.get(acc, n) do
        nil -> Map.put(acc, n, e)
        %Edge{weight: w} when e.weight < w -> Map.put(acc, n, e)
        _ -> acc
      end
    end)
    |> Map.values()
  end

  defp unordered_key(a, b) do
    cond do
      a == b -> {a, b}
      compare(a, b) -> {a, b}
      true -> {b, a}
    end
  end

  # Total-order comparison that works for any Erlang term.
  defp compare(a, b), do: a <= b
end
