defmodule Grafi.CycleError do
  @moduledoc """
  Raised by `Grafi.DAG` when an operation would create a cycle, or when
  `Grafi.DAG.from_graph!/1` is given a cyclic graph.
  """
  defexception [:message]
end
