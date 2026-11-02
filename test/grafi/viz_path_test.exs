defmodule Grafi.VizPathTest do
  # Changes the OS `PATH`, which is global, so it must not run alongside
  # async tests.
  use ExUnit.Case, async: false

  alias Grafi.Viz

  @moduletag :tmp_dir

  # Fake Graphviz engines are /bin/sh scripts. Viz invokes them as
  # `<engine> -T<format> -o <out_path> <dot_path>`, so `$1` is the format
  # flag, `$3` the output file and `$4` the DOT input.

  setup do
    original = System.get_env("PATH")

    on_exit(fn ->
      if original, do: System.put_env("PATH", original), else: System.delete_env("PATH")
    end)

    %{original_path: original, graph: Grafi.new() |> Grafi.add_edge(:a, :b)}
  end

  defp fake_engine(tmp_dir, name, body) do
    bin = Path.join(tmp_dir, "bin")
    File.mkdir_p!(bin)
    exe = Path.join(bin, name)
    File.write!(exe, "#!/bin/sh\n" <> body)
    File.chmod!(exe, 0o755)
    bin
  end

  defp prepend_path(dir, original) do
    System.put_env("PATH", Enum.join([dir | List.wrap(original)], ":"))
  end

  defp use_fake_engine(%{tmp_dir: tmp_dir, original_path: original}, name \\ "dot", body) do
    tmp_dir |> fake_engine(name, body) |> prepend_path(original)
  end

  defp os_process_alive?(os_pid) do
    case System.cmd("ps", ["-o", "stat=", "-p", os_pid]) do
      {stat, 0} -> not String.starts_with?(stat, "Z")
      {_, _} -> false
    end
  end

  defp wait_until_dead(os_pid, attempts \\ 100)
  defp wait_until_dead(_os_pid, 0), do: false

  defp wait_until_dead(os_pid, attempts) do
    if os_process_alive?(os_pid) do
      Process.sleep(20)
      wait_until_dead(os_pid, attempts - 1)
    else
      true
    end
  end

  describe "engine missing from PATH" do
    test "render/3 and render_to_file/3 return :graphviz_not_installed", ctx do
      # PATH holds only a fake `neato`, so `dot` cannot be found.
      bin = fake_engine(ctx.tmp_dir, "neato", "exit 0\n")
      System.put_env("PATH", bin)

      refute Viz.graphviz_available?()
      refute Viz.graphviz_available?(:dot)
      assert Viz.graphviz_available?(:neato)

      assert {:error, :graphviz_not_installed} = Viz.render(ctx.graph, :svg)

      path = Path.join(ctx.tmp_dir, "graph.svg")
      assert {:error, :graphviz_not_installed} = Viz.render_to_file(ctx.graph, path)
      refute File.exists?(path)
    end
  end

  describe "render/3 with a fake engine" do
    test "returns the bytes Graphviz wrote to its -o file", ctx do
      use_fake_engine(ctx, ~S"""
      printf '%s %s\n' "$1" "$2" > "$3"
      cat "$4" >> "$3"
      """)

      assert {:ok, out} = Viz.render(ctx.graph, :svg)
      assert ["-Tsvg -o", dot] = String.split(out, "\n", parts: 2)
      assert dot =~ "digraph"

      assert {:ok, ^out} = Viz.render(ctx.graph, :svg, timeout: :infinity)
    end

    test "Graphviz warnings do not end up in the rendered output", ctx do
      use_fake_engine(ctx, ~S"""
      echo 'Warning: Could not load fonts' >&2
      echo 'chatter on stdout'
      printf 'IMAGE' > "$3"
      """)

      assert {:ok, "IMAGE"} = Viz.render(ctx.graph, :png)
    end

    test "passes :name through to the DOT source", ctx do
      use_fake_engine(ctx, ~S"""
      cat "$4" > "$3"
      """)

      assert {:ok, dot} = Viz.render(ctx.graph, :dot, name: "my_graph")
      assert dot =~ ~r/digraph\s+"?my_graph"?\s*\{/
    end

    test "runs the executable of the requested :engine", ctx do
      use_fake_engine(ctx, "dot", ~S"""
      printf 'dot' > "$3"
      """)

      use_fake_engine(ctx, "neato", ~S"""
      printf 'neato' > "$3"
      """)

      assert {:ok, "neato"} = Viz.render(ctx.graph, :svg, engine: :neato)
      assert {:ok, "dot"} = Viz.render(ctx.graph, :svg)
    end

    test "a non-zero exit returns {:graphviz_failed, output, code} with the real stderr",
         ctx do
      use_fake_engine(ctx, ~S"""
      echo 'Error: syntax error in line 1 near x' >&2
      exit 3
      """)

      assert {:error, {:graphviz_failed, output, 3}} = Viz.render(ctx.graph, :svg)
      assert output =~ "Error: syntax error in line 1 near x"
    end

    test "temp files are mode 0600 and removed afterwards", ctx do
      use_fake_engine(ctx, ~S"""
      perms=$(ls -l "$4" "$3" | cut -c1-10 | tr '\n' ' ')
      printf '%s\n%s\n%s' "$perms" "$4" "$3" > "$3"
      """)

      assert {:ok, out} = Viz.render(ctx.graph, :svg)
      assert [perms, dot_path, out_path] = String.split(out, "\n")
      assert perms == "-rw------- -rw------- "
      refute File.exists?(dot_path)
      refute File.exists?(out_path)
    end

    test "kills Graphviz and returns {:error, :timeout} when :timeout expires", ctx do
      pid_file = Path.join(ctx.tmp_dir, "engine.pid")

      use_fake_engine(ctx, """
      printf '%s\\n%s' "$$" "$4" > '#{pid_file}'
      exec sleep 30
      """)

      {micros, result} = :timer.tc(fn -> Viz.render(ctx.graph, :svg, timeout: 500) end)

      assert result == {:error, :timeout}
      assert micros < 10_000_000

      assert [os_pid, dot_path] = pid_file |> File.read!() |> String.split("\n")
      assert wait_until_dead(os_pid), "fake engine #{os_pid} is still running"
      refute File.exists?(dot_path)

      # No port messages are left behind in the caller's mailbox.
      Process.sleep(100)
      {:messages, messages} = Process.info(self(), :messages)
      refute Enum.any?(messages, &match?({port, _} when is_port(port), &1))
    end
  end

  describe "render_to_file/3 with a fake engine" do
    test "infers the format from the extension", ctx do
      use_fake_engine(ctx, ~S"""
      printf '%s' "$1" > "$3"
      """)

      for {file, flag} <- [
            {"graph.gv", "-Tdot"},
            {"graph.dot", "-Tdot"},
            {"graph.pdf", "-Tpdf"},
            {"graph.eps", "-Teps"},
            {"graph.json", "-Tjson"},
            {"graph.svg", "-Tsvg"},
            {"graph.png", "-Tpng"},
            {"GRAPH.SVG", "-Tsvg"}
          ] do
        path = Path.join(ctx.tmp_dir, file)
        assert :ok = Viz.render_to_file(ctx.graph, path), file
        assert File.read!(path) == flag, file
      end

      path = Path.join(ctx.tmp_dir, "graph.out")
      assert :ok = Viz.render_to_file(ctx.graph, path, format: :pdf)
      assert File.read!(path) == "-Tpdf"
    end

    test "returns {:file_write_error, reason} when the target can't be written", ctx do
      use_fake_engine(ctx, ~S"""
      printf 'IMAGE' > "$3"
      """)

      path = Path.join([ctx.tmp_dir, "missing_dir", "graph.svg"])

      assert {:error, {:file_write_error, :enoent}} = Viz.render_to_file(ctx.graph, path)
    end

    test "propagates Graphviz failures", ctx do
      use_fake_engine(ctx, ~S"""
      echo 'boom' >&2
      exit 1
      """)

      path = Path.join(ctx.tmp_dir, "graph.svg")

      assert {:error, {:graphviz_failed, "boom\n", 1}} = Viz.render_to_file(ctx.graph, path)
      refute File.exists?(path)
    end
  end
end
