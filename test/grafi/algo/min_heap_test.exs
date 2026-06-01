defmodule Grafi.Algo.MinHeapTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias Grafi.Algo.MinHeap

  describe "basic operations" do
    test "pop on empty heap returns :empty" do
      assert MinHeap.pop(MinHeap.new()) == :empty
    end

    test "insert then pop returns the element" do
      heap = MinHeap.new() |> MinHeap.insert({3, :a})
      assert {:ok, {3, :a}, rest} = MinHeap.pop(heap)
      assert MinHeap.pop(rest) == :empty
    end

    test "pops elements in ascending order of the first tuple element" do
      heap =
        [{5, :e}, {1, :a}, {3, :c}, {2, :b}, {4, :d}]
        |> Enum.reduce(MinHeap.new(), &MinHeap.insert(&2, &1))

      assert {:ok, {1, :a}, h1} = MinHeap.pop(heap)
      assert {:ok, {2, :b}, h2} = MinHeap.pop(h1)
      assert {:ok, {3, :c}, h3} = MinHeap.pop(h2)
      assert {:ok, {4, :d}, h4} = MinHeap.pop(h3)
      assert {:ok, {5, :e}, h5} = MinHeap.pop(h4)
      assert MinHeap.pop(h5) == :empty
    end

    test "from_list/1 builds a heap; from_list([]) is empty" do
      assert MinHeap.from_list([]) == MinHeap.new()

      heap = MinHeap.from_list([{2, :b}, {1, :a}])
      assert {:ok, {1, :a}, _} = MinHeap.pop(heap)
    end

    test "ties on the key are both retained" do
      heap = MinHeap.from_list([{1, :a}, {1, :b}])
      assert {:ok, {1, _}, rest} = MinHeap.pop(heap)
      assert {:ok, {1, _}, empty} = MinHeap.pop(rest)
      assert MinHeap.pop(empty) == :empty
    end
  end

  describe "property: heap-sort" do
    property "popping all elements yields keys in non-decreasing order" do
      check all(keys <- list_of(integer(), min_length: 1, max_length: 50)) do
        heap =
          keys
          |> Enum.with_index()
          |> Enum.reduce(MinHeap.new(), fn {k, i}, h -> MinHeap.insert(h, {k, i}) end)

        popped = drain(heap, [])
        assert popped == Enum.sort(keys)
        assert length(popped) == length(keys)
      end
    end
  end

  defp drain(heap, acc) do
    case MinHeap.pop(heap) do
      :empty -> Enum.reverse(acc)
      {:ok, {k, _}, rest} -> drain(rest, [k | acc])
    end
  end
end
