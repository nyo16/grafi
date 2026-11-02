defmodule Grafi.Algo.InvariantsPropertyTest do
  @moduledoc """
  Invariants every algorithm must keep on any graph: generated graphs may be
  empty, disconnected, and have self-loops and parallel edges.
  """
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias Grafi.{DAG, Graph}
  alias Grafi.Algo.{Cycles, Isomorphism, KCore, ShortestPath, Traversal}
  alias Grafi.Test.Generators

  defp sorted_vertices(g), do: g |> Graph.vertices() |> Enum.sort()

  # Members of `parts` cover V exactly once.
  defp assert_partition(parts, g) do
    members = Enum.concat(parts)
    assert Enum.sort(members) == sorted_vertices(g)
    assert length(members) == length(Enum.uniq(members))
    assert Enum.all?(parts, &(&1 != []))
  end

  # `g` without self-loops and parallel edges (isomorphism and k-core work on
  # simple graphs).
  defp simple(g) do
    base = Graph.add_vertices(Graph.new(type: g.type), Graph.vertices(g))

    g
    |> Graph.edges()
    |> Enum.reject(&(&1.from == &1.to))
    |> Enum.uniq_by(fn %{from: f, to: t} ->
      if g.type == :undirected, do: Enum.sort([f, t]), else: {f, t}
    end)
    |> Enum.reduce(base, &Graph.add_edge(&2, &1.from, &1.to, weight: &1.weight))
  end

  # `g` with every edge oriented from the smaller to the larger vertex (in
  # term order), which is acyclic.
  defp acyclic(g) do
    base = Graph.add_vertices(Graph.new(), Graph.vertices(g))

    g
    |> Graph.edges()
    |> Enum.reject(&(&1.from == &1.to))
    |> Enum.reduce(base, fn %{from: f, to: t}, acc ->
      {a, b} = if f < t, do: {f, t}, else: {t, f}
      Graph.add_edge(acc, a, b)
    end)
  end

  property "strongly connected components partition V" do
    check all(g <- Generators.graph(type: :directed)) do
      assert_partition(Cycles.strongly_connected_components(g), g)
    end
  end

  property "vertices in one SCC reach each other, and SCCs are maximal" do
    check all(g <- Generators.graph(type: :directed, max_vertices: 8)) do
      sccs = Cycles.strongly_connected_components(g)
      scc_of = for scc <- sccs, v <- scc, into: %{}, do: {v, scc}

      for u <- Graph.vertices(g), v <- Graph.vertices(g) do
        mutual? = Traversal.reachable?(g, u, v) and Traversal.reachable?(g, v, u)
        assert mutual? == (scc_of[u] == scc_of[v])
      end
    end
  end

  property "weak components partition V and no edge crosses two of them" do
    check all(g <- Generators.graph()) do
      components = Cycles.connected_components(g)
      assert_partition(components, g)

      index = for {c, i} <- Enum.with_index(components), v <- c, into: %{}, do: {v, i}
      assert Enum.all?(Graph.edges(g), &(index[&1.from] == index[&1.to]))
    end
  end

  property "a topological order lists every vertex once and respects every edge" do
    check all(g <- map(Generators.graph(type: :directed), &acyclic/1)) do
      {:ok, order} = Traversal.topological_sort(g)
      assert Enum.sort(order) == sorted_vertices(g)

      position = order |> Enum.with_index() |> Map.new()
      assert Enum.all?(Graph.edges(g), &(position[&1.from] < position[&1.to]))

      assert {:ok, ^order} = g |> DAG.from_graph!() |> DAG.topological_sort(engine: :elixir)
    end
  end

  property "a graph with a cycle has no topological order" do
    check all(g <- Generators.graph(type: :directed)) do
      case Traversal.topological_sort(g) do
        {:ok, _order} -> refute Cycles.has_cycle?(g)
        {:error, :has_cycle} -> assert Cycles.has_cycle?(g)
      end
    end
  end

  property "a graph is isomorphic to a relabelled copy of itself" do
    check all(g <- map(Generators.graph(max_vertices: 8, max_edges: 14), &simple/1)) do
      mapping = g |> Graph.vertices() |> Enum.with_index() |> Map.new()
      base = Graph.add_vertices(Graph.new(type: g.type), Map.values(mapping))

      relabelled =
        Enum.reduce(Graph.edges(g), base, &Graph.add_edge(&2, mapping[&1.from], mapping[&1.to]))

      for engine <- [:elixir, :auto] do
        assert Isomorphism.isomorphic?(g, relabelled, engine: engine)
      end
    end
  end

  property "Bellman-Ford and Dijkstra agree on non-negative weights" do
    check all(g <- Generators.graph(), g = non_negative(g), source <- source(g)) do
      if source != :none do
        {:ok, bf} = ShortestPath.bellman_ford(g, source)
        dijkstra = ShortestPath.dijkstra_all(g, source)

        assert Map.keys(bf) |> Enum.sort() == Map.keys(dijkstra) |> Enum.sort()

        for {v, d} <- dijkstra,
            do: assert_in_delta(bf[v], d, 1.0e-9 * max(1.0, abs(d)), inspect(v))
      end
    end
  end

  property "every vertex of the k-core has degree at least k inside it" do
    check all(g <- map(Generators.graph(type: :undirected), &simple/1), k <- integer(0..4)) do
      core = KCore.k_core(g, k)
      assert Enum.all?(Graph.vertices(core), &(Graph.degree(core, &1) >= k))

      # Maximal: every vertex outside the core has core number below k.
      numbers = KCore.core_numbers(g)

      for v <- Graph.vertices(g) do
        assert Graph.has_vertex?(core, v) == numbers[v] >= k
      end
    end
  end

  defp non_negative(g) do
    base = Graph.add_vertices(Graph.new(type: g.type), Graph.vertices(g))
    Enum.reduce(Graph.edges(g), base, &Graph.add_edge(&2, &1.from, &1.to, weight: abs(&1.weight)))
  end

  defp source(g) do
    case Graph.vertices(g) do
      [] -> constant(:none)
      vs -> member_of(vs)
    end
  end
end
