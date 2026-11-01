defmodule Grafi.TimeoutError do
  @moduledoc """
  Raised when a search runs out of its time budget in a function whose
  contract has no error return, such as
  `Grafi.Algo.Isomorphism.isomorphic?/3`.

  `timeout` is the budget in milliseconds: the `:timeout` option, or
  `config :grafi, vf2_timeout` when the option is absent.
  """

  defexception [:timeout]

  @impl true
  def message(%__MODULE__{timeout: timeout}),
    do: "search did not finish within its #{timeout} ms timeout"
end
