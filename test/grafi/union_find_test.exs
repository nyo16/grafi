defmodule Grafi.UnionFindTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  doctest Grafi.UnionFind

  alias Grafi.UnionFind

  describe "construction" do
    test "new/0 yields an empty forest" do
      uf = UnionFind.new()
      assert UnionFind.count_sets(uf) == 0
      assert UnionFind.sets(uf) == %{}
    end

    test "new/1 preloads singletons" do
      uf = UnionFind.new([:a, :b, :c])
      assert UnionFind.count_sets(uf) == 3
      assert MapSet.new(Map.keys(UnionFind.sets(uf))) == MapSet.new([:a, :b, :c])
    end

    test "new/1 is idempotent on duplicates" do
      uf = UnionFind.new([:a, :a, :b])
      assert UnionFind.count_sets(uf) == 2
    end

    test "make_set/2 inserts only if missing" do
      uf = UnionFind.new() |> UnionFind.make_set(:a) |> UnionFind.make_set(:a)
      assert UnionFind.count_sets(uf) == 1
    end
  end

  describe "find / union / connected?" do
    setup do
      %{uf: UnionFind.new([:a, :b, :c, :d, :e])}
    end

    test "find on a singleton returns itself", %{uf: uf} do
      assert {:a, _} = UnionFind.find(uf, :a)
    end

    test "union merges sets", %{uf: uf} do
      uf = UnionFind.union(uf, :a, :b)
      assert UnionFind.connected?(uf, :a, :b)
      refute UnionFind.connected?(uf, :a, :c)
    end

    test "union is transitive", %{uf: uf} do
      uf =
        uf
        |> UnionFind.union(:a, :b)
        |> UnionFind.union(:b, :c)

      assert UnionFind.connected?(uf, :a, :c)
      assert UnionFind.count_sets(uf) == 3
    end

    test "union of already-connected elements is a no-op on count", %{uf: uf} do
      uf = uf |> UnionFind.union(:a, :b) |> UnionFind.union(:a, :b)
      assert UnionFind.count_sets(uf) == 4
    end

    test "find implicitly creates unknown items" do
      {root, uf} = UnionFind.find(UnionFind.new(), :ghost)
      assert root == :ghost
      assert UnionFind.count_sets(uf) == 1
    end

    test "connected? for unknown items is false" do
      uf = UnionFind.new([:a])
      refute UnionFind.connected?(uf, :a, :ghost)
      refute UnionFind.connected?(uf, :ghost, :a)
      refute UnionFind.connected?(uf, :ghost, :phantom)
    end
  end

  describe "path compression" do
    test "find returns the correct root after compression" do
      # Force a deep chain by unioning singletons one at a time.
      uf =
        UnionFind.new(Enum.to_list(1..50))
        |> then(fn uf ->
          Enum.reduce(2..50, uf, fn i, acc -> UnionFind.union(acc, i - 1, i) end)
        end)

      {root, uf2} = UnionFind.find(uf, 50)
      # After compression every element on the path should point directly
      # to root; subsequent finds must agree.
      for i <- 1..50 do
        {r, _} = UnionFind.find(uf2, i)
        assert r == root
      end
    end
  end

  describe "sets/1" do
    test "reflects the partition" do
      uf =
        UnionFind.new([:a, :b, :c, :d, :e])
        |> UnionFind.union(:a, :b)
        |> UnionFind.union(:c, :d)

      partitions = UnionFind.sets(uf) |> Map.values() |> Enum.map(&MapSet.to_list/1)
      partitions = Enum.map(partitions, &Enum.sort/1) |> Enum.sort()

      assert partitions == [[:a, :b], [:c, :d], [:e]]
    end
  end

  describe "count_sets/1" do
    test "decreases by 1 per successful union" do
      uf = UnionFind.new([:a, :b, :c, :d])
      assert UnionFind.count_sets(uf) == 4

      uf = UnionFind.union(uf, :a, :b)
      assert UnionFind.count_sets(uf) == 3

      uf = UnionFind.union(uf, :c, :d)
      assert UnionFind.count_sets(uf) == 2

      uf = UnionFind.union(uf, :a, :c)
      assert UnionFind.count_sets(uf) == 1

      # Redundant union — no change.
      uf = UnionFind.union(uf, :b, :d)
      assert UnionFind.count_sets(uf) == 1
    end
  end

  describe "item comparison" do
    test "1 and 1.0 are distinct items" do
      uf = UnionFind.new([1, 1.0, :x])
      assert UnionFind.count_sets(uf) == 3
      refute UnionFind.connected?(uf, 1, 1.0)

      uf = UnionFind.union(uf, 1, 1.0)
      assert UnionFind.count_sets(uf) == 2
      assert UnionFind.connected?(uf, 1, 1.0)
      refute UnionFind.connected?(uf, 1, :x)

      uf = UnionFind.union(uf, 1.0, :x)
      assert UnionFind.count_sets(uf) == 1
      assert UnionFind.connected?(uf, 1, :x)
    end
  end

  describe "properties" do
    property "count_sets == n - successful unions" do
      check all(
              n <- integer(1..30),
              k <- integer(0..50),
              ops <- list_of(tuple({integer(0..29), integer(0..29)}), length: k)
            ) do
        items = Enum.to_list(0..(n - 1))
        uf0 = UnionFind.new(items)

        {uf, successful} =
          Enum.reduce(ops, {uf0, 0}, fn {x, y}, {acc, s} ->
            x = rem(x, n)
            y = rem(y, n)

            if UnionFind.connected?(acc, x, y) do
              {acc, s}
            else
              {UnionFind.union(acc, x, y), s + 1}
            end
          end)

        assert UnionFind.count_sets(uf) == n - successful
      end
    end

    property "connected? is reflexive, symmetric, and transitive" do
      check all(
              n <- integer(2..15),
              edges <- list_of(tuple({integer(0..14), integer(0..14)}), max_length: 30)
            ) do
        items = Enum.to_list(0..(n - 1))

        uf =
          Enum.reduce(edges, UnionFind.new(items), fn {x, y}, acc ->
            UnionFind.union(acc, rem(x, n), rem(y, n))
          end)

        # Reflexive
        for i <- items, do: assert(UnionFind.connected?(uf, i, i))

        # Symmetric on a small sample
        for i <- items, j <- items do
          assert UnionFind.connected?(uf, i, j) == UnionFind.connected?(uf, j, i)
        end

        # Transitive: for any i, j, k connected pairwise i~j and j~k => i~k
        for i <- items, j <- items, k <- items do
          if UnionFind.connected?(uf, i, j) and UnionFind.connected?(uf, j, k) do
            assert UnionFind.connected?(uf, i, k)
          end
        end
      end
    end
  end
end
