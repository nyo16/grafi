defmodule Grafi.EngineErrorsTest do
  # The error policy shared by both engines (see Grafi.NIF): invalid options
  # raise ArgumentError before dispatch, data errors return the same error on
  # either engine, and igraph failures never take the VM down.
  use ExUnit.Case, async: true

  alias Grafi.Algo.{Centrality, Community, Cycles, Isomorphism, ShortestPath}
  alias Grafi.{DAG, Generators, Graph, NIF}

  @engines [:nif, :elixir]

  defp undirected(edges), do: Graph.new(type: :undirected) |> Graph.add_edges(edges)

  defp two_k4s do
    k4 = fn off -> for i <- 0..2, j <- (i + 1)..3, do: {i + off, j + off} end
    undirected(k4.(0) ++ k4.(10))
  end

  defp negative_graph(type) do
    Graph.new(type: type) |> Graph.add_edges([{:a, :b, weight: -1.0}, {:b, :c, weight: 2.0}])
  end

  describe "invalid options raise ArgumentError on both engines" do
    for engine <- @engines do
      @engine engine

      test "pagerank damping: 1.5 (#{engine})" do
        assert_raise ArgumentError, ~r/:damping/, fn ->
          Centrality.pagerank(two_k4s(), damping: 1.5, engine: @engine)
        end
      end

      test "pagerank iterations: 0 (#{engine})" do
        assert_raise ArgumentError, ~r/:iterations/, fn ->
          Centrality.pagerank(two_k4s(), iterations: 0, engine: @engine)
        end
      end

      test "leiden resolution: 0.0 (#{engine})" do
        assert_raise ArgumentError, ~r/:resolution/, fn ->
          Community.leiden(two_k4s(), resolution: 0.0, engine: @engine)
        end
      end

      test "leiden unknown objective (#{engine})" do
        assert_raise ArgumentError, ~r/:objective/, fn ->
          Community.leiden(two_k4s(), objective: :surprise, engine: @engine)
        end
      end

      test "betweenness weighted: \"yes\" (#{engine})" do
        assert_raise ArgumentError, ~r/:weighted/, fn ->
          Centrality.betweenness(two_k4s(), weighted: "yes", engine: @engine)
        end
      end

      test "isomorphism timeout: 0 (#{engine})" do
        assert_raise ArgumentError, ~r/:timeout/, fn ->
          Isomorphism.isomorphic?(two_k4s(), two_k4s(), timeout: 0, engine: @engine)
        end
      end

      test "isomorphism timeout above 0xFFFFFFFF ms (#{engine})" do
        for t <- [2 ** 63, 0x1_0000_0000] do
          assert_raise ArgumentError, ~r/:timeout/, fn ->
            Isomorphism.isomorphic?(two_k4s(), two_k4s(), timeout: t, engine: @engine)
          end
        end
      end
    end

    test "unknown :engine" do
      assert_raise ArgumentError, ~r/:engine/, fn ->
        Centrality.pagerank(two_k4s(), engine: :gpu)
      end

      assert_raise ArgumentError, ~r/:engine/, fn ->
        ShortestPath.dijkstra(two_k4s(), 0, 1, engine: :gpu)
      end
    end

    # Each call below hits an early return that skips engine dispatch.
    test "unknown :engine raises even on early-return paths" do
      single = Graph.new() |> Graph.add_vertex(:a)
      empty = Graph.new(type: :undirected)

      calls = [
        fn -> Centrality.closeness(single, engine: :gpu) end,
        fn -> ShortestPath.dijkstra(two_k4s(), 0, :missing, engine: :gpu) end,
        fn -> Isomorphism.isomorphic?(two_k4s(), undirected([{:a, :b}]), engine: :gpu) end,
        fn -> Isomorphism.isomorphism(two_k4s(), undirected([{:a, :b}]), engine: :gpu) end,
        fn -> Isomorphism.subgraph_isomorphic?(two_k4s(), empty, engine: :gpu) end,
        fn -> Isomorphism.subgraph_isomorphism(two_k4s(), empty, engine: :gpu) end,
        fn -> Isomorphism.count_subgraph_isomorphisms(two_k4s(), empty, engine: :gpu) end
      ]

      for call <- calls, do: assert_raise(ArgumentError, ~r/:engine/, call)
    end
  end

  describe "negative edge weights" do
    for engine <- @engines do
      @engine engine

      test "weighted centralities raise ArgumentError (#{engine})" do
        g = negative_graph(:directed)

        assert_raise ArgumentError, fn -> Centrality.pagerank(g, engine: @engine) end
        assert_raise ArgumentError, fn -> Centrality.closeness(g, engine: @engine) end

        assert_raise ArgumentError, fn ->
          Centrality.betweenness(g, weighted: true, engine: @engine)
        end
      end

      test "dijkstra returns {:error, :negative_weight} (#{engine})" do
        assert ShortestPath.dijkstra(negative_graph(:directed), :a, :c, engine: @engine) ==
                 {:error, :negative_weight}
      end
    end

    @tag :nif
    test "unweighted betweenness ignores weights, so negative weights are fine" do
      g = negative_graph(:directed)

      # Directed path a -> b -> c: b lies on the only a->c path.
      # Normalized by 1 / ((n - 1)(n - 2)) = 1/2.
      expected = %{a: 0.0, b: 0.5, c: 0.0}
      assert Centrality.betweenness(g, engine: :nif) == expected
      assert Centrality.betweenness(g, engine: :elixir) == expected
    end

    @tag :nif
    test "community detection returns {:error, :negative_weight}" do
      g = negative_graph(:undirected)

      assert Community.louvain(g) == {:error, :negative_weight}
      assert Community.leiden(g) == {:error, :negative_weight}
      assert Community.label_propagation(g) == {:error, :negative_weight}
    end

    # The C++ guards also protect callers of the raw NIF functions; igraph
    # itself silently accepts negative PageRank and Leiden weights.
    @tag :nif
    test "raw NIF calls reject negative weights" do
      {_, csr} = Graph.to_csr(negative_graph(:directed))

      assert NIF.nif_pagerank(csr, 0.85, 100) == {:error, :negative_weight}
      assert NIF.nif_closeness(csr) == {:error, :non_positive_weight}
      assert NIF.nif_betweenness(csr, true, true) == {:error, :non_positive_weight}
      assert NIF.nif_dijkstra(csr, 0, 2) == {:error, :negative_weight}

      {_, undirected_csr} = Graph.to_csr(negative_graph(:undirected))
      assert NIF.nif_leiden(undirected_csr, 1.0, :modularity) == {:error, :negative_weight}
    end
  end

  describe "zero edge weights" do
    # Closeness and weighted betweenness need positive weights; PageRank and
    # Dijkstra stay well-defined at zero.
    defp zero_graph do
      Graph.new(type: :directed) |> Graph.add_edges([{:a, :b, weight: 0.0}, {:b, :c, weight: 2.0}])
    end

    test "closeness and weighted betweenness reject a zero weight before dispatch" do
      for engine <- @engines do
        assert_raise ArgumentError, ~r/positive edge weights/, fn ->
          Centrality.closeness(zero_graph(), engine: engine)
        end

        assert_raise ArgumentError, ~r/positive edge weights/, fn ->
          Centrality.betweenness(zero_graph(), weighted: true, engine: engine)
        end
      end
    end

    @tag :nif
    test "unweighted betweenness, PageRank and Dijkstra accept a zero weight on both engines" do
      g = zero_graph()

      for engine <- @engines do
        # Directed path a -> b -> c, normalized by 1/2 as above.
        assert Centrality.betweenness(g, engine: engine) == %{a: 0.0, b: 0.5, c: 0.0}
        assert abs(Enum.sum(Map.values(Centrality.pagerank(g, engine: engine))) - 1.0) < 1.0e-9
        assert ShortestPath.dijkstra(g, :a, :c, engine: engine) == {:ok, {[:a, :b, :c], 2.0}}
      end
    end

    @tag :nif
    test "raw NIF calls reject a zero weight only where it is undefined" do
      {_, csr} = Graph.to_csr(zero_graph())

      assert NIF.nif_closeness(csr) == {:error, :non_positive_weight}
      assert NIF.nif_betweenness(csr, true, true) == {:error, :non_positive_weight}
      assert NIF.nif_betweenness(csr, false, true) == [0.0, 0.5, 0.0]
      assert NIF.nif_dijkstra(csr, 0, 2) == {:ok, [0, 1, 2], 2.0}
    end
  end

  describe "community detection" do
    # V1: directed Louvain used to abort the whole VM (exit 134).
    @tag :nif
    test "directed graphs return {:error, :directed_unsupported}" do
      g = Graph.new(type: :directed) |> Graph.add_edges([{:a, :b}, {:b, :c}])

      assert Community.louvain(g) == {:error, :directed_unsupported}
      assert Community.leiden(g) == {:error, :directed_unsupported}
    end

    @tag :nif
    test "integer resolution is accepted" do
      assert {:ok, %{n_communities: 2}} = Community.leiden(two_k4s(), resolution: 2)
    end
  end

  describe "VF2 timeout" do
    # A dense host and a K14 pattern take seconds to refute exhaustively.
    setup do
      %{
        host: Generators.erdos_renyi(40, 0.5, seed: 42, type: :undirected),
        pattern: Generators.complete(14, type: :undirected)
      }
    end

    for engine <- @engines do
      @engine engine
      if engine == :nif, do: @tag(:nif)

      test "times out on every function (#{engine})", %{host: host, pattern: pattern} do
        opts = [timeout: 20, engine: @engine]

        assert_raise Grafi.TimeoutError, ~r/20 ms/, fn ->
          Isomorphism.subgraph_isomorphic?(host, pattern, opts)
        end

        assert Isomorphism.subgraph_isomorphism(host, pattern, opts) == {:error, :timeout}
        assert Isomorphism.count_subgraph_isomorphisms(host, pattern, opts) == {:error, :timeout}
      end

      # Two random 3-regular graphs share vertex count, edge count and degree
      # sequence, so no invariant short-circuits the search. VF2 refutation
      # time on such pairs is heavy-tailed: in a 2026-11 probe (igraph 1.0.1,
      # OTP 28) seeds 1/2 ran for more than 3 s on both engines, while n = 80
      # was refuted by igraph in 1 ms. If an igraph, OTP or generator change
      # makes this instance easy, try a larger n or other seeds.
      if engine == :nif, do: @tag(:nif)

      test "isomorphic?/3 and isomorphism/3 time out (#{engine})" do
        a = Generators.random_regular(200, 3, seed: 1, type: :undirected)
        b = Generators.random_regular(200, 3, seed: 2, type: :undirected)
        opts = [timeout: 20, engine: @engine]

        assert_raise Grafi.TimeoutError, ~r/20 ms/, fn -> Isomorphism.isomorphic?(a, b, opts) end
        assert Isomorphism.isomorphism(a, b, opts) == {:error, :timeout}
      end
    end

    # Raw-NIF backstop: a timeout too large for steady_clock means no deadline
    # instead of an overflowed (already passed) one. 0xFFFFFFFF ms is the
    # largest value that still sets a deadline. The deadline is only checked
    # every 1024 compat callbacks, and mapping each vertex costs at least
    # one, so more than 1024 vertices is the deterministic stand-in for
    # "the check actually runs" (no wall-clock assertion).
    @tag :nif
    test "raw VF2 NIF honours the largest deadline and treats anything above it as none" do
      g = Generators.erdos_renyi(1500, 4 / 1500, seed: 1, type: :undirected)
      assert Graph.num_vertices(g) > 1024
      {_, csr} = Graph.to_csr(g)

      for t <- [0xFFFF_FFFF, 0x1_0000_0000, 2 ** 63 - 1] do
        assert NIF.nif_isomorphic_vf2(csr, csr, t) == {:ok, true}
      end
    end
  end

  test "NIF.call/1 tags unexpected igraph messages" do
    assert NIF.call({:error, "igraph error in x: boom"}) ==
             {:error, {:igraph, "igraph error in x: boom"}}

    assert NIF.call({:error, :negative_weight}) == {:error, :negative_weight}
  end

  # Passed via the context: with a literal argument the type checker proves
  # `call!/1` always raises and warns.
  @tag result: {:error, "boom"}
  test "NIF.call!/1 raises Grafi.NIFError carrying the tagged igraph message", %{result: result} do
    assert_raise Grafi.NIFError, ~r/\{:igraph, "boom"\}/, fn -> NIF.call!(result) end
  end

  # Run only without the NIF (GRAFI_NIF_ENABLED=false or igraph missing).
  describe "engine: :nif without the NIF" do
    @describetag :no_nif

    test "functions without an error return raise Grafi.NIFError" do
      g = two_k4s()

      assert_raise Grafi.NIFError, ~r/nif_not_available/, fn ->
        Centrality.pagerank(g, engine: :nif)
      end

      assert_raise Grafi.NIFError, ~r/nif_not_available/, fn ->
        Cycles.strongly_connected_components(g, engine: :nif)
      end

      assert_raise Grafi.NIFError, ~r/nif_not_available/, fn ->
        Isomorphism.isomorphic?(g, g, engine: :nif)
      end

      assert_raise Grafi.NIFError, ~r/nif_not_available/, fn ->
        Isomorphism.subgraph_isomorphic?(g, g, engine: :nif)
      end
    end

    test "functions with an error return report {:error, :nif_not_available}" do
      g = two_k4s()
      dag = DAG.from_graph!(Graph.new() |> Graph.add_edges([{:a, :b}, {:b, :c}]))

      assert ShortestPath.dijkstra(g, 0, 1, engine: :nif) == {:error, :nif_not_available}
      assert Isomorphism.isomorphism(g, g, engine: :nif) == {:error, :nif_not_available}
      assert DAG.topological_sort(dag, engine: :nif) == {:error, :nif_not_available}
    end
  end

  # The C++ structural validator, reached through the raw NIF so the Elixir
  # side cannot pre-empt it. The base map is a valid directed edge 0 -> 1.
  describe "CSR validator (raw NIF)" do
    @describetag :nif

    defp i64(list), do: for(x <- list, into: <<>>, do: <<x::signed-native-64>>)

    defp raw_csr(overrides) do
      Map.merge(
        %{
          row_offsets: i64([0, 1, 1]),
          col_indices: i64([1]),
          weights: <<1.0::float-native-64>>,
          n_vertices: 2,
          directed: true
        },
        Map.new(overrides)
      )
    end

    test "the base map is valid: two singleton components" do
      assert NIF.nif_scc(raw_csr([])) == {[0, 1], 2}
    end

    test "a row_offsets that is not a whole number of int64s is a badarg" do
      assert NIF.nif_scc(raw_csr(row_offsets: <<0::56>>)) == {:error, :badarg_row_offsets}
      assert NIF.nif_scc(raw_csr(row_offsets: [0, 1, 1])) == {:error, :badarg_row_offsets}
    end

    test "structurally inconsistent maps are :invalid_csr" do
      nan = <<0x7FF8000000000001::unsigned-native-64>>

      for overrides <- [
            [n_vertices: 3],
            [row_offsets: i64([1, 1, 1])],
            [row_offsets: i64([0, 2, 1])],
            [col_indices: i64([5])],
            [weights: nan],
            [n_vertices: 2 ** 62, row_offsets: i64([0]), col_indices: <<>>, weights: <<>>],
            [row_offsets: i64([0, 1, 2])],
            [weights: <<>>]
          ] do
        assert NIF.nif_scc(raw_csr(overrides)) == {:error, :invalid_csr}, inspect(overrides)
      end
    end
  end
end
