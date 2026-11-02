defmodule Grafi.Viz do
  @moduledoc """
  Render Grafi graphs to image formats by shelling out to Graphviz.

  This module is a thin wrapper around the `dot` (and friends) CLI. It
  serialises the graph to DOT via `Grafi.Serialize.DOT.to_dot/2`, writes
  the DOT to a private temporary file, runs the chosen Graphviz engine
  on it, and returns the resulting bytes.

  ## Requirements

  Graphviz must be installed and the engine executable (`dot` by
  default) must be in `PATH`. Check at runtime with
  `graphviz_available?/1`.

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

  @default_timeout 30_000

  # ── Public API ────────────────────────────────────────────────────────

  @doc """
  Returns `true` if the executable for the Graphviz `engine` (default
  `:dot`) is in `PATH`. Returns `false` for an unsupported engine.
  """
  @spec graphviz_available?(engine()) :: boolean()
  def graphviz_available?(engine \\ :dot) do
    find_engine(engine) != nil
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
    * `:timeout` — milliseconds to wait for Graphviz (default `30_000`,
      or `:infinity`). On expiry the Graphviz OS process is killed.

  ## Errors

    * `{:error, :graphviz_not_installed}` — the engine executable is not
      in PATH.
    * `{:error, {:invalid_format, fmt}}` — unsupported format atom.
    * `{:error, {:invalid_engine, eng}}` — unsupported engine atom.
    * `{:error, {:graphviz_failed, output, exit_code}}` — Graphviz
      returned a non-zero exit status; `output` is what it printed
      (stdout and stderr combined).
    * `{:error, :timeout}` — Graphviz did not finish within `:timeout`.
    * `{:error, {:tempfile_error, reason}}` — a temporary file could not
      be created, written or read.
  """
  @spec render(Graph.t(), format(), keyword()) ::
          {:ok, binary()}
          | {:error,
             :graphviz_not_installed
             | :timeout
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

      exe = find_engine(engine) ->
        do_render(graph, format, exe, opts)

      true ->
        {:error, :graphviz_not_installed}
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
  from the file extension (e.g. `"foo.svg"` → `:svg`, `"foo.gv"` →
  `:dot`).

  Returns `:ok` on success, `{:error, reason}` otherwise.

  ## Options

  Same as `render/3`, plus:

    * `:format` — explicit format override (skips extension inference).
  """
  @spec render_to_file(Graph.t(), Path.t(), keyword()) ::
          :ok
          | {:error,
             :graphviz_not_installed
             | :timeout
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

  defp find_engine(engine) when engine in @valid_engines do
    System.find_executable(Atom.to_string(engine))
  end

  defp find_engine(_engine), do: nil

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

  # Graphviz reads the DOT from one temp file and writes its output to
  # another (`-o`). Feeding stdin through a Port is not an option: a Port
  # cannot close only its write end, so Graphviz would never see EOF.
  # Writing to a file rather than stdout keeps Graphviz warnings, which
  # arrive on the merged stderr stream, out of the rendered bytes. Both
  # files are removed in an `after`.
  defp do_render(graph, format, exe, opts) do
    timeout = Keyword.get(opts, :timeout, @default_timeout)
    dot_string = Grafi.Serialize.DOT.to_dot(graph, Keyword.take(opts, [:name]))

    with_tempfile("dot", dot_string, fn dot_path ->
      with_tempfile(Atom.to_string(format), "", fn out_path ->
        run_graphviz(exe, ["-T#{format}", "-o", out_path, dot_path], out_path, timeout)
      end)
    end)
  end

  defp with_tempfile(ext, content, fun) do
    case create_tempfile(ext, content) do
      {:ok, path} ->
        try do
          fun.(path)
        after
          _ = File.rm(path)
        end

      {:error, _} = err ->
        err
    end
  end

  # `:exclusive` refuses an existing path (no symlink or pre-created file
  # can be hijacked), and the mode is tightened before any content lands.
  defp create_tempfile(ext, content) do
    name =
      "grafi-viz-#{System.system_time(:nanosecond)}-#{:erlang.unique_integer([:positive])}.#{ext}"

    path = Path.join(System.tmp_dir!(), name)

    write = fn io ->
      with :ok <- File.chmod(path, 0o600), do: IO.binwrite(io, content)
    end

    case File.open(path, [:write, :exclusive, :binary], write) do
      {:ok, :ok} ->
        {:ok, path}

      {:ok, {:error, reason}} ->
        _ = File.rm(path)
        {:error, {:tempfile_error, reason}}

      {:error, reason} ->
        {:error, {:tempfile_error, reason}}
    end
  end

  defp run_graphviz(exe, argv, out_path, timeout) do
    with {:ok, port} <- open_port(exe, argv) do
      case await_port(port, [], deadline(timeout)) do
        {0, _output} -> read_output(out_path)
        {code, output} -> {:error, {:graphviz_failed, output, code}}
        :timeout -> kill_port(port)
      end
    end
  end

  defp open_port(exe, argv) do
    {:ok,
     Port.open({:spawn_executable, exe}, [
       :binary,
       :exit_status,
       :stderr_to_stdout,
       args: argv
     ])}
  rescue
    # The executable vanished or lost its exec bit after the PATH lookup.
    e in ErlangError -> {:error, {:graphviz_failed, Exception.message(e), -1}}
  end

  defp await_port(port, acc, deadline) do
    receive do
      {^port, {:data, data}} ->
        await_port(port, [acc | data], deadline)

      {^port, {:exit_status, code}} ->
        {code, IO.iodata_to_binary(acc)}
    after
      remaining(deadline) -> :timeout
    end
  end

  defp deadline(:infinity), do: :infinity
  defp deadline(timeout), do: System.monotonic_time(:millisecond) + timeout

  defp remaining(:infinity), do: :infinity
  defp remaining(deadline), do: max(deadline - System.monotonic_time(:millisecond), 0)

  # Closing a Port does not stop the OS process, so kill it explicitly
  # (the shell builtin `kill` needs nothing from PATH), then drop any
  # messages the port delivered before it was closed.
  defp kill_port(port) do
    case Port.info(port, :os_pid) do
      {:os_pid, os_pid} ->
        _ = :os.cmd(kill_command(os_pid))
        :ok

      nil ->
        :ok
    end

    close_port(port)
    flush_port(port)
    {:error, :timeout}
  end

  defp kill_command(os_pid) do
    case :os.type() do
      {:win32, _} -> ~c"taskkill /F /T /PID #{os_pid}"
      _ -> ~c"kill -9 #{os_pid}"
    end
  end

  defp close_port(port) do
    Port.close(port)
  catch
    # The killed process may already have closed the port by itself.
    :error, :badarg -> true
  end

  defp flush_port(port) do
    receive do
      {^port, _} -> flush_port(port)
    after
      0 -> :ok
    end
  end

  defp read_output(out_path) do
    case File.read(out_path) do
      {:ok, bin} -> {:ok, bin}
      {:error, reason} -> {:error, {:tempfile_error, reason}}
    end
  end
end
