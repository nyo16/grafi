defmodule Grafi.DAG do
  @moduledoc """
  A Directed Acyclic Graph with runtime cycle prevention.

  Every edge addition that would introduce a cycle raises `Grafi.CycleError`.

  > If cycle prevention is not needed, use `Grafi.Graph` directly — `add_edge`
  > is then O(1) instead of O(|V|+|E|) per insertion.

      iex> dag = Grafi.DAG.new()
      ...>   |> Grafi.DAG.add_edge(:compile, :test)
      ...>   |> Grafi.DAG.add_edge(:test, :deploy)
      iex> Grafi.DAG.topological_sort(dag)
      {:ok, [:compile, :test, :deploy]}
  """

  alias Grafi.Args
  alias Grafi.Graph
  alias Grafi.NIF

  @type t :: %__MODULE__{graph: Graph.t()}
  defstruct [:graph]

  @spec new() :: t()
  def new, do: %__MODULE__{graph: Graph.new(type: :directed)}

  @doc """
  Wraps an existing directed graph as a DAG, returning an error if it
  contains a cycle.

  Raises `Grafi.NIFError` if the igraph cycle check fails unexpectedly.
  """
  @spec from_graph(Graph.t()) :: {:ok, t()} | {:error, :has_cycle | :must_be_directed}
  def from_graph(%Graph{type: :undirected}), do: {:error, :must_be_directed}

  def from_graph(%Graph{type: :directed} = g) do
    case topological_sort_graph(g, []) do
      {:ok, _} -> {:ok, %__MODULE__{graph: g}}
      {:error, :has_cycle} = error -> error
      {:error, reason} -> raise Grafi.NIFError, reason: reason
    end
  end

  @doc "Like from_graph/1 but raises on cycle or undirected input."
  @spec from_graph!(Graph.t()) :: t()
  def from_graph!(g) do
    case from_graph(g) do
      {:ok, dag} -> dag
      {:error, r} -> raise Grafi.CycleError, message: "cannot create DAG: #{r}"
    end
  end

  @doc "Adds a vertex to the DAG, optionally with a label."
  @spec add_vertex(t(), any(), keyword()) :: t()
  def add_vertex(%__MODULE__{graph: g} = dag, v, opts \\ []),
    do: %{dag | graph: Graph.add_vertex(g, v, opts)}

  @doc """
  Adds an edge to the DAG, auto-creating missing vertices.

  Raises `Grafi.CycleError` for self-loops or if the edge would create a
  cycle. The reachability check runs against the graph with both endpoints
  guaranteed present, so newly inserted vertices participate in the check.

  ## Options
    * `:weight` — numeric weight (default `1.0`)
    * `:label` — arbitrary label

  ## Examples

      iex> dag = Grafi.DAG.new() |> Grafi.DAG.add_edge(:a, :b)
      iex> _ = Grafi.DAG.add_edge(dag, :b, :c)
      iex> try do
      ...>   Grafi.DAG.add_edge(dag, :b, :a)
      ...> rescue
      ...>   e in Grafi.CycleError -> e.message =~ "would create a cycle"
      ...> end
      true
  """
  @spec add_edge(t(), any(), any(), keyword()) :: t()
  def add_edge(%__MODULE__{graph: g} = dag, v1, v2, opts \\ []) do
    if v1 == v2,
      do: raise(Grafi.CycleError, message: "self-loop: #{inspect(v1)}")

    g_with_verts = g |> Graph.add_vertex(v1) |> Graph.add_vertex(v2)

    if Grafi.Algo.Traversal.reachable?(g_with_verts, v2, v1),
      do:
        raise(Grafi.CycleError,
          message: "#{inspect(v1)} -> #{inspect(v2)} would create a cycle"
        )

    %{dag | graph: Graph.add_edge(g_with_verts, v1, v2, opts)}
  end

  @doc "Adds multiple edges to the DAG, raising CycleError if any would create a cycle."
  @spec add_edges(t(), list()) :: t()
  def add_edges(%__MODULE__{} = dag, edges) do
    Enum.reduce(edges, dag, fn
      {a, b}, acc -> add_edge(acc, a, b)
      {a, b, o}, acc -> add_edge(acc, a, b, o)
    end)
  end

  @doc """
  Returns a topological ordering of the DAG's vertices via Kahn's algorithm.

  The order is deterministic: sources start in vertex term order, and each
  vertex releases its successors in term order (first in, first out). Both
  engines produce this exact order.

  Since a `Grafi.DAG` is cycle-free by construction this succeeds with
  `{:ok, sorted}` (the `{:error, :has_cycle}` arm exists for internal use on
  raw `Grafi.Graph`s).

  ## Options
    - `:engine` — `:auto | :nif | :elixir`, see `Grafi.NIF`. `engine: :nif`
      without the NIF returns `{:error, :nif_not_available}`.

  ## Examples

      iex> Grafi.DAG.new()
      ...> |> Grafi.DAG.add_edge(:a, :b)
      ...> |> Grafi.DAG.add_edge(:b, :c)
      ...> |> Grafi.DAG.topological_sort()
      {:ok, [:a, :b, :c]}
  """
  @spec topological_sort(t(), keyword()) ::
          {:ok, [any()]}
          | {:error, :has_cycle | :nif_not_available | {:igraph, String.t()}}
  def topological_sort(%__MODULE__{graph: g}, opts \\ []) do
    Args.engine!(opts)
    topological_sort_graph(g, opts)
  end

  @doc "Groups vertices into layers by their longest-path depth from sources."
  @spec layers(t()) :: %{non_neg_integer() => [any()]}
  def layers(%__MODULE__{graph: g} = dag) do
    case topological_sort(dag) do
      {:ok, sorted} ->
        {layer_map, _} =
          Enum.reduce(sorted, {%{}, %{}}, fn v, {lm, vl} ->
            preds = Graph.in_neighbors(g, v)

            layer =
              if preds == [], do: 0, else: (Enum.map(preds, &Map.get(vl, &1, 0)) |> Enum.max()) + 1

            {Map.update(lm, layer, [v], &(&1 ++ [v])), Map.put(vl, v, layer)}
          end)

        layer_map

      _ ->
        %{}
    end
  end

  @doc "Returns vertices with no incoming edges."
  @spec sources(t()) :: [any()]
  def sources(%__MODULE__{graph: g}),
    do: Graph.vertices(g) |> Enum.filter(&(Graph.in_degree(g, &1) == 0))

  @doc "Returns vertices with no outgoing edges."
  @spec sinks(t()) :: [any()]
  def sinks(%__MODULE__{graph: g}),
    do: Graph.vertices(g) |> Enum.filter(&(Graph.out_degree(g, &1) == 0))

  @doc """
  Returns the longest weighted path in the DAG and its total weight.

  ## Examples

      iex> Grafi.DAG.new()
      ...> |> Grafi.DAG.add_edges([
      ...>   {:a, :b, weight: 3.0},
      ...>   {:a, :c, weight: 1.0},
      ...>   {:b, :d, weight: 2.0},
      ...>   {:c, :d, weight: 10.0}
      ...> ])
      ...> |> Grafi.DAG.critical_path()
      {[:a, :c, :d], 11.0}
  """
  @spec critical_path(t()) :: {[any()], number()}
  def critical_path(%__MODULE__{graph: g} = dag) do
    case topological_sort(dag) do
      {:ok, sorted} ->
        src = sources(dag)
        dist = Map.new(sorted, &{&1, :neg_inf})
        dist = Enum.reduce(src, dist, &Map.put(&2, &1, 0))

        {dist, parent} =
          Enum.reduce(sorted, {dist, %{}}, fn u, acc ->
            relax_outgoing(g, u, acc)
          end)

        {end_v, max_d} =
          dist
          |> Enum.reject(fn {_, d} -> d == :neg_inf end)
          |> Enum.max_by(&elem(&1, 1), fn -> {nil, 0} end)

        {rebuild_path(parent, end_v, []), max_d}

      _ ->
        {[], 0}
    end
  end

  @doc "Returns the underlying Graph struct."
  @spec to_graph(t()) :: Graph.t()
  def to_graph(%__MODULE__{graph: g}), do: g

  # ── Internal ──────────────────────────────────────────────────────────

  # Longest-path relaxation for one source vertex `u` in critical_path/1.
  defp relax_outgoing(g, u, {d, p}) do
    if d[u] == :neg_inf do
      {d, p}
    else
      Enum.reduce(Graph.out_neighbors(g, u), {d, p}, fn v, acc ->
        relax_edge(g, u, v, acc)
      end)
    end
  end

  defp relax_edge(g, u, v, {d, p}) do
    w = Graph.edges_between(g, u, v) |> Enum.map(& &1.weight) |> Enum.max(fn -> 1.0 end)
    nd = d[u] + w

    if nd > d[v] or d[v] == :neg_inf,
      do: {Map.put(d, v, nd), Map.put(p, v, u)},
      else: {d, p}
  end

  defp topological_sort_graph(%Graph{} = g, opts) do
    case NIF.engine(g, opts) do
      :nif ->
        {_idx, csr} = Graph.to_csr(g)

        case NIF.call(NIF.nif_topological_sort(csr)) do
          {:ok, order} -> {:ok, Enum.map(order, &elem(csr.vertices, &1))}
          {:error, _} = error -> error
        end

      :elixir ->
        kahn(g)

      {:error, _} = error ->
        error
    end
  end

  # Kahn's algorithm with ties broken by vertex term order, which is exactly
  # igraph_topological_sorting's order on the CSR built by Graph.to_csr/1
  # (vertex index = term order). Degrees count distinct neighbours, matching
  # one decrement per distinct successor.
  defp kahn(g) do
    vs = g |> Graph.vertices() |> Enum.sort()
    in_deg = Map.new(vs, &{&1, Graph.in_degree(g, &1)})
    sources = Enum.filter(vs, &(in_deg[&1] == 0))
    do_kahn(g, :queue.from_list(sources), in_deg, [], length(vs))
  end

  defp do_kahn(g, q, in_deg, acc, remaining) do
    case :queue.out(q) do
      {:empty, _} when remaining == 0 ->
        {:ok, Enum.reverse(acc)}

      {:empty, _} ->
        {:error, :has_cycle}

      {{:value, v}, q} ->
        {q, in_deg} =
          g
          |> Graph.out_neighbors(v)
          |> Enum.sort()
          |> Enum.reduce({q, in_deg}, fn n, {q, d} ->
            d = Map.update!(d, n, &(&1 - 1))
            if d[n] == 0, do: {:queue.in(n, q), d}, else: {q, d}
          end)

        do_kahn(g, q, in_deg, [v | acc], remaining - 1)
    end
  end

  defp rebuild_path(_, nil, path), do: path
  defp rebuild_path(parent, v, path), do: rebuild_path(parent, Map.get(parent, v), [v | path])

  defimpl Inspect do
    def inspect(%Grafi.DAG{graph: g}, _),
      do: "#Grafi.DAG<V: #{g.num_vertices}, E: #{g.num_edges}>"
  end
end

defmodule Grafi.CycleError do
  defexception [:message]
end
