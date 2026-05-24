defmodule Grafi.VizTest do
  use ExUnit.Case, async: true

  alias Grafi.Viz

  @graphviz_available Viz.graphviz_available?()

  describe "graphviz_available?/0" do
    test "returns a boolean" do
      assert is_boolean(Viz.graphviz_available?())
    end
  end

  describe "render/3 — input validation (no graphviz required)" do
    test "invalid format atom returns {:invalid_format, _}" do
      g = Grafi.new() |> Grafi.add_edge(:a, :b)
      fmt = String.to_atom("bogus_" <> Integer.to_string(:rand.uniform(1_000_000)))
      assert {:error, {:invalid_format, ^fmt}} = Viz.render(g, fmt)
    end

    test "invalid engine returns {:invalid_engine, _}" do
      g = Grafi.new() |> Grafi.add_edge(:a, :b)
      eng = String.to_atom("bogus_eng_" <> Integer.to_string(:rand.uniform(1_000_000)))
      assert {:error, {:invalid_engine, ^eng}} = Viz.render(g, :svg, engine: eng)
    end
  end

  describe "render/3 — graphviz integration" do
    @describetag :graphviz

    if @graphviz_available do
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
    else
      test "skipped — graphviz not installed" do
        # Placeholder so the describe block isn't empty; never fails.
        assert true
      end
    end
  end

  describe "render!/3 — failure" do
    test "raises on error (invalid format)" do
      g = Grafi.new() |> Grafi.add_edge(:a, :b)
      # Build the bogus atom at runtime to bypass Elixir's static
      # type-check on the format argument.
      fmt = String.to_atom("bogus_fmt_" <> Integer.to_string(:rand.uniform(1_000_000)))

      assert_raise RuntimeError, ~r/Grafi.Viz.render!/, fn ->
        Viz.render!(g, fmt)
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

    if @graphviz_available do
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
        assert File.exists?(path)
      end
    end
  end
end
