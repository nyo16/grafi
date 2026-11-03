defmodule Grafi.LayoutTest do
  use ExUnit.Case, async: true
  doctest Grafi.Layout

  alias Grafi.Layout

  # Helper: extract the y-coordinate of a vertex from a layout map.
  # Used instead of pattern matching against 0.0/1.0 to avoid the
  # Elixir 1.18 "matching on 0.0 is equivalent to +0.0" warning.
  defp y_of(pos, v) do
    {_x, y} = pos[v]
    y
  end

  describe "sugiyama/2" do
    test "diamond DAG has expected layer assignment" do
      # a → b → d
      # a → c → d
      g =
        Grafi.new()
        |> Grafi.add_edges([{:a, :b}, {:a, :c}, {:b, :d}, {:c, :d}])

      assert {:ok, pos} = Layout.sugiyama(g)
      assert y_of(pos, :a) == 0.0
      assert y_of(pos, :b) == 1.0
      assert y_of(pos, :c) == 1.0
      assert y_of(pos, :d) == 2.0
    end

    test "linear path layers increase by one" do
      g =
        Grafi.new()
        |> Grafi.add_edges([{:a, :b}, {:b, :c}, {:c, :d}])

      assert {:ok, pos} = Layout.sugiyama(g)
      assert y_of(pos, :a) == 0.0
      assert y_of(pos, :b) == 1.0
      assert y_of(pos, :c) == 2.0
      assert y_of(pos, :d) == 3.0
    end

    test "vertices on the same layer get distinct x-coordinates" do
      g =
        Grafi.new()
        |> Grafi.add_edges([{:root, :child1}, {:root, :child2}, {:root, :child3}])

      assert {:ok, pos} = Layout.sugiyama(g)

      xs =
        [:child1, :child2, :child3]
        |> Enum.map(fn v ->
          {x, _y} = pos[v]
          x
        end)

      assert length(Enum.uniq(xs)) == 3
    end

    test "cyclic graph returns {:error, :has_cycle}" do
      g =
        Grafi.new()
        |> Grafi.add_edges([{:a, :b}, {:b, :c}, {:c, :a}])

      assert {:error, :has_cycle} = Layout.sugiyama(g)
    end

    test "y-coordinate equals layer index times layer_spacing" do
      g =
        Grafi.new()
        |> Grafi.add_edges([{:a, :b}, {:b, :c}, {:c, :d}])

      assert {:ok, pos} = Layout.sugiyama(g, layer_spacing: 2.5)

      assert y_of(pos, :a) == 0.0
      assert y_of(pos, :b) == 2.5
      assert y_of(pos, :c) == 5.0
      assert y_of(pos, :d) == 7.5
    end

    test "respects custom vertex_spacing" do
      g =
        Grafi.new()
        |> Grafi.add_edges([{:r, :a}, {:r, :b}])

      assert {:ok, pos} = Layout.sugiyama(g, vertex_spacing: 4.0)

      {xa, _} = pos[:a]
      {xb, _} = pos[:b]
      assert abs(abs(xa - xb) - 4.0) < 1.0e-9
    end

    test ":crossings :none skips barycenter sweeps" do
      # A deliberately bad initial order — barycenter should fix it.
      # Layer 0: [a, b]; Layer 1: [x, y] where a → y and b → x.
      g =
        Grafi.new()
        |> Grafi.add_vertices([:a, :b, :x, :y])
        |> Grafi.add_edges([{:a, :y}, {:b, :x}])

      {:ok, with_sweep} = Layout.sugiyama(g, crossings: :default)
      {:ok, without_sweep} = Layout.sugiyama(g, crossings: :none)
      # Both must yield valid maps with the same vertices.
      assert Map.keys(with_sweep) |> Enum.sort() == [:a, :b, :x, :y]
      assert Map.keys(without_sweep) |> Enum.sort() == [:a, :b, :x, :y]
    end

    test "barycenter sweep reduces crossings (relative ordering improves)" do
      # Construct a graph where the natural insertion order produces
      # crossings, and verify the barycenter sweep aligns the lower
      # layer with the upper layer.
      #
      # Upper layer (layer 0): [u1, u2]
      # Lower layer (layer 1): [l1, l2]
      # Edges: u1 → l2, u2 → l1
      # Without crossing reduction, default insertion order leaves
      # [u1, u2] and [l1, l2] crossing each other. With barycenter, the
      # lower layer should reorder so that l2 appears before l1
      # (because l2's only predecessor u1 sits at index 0 above).
      g =
        Grafi.new()
        |> Grafi.add_vertices([:u1, :u2])
        |> Grafi.add_edges([{:u1, :l2}, {:u2, :l1}])

      {:ok, swept} = Layout.sugiyama(g, crossings: :default)

      # In the lower layer, l2 should be to the left of l1.
      {xl1, yl1} = swept[:l1]
      {xl2, yl2} = swept[:l2]
      assert yl1 == 1.0
      assert yl2 == 1.0
      assert xl2 < xl1
    end

    test "isolated vertex sits at layer 0" do
      g = Grafi.new() |> Grafi.add_vertex(:lonely)
      assert {:ok, pos} = Layout.sugiyama(g)
      assert y_of(pos, :lonely) == 0.0
    end

    test "empty graph returns empty layout" do
      assert {:ok, %{}} = Layout.sugiyama(Grafi.new())
    end
  end

  describe "levels/1" do
    test "returns layer assignment for diamond DAG" do
      g =
        Grafi.new()
        |> Grafi.add_edges([{:a, :b}, {:a, :c}, {:b, :d}, {:c, :d}])

      assert {:ok, layer_of} = Layout.levels(g)
      assert layer_of[:a] == 0
      assert layer_of[:b] == 1
      assert layer_of[:c] == 1
      assert layer_of[:d] == 2
    end

    test "cyclic graph returns {:error, :has_cycle}" do
      g =
        Grafi.new()
        |> Grafi.add_edges([{:a, :b}, {:b, :a}])

      assert {:error, :has_cycle} = Layout.levels(g)
    end

    test "single vertex graph returns layer 0" do
      g = Grafi.new() |> Grafi.add_vertex(:only)
      assert {:ok, %{only: 0}} = Layout.levels(g)
    end
  end

  describe "undirected input" do
    test "an undirected tree is laid out from its smallest vertex" do
      g = Grafi.new(type: :undirected) |> Grafi.add_edges([{:b, :a}, {:b, :c}, {:c, :d}])
      assert Layout.levels(g) == {:ok, %{a: 0, b: 1, c: 2, d: 3}}
      assert {:ok, pos} = Layout.sugiyama(g)
      assert y_of(pos, :d) == 3.0
    end

    test "an undirected cycle is rejected" do
      g = Grafi.new(type: :undirected) |> Grafi.add_edges([{:a, :b}, {:b, :c}, {:c, :a}])
      assert Layout.levels(g) == {:error, :has_cycle}
      assert Layout.sugiyama(g) == {:error, :has_cycle}
    end
  end

  test "sugiyama/2 rejects unknown options" do
    assert_raise ArgumentError, ~r/unknown keys \[:spacing\]/, fn ->
      Layout.sugiyama(Grafi.new(), spacing: 2.0)
    end
  end

  test "levels follow the longest path on a DAG with a shortcut" do
    g = Grafi.new() |> Grafi.add_edges([{:a, :b}, {:b, :c}, {:a, :c}])
    assert Layout.levels(g) == {:ok, %{a: 0, b: 1, c: 2}}
  end
end
