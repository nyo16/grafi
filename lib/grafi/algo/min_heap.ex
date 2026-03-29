defmodule Grafi.Algo.MinHeap do
  @moduledoc false
  # Pairing heap — O(1) insert, O(log n) amortized delete-min.
  # Used internally by Dijkstra and A* for the priority queue.
  #
  # Elements are compared by the first element of the tuple.

  @type t :: nil | {tuple(), [t()]}

  @spec new() :: nil
  def new, do: nil

  @spec insert(t(), tuple()) :: t()
  def insert(nil, elem), do: {elem, []}
  def insert(heap, elem), do: meld(heap, {elem, []})

  @spec pop(t()) :: {:ok, tuple(), t()} | :empty
  def pop(nil), do: :empty
  def pop({elem, children}), do: {:ok, elem, merge_pairs(children)}

  @spec from_list([tuple()]) :: t()
  def from_list([]), do: nil
  def from_list(list), do: Enum.reduce(list, nil, &insert(&2, &1))

  # ── Internal ──────────────────────────────────────────────────────────

  defp meld(nil, h), do: h
  defp meld(h, nil), do: h

  defp meld({e1, c1} = _h1, {e2, c2} = _h2) do
    if elem(e1, 0) <= elem(e2, 0),
      do: {e1, [{e2, c2} | c1]},
      else: {e2, [{e1, c1} | c2]}
  end

  defp merge_pairs([]), do: nil
  defp merge_pairs([h]), do: h
  defp merge_pairs([h1, h2 | rest]), do: meld(meld(h1, h2), merge_pairs(rest))
end
