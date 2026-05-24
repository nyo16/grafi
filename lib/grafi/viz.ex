defmodule Grafi.Viz do
  @moduledoc """
  Render Grafi graphs to image formats by shelling out to Graphviz.

  This module is a thin wrapper around the `dot` (and friends) CLI. It
  serialises the graph to DOT via `Grafi.Serialize.DOT.to_dot/2`, writes
  the DOT to a temporary file, invokes the chosen Graphviz engine, and
  returns the resulting bytes.

  ## Requirements

  Graphviz must be installed and `dot` must be in `PATH`. Check at
  runtime with `graphviz_available?/0`.

  ## Examples

      # Render to SVG (requires graphviz installed)
      {:ok, svg} = Grafi.Viz.render(graph, :svg)
      File.write!("graph.svg", svg)

      # One-shot: render and write
      :ok = Grafi.Viz.render_to_file(graph, "graph.png")
  """

  alias Grafi.Graph

  @type format :: :svg | :png | :pdf | :dot | :json | :eps
  @type engine :: :dot | :neato | :circo | :twopi | :fdp | :sfdp

  @valid_formats [:svg, :png, :pdf, :dot, :json, :eps]
  @valid_engines [:dot, :neato, :circo, :twopi, :fdp, :sfdp]

  # ── Public API ────────────────────────────────────────────────────────

  @doc """
  Returns `true` if the Graphviz `dot` binary is available in `PATH`.
  """
  @spec graphviz_available?() :: boolean()
  def graphviz_available? do
    System.find_executable("dot") != nil
  end

  @doc """
  Render a graph to the given image `format` via Graphviz.

  Returns `{:ok, binary}` on success — an SVG XML string, PNG bytes,
  etc. — or `{:error, reason}` on failure.

  ## Formats

  `:svg`, `:png`, `:pdf`, `:dot`, `:json`, `:eps`.

  ## Options

    * `:engine` — Graphviz layout engine. One of `:dot` (default),
      `:neato`, `:circo`, `:twopi`, `:fdp`, `:sfdp`.
    * `:name` — graph name, passed to `Grafi.Serialize.DOT.to_dot/2`.

  ## Errors

    * `{:error, :graphviz_not_installed}` — `dot` is not in PATH.
    * `{:error, {:invalid_format, fmt}}` — unsupported format atom.
    * `{:error, {:invalid_engine, eng}}` — unsupported engine atom.
    * `{:error, {:graphviz_failed, stderr, exit_code}}` — Graphviz
      returned a non-zero exit status.
  """
  @spec render(Graph.t(), format(), keyword()) ::
          {:ok, binary()}
          | {:error,
             :graphviz_not_installed
             | {:invalid_format, atom()}
             | {:invalid_engine, atom()}
             | {:graphviz_failed, String.t(), integer()}
             | {:tempfile_error, term()}}
  def render(graph, format \\ :svg, opts \\ [])

  def render(_graph, format, _opts) when format not in @valid_formats do
    {:error, {:invalid_format, format}}
  end

  def render(%Graph{} = graph, format, opts) do
    engine = Keyword.get(opts, :engine, :dot)

    cond do
      engine not in @valid_engines ->
        {:error, {:invalid_engine, engine}}

      not graphviz_available?() ->
        {:error, :graphviz_not_installed}

      true ->
        do_render(graph, format, engine, opts)
    end
  end

  @doc """
  Bang version of `render/3` — returns the binary directly or raises.
  """
  @spec render!(Graph.t(), format(), keyword()) :: binary()
  def render!(graph, format \\ :svg, opts \\ []) do
    case render(graph, format, opts) do
      {:ok, bin} ->
        bin

      {:error, reason} ->
        raise "Grafi.Viz.render!/3 failed: #{inspect(reason)}"
    end
  end

  @doc """
  Render a graph and write it to `path`. The output format is inferred
  from the file extension (e.g. `"foo.svg"` → `:svg`).

  Returns `:ok` on success, `{:error, reason}` otherwise.

  ## Options

  Same as `render/3`, plus:

    * `:format` — explicit format override (skips extension inference).
  """
  @spec render_to_file(Graph.t(), Path.t(), keyword()) ::
          :ok
          | {:error,
             :graphviz_not_installed
             | {:invalid_format, atom() | String.t()}
             | {:invalid_engine, atom()}
             | {:graphviz_failed, String.t(), integer()}
             | {:tempfile_error, term()}
             | {:file_write_error, File.posix()}}
  def render_to_file(%Graph{} = graph, path, opts \\ []) do
    case Keyword.get(opts, :format) || infer_format(path) do
      {:error, _} = err ->
        err

      format when is_atom(format) ->
        case render(graph, format, opts) do
          {:ok, bin} ->
            case File.write(path, bin) do
              :ok -> :ok
              {:error, reason} -> {:error, {:file_write_error, reason}}
            end

          {:error, _} = err ->
            err
        end
    end
  end

  # ── Internals ─────────────────────────────────────────────────────────

  defp infer_format(path) do
    ext =
      path
      |> Path.extname()
      |> String.downcase()
      |> String.trim_leading(".")

    case ext do
      "svg" -> :svg
      "png" -> :png
      "pdf" -> :pdf
      "dot" -> :dot
      "gv" -> :dot
      "json" -> :json
      "eps" -> :eps
      other -> {:error, {:invalid_format, other}}
    end
  end

  defp do_render(graph, format, engine, opts) do
    dot_opts = Keyword.take(opts, [:name])
    dot_string = Grafi.Serialize.DOT.to_dot(graph, dot_opts)

    with {:ok, dot_path} <- write_tempfile(dot_string) do
      try do
        run_graphviz(engine, format, dot_path)
      after
        _ = File.rm(dot_path)
      end
    end
  end

  defp write_tempfile(dot_string) do
    # We use a temp-file rather than piping via Port.open/2 because
    # System.cmd/3 has no stdin-input option across the Elixir versions
    # we support (~> 1.15), and Port handling adds complexity around
    # half-closed streams. The temp file is always removed in an `after`.
    name =
      "grafi-viz-#{System.system_time(:nanosecond)}-#{:erlang.unique_integer([:positive])}.dot"

    path = Path.join(System.tmp_dir!(), name)

    case File.write(path, dot_string) do
      :ok -> {:ok, path}
      {:error, reason} -> {:error, {:tempfile_error, reason}}
    end
  end

  defp run_graphviz(engine, format, dot_path) do
    args = ["-T#{format}", dot_path]

    case System.cmd(Atom.to_string(engine), args, stderr_to_stdout: false) do
      {output, 0} ->
        {:ok, output}

      {stderr, exit_code} ->
        {:error, {:graphviz_failed, stderr, exit_code}}
    end
  rescue
    e in ErlangError ->
      # System.cmd raises if the executable can't be found mid-flight.
      {:error, {:graphviz_failed, Exception.message(e), -1}}
  end
end
