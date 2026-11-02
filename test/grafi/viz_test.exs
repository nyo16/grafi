defmodule Grafi.VizTest do
  use ExUnit.Case, async: true

  alias Grafi.Viz

  # Tests tagged :graphviz need a real Graphviz install; test_helper.exs
  # excludes them when `dot` is not in PATH. Behaviour that does not
  # depend on real Graphviz output is covered with fake engines in
  # Grafi.VizPathTest.

  describe "graphviz_available?/1" do
    test "is false for an unsupported engine" do
      eng = Enum.random([:bogus_engine])
      refute Viz.graphviz_available?(eng)
    end
  end

  describe "render/3 — input validation (no graphviz required)" do
    test "an invalid format raises ArgumentError" do
      g = Grafi.new() |> Grafi.add_edge(:a, :b)
      fmt = Enum.random([:bogus_format])

      assert_raise ArgumentError, ~r/invalid format :bogus_format/, fn ->
        Viz.render(g, fmt)
      end
    end

    test "an unknown option raises ArgumentError" do
      g = Grafi.new() |> Grafi.add_edge(:a, :b)

      assert_raise ArgumentError, ~r/unknown keys \[:engin\]/, fn ->
        Viz.render(g, :svg, engin: :neato)
      end
    end

    test "invalid engine returns {:invalid_engine, _}" do
      g = Grafi.new() |> Grafi.add_edge(:a, :b)
      eng = Enum.random([:bogus_engine])
      assert {:error, {:invalid_engine, ^eng}} = Viz.render(g, :svg, engine: eng)
    end
  end

  describe "render/3 — graphviz integration" do
    @describetag :graphviz

    test "renders SVG containing <svg> element" do
      g =
        Grafi.new()
        |> Grafi.add_edges([{:a, :b}, {:b, :c}])

      assert {:ok, svg} = Viz.render(g, :svg)
      assert is_binary(svg)
      assert String.starts_with?(svg, "<?xml") or String.contains?(svg, "<svg")
    end

    test "renders non-empty PNG binary" do
      g =
        Grafi.new()
        |> Grafi.add_edges([{:a, :b}])

      assert {:ok, png} = Viz.render(g, :png)
      assert is_binary(png)
      assert byte_size(png) > 0
      # PNG magic bytes.
      assert <<0x89, "PNG", 0x0D, 0x0A, 0x1A, 0x0A, _::binary>> = png
    end

    test "renders DOT format (round-trip through graphviz)" do
      g = Grafi.new() |> Grafi.add_edge(:a, :b)
      assert {:ok, dot} = Viz.render(g, :dot)
      assert dot =~ "digraph"
    end

    test "passes :name through to the rendered graph" do
      g = Grafi.new() |> Grafi.add_edge(:a, :b)
      assert {:ok, dot} = Viz.render(g, :dot, name: "my_graph")
      assert dot =~ ~r/digraph\s+"?my_graph"?\s*\{/
    end

    test "render/3 with a different engine succeeds" do
      g = Grafi.new() |> Grafi.add_edges([{:a, :b}, {:b, :c}])
      assert {:ok, svg} = Viz.render(g, :svg, engine: :neato)
      assert is_binary(svg)
    end

    test "render!/3 returns binary on success" do
      g = Grafi.new() |> Grafi.add_edge(:a, :b)
      bin = Viz.render!(g, :svg)
      assert is_binary(bin)
    end
  end

  describe "render!/3 — failure" do
    test "raises ArgumentError for an invalid format" do
      g = Grafi.new() |> Grafi.add_edge(:a, :b)
      # Pick the bogus atom at runtime to bypass Elixir's static
      # type-check on the format argument.
      fmt = Enum.random([:bogus_format])

      assert_raise ArgumentError, ~r/invalid format :bogus_format/, fn ->
        Viz.render!(g, fmt)
      end
    end

    test "raises with the reason of an error result" do
      g = Grafi.new() |> Grafi.add_edge(:a, :b)
      eng = Enum.random([:bogus_engine])

      assert_raise RuntimeError, ~r/render!\/3 failed: \{:invalid_engine, :bogus_engine\}/, fn ->
        Viz.render!(g, :svg, engine: eng)
      end
    end
  end

  describe "render_to_file/3" do
    @describetag :tmp_dir

    test "infers format from extension and rejects unknown extensions", %{tmp_dir: tmp_dir} do
      g = Grafi.new() |> Grafi.add_edge(:a, :b)
      path = Path.join(tmp_dir, "graph.bogusext")

      assert {:error, {:invalid_format, "bogusext"}} = Viz.render_to_file(g, path)
    end

    test "an invalid explicit :format raises ArgumentError", %{tmp_dir: tmp_dir} do
      g = Grafi.new() |> Grafi.add_edge(:a, :b)
      path = Path.join(tmp_dir, "graph.svg")

      assert_raise ArgumentError, ~r/invalid format "svg"/, fn ->
        Viz.render_to_file(g, path, format: "svg")
      end

      refute File.exists?(path)
    end

    test "an unknown option raises ArgumentError", %{tmp_dir: tmp_dir} do
      g = Grafi.new() |> Grafi.add_edge(:a, :b)

      assert_raise ArgumentError, ~r/unknown keys \[:fromat\]/, fn ->
        Viz.render_to_file(g, Path.join(tmp_dir, "graph.svg"), fromat: :svg)
      end
    end
  end

  describe "render_to_file/3 — graphviz integration" do
    @describetag :tmp_dir
    @describetag :graphviz

    test "writes an SVG file at the given path", %{tmp_dir: tmp_dir} do
      g = Grafi.new() |> Grafi.add_edges([{:a, :b}, {:b, :c}])
      path = Path.join(tmp_dir, "graph.svg")

      assert :ok = Viz.render_to_file(g, path)
      assert File.exists?(path)
      assert File.read!(path) =~ ~r/<svg/
    end

    test "respects explicit :format override", %{tmp_dir: tmp_dir} do
      g = Grafi.new() |> Grafi.add_edge(:a, :b)
      path = Path.join(tmp_dir, "graph.out")

      assert :ok = Viz.render_to_file(g, path, format: :svg)
      assert File.read!(path) =~ ~r/<svg/
    end

    test "infers .gv, .pdf, .eps and .json", %{tmp_dir: tmp_dir} do
      g = Grafi.new() |> Grafi.add_edge(:a, :b)

      write = fn file ->
        path = Path.join(tmp_dir, file)
        assert :ok = Viz.render_to_file(g, path)
        File.read!(path)
      end

      assert write.("graph.gv") =~ "digraph"
      assert "%PDF" <> _ = write.("graph.pdf")
      assert "%!PS" <> _ = write.("graph.eps")
      assert "{" <> _ = write.("graph.json") |> String.trim_leading()
    end

    test "returns {:file_write_error, reason} when the target can't be written",
         %{tmp_dir: tmp_dir} do
      g = Grafi.new() |> Grafi.add_edge(:a, :b)
      path = Path.join([tmp_dir, "missing_dir", "graph.svg"])

      assert {:error, {:file_write_error, :enoent}} = Viz.render_to_file(g, path)
    end
  end
end
