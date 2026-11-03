defmodule Grafi.Algo.InvariantsPropertyTest do
  @moduledoc """
  Invariants every algorithm must keep on any graph: generated graphs may be
  empty, disconnected, and have self-loops and parallel edges.
  """
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias Grafi.Algo.{Cycles, Isomorphism, KCore, ShortestPath, Traversal}
  alias Grafi.{DAG, Graph}
  alias Grafi.Test.Generators

  defp sorted_vertices(g), do: g |> Graph.vertices() |> Enum.sort()

  # `parts` cover V exactly once, in canonical order: each part sorted, parts
  # ordered by their smallest member.
  defp assert_partition(parts, g) do
    members = Enum.concat(parts)
    assert Enum.sort(members) == sorted_vertices(g)
    assert length(members) == length(Enum.uniq(members))
    assert Enum.all?(parts, &(&1 != []))
    assert parts == parts |> Enum.map(&Enum.sort/1) |> Enum.sort_by(&hd/1)
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

      # :auto uses the NIF when it is loaded: a NIF/Elixir parity check.
      assert {:ok, ^order} = g |> DAG.from_graph!() |> DAG.topological_sort(engine: :auto)
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

  property "an undirected graph has a cycle exactly when it is not a forest (E > V - C)" do
    check all(g <- Generators.graph(type: :undirected)) do
      forest_edges = Graph.num_vertices(g) - length(Cycles.connected_components(g))
      assert Cycles.has_cycle?(g) == Graph.num_edges(g) > forest_edges
    end
  end

  property "find_cycle returns a closed walk along real edges" do
    check all(g <- Generators.graph()) do
      case Cycles.find_cycle(g) do
        {:error, :no_cycle} ->
          refute Cycles.has_cycle?(g)

        {:ok, [first | _] = walk} ->
          assert Cycles.has_cycle?(g)
          assert List.last(walk) == first
          interior = Enum.drop(walk, -1)
          assert length(interior) == length(Enum.uniq(interior))

          for [a, b] <- Enum.chunk_every(walk, 2, 1, :discard),
              do: assert(Graph.edges_between(g, a, b) != [], "#{inspect(a)} -> #{inspect(b)}")

          # An undirected walk a, b, a needs two parallel edges, not one edge twice.
          with %Graph{type: :undirected} <- g, [a, b, a] when a != b <- walk do
            assert length(Graph.edges_between(g, a, b)) >= 2
          end
      end
    end
  end

  property "a graph is isomorphic to a shuffled relabelling of itself" do
    check all(
            g <- map(Generators.graph(max_vertices: 8, max_edges: 14), &simple/1),
            seed <- integer()
          ) do
      relabelled = shuffled_copy(g, seed)

      for engine <- [:elixir, :auto] do
        assert Isomorphism.isomorphic?(g, relabelled, engine: engine)
      end
    end
  end

  property "isomorphic? agrees with trying every bijection" do
    check all(
            type <- member_of([:directed, :undirected]),
            g1 <- map(Generators.graph(type: type, id_type: :integer, max_vertices: 5), &simple/1),
            g2 <- map(Generators.graph(type: type, id_type: :integer, max_vertices: 5), &simple/1)
          ) do
      expected = brute_isomorphic?(g1, g2)

      for engine <- [:elixir, :auto] do
        assert Isomorphism.isomorphic?(g1, g2, engine: engine) == expected
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

  property "the k-core is what repeatedly peeling vertices of degree below k leaves" do
    check all(g <- map(Generators.graph(type: :undirected), &simple/1), k <- integer(0..4)) do
      core = KCore.k_core(g, k)
      assert Enum.all?(Graph.vertices(core), &(Graph.degree(core, &1) >= k))
      assert sorted_vertices(core) == g |> peel(k) |> Enum.sort()
    end
  end

  # Vertices left after removing, until none is left, every vertex with fewer
  # than k neighbours among the remaining ones (an independent k-core oracle).
  defp peel(g, k) do
    nbrs = Map.new(Graph.vertices(g), &{&1, MapSet.new(Graph.neighbors(g, &1))})

    Stream.iterate(MapSet.new(Graph.vertices(g)), fn alive ->
      alive
      |> Enum.filter(&(MapSet.size(MapSet.intersection(nbrs[&1], alive)) >= k))
      |> MapSet.new()
    end)
    |> Stream.chunk_every(2, 1)
    |> Enum.find(fn [a, b] -> MapSet.equal?(a, b) end)
    |> hd()
    |> MapSet.to_list()
  end

  defp shuffled_copy(g, seed) do
    :rand.seed(:exsss, {seed, seed, seed})
    vs = Graph.vertices(g)
    mapping = vs |> Enum.zip(Enum.shuffle(0..(length(vs) - 1)//1)) |> Map.new()
    base = Graph.add_vertices(Graph.new(type: g.type), Map.values(mapping))
    Enum.reduce(Graph.edges(g), base, &Graph.add_edge(&2, mapping[&1.from], mapping[&1.to]))
  end

  defp edge_set(g, mapping) do
    g
    |> Graph.edges()
    |> Enum.map(fn %{from: f, to: t} ->
      {a, b} = {mapping[f], mapping[t]}
      if g.type == :undirected and b < a, do: {b, a}, else: {a, b}
    end)
    |> Enum.sort()
  end

  defp brute_isomorphic?(g1, g2) do
    vs1 = Graph.vertices(g1)
    vs2 = Graph.vertices(g2)
    target = edge_set(g2, Map.new(vs2, &{&1, &1}))

    length(vs1) == length(vs2) and
      Enum.any?(permutations(vs2), &(edge_set(g1, Map.new(Enum.zip(vs1, &1))) == target))
  end

  defp permutations([]), do: [[]]
  defp permutations(list), do: for(x <- list, rest <- permutations(list -- [x]), do: [x | rest])

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
