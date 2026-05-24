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
      :ok ->
        :ok

      # allow graceful degradation
      {:error, {:load_failed, _}} ->
        :ok

      {:error, reason} ->
        require Logger
        Logger.warning("Grafi NIF not loaded: #{inspect(reason)}. Using pure Elixir fallback.")
        :ok
    end
  end

  @doc "Returns true if the NIF engine is loaded and available."
  @spec available?() :: boolean()
  def available? do
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

  @doc """
  Validates the structural invariants of a CSR map before sending it to the NIF.

  Raises `ArgumentError` if the map is missing fields, has the wrong types, or
  violates any of:

    * `row_offsets` has length `n_vertices + 1`
    * `row_offsets[0] == 0`
    * `row_offsets` is monotonically non-decreasing
    * `List.last(row_offsets) == length(col_indices)`
    * `length(col_indices) == length(weights)`
    * every `col_indices[j]` is in `[0, n_vertices)`
    * `n_vertices >= 0`

  This duplicates checks the C++ NIF should also perform; defence-in-depth
  prevents passing junk to the NIF.
  """
  @spec validate_csr!(map()) :: map()
  def validate_csr!(
        %{row_offsets: ro, col_indices: ci, weights: w, n_vertices: n, directed: d} = csr
      )
      when is_list(ro) and is_list(ci) and is_list(w) and is_integer(n) and is_boolean(d) do
    unless n >= 0,
      do: raise(ArgumentError, "n_vertices must be non-negative")

    unless length(ro) == n + 1,
      do: raise(ArgumentError, "row_offsets length must be n_vertices + 1")

    unless length(ci) == length(w),
      do: raise(ArgumentError, "col_indices and weights must have same length")

    case ro do
      [0 | _] -> :ok
      _ -> raise(ArgumentError, "row_offsets[0] must be 0")
    end

    validate_monotonic!(ro)

    last = List.last(ro)

    unless last == length(ci),
      do: raise(ArgumentError, "last row_offset must equal length(col_indices)")

    validate_col_indices!(ci, n)

    csr
  end

  def validate_csr!(_), do: raise(ArgumentError, "invalid CSR map structure")

  defp validate_monotonic!([_]), do: :ok
  defp validate_monotonic!([]), do: :ok

  defp validate_monotonic!([a, b | _]) when a > b,
    do: raise(ArgumentError, "row_offsets must be monotonically non-decreasing")

  defp validate_monotonic!([_ | rest]), do: validate_monotonic!(rest)

  defp validate_col_indices!([], _n), do: :ok

  defp validate_col_indices!([c | _], n) when not is_integer(c) or c < 0 or c >= n,
    do: raise(ArgumentError, "col_indices entry #{inspect(c)} out of bounds [0, #{n})")

  defp validate_col_indices!([_ | rest], n), do: validate_col_indices!(rest, n)

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

  # credo:disable-for-next-line Credo.Check.Readability.PredicateFunctionNames
  def nif_is_acyclic(_csr_map),
    do: :erlang.nif_error(:nif_not_loaded)

  def nif_topological_sort(_csr_map),
    do: :erlang.nif_error(:nif_not_loaded)

  def nif_isomorphic_vf2(_csr1, _csr2),
    do: :erlang.nif_error(:nif_not_loaded)

  def nif_subisomorphic_vf2(_csr1, _csr2),
    do: :erlang.nif_error(:nif_not_loaded)

  def nif_isomorphism_vf2(_csr1, _csr2),
    do: :erlang.nif_error(:nif_not_loaded)

  def nif_subgraph_isomorphism_vf2(_csr1, _csr2),
    do: :erlang.nif_error(:nif_not_loaded)

  def nif_count_subisomorphisms_vf2(_csr1, _csr2),
    do: :erlang.nif_error(:nif_not_loaded)
end
