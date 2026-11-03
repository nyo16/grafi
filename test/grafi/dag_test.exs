defmodule Grafi.DAGTest do
  use ExUnit.Case, async: true
  doctest Grafi.DAG
  alias Grafi.DAG
  alias Grafi.Graph

  # Reductions spent by `fun` in this process: deterministic, unlike wall
  # clock, so a scaling ratio can be asserted tightly.
  defp reductions(fun) do
    {:reductions, before} = Process.info(self(), :reductions)
    fun.()
    {:reductions, after_call} = Process.info(self(), :reductions)
    after_call - before
  end

  test "topological sort" do
    dag =
      DAG.new()
      |> DAG.add_edge(:a, :b)
      |> DAG.add_edge(:b, :c)
      |> DAG.add_edge(:a, :c)

    assert {:ok, sorted} = DAG.topological_sort(dag)
    assert hd(sorted) == :a
    assert List.last(sorted) == :c
  end

  test "cycle prevention" do
    dag = DAG.new() |> DAG.add_edge(:a, :b)

    assert_raise Grafi.CycleError, ~r/:b -> :a would create a cycle/, fn ->
      DAG.add_edge(dag, :b, :a)
    end
  end

  test "self-loop prevention" do
    assert_raise Grafi.CycleError, ~r/self-loop: :a/, fn ->
      DAG.new() |> DAG.add_edge(:a, :a)
    end
  end

  test "layers" do
    dag =
      DAG.new()
      |> DAG.add_edges([{:a, :c}, {:b, :c}, {:c, :d}])

    layers = DAG.layers(dag)
    assert :a in layers[0]
    assert :b in layers[0]
    assert layers[1] == [:c]
    assert layers[2] == [:d]
  end

  test "sources and sinks" do
    dag =
      DAG.new()
      |> DAG.add_edges([{:a, :b}, {:b, :c}])

    assert DAG.sources(dag) == [:a]
    assert DAG.sinks(dag) == [:c]
  end

  test "critical path" do
    dag =
      DAG.new()
      |> DAG.add_edges([
        {:a, :b, weight: 3.0},
        {:a, :c, weight: 1.0},
        {:b, :d, weight: 2.0},
        {:c, :d, weight: 10.0}
      ])

    {path, cost} = DAG.critical_path(dag)
    assert path == [:a, :c, :d]
    assert cost == 11.0
  end

  describe "add_edges/2" do
    test "inserts every edge with its options" do
      dag = DAG.new() |> DAG.add_edges([{:a, :b}, {:b, :c, weight: 2.5}])
      g = DAG.to_graph(dag)
      assert Graph.num_edges(g) == 2
      assert [%{weight: 2.5}] = Graph.edges_between(g, :b, :c)
    end

    test "raises naming a new edge that closes a cycle" do
      dag = DAG.new() |> DAG.add_edges([{:a, :b}, {:b, :c}])

      error =
        assert_raise Grafi.CycleError, fn ->
          DAG.add_edges(dag, [{:x, :y}, {:c, :a}])
        end

      assert error.message =~ ":c -> :a would create a cycle"
    end

    test "a cycle made only of new edges is reported" do
      assert_raise Grafi.CycleError, ~r/would create a cycle/, fn ->
        DAG.add_edges(DAG.new(), [{:a, :b}, {:b, :c}, {:c, :a}])
      end
    end

    test "raises on a self-loop" do
      assert_raise Grafi.CycleError, ~r/self-loop: :q/, fn ->
        DAG.add_edges(DAG.new(), [{:a, :b}, {:q, :q}])
      end
    end

    test "rejects unknown edge options" do
      assert_raise ArgumentError, ~r/unknown keys \[:colour\]/, fn ->
        DAG.add_edges(DAG.new(), [{:a, :b, colour: :red}])
      end
    end

    # Inserting everything and checking acyclicity once is linear; the base
    # code checked reachability per edge, quadratic on a path whose edges
    # arrive back to front.
    @tag :slow
    test "a path added back to front scales linearly" do
      reversed_path = fn n -> for i <- n..1//-1, do: {i - 1, i} end
      {small, large} = {reversed_path.(2_000), reversed_path.(8_000)}

      r_small = reductions(fn -> DAG.add_edges(DAG.new(), small) end)
      r_large = reductions(fn -> DAG.add_edges(DAG.new(), large) end)

      # Linear: about 4x. Quadratic: about 16x.
      assert r_large < 8 * r_small, "4x the edges took #{r_large} vs #{r_small} reductions"
    end
  end

  describe "from_graph/1 and from_graph!/1" do
    test "accepts a directed acyclic graph" do
      g = Graph.new() |> Graph.add_edges([{:a, :b}])
      assert {:ok, dag} = DAG.from_graph(g)
      assert DAG.to_graph(dag) == g
      assert DAG.from_graph!(g) == dag
    end

    test "rejects undirected and cyclic graphs" do
      assert DAG.from_graph(Graph.new(type: :undirected)) == {:error, :must_be_directed}
      cyclic = Graph.new() |> Graph.add_edges([{:a, :b}, {:b, :a}])
      assert DAG.from_graph(cyclic) == {:error, :has_cycle}
    end

    test "from_graph! raises ArgumentError for undirected input" do
      assert_raise ArgumentError, ~r/must be directed/, fn ->
        DAG.from_graph!(Graph.new(type: :undirected))
      end
    end

    test "from_graph! raises CycleError for cyclic input" do
      cyclic = Graph.new() |> Graph.add_edges([{:a, :b}, {:b, :a}])
      assert_raise Grafi.CycleError, ~r/has_cycle/, fn -> DAG.from_graph!(cyclic) end
    end
  end

  describe "add_vertex/3" do
    test "adds a labelled vertex" do
      dag = DAG.new() |> DAG.add_vertex(:a, label: "A")
      assert Graph.label(DAG.to_graph(dag), :a) == "A"
      assert DAG.sources(dag) == [:a]
    end

    test "rejects unknown options" do
      assert_raise ArgumentError, ~r/unknown keys \[:weight\]/, fn ->
        DAG.add_vertex(DAG.new(), :a, weight: 1)
      end
    end
  end

  test "add_edge/4 rejects unknown options" do
    assert_raise ArgumentError, ~r/unknown keys \[:colour\]/, fn ->
      DAG.add_edge(DAG.new(), :a, :b, colour: :red)
    end
  end

  test "topological_sort/2 rejects unknown options" do
    assert_raise ArgumentError, ~r/unknown keys \[:bogus\]/, fn ->
      DAG.topological_sort(DAG.new(), bogus: true)
    end
  end

  describe "empty DAG" do
    test "critical_path and layers" do
      assert DAG.critical_path(DAG.new()) == {[], 0}
      assert DAG.layers(DAG.new()) == %{}
    end
  end

  test "layers keep vertices in topological order within a layer" do
    dag = DAG.new() |> DAG.add_edges([{:c, :x}, {:a, :x}, {:b, :x}])
    assert DAG.layers(dag) == %{0 => [:a, :b, :c], 1 => [:x]}
  end

  test "Inspect respects opts" do
    dag = DAG.new() |> DAG.add_edges([{:a, :b}, {:b, :c}])
    assert inspect(dag) == "#Grafi.DAG<V: 3, E: 2>"

    dag = Enum.reduce(1..1500, DAG.new(), &DAG.add_vertex(&2, &1))
    assert inspect(dag, custom_options: [], limit: :infinity) == "#Grafi.DAG<V: 1500, E: 0>"
    assert inspect(dag, syntax_colors: [number: :red]) =~ IO.ANSI.red()
  end

  test "Enumerable enumerates the vertices" do
    dag = DAG.new() |> DAG.add_edges([{:a, :b}, {:b, :c}])
    assert Enum.sort(dag) == [:a, :b, :c]
    assert Enum.count(dag) == 3
    assert Enum.member?(dag, :b)
    refute Enum.member?(dag, :z)
    assert Enum.map(dag, & &1) |> length() == 3
  end
end
