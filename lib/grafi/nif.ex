defmodule Grafi.NIF do
  @moduledoc """
  Native Implemented Functions wrapping igraph via C++.

  This module provides the Elixir-side stubs that dispatch to the C++
  NIF library. All heavy algorithms run on dirty CPU schedulers.

  The NIF is optional — if igraph is not installed or the NIF fails to
  compile, all functions gracefully fall back to pure Elixir
  implementations in `Grafi.Algo.*`.
  """

  @on_load :load_nif

  @doc false
  def load_nif do
    path = :filename.join(:code.priv_dir(:grafi), ~c"grafi_nif")

    case :erlang.load_nif(path, 0) do
      :ok -> :ok
      {:error, {:load_failed, _}} -> :ok  # allow graceful degradation
      {:error, reason} ->
        require Logger
        Logger.warning("Grafi NIF not loaded: #{inspect(reason)}. Using pure Elixir fallback.")
        :ok
    end
  end

  @doc "Returns true if the NIF engine is loaded and available."
  @spec available?() :: boolean()
  def available? do
    try do
      nif_is_acyclic(%{
        row_offsets: [0, 0],
        col_indices: [],
        weights: [],
        n_vertices: 1,
        directed: true
      })
      true
    rescue
      _ -> false
    end
  end

  # ── NIF stubs ─────────────────────────────────────────────────────────
  # Each stub raises if the NIF is not loaded. The Algo modules check
  # available?() before calling these and fall back to Elixir.

  def nif_pagerank(_csr_map, _damping, _max_iter),
    do: :erlang.nif_error(:nif_not_loaded)

  def nif_dijkstra(_csr_map, _source, _target),
    do: :erlang.nif_error(:nif_not_loaded)

  def nif_betweenness(_csr_map),
    do: :erlang.nif_error(:nif_not_loaded)

  def nif_closeness(_csr_map),
    do: :erlang.nif_error(:nif_not_loaded)

  def nif_louvain(_csr_map),
    do: :erlang.nif_error(:nif_not_loaded)

  def nif_label_propagation(_csr_map),
    do: :erlang.nif_error(:nif_not_loaded)

  def nif_leiden(_csr_map, _resolution),
    do: :erlang.nif_error(:nif_not_loaded)

  def nif_scc(_csr_map),
    do: :erlang.nif_error(:nif_not_loaded)

  def nif_is_acyclic(_csr_map),
    do: :erlang.nif_error(:nif_not_loaded)

  def nif_topological_sort(_csr_map),
    do: :erlang.nif_error(:nif_not_loaded)
end
