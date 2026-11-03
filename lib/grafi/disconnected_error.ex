defmodule Grafi.DisconnectedError do
  @moduledoc """
  Raised by `Grafi.Algo.MST.kruskal!/1` (and friends) when a minimum
  spanning *tree* is requested but the input graph has more than one
  connected component (i.e. only a spanning *forest* exists).
  """
  defexception [:message]

  @impl true
  def exception(opts) when is_list(opts) do
    %__MODULE__{message: Keyword.get(opts, :message, "graph is disconnected")}
  end

  def exception(msg) when is_binary(msg), do: %__MODULE__{message: msg}
end
