defmodule Grafi.NIF do
  @moduledoc """
  Bridge to the igraph C++ NIF, plus the dispatcher that decides per call
  whether an algorithm runs natively or in pure Elixir.

  ## Engine selection

  Every NIF-capable function accepts `engine: :auto | :nif | :elixir`:

    * `:auto` (default) — the NIF runs when `available?/0` is `true` and the
      graph has more than `config :grafi, nif_threshold` vertices (default
      `500`). Isomorphism and community detection use the NIF whenever it is
      available, regardless of size.
    * `:nif` — always the NIF. When it is unavailable the function reports
      `:nif_not_available` (an `{:error, :nif_not_available}` return, or a
      `Grafi.NIFError` for functions without an error return).
    * `:elixir` — always pure Elixir. Algorithms without an Elixir
      implementation (Louvain, Leiden, label propagation) return
      `{:error, :nif_not_available}`.

  Any other `:engine` value raises `ArgumentError`.

  ## Configuration

      config :grafi,
        nif_threshold: 500,     # :auto uses the NIF above this many vertices
        nif_enabled: true,      # false disables NIF dispatch entirely
        vf2_timeout: :infinity  # isomorphism budget (ms); set finite for untrusted input

  The defaults live in the `:grafi` application environment. See
  `Grafi.Algo.Isomorphism` "Timeouts" for how `vf2_timeout` applies.

  The native library is optional: if igraph was missing at build time or the
  library fails to load, every algorithm with an Elixir implementation keeps
  working. All NIFs except the O(1) load probe run on dirty CPU schedulers.
  """

  require Logger

  alias Grafi.Args
  alias Grafi.Graph

  @on_load :load_nif
  @available_key {__MODULE__, :available}

  # Duplicated in mix.exs `application/0` `env:`; keep both in sync. The
  # fallbacks cover code paths where the :grafi app env is not loaded (e.g.
  # `elixir -pa ebin` without starting the application).
  @default_nif_threshold 500
  @default_nif_enabled true

  @type engine :: :nif | :elixir

  @doc false
  @spec load_nif() :: :ok
  def load_nif do
    loaded? =
      with dir when is_list(dir) <- :code.priv_dir(:grafi),
           :ok <- :erlang.load_nif(:filename.join(dir, ~c"grafi_nif"), 0) do
        nif_loaded() == :ok
      else
        {:error, reason} ->
          log_load_failure(reason)
          false
      end

    :persistent_term.put(@available_key, loaded?)
    :ok
  end

  # The Makefile writes `priv/.grafi_nif_skipped` when it deliberately skips
  # the build (igraph not installed). That is an expected configuration, so
  # it is not worth a warning.
  defp log_load_failure(reason) do
    if build_skipped?() do
      Logger.debug("Grafi NIF not built (igraph missing at build time); using pure Elixir")
    else
      Logger.warning("Grafi NIF not loaded: #{inspect(reason)}. Using pure Elixir fallback.")
    end
  end

  defp build_skipped? do
    case :code.priv_dir(:grafi) do
      dir when is_list(dir) -> File.exists?(Path.join(List.to_string(dir), ".grafi_nif_skipped"))
      {:error, _} -> false
    end
  end

  @doc """
  Returns `true` if the NIF library is loaded and NIF dispatch is enabled
  (`config :grafi, nif_enabled: true`, the default).
  """
  @spec available?() :: boolean()
  def available? do
    :persistent_term.get(@available_key, false) and
      Application.get_env(:grafi, :nif_enabled, @default_nif_enabled)
  end

  @doc """
  Chooses the engine for one call from the caller's `opts[:engine]`.

  Returns `:nif`, `:elixir`, or `{:error, :nif_not_available}` when
  `engine: :nif` was requested but `available?/0` is `false`.

  `overrides` tunes the `:auto` rule for a call site:

    * `prefer: :nif` — use the NIF whenever it is available, ignoring
      `:nif_threshold`.

  Raises `ArgumentError` for an unknown `:engine` value.
  """
  @spec engine(Graph.t(), keyword(), keyword()) :: engine() | {:error, :nif_not_available}
  def engine(%Graph{} = g, opts, overrides \\ []) do
    case Args.engine!(opts) do
      :auto ->
        if available?() and auto_nif?(g, overrides), do: :nif, else: :elixir

      :nif ->
        if available?(), do: :nif, else: {:error, :nif_not_available}

      :elixir ->
        :elixir
    end
  end

  defp auto_nif?(g, overrides) do
    Keyword.get(overrides, :prefer) == :nif or
      Graph.num_vertices(g) > Application.get_env(:grafi, :nif_threshold, @default_nif_threshold)
  end

  @doc """
  Normalizes a raw NIF result.

  Error atoms pass through unchanged. An unexpected igraph failure, which the
  NIF reports as a message string, becomes `{:error, {:igraph, message}}`.
  Any other value is returned as is.
  """
  @spec call(term()) :: term()
  def call({:error, message}) when is_binary(message), do: {:error, {:igraph, message}}
  def call(result), do: result

  @doc """
  Like `call/1`, but raises `Grafi.NIFError` for any `{:error, reason}`.

  For functions whose contract has no error return.
  """
  @spec call!(term()) :: term()
  def call!(result) do
    case call(result) do
      {:error, reason} -> raise Grafi.NIFError, reason: reason
      ok -> ok
    end
  end

  @doc false
  # Pairs a per-index NIF result list with the vertex ids of `Graph.to_csr/1`.
  @spec by_vertex(map(), [term()]) :: %{Graph.vertex_id() => term()}
  def by_vertex(%{vertices: vs}, values) do
    values |> Enum.with_index() |> Map.new(fn {x, i} -> {elem(vs, i), x} end)
  end

  @doc """
  Validates the structural invariants of a hand-built CSR map before it is
  passed to a raw NIF function.

  The map has the format produced by `Grafi.Graph.to_csr/1`: `row_offsets`
  and `col_indices` are binaries of `signed-native-64` integers and `weights`
  is a binary of `float-native-64` floats.

  Raises `ArgumentError` if the map is missing fields, has the wrong types, or
  violates any of:

    * every array's byte size is a multiple of 8, and weights are finite
    * `row_offsets` has `n_vertices + 1` entries
    * `row_offsets[0] == 0`
    * `row_offsets` is monotonically non-decreasing
    * the last row offset equals the number of `col_indices`
    * `col_indices` and `weights` have the same number of entries
    * every `col_indices[j]` is in `[0, n_vertices)`
    * `n_vertices >= 0`

  CSR maps built by `Grafi.Graph.to_csr/1` are valid by construction, and
  the NIF re-validates every CSR it receives; this check exists for CSR data
  built elsewhere.
  """
  @spec validate_csr!(map()) :: :ok
  def validate_csr!(%{
        row_offsets: ro_bin,
        col_indices: ci_bin,
        weights: w_bin,
        n_vertices: n,
        directed: d
      })
      when is_binary(ro_bin) and is_binary(ci_bin) and is_binary(w_bin) and is_integer(n) and
             is_boolean(d) do
    ro = decode_int64s!(ro_bin, :row_offsets)
    ci = decode_int64s!(ci_bin, :col_indices)
    w = decode_float64s!(w_bin)

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

    :ok
  end

  def validate_csr!(_), do: raise(ArgumentError, "invalid CSR map structure")

  defp decode_int64s!(bin, field) do
    unless rem(byte_size(bin), 8) == 0,
      do: raise(ArgumentError, "#{field} byte size must be a multiple of 8")

    for <<x::signed-native-64 <- bin>>, do: x
  end

  # A float segment does not match NaN or infinity bit patterns, so those
  # entries drop out of the comprehension and the count comes up short.
  defp decode_float64s!(bin) do
    floats = for <<x::float-native-64 <- bin>>, do: x

    unless rem(byte_size(bin), 8) == 0 and length(floats) == div(byte_size(bin), 8),
      do: raise(ArgumentError, "weights must be a binary of finite float-native-64 values")

    floats
  end

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
  # Replaced by the native implementations in load_nif/0. Callers go through
  # engine/3, so a stub only runs if a raw nif_* function is called directly
  # while the library is not loaded.

  @doc false
  def nif_loaded, do: :erlang.nif_error(:nif_not_loaded)

  @doc false
  def nif_pagerank(_csr_map, _damping, _max_iter),
    do: :erlang.nif_error(:nif_not_loaded)

  @doc false
  def nif_dijkstra(_csr_map, _source, _target),
    do: :erlang.nif_error(:nif_not_loaded)

  @doc false
  def nif_betweenness(_csr_map, _weighted?, _normalized?),
    do: :erlang.nif_error(:nif_not_loaded)

  @doc false
  def nif_closeness(_csr_map),
    do: :erlang.nif_error(:nif_not_loaded)

  @doc false
  def nif_louvain(_csr_map),
    do: :erlang.nif_error(:nif_not_loaded)

  @doc false
  def nif_label_propagation(_csr_map),
    do: :erlang.nif_error(:nif_not_loaded)

  @doc false
  def nif_leiden(_csr_map, _resolution, _objective),
    do: :erlang.nif_error(:nif_not_loaded)

  @doc false
  def nif_scc(_csr_map),
    do: :erlang.nif_error(:nif_not_loaded)

  @doc false
  # credo:disable-for-next-line Credo.Check.Readability.PredicateFunctionNames
  def nif_is_acyclic(_csr_map),
    do: :erlang.nif_error(:nif_not_loaded)

  @doc false
  def nif_topological_sort(_csr_map),
    do: :erlang.nif_error(:nif_not_loaded)

  @doc false
  def nif_isomorphic_vf2(_csr1, _csr2, _timeout_ms),
    do: :erlang.nif_error(:nif_not_loaded)

  @doc false
  def nif_subisomorphic_vf2(_csr1, _csr2, _timeout_ms),
    do: :erlang.nif_error(:nif_not_loaded)

  @doc false
  def nif_isomorphism_vf2(_csr1, _csr2, _timeout_ms),
    do: :erlang.nif_error(:nif_not_loaded)

  @doc false
  def nif_subgraph_isomorphism_vf2(_csr1, _csr2, _timeout_ms),
    do: :erlang.nif_error(:nif_not_loaded)

  @doc false
  def nif_count_subisomorphisms_vf2(_csr1, _csr2, _timeout_ms),
    do: :erlang.nif_error(:nif_not_loaded)
end
