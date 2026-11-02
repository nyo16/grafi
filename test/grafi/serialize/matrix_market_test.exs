defmodule Grafi.Serialize.MatrixMarketTest do
  use ExUnit.Case, async: true

  alias Grafi.Graph
  alias Grafi.Serialize.MatrixMarket

  doctest Grafi.Serialize.MatrixMarket

  describe "to_matrix_market/2" do
    test "directed graph emits 'general' symmetry" do
      g = Graph.new() |> Graph.add_edge(:a, :b, weight: 1.0)
      text = MatrixMarket.to_matrix_market(g)

      assert String.starts_with?(text, "%%MatrixMarket matrix coordinate real general")
    end

    test "undirected graph emits 'symmetric' symmetry" do
      g = Graph.new(type: :undirected) |> Graph.add_edge(:a, :b)
      text = MatrixMarket.to_matrix_market(g)

      assert String.starts_with?(text, "%%MatrixMarket matrix coordinate real symmetric")
    end

    test "writes GRAFI_VERTEX comments for id round-trip" do
      g = Graph.new() |> Graph.add_edge(:alpha, :beta)
      text = MatrixMarket.to_matrix_market(g)

      assert text =~ "%GRAFI_VERTEX 1 "
      assert text =~ "%GRAFI_VERTEX 2 "
      assert text =~ "atom:alpha"
    end

    test "size line has correct nnz" do
      g =
        Graph.new()
        |> Graph.add_edges([{:a, :b}, {:b, :c}, {:a, :c}])

      text = MatrixMarket.to_matrix_market(g)
      # 3 vertices, 3 entries
      assert text =~ "3 3 3"
    end
  end

  describe "from_matrix_market/2" do
    test "parses with vertex comments" do
      input = """
      %%MatrixMarket matrix coordinate real general
      %GRAFI_VERTEX 1 a
      %GRAFI_VERTEX 2 b
      2 2 1
      1 2 2.5
      """

      g = MatrixMarket.from_matrix_market(input)
      assert g.type == :directed
      assert Graph.has_edge?(g, "a", "b")
      [e] = Graph.edges_between(g, "a", "b")
      assert e.weight == 2.5
    end

    test "parses without vertex comments (integer ids)" do
      input = """
      %%MatrixMarket matrix coordinate real general
      2 2 1
      1 2 1.0
      """

      g = MatrixMarket.from_matrix_market(input)
      assert Graph.has_edge?(g, 1, 2)
    end

    test "ignores unknown comments" do
      input = """
      %%MatrixMarket matrix coordinate real general
      % some random comment
      %GRAFI_VERTEX 1 a
      %GRAFI_VERTEX 2 b
      % another comment
      2 2 1
      1 2 1.0
      """

      g = MatrixMarket.from_matrix_market(input)
      assert Graph.has_edge?(g, "a", "b")
    end

    test "missing header returns error" do
      assert {:error, _} = MatrixMarket.from_matrix_market("garbage\n")
    end

    test "malformed body returns error" do
      input = """
      %%MatrixMarket matrix coordinate real general
      2 2 1
      not numbers
      """

      assert {:error, _} = MatrixMarket.from_matrix_market(input)
    end

    test "isolated vertex preserved through comment + zero-row" do
      input = """
      %%MatrixMarket matrix coordinate real general
      %GRAFI_VERTEX 1 a
      %GRAFI_VERTEX 2 b
      %GRAFI_VERTEX 3 c
      3 3 1
      1 2 1.0
      """

      g = MatrixMarket.from_matrix_market(input)
      assert Graph.has_vertex?(g, "c")
    end
  end

  describe "from_matrix_market/2 limits" do
    @header "%%MatrixMarket matrix coordinate real general\n"

    test "a huge declared size is rejected before allocating vertices" do
      input = @header <> "1000000000000 1000000000000 0\n"

      assert {:error, {:too_many_vertices, 1_000_000_000_000}} =
               MatrixMarket.from_matrix_market(input)
    end

    test ":max_vertices caps rows and cols" do
      assert {:error, {:too_many_vertices, 11}} =
               MatrixMarket.from_matrix_market(@header <> "11 2 0\n", max_vertices: 10)

      assert {:error, {:too_many_vertices, 11}} =
               MatrixMarket.from_matrix_market(@header <> "2 11 0\n", max_vertices: 10)

      g = MatrixMarket.from_matrix_market(@header <> "10 10 0\n", max_vertices: 10)
      assert Graph.num_vertices(g) == 10
    end

    test ":max_vertices accepts :infinity" do
      g = MatrixMarket.from_matrix_market(@header <> "3 3 0\n", max_vertices: :infinity)
      assert Graph.num_vertices(g) == 3
    end

    test "an invalid :max_vertices raises" do
      assert_raise ArgumentError, fn ->
        MatrixMarket.from_matrix_market(@header <> "3 3 0\n", max_vertices: -1)
      end
    end

    test ":max_bytes rejects oversized input" do
      input = @header <> "1 1 0\n"
      size = byte_size(input)

      assert {:error, {:too_large, ^size, 10}} =
               MatrixMarket.from_matrix_market(input, max_bytes: 10)

      assert %Graph{} = MatrixMarket.from_matrix_market(input, max_bytes: size)
    end

    test "a row index beyond rows is out of range" do
      input = @header <> "2 2 1\n3 1 1.0\n"
      assert {:error, {:index_out_of_range, 3}} = MatrixMarket.from_matrix_market(input)
    end

    test "a column index beyond cols is out of range" do
      input = @header <> "2 2 1\n1 3 1.0\n"
      assert {:error, {:index_out_of_range, 3}} = MatrixMarket.from_matrix_market(input)
    end

    test "index 0 is out of range (indices are 1-based)" do
      input = @header <> "2 2 1\n0 1 1.0\n"
      assert {:error, {:index_out_of_range, 0}} = MatrixMarket.from_matrix_market(input)
    end

    test "fewer entries than nnz is a mismatch" do
      input = @header <> "2 2 2\n1 2 1.0\n"
      assert {:error, {:nnz_mismatch, 2, 1}} = MatrixMarket.from_matrix_market(input)
    end

    test "more entries than nnz is a mismatch" do
      input = @header <> "2 2 1\n1 2 1.0\n2 1 1.0\n"
      assert {:error, {:nnz_mismatch, 1, 2}} = MatrixMarket.from_matrix_market(input)
    end
  end

  describe "from_matrix_market/2 errors" do
    @header "%%MatrixMarket matrix coordinate real general\n"

    test "array format is a bad header" do
      input = "%%MatrixMarket matrix array real general\n2 2\n1.0\n"
      assert {:error, :bad_header} = MatrixMarket.from_matrix_market(input)
    end

    test "skew-symmetric is a bad header" do
      input = "%%MatrixMarket matrix coordinate real skew-symmetric\n2 2 0\n"
      assert {:error, :bad_header} = MatrixMarket.from_matrix_market(input)
    end

    test "missing header" do
      assert {:error, :missing_header} = MatrixMarket.from_matrix_market("2 2 0\n")
    end

    test "a vertex comment without an id" do
      input = @header <> "%GRAFI_VERTEX 1\n1 1 0\n"
      assert {:error, :bad_vertex_comment} = MatrixMarket.from_matrix_market(input)
    end

    test "a vertex comment with a non-integer index" do
      input = @header <> "%GRAFI_VERTEX x a\n1 1 0\n"
      assert {:error, {:bad_vertex_comment, "x"}} = MatrixMarket.from_matrix_market(input)
    end

    test "missing size line" do
      assert {:error, :missing_size_line} = MatrixMarket.from_matrix_market(@header)
    end

    test "a size line with two fields" do
      assert {:error, :bad_size_line} = MatrixMarket.from_matrix_market(@header <> "2 2\n")
    end

    test "a size line with non-integers" do
      assert {:error, :bad_size_line} = MatrixMarket.from_matrix_market(@header <> "2 x 0\n")
    end

    test "a negative size is a bad size line" do
      assert {:error, :bad_size_line} = MatrixMarket.from_matrix_market(@header <> "-1 -1 0\n")
    end

    test "a non-numeric value is an invalid weight" do
      input = @header <> "2 2 1\n1 2 abc\n"
      assert {:error, {:invalid_weight, "abc"}} = MatrixMarket.from_matrix_market(input)
    end

    test "an overflowing value is an invalid weight, not an exception message" do
      big = String.duplicate("9", 400)

      assert {:error, {:invalid_weight, ^big}} =
               MatrixMarket.from_matrix_market(@header <> "2 2 1\n1 2 #{big}\n")

      assert {:error, {:invalid_weight, "1e400"}} =
               MatrixMarket.from_matrix_market(@header <> "2 2 1\n1 2 1e400\n")
    end

    test "an entry with too many fields is malformed" do
      input = @header <> "2 2 1\n1 2 1.0 4.0\n"

      assert {:error, {:malformed_entry, "1 2 1.0 4.0"}} =
               MatrixMarket.from_matrix_market(input)
    end
  end

  describe "from_matrix_market/2 entries and ids" do
    test "2-column pattern entries are unit-weight edges" do
      input = """
      %%MatrixMarket matrix coordinate pattern general
      3 3 2
      1 2
      2 3
      """

      g = MatrixMarket.from_matrix_market(input)
      assert [%{weight: 1.0}] = Graph.edges_between(g, 1, 2)
      assert [%{weight: 1.0}] = Graph.edges_between(g, 2, 3)
    end

    test "tab-separated fields are accepted" do
      input = "%%MatrixMarket\tmatrix coordinate real general\n2\t2\t1\n1\t2\t2.0\n"
      g = MatrixMarket.from_matrix_market(input)
      assert [%{weight: 2.0}] = Graph.edges_between(g, 1, 2)
    end

    test "integer and float vertex ids round-trip" do
      g = Graph.new() |> Graph.add_edge(7, 2.5, weight: 1.0)
      text = MatrixMarket.to_matrix_market(g)

      assert text =~ "int:7"
      assert text =~ "float:2.5"

      g2 = MatrixMarket.from_matrix_market(text)
      assert Graph.has_edge?(g2, 7, 2.5)
    end

    test "an atom id unknown to the VM decodes to its string" do
      # The name is only ever written inside a string, so the atom does not exist.
      name = "grafi_mm_never_created_" <> Integer.to_string(System.unique_integer([:positive]))

      input = """
      %%MatrixMarket matrix coordinate real general
      %GRAFI_VERTEX 1 atom:#{name}
      1 1 0
      """

      g = MatrixMarket.from_matrix_market(input)
      assert Graph.vertices(g) == [name]
      assert_raise ArgumentError, fn -> String.to_existing_atom(name) end
    end
  end

  describe "round-trip" do
    test "directed graph round-trips with string ids" do
      g =
        Graph.new()
        |> Graph.add_edge("a", "b", weight: 2.5)
        |> Graph.add_edge("b", "c", weight: 3.0)
        |> Graph.add_edge("a", "c", weight: 7.0)

      text = MatrixMarket.to_matrix_market(g)
      g2 = MatrixMarket.from_matrix_market(text)

      assert g2.type == :directed
      assert Graph.num_vertices(g2) == 3
      [e_ab] = Graph.edges_between(g2, "a", "b")
      assert e_ab.weight == 2.5
    end

    test "atom vertex ids round-trip" do
      g = Graph.new() |> Graph.add_edge(:athens, :sparta, weight: 1.0)
      text = MatrixMarket.to_matrix_market(g)
      g2 = MatrixMarket.from_matrix_market(text)
      assert Graph.has_edge?(g2, :athens, :sparta)
    end

    test "undirected round-trip" do
      g =
        Graph.new(type: :undirected)
        |> Graph.add_edge("x", "y", weight: 1.5)

      text = MatrixMarket.to_matrix_market(g)
      g2 = MatrixMarket.from_matrix_market(text)

      assert g2.type == :undirected
      assert Graph.has_edge?(g2, "x", "y")
      assert Graph.has_edge?(g2, "y", "x")
    end

    test "parallel multi-edges collapse via weight sum (documented)" do
      g =
        Graph.new()
        |> Graph.add_edge("a", "b", weight: 1.0)
        |> Graph.add_edge("a", "b", weight: 2.0)

      text = MatrixMarket.to_matrix_market(g)
      g2 = MatrixMarket.from_matrix_market(text)

      # Multi-edges are collapsed to a single edge with summed weight.
      assert Graph.num_edges(g2) == 1
      [e] = Graph.edges_between(g2, "a", "b")
      assert e.weight == 3.0
    end
  end
end
