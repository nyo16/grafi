defmodule Grafi.DAGTest do
  use ExUnit.Case, async: true
  alias Grafi.DAG

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

    assert_raise Grafi.CycleError, fn ->
      DAG.add_edge(dag, :b, :a)
    end
  end

  test "self-loop prevention" do
    assert_raise Grafi.CycleError, fn ->
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
end
