defmodule Grafi.Edge do
  @moduledoc "Represents a weighted, labelled edge between two vertices."

  @type t :: %__MODULE__{
          from: any(),
          to: any(),
          weight: number(),
          label: any()
        }

  defstruct [:from, :to, weight: 1.0, label: nil]

  defimpl Inspect do
    def inspect(%Grafi.Edge{from: f, to: t, weight: w, label: l}, _opts) do
      label_str = if l, do: ", label: #{inspect(l)}", else: ""
      "#Grafi.Edge<#{inspect(f)} -> #{inspect(t)}, w: #{w}#{label_str}>"
    end
  end
end
