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
  alias Grafi.Serialize.Util

  @type format :: :svg | :png | :pdf | :dot | :json | :eps
  @type engine :: :dot | :neato | :circo | :twopi | :fdp | :sfdp

  @valid_formats [:svg, :png, :pdf, :dot, :json, :eps]
  @valid_engines [:dot, :neato, :circo, :twopi, :fdp, :sfdp]

  @default_timeout 30_000
  @max_output 1_048_576

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
  etc. — or `{:error, reason}` on failure. An unsupported `format` or an
  unknown option raises `ArgumentError`.

  ## Formats

  `:svg`, `:png`, `:pdf`, `:dot`, `:json`, `:eps`.

  ## Options

    * `:engine` — Graphviz layout engine. One of `:dot` (default),
      `:neato`, `:circo`, `:twopi`, `:fdp`, `:sfdp`.
    * `:name` — graph name, passed to `Grafi.Serialize.DOT.to_dot/2`.
    * `:timeout` — milliseconds to wait for Graphviz (default `30_000`,
      or `:infinity`). On expiry the Graphviz OS process is killed.
      Any other value raises `ArgumentError`.

  The temporary files live in a private directory (mode `0700`) that is
  removed when the render returns. If the calling process is killed
  mid-render, that directory is left behind and Graphviz keeps running
  until it finishes on its own.

  ## Errors

    * `{:error, :graphviz_not_installed}` — the engine executable is not
      in PATH.
    * `{:error, {:invalid_engine, eng}}` — unsupported engine atom.
    * `{:error, {:graphviz_failed, output, exit_code}}` — Graphviz
      returned a non-zero exit status; `output` is what it printed
      (stdout and stderr combined, truncated to 1 MiB). `exit_code` is
      `-1` when the executable could not be started (for example it
      vanished or lost its exec bit after the `PATH` lookup).
    * `{:error, :timeout}` — Graphviz did not finish within `:timeout`.
    * `{:error, {:tempfile_error, reason}}` — a temporary file could not
      be created, written or read; `reason` is `:no_tmp_dir` when
      `System.tmp_dir/0` finds no writable directory.
  """
  @spec render(Graph.t(), format(), keyword()) ::
          {:ok, binary()}
          | {:error,
             :graphviz_not_installed
             | :timeout
             | {:invalid_engine, atom()}
             | {:graphviz_failed, String.t(), integer()}
             | {:tempfile_error, term()}}
  def render(graph, format \\ :svg, opts \\ [])

  def render(_graph, format, _opts) when format not in @valid_formats do
    raise ArgumentError,
          "invalid format #{inspect(format)} (expected one of #{inspect(@valid_formats)})"
  end

  def render(%Graph{} = graph, format, opts) do
    opts = Keyword.validate!(opts, engine: :dot, timeout: @default_timeout, name: "G")
    engine = opts[:engine]

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

  Returns `:ok` on success, `{:error, reason}` otherwise. An extension
  that names no supported format is `{:error, {:invalid_format, ext}}`;
  an unsupported explicit `:format` raises `ArgumentError`, as in
  `render/3`.

  ## Options

  Same as `render/3`, plus:

    * `:format` — explicit format override (skips extension inference).
  """
  @spec render_to_file(Graph.t(), Path.t(), keyword()) ::
          :ok
          | {:error,
             :graphviz_not_installed
             | :timeout
             | {:invalid_format, String.t()}
             | {:invalid_engine, atom()}
             | {:graphviz_failed, String.t(), integer()}
             | {:tempfile_error, term()}
             | {:file_write_error, File.posix()}}
  def render_to_file(%Graph{} = graph, path, opts \\ []) do
    {format, opts} =
      opts
      |> Keyword.validate!([:format, engine: :dot, timeout: @default_timeout, name: "G"])
      |> Keyword.pop(:format)

    case format || infer_format(path) do
      {:error, _} = err ->
        err

      format ->
        with {:ok, bin} <- render(graph, format, opts) do
          case File.write(path, bin) do
            :ok -> :ok
            {:error, reason} -> {:error, {:file_write_error, reason}}
          end
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
  # files live in a private per-render directory removed in an `after`.
  defp do_render(graph, format, exe, opts) do
    timeout = validate_timeout(opts[:timeout])
    dot_string = Grafi.Serialize.DOT.to_dot(graph, name: opts[:name])

    with_private_dir(fn dir ->
      dot_path = Path.join(dir, "in.dot")
      out_path = Path.join(dir, "out.#{format}")

      with :ok <- write_tempfile(dot_path, dot_string) do
        run_graphviz(exe, ["-T#{format}", "-o", out_path, dot_path], out_path, timeout)
      end
    end)
  end

  defp validate_timeout(:infinity), do: :infinity
  defp validate_timeout(t) when is_integer(t) and t > 0, do: t

  defp validate_timeout(other) do
    raise ArgumentError,
          "expected :timeout to be a positive integer or :infinity, got: #{inspect(other)}"
  end

  defp with_private_dir(fun) do
    case create_private_dir(System.tmp_dir(), 5) do
      {:ok, dir} ->
        try do
          fun.(dir)
        after
          _ = File.rm_rf(dir)
        end

      {:error, _} = err ->
        err
    end
  end

  # `File.mkdir/1` fails on an existing path, so a pre-created directory or
  # symlink cannot be hijacked; the directory is tightened to 0700 before
  # any file is created inside it, and the files inherit that protection.
  defp create_private_dir(nil, _attempts), do: {:error, {:tempfile_error, :no_tmp_dir}}

  defp create_private_dir(tmp, attempts) do
    dir = Path.join(tmp, "grafi-viz-" <> Base.url_encode64(:rand.bytes(12)))

    case File.mkdir(dir) do
      :ok ->
        case File.chmod(dir, 0o700) do
          :ok ->
            {:ok, dir}

          {:error, reason} ->
            _ = File.rm_rf(dir)
            {:error, {:tempfile_error, reason}}
        end

      {:error, :eexist} when attempts > 1 ->
        create_private_dir(tmp, attempts - 1)

      {:error, reason} ->
        {:error, {:tempfile_error, reason}}
    end
  end

  defp write_tempfile(path, content) do
    case File.write(path, content, [:exclusive, :binary]) do
      :ok -> :ok
      {:error, reason} -> {:error, {:tempfile_error, reason}}
    end
  end

  defp run_graphviz(exe, argv, out_path, timeout) do
    with {:ok, port} <- open_port(exe, argv) do
      port
      |> await_port({[], 0}, deadline(timeout))
      |> finish(port, out_path)
    end
  end

  defp finish({0, _output}, port, out_path) do
    flush_exit(port)
    read_output(out_path)
  end

  defp finish({code, output}, port, _out_path) do
    flush_exit(port)
    {:error, {:graphviz_failed, output, code}}
  end

  # The process may have exited just as the deadline passed. If its exit
  # status is already queued, use it: killing by OS pid now could hit an
  # unrelated process that reused the pid.
  defp finish(:timeout, port, out_path) do
    receive do
      {^port, {:exit_status, code}} ->
        finish({code, ""}, port, out_path)
    after
      0 -> kill_port(port)
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

  defp await_port(port, {acc, _size} = buf, deadline) do
    receive do
      {^port, {:data, data}} ->
        await_port(port, append_output(buf, data), deadline)

      {^port, {:exit_status, code}} ->
        {code, IO.iodata_to_binary(acc)}
    after
      remaining(deadline) -> :timeout
    end
  end

  # Graphviz diagnostics are kept for error payloads only, so cap them.
  defp append_output({_acc, size} = buf, _data) when size >= @max_output, do: buf

  defp append_output({acc, size}, data) do
    take = min(byte_size(data), @max_output - size)
    {[acc, Util.own(binary_part(data, 0, take))], size + take}
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
    flush_exit(port)
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

  # A caller that traps exits also receives the port's `{:EXIT, port, _}`.
  defp flush_exit(port) do
    receive do
      {:EXIT, ^port, _} -> :ok
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
