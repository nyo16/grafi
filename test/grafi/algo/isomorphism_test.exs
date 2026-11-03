defmodule Grafi.Algo.IsomorphismTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias Grafi.Algo.Isomorphism
  alias Grafi.Graph

  doctest Grafi.Algo.Isomorphism

  # ── Builders ──────────────────────────────────────────────────────────

  defp k(n, opts \\ []) do
    type = Keyword.get(opts, :type, :undirected)

    Graph.new(type: type)
    |> Graph.add_edges(for(i <- 1..n, j <- (i + 1)..n//1, do: {i, j}))
  end

  defp path(labels, opts \\ []) do
    type = Keyword.get(opts, :type, :undirected)
    edges = labels |> Enum.chunk_every(2, 1, :discard) |> Enum.map(fn [a, b] -> {a, b} end)
    Graph.new(type: type) |> Graph.add_edges(edges)
  end

  defp triangle(opts \\ []) do
    type = Keyword.get(opts, :type, :undirected)
    Graph.new(type: type) |> Graph.add_edges([{:a, :b}, {:b, :c}, {:c, :a}])
  end

  # Verify that a mapping is a valid isomorphism from g1 to g2.
  defp valid_iso?(g1, g2, mapping) do
    Graph.num_vertices(g1) == map_size(mapping) and
      Enum.all?(Graph.vertices(g1), &Map.has_key?(mapping, &1)) and
      Enum.uniq(Map.values(mapping)) |> length() == map_size(mapping) and
      Enum.all?(Graph.edges(g1), fn e ->
        Graph.has_edge?(g2, mapping[e.from], mapping[e.to])
      end) and
      Enum.all?(Graph.edges(g2), fn e ->
        rev = Map.new(mapping, fn {k, v} -> {v, k} end)
        Graph.has_edge?(g1, rev[e.from], rev[e.to])
      end)
  end

  # Every pattern edge maps onto a host edge, and the mapping is injective.
  defp valid_subiso?(host, pattern, mapping) do
    map_size(mapping) == Graph.num_vertices(pattern) and
      mapping |> Map.values() |> Enum.uniq() |> length() == map_size(mapping) and
      Enum.all?(Graph.edges(pattern), &Graph.has_edge?(host, mapping[&1.from], mapping[&1.to]))
  end

  # The whole suite runs once per engine; the :nif pass is skipped when the
  # NIF is unavailable (see test_helper.exs).
  for engine <- [:nif, :elixir] do
    @opts [engine: engine]

    describe "#{engine} engine: isomorphic?/3" do
      if engine == :nif, do: @describetag(:nif)

      test "two K_3 graphs are isomorphic" do
        a = triangle()
        b = Graph.new(type: :undirected) |> Graph.add_edges([{1, 2}, {2, 3}, {3, 1}])
        assert Isomorphism.isomorphic?(a, b, @opts) == true
      end

      test "K_3 and P_3 are not isomorphic" do
        assert Isomorphism.isomorphic?(triangle(), path([:x, :y, :z]), @opts) == false
      end

      test "K_3 and K_4 are not isomorphic (vertex-count mismatch)" do
        assert Isomorphism.isomorphic?(triangle(), k(4), @opts) == false
      end

      test "C_6 and two disjoint triangles share a degree sequence but are not isomorphic" do
        c6 = Graph.new(type: :undirected) |> Graph.add_edges(for i <- 0..5, do: {i, rem(i + 1, 6)})

        two_triangles =
          Graph.new(type: :undirected)
          |> Graph.add_edges([{:a, :b}, {:b, :c}, {:c, :a}, {:x, :y}, {:y, :z}, {:z, :x}])

        assert Isomorphism.isomorphic?(c6, two_triangles, @opts) == false
      end

      test "g is isomorphic to itself" do
        g =
          Graph.new(type: :undirected)
          |> Graph.add_edges([{1, 2}, {2, 3}, {3, 4}, {4, 1}, {1, 3}])

        assert Isomorphism.isomorphic?(g, g, @opts) == true
      end

      test "two empty graphs are isomorphic" do
        assert Isomorphism.isomorphic?(
                 Graph.new(type: :undirected),
                 Graph.new(type: :undirected),
                 @opts
               ) == true
      end

      test "two singleton graphs are isomorphic" do
        a = Graph.new(type: :undirected) |> Graph.add_vertex(:x)
        b = Graph.new(type: :undirected) |> Graph.add_vertex(1)
        assert Isomorphism.isomorphic?(a, b, @opts) == true
      end

      test "raises on mismatched directedness" do
        a = Graph.new(type: :directed) |> Graph.add_edges([{:a, :b}])
        b = Graph.new(type: :undirected) |> Graph.add_edges([{:a, :b}])
        assert_raise ArgumentError, ~r/same type/, fn -> Isomorphism.isomorphic?(a, b, @opts) end
      end

      test "directed: cycle vs relabelled cycle" do
        a = Graph.new() |> Graph.add_edges([{:a, :b}, {:b, :c}, {:c, :a}])
        b = Graph.new() |> Graph.add_edges([{1, 2}, {2, 3}, {3, 1}])
        assert Isomorphism.isomorphic?(a, b, @opts) == true
      end

      test "directed: a 3-cycle is not isomorphic to a transitive triangle" do
        cycle = Graph.new() |> Graph.add_edges([{:a, :b}, {:b, :c}, {:c, :a}])
        transitive = Graph.new() |> Graph.add_edges([{1, 2}, {2, 3}, {1, 3}])
        assert Isomorphism.isomorphic?(cycle, transitive, @opts) == false
      end
    end

    describe "#{engine} engine: isomorphism/3" do
      if engine == :nif, do: @describetag(:nif)

      test "returns a valid mapping on isomorphic graphs" do
        a = triangle()
        b = Graph.new(type: :undirected) |> Graph.add_edges([{10, 20}, {20, 30}, {30, 10}])

        assert {:ok, mapping} = Isomorphism.isomorphism(a, b, @opts)
        assert valid_iso?(a, b, mapping)
      end

      test "self-isomorphism mapping is valid" do
        g = Graph.new(type: :undirected) |> Graph.add_edges([{1, 2}, {2, 3}, {3, 4}])

        assert {:ok, mapping} = Isomorphism.isomorphism(g, g, @opts)
        assert valid_iso?(g, g, mapping)
      end

      test "returns {:error, :no_isomorphism} on non-isomorphic graphs" do
        assert Isomorphism.isomorphism(triangle(), path([:a, :b, :c]), @opts) ==
                 {:error, :no_isomorphism}
      end

      test "empty graphs map to empty mapping" do
        assert Isomorphism.isomorphism(
                 Graph.new(type: :undirected),
                 Graph.new(type: :undirected),
                 @opts
               ) == {:ok, %{}}
      end
    end

    describe "#{engine} engine: subgraph_isomorphic?/3" do
      if engine == :nif, do: @describetag(:nif)

      test "triangle is sub-isomorphic to K_4" do
        assert Isomorphism.subgraph_isomorphic?(k(4), triangle(), @opts) == true
      end

      test "K_4 is NOT sub-isomorphic to triangle" do
        assert Isomorphism.subgraph_isomorphic?(triangle(), k(4), @opts) == false
      end

      test "P_3 is sub-isomorphic to a longer path" do
        host = path([:a, :b, :c, :d, :e])
        assert Isomorphism.subgraph_isomorphic?(host, path([1, 2, 3]), @opts) == true
      end

      test "matching is not induced: P_3 is sub-isomorphic to K_3" do
        assert Isomorphism.subgraph_isomorphic?(triangle(), path([1, 2, 3]), @opts) == true
      end

      test "empty pattern always matches" do
        assert Isomorphism.subgraph_isomorphic?(triangle(), Graph.new(type: :undirected), @opts) ==
                 true
      end

      test "any graph contains itself" do
        assert Isomorphism.subgraph_isomorphic?(k(4), k(4), @opts) == true
      end

      test "directed: a directed path embeds in a directed 3-cycle" do
        cycle = triangle(type: :directed)

        assert Isomorphism.subgraph_isomorphic?(cycle, path([1, 2, 3], type: :directed), @opts) ==
                 true
      end

      test "directed: an in-star (two edges into one vertex) does not embed in a 3-cycle" do
        cycle = triangle(type: :directed)
        in_star = Graph.new() |> Graph.add_edges([{1, 2}, {3, 2}])
        assert Isomorphism.subgraph_isomorphic?(cycle, in_star, @opts) == false
      end
    end

    describe "#{engine} engine: subgraph_isomorphism/3" do
      if engine == :nif, do: @describetag(:nif)

      test "returns a valid pattern->host mapping" do
        host = k(4)
        pattern = triangle()

        assert {:ok, mapping} = Isomorphism.subgraph_isomorphism(host, pattern, @opts)
        assert valid_subiso?(host, pattern, mapping)
      end

      test "P_3 maps into K_3" do
        pattern = path([1, 2, 3])

        assert {:ok, mapping} = Isomorphism.subgraph_isomorphism(triangle(), pattern, @opts)
        assert valid_subiso?(triangle(), pattern, mapping)
      end

      test "directed: mapping respects edge direction" do
        host = Graph.new() |> Graph.add_edges([{:a, :b}, {:b, :c}, {:c, :d}])
        pattern = path([1, 2, 3], type: :directed)

        assert {:ok, mapping} = Isomorphism.subgraph_isomorphism(host, pattern, @opts)
        assert valid_subiso?(host, pattern, mapping)
      end

      test "returns {:error, :no_isomorphism} when pattern is larger" do
        assert Isomorphism.subgraph_isomorphism(triangle(), k(4), @opts) ==
                 {:error, :no_isomorphism}
      end
    end

    describe "#{engine} engine: count_subgraph_isomorphisms/3" do
      if engine == :nif, do: @describetag(:nif)

      test "triangle into K_4 yields 24 (4 triangles × 3! orderings)" do
        assert Isomorphism.count_subgraph_isomorphisms(k(4), triangle(), @opts) == {:ok, 24}
      end

      test "triangle into K_3 yields 6 (3! orderings)" do
        assert Isomorphism.count_subgraph_isomorphisms(triangle(), triangle(), @opts) == {:ok, 6}
      end

      test "P_3 into K_3 yields 6" do
        # Every ordered choice (a, b, c) of three distinct K_3 vertices is a
        # P_3, since any two are adjacent: 3·2·1 = 6.
        assert Isomorphism.count_subgraph_isomorphisms(triangle(), path([1, 2, 3]), @opts) ==
                 {:ok, 6}
      end

      test "directed P_3 into a directed 3-cycle yields 3 (one per start vertex)" do
        cycle = triangle(type: :directed)
        pattern = path([1, 2, 3], type: :directed)
        assert Isomorphism.count_subgraph_isomorphisms(cycle, pattern, @opts) == {:ok, 3}
      end

      test "pattern larger than host yields 0" do
        assert Isomorphism.count_subgraph_isomorphisms(triangle(), k(4), @opts) == {:ok, 0}
      end

      test "empty pattern yields 1" do
        assert Isomorphism.count_subgraph_isomorphisms(
                 triangle(),
                 Graph.new(type: :undirected),
                 @opts
               ) == {:ok, 1}
      end
    end
  end

  describe "options" do
    test "unknown options raise in every function, before any early return" do
      empty = Graph.new(type: :undirected)

      calls = [
        &Isomorphism.isomorphic?/3,
        &Isomorphism.subgraph_isomorphic?/3,
        &Isomorphism.isomorphism/3,
        &Isomorphism.subgraph_isomorphism/3,
        &Isomorphism.count_subgraph_isomorphisms/3,
        &Grafi.isomorphic?/3,
        &Grafi.subgraph_isomorphic?/3
      ]

      for call <- calls, {g, h} <- [{empty, empty}, {triangle(), k(4)}] do
        assert_raise ArgumentError, ~r/unknown keys \[:induced\]/, fn ->
          call.(g, h, engine: :elixir, induced: true)
        end
      end
    end
  end

  describe "elixir engine against brute force" do
    property "isomorphic?/3 and isomorphism/3 agree with trying every bijection" do
      check all({g1, g2} <- small_graph_pair(6, 6)) do
        expected = brute_isomorphic?(g1, g2)
        assert Isomorphism.isomorphic?(g1, g2, engine: :elixir) == expected

        case Isomorphism.isomorphism(g1, g2, engine: :elixir) do
          {:ok, mapping} -> assert expected and valid_iso?(g1, g2, mapping)
          {:error, :no_isomorphism} -> refute expected
        end
      end
    end

    property "count_subgraph_isomorphisms/3 counts every edge-preserving injection" do
      check all({pattern, host} <- small_graph_pair(4, 6)) do
        expected = brute_subiso_count(host, pattern)

        assert Isomorphism.count_subgraph_isomorphisms(host, pattern, engine: :elixir) ==
                 {:ok, expected}

        assert Isomorphism.subgraph_isomorphic?(host, pattern, engine: :elixir) == expected > 0

        case Isomorphism.subgraph_isomorphism(host, pattern, engine: :elixir) do
          {:ok, mapping} -> assert valid_subiso?(host, pattern, mapping)
          {:error, :no_isomorphism} -> assert expected == 0
        end
      end
    end

    # igraph's VF2 rejects self-loops, so the pairs here have none.
    @tag :nif
    property "the elixir and nif engines agree on loop-free graphs" do
      check all({g1, g2} <- small_graph_pair(6, 6, false)) do
        for {a, b} <- [{g1, g2}, {g2, g1}] do
          assert Isomorphism.isomorphic?(a, b, engine: :elixir) ==
                   Isomorphism.isomorphic?(a, b, engine: :nif)

          assert Isomorphism.count_subgraph_isomorphisms(a, b, engine: :elixir) ==
                   Isomorphism.count_subgraph_isomorphisms(a, b, engine: :nif)
        end
      end
    end

    test "a pattern self-loop maps only onto a host self-loop" do
      host = path([1, 2, 3])
      pattern = Graph.new(type: :undirected) |> Graph.add_edges([{:x, :x}, {:x, :y}])

      assert Isomorphism.count_subgraph_isomorphisms(host, pattern, engine: :elixir) == {:ok, 0}
      refute Isomorphism.subgraph_isomorphic?(host, pattern, engine: :elixir)

      looped = Graph.add_edge(host, 2, 2)

      assert Isomorphism.count_subgraph_isomorphisms(looped, pattern, engine: :elixir) ==
               {:ok, 2}
    end

    property "a graph is isomorphic to a shuffled relabelling of itself" do
      check all(g <- Grafi.Test.Generators.graph(max_vertices: 30, max_edges: 60, weights: false)) do
        h = shuffled_copy(g, :erlang.phash2(g))
        assert Isomorphism.isomorphic?(g, h, engine: :elixir)
        assert {:ok, mapping} = Isomorphism.isomorphism(g, h, engine: :elixir)
        assert valid_iso?(g, h, mapping)
      end
    end

    # 1 and 1.0 are distinct vertices. In each 7-cycle the edge opposite
    # the BFS root (0 or -1, the smallest key of its cycle) joins such a
    # pair, so the search meets it as a back edge, not a parent edge.
    # Comparing ids with `!=` dropped those back edges from the check, and
    # two 7-cycles "embedded" in a 14-cycle as two paths.
    test "back edges between 1 and 1.0 are checked like any other" do
      cycle = fn vs -> Enum.zip(vs, tl(vs) ++ [hd(vs)]) end

      two_c7 =
        Graph.new(type: :undirected)
        |> Graph.add_edges(cycle.([0, :a1, :a2, 1, 1.0, :a5, :a6]))
        |> Graph.add_edges(cycle.([-1, :b1, :b2, 2, 2.0, :b5, :b6]))

      c14 = Graph.new(type: :undirected) |> Graph.add_edges(cycle.(Enum.to_list(100..113)))

      refute Isomorphism.isomorphic?(two_c7, c14, engine: :elixir)
      assert Isomorphism.isomorphism(two_c7, c14, engine: :elixir) == {:error, :no_isomorphism}

      copy = shuffled_copy(two_c7, 7)
      assert {:ok, mapping} = Isomorphism.isomorphism(two_c7, copy, engine: :elixir)
      assert valid_iso?(two_c7, copy, mapping)
    end

    # Colour refinement used to run before the first deadline check, about
    # 2.5 s on two K_400 whatever the timeout. It now checks per vertex.
    @tag :slow
    test "the timeout also bounds the preprocessing on dense graphs" do
      {g, h} = {k(400), k(400)}

      {us, result} =
        :timer.tc(fn ->
          try do
            Isomorphism.isomorphic?(g, h, engine: :elixir, timeout: 50)
          rescue
            Grafi.TimeoutError -> :timeout
          end
        end)

      assert result in [true, :timeout]
      assert us < 1_000_000, "took #{div(us, 1000)} ms with a 50 ms timeout"
    end

    # Colour refinement splits random 3-regular graphs, which degrees cannot,
    # so the search barely backtracks: 4x the vertices costs about 5x as
    # much. Without it the search is exponential (n = 100 ran > 60 s).
    # Counted in reductions, which are deterministic for pure Elixir code.
    @tag :slow
    test "isomorphic?/3 scales near-linearly on random 3-regular graphs" do
      cost = fn n ->
        g = Grafi.Generators.random_regular(n, 3, seed: 1, type: :undirected)
        h = shuffled_copy(g, n)
        {:reductions, before} = Process.info(self(), :reductions)
        assert Isomorphism.isomorphic?(g, h, engine: :elixir, timeout: 30_000)
        {:reductions, after_} = Process.info(self(), :reductions)
        after_ - before
      end

      {small, large} = {cost.(126), cost.(504)}
      assert large < 8 * small, "4x the vertices took #{Float.round(large / small, 1)}x"
    end
  end

  describe "resolve_timeout/2 (the config :grafi, vf2_timeout path)" do
    test "an explicit :timeout wins over any config value, even an invalid one" do
      assert Isomorphism.resolve_timeout([timeout: 50], 1_000) == 50
      assert Isomorphism.resolve_timeout([timeout: :infinity], 1_000) == :infinity
      assert Isomorphism.resolve_timeout([timeout: 50], :bogus) == 50
    end

    test "the config value applies when :timeout is absent" do
      assert Isomorphism.resolve_timeout([], 1_000) == 1_000
      assert Isomorphism.resolve_timeout([], :infinity) == :infinity
    end

    test "an invalid config value raises ArgumentError naming the config key" do
      for bad <- [0, -1, 0x1_0000_0000, "5s", nil] do
        assert_raise ArgumentError, ~r/vf2_timeout/, fn -> Isomorphism.resolve_timeout([], bad) end
      end
    end

    test "the shipped vf2_timeout default is :infinity" do
      assert Application.fetch_env!(:grafi, :vf2_timeout) == :infinity
    end

    test "an explicit :timeout accepts both ends of the 1..0xFFFF_FFFF range" do
      assert Isomorphism.resolve_timeout([timeout: 1], nil) == 1
      assert Isomorphism.resolve_timeout([timeout: 0xFFFF_FFFF], nil) == 0xFFFF_FFFF
    end
  end

  # ── Brute force and generators ───────────────────────────────────────

  # Two graphs without parallel edges (and with self-loops if `loops?`) of
  # the same type, on 1..max1 and 1..max2 vertices.
  defp small_graph_pair(max1, max2, loops? \\ true) do
    gen all(
          type <- member_of([:undirected, :directed]),
          g1 <- small_graph(type, max1, loops?),
          g2 <- small_graph(type, max2, loops?)
        ) do
      {g1, g2}
    end
  end

  defp small_graph(type, max_n, loops?) do
    gen all(
          n <- integer(1..max_n),
          edges <- list_of({integer(0..(n - 1)), integer(0..(n - 1))}, max_length: 10)
        ) do
      edges =
        if type == :undirected,
          do: Enum.map(edges, fn {a, b} -> {min(a, b), max(a, b)} end),
          else: edges

      edges = if loops?, do: edges, else: Enum.reject(edges, fn {a, b} -> a == b end)

      Graph.new(type: type)
      |> Graph.add_vertices(Enum.to_list(0..(n - 1)))
      |> Graph.add_edges(Enum.uniq(edges))
    end
  end

  # The arcs of g under `rename`, both ways round for an undirected edge.
  defp arcs(g, rename) do
    for e <- Graph.edges(g),
        arc <-
          if(g.type == :undirected, do: [{e.from, e.to}, {e.to, e.from}], else: [{e.from, e.to}]),
        into: MapSet.new() do
      {rename.(elem(arc, 0)), rename.(elem(arc, 1))}
    end
  end

  defp brute_isomorphic?(g1, g2) do
    v1 = Graph.vertices(g1)
    target = arcs(g2, & &1)

    length(v1) == Graph.num_vertices(g2) and Graph.num_edges(g1) == Graph.num_edges(g2) and
      Enum.any?(permutations(Graph.vertices(g2)), fn perm ->
        m = Map.new(Enum.zip(v1, perm))
        arcs(g1, &Map.fetch!(m, &1)) == target
      end)
  end

  defp brute_subiso_count(host, pattern) do
    host_arcs = arcs(host, & &1)
    pv = Graph.vertices(pattern)

    host
    |> Graph.vertices()
    |> injections(length(pv))
    |> Enum.count(fn image ->
      m = Map.new(Enum.zip(pv, image))
      pattern |> arcs(&Map.fetch!(m, &1)) |> MapSet.subset?(host_arcs)
    end)
  end

  defp permutations(list), do: injections(list, length(list))

  # Every ordered choice of k distinct elements of list.
  defp injections(_list, 0), do: [[]]

  defp injections(list, k) do
    for x <- list, rest <- injections(list -- [x], k - 1), do: [x | rest]
  end

  # g with its vertices renamed by a random permutation, and its vertices
  # and edges inserted in a random order.
  defp shuffled_copy(g, seed) do
    :rand.seed(:exsss, {seed, 17, 29})
    vs = Graph.vertices(g)
    rename = vs |> Enum.zip(Enum.shuffle(vs)) |> Map.new(fn {a, b} -> {a, {:copy, b}} end)

    base =
      vs
      |> Enum.shuffle()
      |> Enum.reduce(Graph.new(type: g.type), &Graph.add_vertex(&2, rename[&1]))

    g
    |> Graph.edges()
    |> Enum.shuffle()
    |> Enum.reduce(base, &Graph.add_edge(&2, rename[&1.from], rename[&1.to]))
  end
end
