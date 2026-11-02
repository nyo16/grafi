defmodule Grafi.Algo.MaxFlowTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  doctest Grafi.Algo.MaxFlow

  alias Grafi.Algo.MaxFlow
  alias Grafi.Graph

  # ── Helpers ───────────────────────────────────────────────────────────

  # The classic 5-vertex network used in many textbooks. Max flow s→t = 5
  # (min cut {s} | rest = 3 + 2 = 5).
  defp classic_4 do
    Graph.new()
    |> Graph.add_edges([
      {:s, :a, weight: 3},
      {:s, :b, weight: 2},
      {:a, :b, weight: 2},
      {:a, :t, weight: 2},
      {:b, :t, weight: 3}
    ])
  end

  # CLRS Figure 26.1(a) — max flow = 23.
  # Vertices: s, v1, v2, v3, v4, t.
  # Capacities: s→v1: 16, s→v2: 13, v1→v3: 12, v2→v1: 4, v2→v4: 14,
  #             v3→v2: 9, v3→t: 20, v4→v3: 7, v4→t: 4.
  defp clrs_network do
    Graph.new()
    |> Graph.add_edges([
      {:s, :v1, weight: 16},
      {:s, :v2, weight: 13},
      {:v1, :v3, weight: 12},
      {:v2, :v1, weight: 4},
      {:v2, :v4, weight: 14},
      {:v3, :v2, weight: 9},
      {:v3, :t, weight: 20},
      {:v4, :v3, weight: 7},
      {:v4, :t, weight: 4}
    ])
  end

  defp sum_caps(g, edges) do
    Enum.reduce(edges, 0, fn {u, v}, acc ->
      g
      |> Graph.edges_between(u, v)
      |> Enum.reduce(acc, fn e, a -> a + e.weight end)
    end)
  end

  # Build a random small directed graph with integer capacities in [1, cap_max].
  # Vertex 0 is the source, n-1 is the sink. Density controls the number of
  # extra random edges added on top of a Hamiltonian path that guarantees
  # source→sink is reachable.
  defp random_network(n, density, cap_max, seed) do
    :rand.seed(:exsss, {seed, seed + 1, seed + 2})
    verts = Enum.to_list(0..(n - 1))
    g0 = Graph.new() |> Graph.add_vertices(verts)

    # Hamiltonian backbone so source can reach sink.
    g_back =
      Enum.reduce(0..(n - 2)//1, g0, fn i, acc ->
        w = :rand.uniform(cap_max)
        Graph.add_edge(acc, i, i + 1, weight: w)
      end)

    Enum.reduce(1..density//1, g_back, fn _, acc ->
      u = :rand.uniform(n) - 1
      v = :rand.uniform(n) - 1

      if u == v do
        acc
      else
        w = :rand.uniform(cap_max)
        Graph.add_edge(acc, u, v, weight: w)
      end
    end)
  end

  # ── Classic 4-vertex network ──────────────────────────────────────────

  describe "classic 4-vertex network: max flow = 5" do
    test "edmonds_karp" do
      assert {:ok, %{flow: 5, flows: flows}} = MaxFlow.edmonds_karp(classic_4(), :s, :t)
      assert is_map(flows)
      # All recorded flows must be positive.
      assert Enum.all?(flows, fn {_uv, f} -> f > 0 end)
    end

    test "dinic" do
      assert {:ok, %{flow: 5, flows: flows}} = MaxFlow.dinic(classic_4(), :s, :t)
      assert is_map(flows)
      assert Enum.all?(flows, fn {_uv, f} -> f > 0 end)
    end

    test "edmonds_karp and dinic agree on flow value" do
      {:ok, %{flow: ek}} = MaxFlow.edmonds_karp(classic_4(), :s, :t)
      {:ok, %{flow: dn}} = MaxFlow.dinic(classic_4(), :s, :t)
      assert ek == dn
    end

    test "flow conservation at intermediate vertices" do
      {:ok, %{flow: total, flows: flows}} = MaxFlow.dinic(classic_4(), :s, :t)

      # Flow leaving source minus flow entering source = total.
      leaving_s = flows |> Enum.filter(fn {{u, _}, _} -> u == :s end) |> Enum.map(&elem(&1, 1))
      assert Enum.sum(leaving_s) == total

      arriving_t = flows |> Enum.filter(fn {{_, v}, _} -> v == :t end) |> Enum.map(&elem(&1, 1))
      assert Enum.sum(arriving_t) == total
    end
  end

  # ── CLRS network: max flow = 23 ───────────────────────────────────────

  describe "CLRS 6-vertex network: max flow = 23" do
    test "edmonds_karp" do
      assert {:ok, %{flow: 23}} = MaxFlow.edmonds_karp(clrs_network(), :s, :t)
    end

    test "dinic" do
      assert {:ok, %{flow: 23}} = MaxFlow.dinic(clrs_network(), :s, :t)
    end

    test "min_cut value = 23" do
      assert {:ok, %{cut_value: 23}} = MaxFlow.min_cut(clrs_network(), :s, :t)
    end
  end

  # ── Trivial cases ─────────────────────────────────────────────────────

  describe "trivial cases" do
    test "source = sink ⇒ flow = 0" do
      g = Graph.new() |> Graph.add_edges([{:a, :b, weight: 5}])
      assert {:ok, %{flow: 0, flows: %{}}} = MaxFlow.edmonds_karp(g, :a, :a)
      assert {:ok, %{flow: 0, flows: %{}}} = MaxFlow.dinic(g, :a, :a)
    end

    test "disconnected source/sink ⇒ flow = 0" do
      g = Graph.new() |> Graph.add_vertices([:s, :t]) |> Graph.add_edge(:x, :y, weight: 5)
      assert {:ok, %{flow: 0, flows: %{}}} = MaxFlow.edmonds_karp(g, :s, :t)
      assert {:ok, %{flow: 0, flows: %{}}} = MaxFlow.dinic(g, :s, :t)
    end

    test "path graph: max flow = bottleneck capacity" do
      g =
        Graph.new()
        |> Graph.add_edges([
          {:s, :a, weight: 10},
          {:a, :b, weight: 3},
          {:b, :c, weight: 7},
          {:c, :t, weight: 5}
        ])

      assert {:ok, %{flow: 3}} = MaxFlow.edmonds_karp(g, :s, :t)
      assert {:ok, %{flow: 3}} = MaxFlow.dinic(g, :s, :t)
    end

    test "single direct edge" do
      g = Graph.new() |> Graph.add_edge(:s, :t, weight: 42)
      assert {:ok, %{flow: 42, flows: %{{:s, :t} => 42}}} = MaxFlow.dinic(g, :s, :t)
    end
  end

  # ── Multigraph: parallel edges sum ────────────────────────────────────

  describe "multigraph" do
    test "parallel edges sum their capacities" do
      g =
        Graph.new()
        |> Graph.add_edge(:s, :t, weight: 3)
        |> Graph.add_edge(:s, :t, weight: 4)
        |> Graph.add_edge(:s, :t, weight: 5)

      assert {:ok, %{flow: 12}} = MaxFlow.edmonds_karp(g, :s, :t)
      assert {:ok, %{flow: 12}} = MaxFlow.dinic(g, :s, :t)
    end

    test "parallel edges on internal hop" do
      g =
        Graph.new()
        |> Graph.add_edges([
          {:s, :a, weight: 10},
          {:a, :b, weight: 3},
          {:a, :b, weight: 4},
          {:b, :t, weight: 10}
        ])

      assert {:ok, %{flow: 7}} = MaxFlow.dinic(g, :s, :t)
    end
  end

  # ── Min-cut ───────────────────────────────────────────────────────────

  describe "min_cut/3" do
    test "max-flow min-cut equality on classic 4-vertex" do
      g = classic_4()
      {:ok, %{flow: max_flow}} = MaxFlow.edmonds_karp(g, :s, :t)
      assert {:ok, %{cut_value: cv}} = MaxFlow.min_cut(g, :s, :t)
      assert cv == max_flow
    end

    test "partition covers all vertices and cut edges are cross edges" do
      g = clrs_network()

      {:ok,
       %{
         cut_value: cv,
         source_side: src,
         sink_side: snk,
         cut_edges: edges
       }} = MaxFlow.min_cut(g, :s, :t)

      all = MapSet.new(Graph.vertices(g))
      assert MapSet.union(src, snk) == all
      assert MapSet.disjoint?(src, snk)
      assert MapSet.member?(src, :s)
      assert MapSet.member?(snk, :t)

      # Every cut edge goes from source side to sink side.
      Enum.each(edges, fn {u, v} ->
        assert MapSet.member?(src, u)
        assert MapSet.member?(snk, v)
      end)

      # Sum of cut-edge capacities = cut value.
      assert sum_caps(g, edges) == cv
    end

    test ":algo option chooses backend" do
      g = clrs_network()
      assert {:ok, %{cut_value: 23}} = MaxFlow.min_cut(g, :s, :t, algo: :edmonds_karp)
      assert {:ok, %{cut_value: 23}} = MaxFlow.min_cut(g, :s, :t, algo: :dinic)
    end

    test "unknown options and an unknown :algo raise, even for a missing vertex" do
      g = clrs_network()

      assert_raise ArgumentError, ~r/unknown keys \[:method\]/, fn ->
        MaxFlow.min_cut(g, :s, :t, method: :dinic)
      end

      assert_raise ArgumentError, ~r/expected :algo to be :dinic or :edmonds_karp/, fn ->
        MaxFlow.min_cut(g, :s, :missing, algo: :push_relabel)
      end
    end

    test "disconnected: cut value 0, no cut edges" do
      g = Graph.new() |> Graph.add_vertices([:s, :t])

      assert {:ok, %{cut_value: 0, cut_edges: [], source_side: src, sink_side: snk}} =
               MaxFlow.min_cut(g, :s, :t)

      assert MapSet.member?(src, :s)
      assert MapSet.member?(snk, :t)
    end

    test "source = sink: source_side = {source}, value = 0" do
      g = Graph.new() |> Graph.add_edges([{:a, :b, weight: 5}])

      assert {:ok, %{cut_value: 0, source_side: src, cut_edges: []}} =
               MaxFlow.min_cut(g, :a, :a)

      assert MapSet.member?(src, :a)
    end
  end

  describe "max_flow/4" do
    test "defaults to Dinic; :algo picks the backend" do
      g = clrs_network()
      assert MaxFlow.max_flow(g, :s, :t) == MaxFlow.dinic(g, :s, :t)
      assert MaxFlow.max_flow(g, :s, :t, algo: :dinic) == MaxFlow.dinic(g, :s, :t)

      assert MaxFlow.max_flow(g, :s, :t, algo: :edmonds_karp) ==
               MaxFlow.edmonds_karp(g, :s, :t)

      assert {:ok, %{flow: 23}} = Grafi.max_flow(g, :s, :t, algo: :edmonds_karp)
    end

    test "returns the backends' errors" do
      assert MaxFlow.max_flow(clrs_network(), :s, :missing) == {:error, :no_such_vertex}
    end

    test "an unknown :algo raises ArgumentError, before any early return" do
      for call <- [&MaxFlow.max_flow/4, &Grafi.max_flow/4], sink <- [:t, :missing] do
        assert_raise ArgumentError, ~r/expected :algo to be :dinic or :edmonds_karp/, fn ->
          call.(clrs_network(), :s, sink, algo: :push_relabel)
        end
      end
    end

    test "unknown options raise in every max-flow function" do
      g = clrs_network()

      for call <- [&MaxFlow.max_flow/4, &MaxFlow.dinic/4, &MaxFlow.edmonds_karp/4] do
        assert_raise ArgumentError, ~r/unknown keys \[:capacity\]/, fn ->
          call.(g, :s, :t, capacity: :weight)
        end
      end

      assert_raise ArgumentError, ~r/unknown keys \[:algo\]/, fn ->
        MaxFlow.dinic(g, :s, :t, algo: :dinic)
      end
    end
  end

  # ── Self-loop ─────────────────────────────────────────────────────────

  describe "self-loops" do
    test "self-loop on the source contributes nothing to flow" do
      g =
        Graph.new()
        |> Graph.add_edges([
          {:s, :s, weight: 100},
          {:s, :t, weight: 5}
        ])

      assert {:ok, %{flow: 5}} = MaxFlow.edmonds_karp(g, :s, :t)
      assert {:ok, %{flow: 5}} = MaxFlow.dinic(g, :s, :t)
    end

    test "self-loop on intermediate vertex does nothing" do
      g =
        Graph.new()
        |> Graph.add_edges([
          {:s, :a, weight: 5},
          {:a, :a, weight: 1_000},
          {:a, :t, weight: 5}
        ])

      assert {:ok, %{flow: 5}} = MaxFlow.dinic(g, :s, :t)
    end
  end

  # ── Errors ────────────────────────────────────────────────────────────

  describe "error handling" do
    test "negative capacity is rejected" do
      g = Graph.new() |> Graph.add_edges([{:s, :t, weight: -1}])
      assert {:error, :negative_capacity} = MaxFlow.edmonds_karp(g, :s, :t)
      assert {:error, :negative_capacity} = MaxFlow.dinic(g, :s, :t)
      assert {:error, :negative_capacity} = MaxFlow.min_cut(g, :s, :t)
    end

    test "missing source" do
      g = Graph.new() |> Graph.add_edge(:s, :t, weight: 1)
      assert {:error, :no_such_vertex} = MaxFlow.edmonds_karp(g, :nope, :t)
      assert {:error, :no_such_vertex} = MaxFlow.dinic(g, :nope, :t)
      assert {:error, :no_such_vertex} = MaxFlow.min_cut(g, :nope, :t)
    end

    test "missing sink" do
      g = Graph.new() |> Graph.add_edge(:s, :t, weight: 1)
      assert {:error, :no_such_vertex} = MaxFlow.edmonds_karp(g, :s, :nope)
      assert {:error, :no_such_vertex} = MaxFlow.dinic(g, :s, :nope)
      assert {:error, :no_such_vertex} = MaxFlow.min_cut(g, :s, :nope)
    end
  end

  # ── Undirected graphs ─────────────────────────────────────────────────

  describe "undirected graphs" do
    test "undirected edge gives capacity in both directions" do
      g =
        Graph.new(type: :undirected)
        |> Graph.add_edges([
          {:s, :a, weight: 5},
          {:a, :t, weight: 5}
        ])

      assert {:ok, %{flow: 5}} = MaxFlow.dinic(g, :s, :t)
      # Flowing backwards from t to s should also be 5.
      assert {:ok, %{flow: 5}} = MaxFlow.dinic(g, :t, :s)
    end
  end

  # ── Property: EK and Dinic agree ──────────────────────────────────────

  describe "properties" do
    property "edmonds_karp and dinic produce identical max-flow values" do
      check all(
              n <- integer(3..7),
              density <- integer(0..10),
              cap_max <- integer(1..10),
              seed <- integer(1..5_000)
            ) do
        g = random_network(n, density, cap_max, seed)
        source = 0
        sink = n - 1

        {:ok, %{flow: ek}} = MaxFlow.edmonds_karp(g, source, sink)
        {:ok, %{flow: dn}} = MaxFlow.dinic(g, source, sink)

        assert ek == dn
      end
    end

    property "min_cut value equals max-flow value" do
      check all(
              n <- integer(3..6),
              density <- integer(0..6),
              cap_max <- integer(1..8),
              seed <- integer(1..2_000)
            ) do
        g = random_network(n, density, cap_max, seed)
        source = 0
        sink = n - 1

        {:ok, %{flow: max_flow}} = MaxFlow.dinic(g, source, sink)

        {:ok, %{cut_value: cv, cut_edges: edges, source_side: src, sink_side: snk}} =
          MaxFlow.min_cut(g, source, sink)

        assert cv == max_flow

        # Cut edges go from source side to sink side.
        Enum.each(edges, fn {u, v} ->
          assert MapSet.member?(src, u)
          assert MapSet.member?(snk, v)
        end)

        # Sum of capacities of cut edges = cut value.
        assert sum_caps(g, edges) == cv
      end
    end
  end
end
