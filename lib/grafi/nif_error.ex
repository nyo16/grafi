defmodule Grafi.NIFError do
  @moduledoc """
  Raised when the igraph NIF fails in a function whose contract has no error
  return, such as `Grafi.Algo.Centrality.pagerank/2`.

  `reason` is the normalized reason from `Grafi.NIF.call/1`: an atom such as
  `:nif_not_available`, or `{:igraph, message}` for an unexpected igraph
  failure.
  """

  defexception [:reason]

  @impl true
  def message(%__MODULE__{reason: reason}), do: "igraph NIF call failed: #{inspect(reason)}"
end
