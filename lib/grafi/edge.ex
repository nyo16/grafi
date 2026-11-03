defmodule Grafi.Edge do
  @moduledoc """
  A weighted, labelled edge between two vertices.

  ## Fields

    * `:from`   — the source vertex id (any term)
    * `:to`     — the destination vertex id (any term)
    * `:weight` — numeric edge weight, defaults to `1.0`. Used by Dijkstra,
                  A*, Bellman-Ford, PageRank-with-weights, etc.
    * `:label`  — arbitrary user-defined term (any/nil). Carried through
                  serialization and ignored by algorithms.

  `Grafi.Graph` permits multi-edges, so multiple `%Edge{}` values may exist
  between the same `(from, to)` pair.
  """

  @type t :: %__MODULE__{
          from: any(),
          to: any(),
          weight: number(),
          label: any()
        }

  @enforce_keys [:from, :to]
  defstruct [:from, :to, weight: 1.0, label: nil]

  defimpl Inspect do
    import Inspect.Algebra

    def inspect(%Grafi.Edge{from: f, to: t, weight: w, label: l}, opts) do
      label = if l == nil, do: [], else: [", label: ", to_doc(l, opts)]

      concat(
        ["#Grafi.Edge<", to_doc(f, opts), " -> ", to_doc(t, opts), ", w: ", to_doc(w, opts)] ++
          label ++ [">"]
      )
    end
  end
end
