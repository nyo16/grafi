defmodule Grafi.DAG do
  @moduledoc """
  A Directed Acyclic Graph with runtime cycle prevention.

  Every edge addition that would introduce a cycle raises `Grafi.CycleError`.

      iex> dag = Grafi.DAG.new()
      ...>   |> Grafi.DAG.add_edge(:compile, :test)
      ...>   |> Grafi.DAG.add_edge(:test, :deploy)
      iex> Grafi.DAG.topological_sort(dag)
      {:ok, [:compile, :test, :deploy]}
  """

  alias Grafi.Graph

  @type t :: %__MODULE__{graph: Graph.t()}
  defstruct [:graph]

  @spec new() :: t()
  def new, do: %__MODULE__{graph: Graph.new(type: :directed)}

  @spec from_graph(Graph.t()) :: {:ok, t()} | {:error, :has_cycle | :must_be_directed}
  def from_graph(%Graph{type: :undirected}), do: {:error, :must_be_directed}
  def from_graph(%Graph{type: :directed} = g) do
    case topological_sort_graph(g) do
      {:ok, _} -> {:ok, %__MODULE__{graph: g}}
      {:error, _} -> {:error, :has_cycle}
    end
  end

  @spec from_graph!(Graph.t()) :: t()
  def from_graph!(g) do
    case from_graph(g) do
      {:ok, dag} -> dag
      {:error, r} -> raise Grafi.CycleError, message: "cannot create DAG: #{r}"
    end
  end

  @spec add_vertex(t(), any(), keyword()) :: t()
  def add_vertex(%__MODULE__{graph: g} = dag, v, opts \\ []),
    do: %{dag | graph: Graph.add_vertex(g, v, opts)}

  @spec add_edge(t(), any(), any(), keyword()) :: t()
  def add_edge(%__MODULE__{graph: g} = dag, v1, v2, opts \\ []) do
    if v1 == v2,
      do: raise(Grafi.CycleError, message: "self-loop: #{inspect(v1)}")

    if Graph.has_vertex?(g, v2) and Graph.has_vertex?(g, v1) do
      if Grafi.Algo.Traversal.reachable?(g, v2, v1),
        do: raise(Grafi.CycleError, message: "#{inspect(v1)} -> #{inspect(v2)} would create a cycle")
    end

    %{dag | graph: Graph.add_edge(g, v1, v2, opts)}
  end

  @spec add_edges(t(), list()) :: t()
  def add_edges(%__MODULE__{} = dag, edges) do
    Enum.reduce(edges, dag, fn
      {a, b}, acc -> add_edge(acc, a, b)
      {a, b, o}, acc -> add_edge(acc, a, b, o)
    end)
  end

  @spec topological_sort(t()) :: {:ok, [any()]} | {:error, :has_cycle}
  def topological_sort(%__MODULE__{graph: g}), do: topological_sort_graph(g)

  @spec layers(t()) :: %{non_neg_integer() => [any()]}
  def layers(%__MODULE__{graph: g} = dag) do
    case topological_sort(dag) do
      {:ok, sorted} ->
        {layer_map, _} =
          Enum.reduce(sorted, {%{}, %{}}, fn v, {lm, vl} ->
            preds = Graph.in_neighbors(g, v)
            layer = if preds == [], do: 0, else: (Enum.map(preds, &Map.get(vl, &1, 0)) |> Enum.max()) + 1
            {Map.update(lm, layer, [v], &(&1 ++ [v])), Map.put(vl, v, layer)}
          end)
        layer_map
      _ -> %{}
    end
  end

  @spec sources(t()) :: [any()]
  def sources(%__MODULE__{graph: g}),
    do: Graph.vertices(g) |> Enum.filter(&(Graph.in_degree(g, &1) == 0))

  @spec sinks(t()) :: [any()]
  def sinks(%__MODULE__{graph: g}),
    do: Graph.vertices(g) |> Enum.filter(&(Graph.out_degree(g, &1) == 0))

  @spec critical_path(t()) :: {[any()], number()}
  def critical_path(%__MODULE__{graph: g} = dag) do
    case topological_sort(dag) do
      {:ok, sorted} ->
        src = sources(dag)
        dist = Map.new(sorted, &{&1, :neg_inf})
        dist = Enum.reduce(src, dist, &Map.put(&2, &1, 0))

        {dist, parent} =
          Enum.reduce(sorted, {dist, %{}}, fn u, {d, p} ->
            if d[u] == :neg_inf, do: {d, p}, else:
              Graph.out_neighbors(g, u)
              |> Enum.reduce({d, p}, fn v, {d2, p2} ->
                w = Graph.edges_between(g, u, v) |> Enum.map(& &1.weight) |> Enum.max(fn -> 1.0 end)
                nd = d2[u] + w
                if nd > d2[v] or d2[v] == :neg_inf,
                  do: {Map.put(d2, v, nd), Map.put(p2, v, u)},
                  else: {d2, p2}
              end)
          end)

        {end_v, max_d} = dist |> Enum.reject(fn {_, d} -> d == :neg_inf end) |> Enum.max_by(&elem(&1, 1), fn -> {nil, 0} end)
        {rebuild_path(parent, end_v, []), max_d}
      _ -> {[], 0}
    end
  end

  @spec to_graph(t()) :: Graph.t()
  def to_graph(%__MODULE__{graph: g}), do: g

  # ── Internal ──────────────────────────────────────────────────────────

  defp topological_sort_graph(%Graph{} = g) do
    in_deg = Graph.vertices(g) |> Map.new(&{&1, Graph.in_degree(g, &1)})
    queue = for {v, 0} <- in_deg, do: v
    kahn(g, queue, in_deg, [])
  end

  defp kahn(_g, [], in_deg, result) do
    if Enum.any?(in_deg, fn {_, d} -> d > 0 end),
      do: {:error, :has_cycle},
      else: {:ok, Enum.reverse(result)}
  end

  defp kahn(g, [v | rest], in_deg, result) do
    {adds, in_deg} =
      Graph.out_neighbors(g, v)
      |> Enum.reduce({[], in_deg}, fn n, {a, d} ->
        nd = d[n] - 1
        d = Map.put(d, n, nd)
        if nd == 0, do: {[n | a], d}, else: {a, d}
      end)

    kahn(g, rest ++ Enum.reverse(adds), Map.put(in_deg, v, -1), [v | result])
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
