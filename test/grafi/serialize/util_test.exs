defmodule Grafi.Serialize.UtilTest do
  use ExUnit.Case, async: true

  alias Grafi.Serialize.Util

  defp lines(text, comment \\ "#") do
    text
    |> Util.reduce_lines([], comment, fn line, acc -> {:cont, [line | acc]} end)
    |> Enum.reverse()
  end

  describe "reduce_lines/4" do
    test "handles CRLF and trims each line" do
      assert lines("a b\r\n  c d \r\n") == ["a b", "c d"]
    end

    test "skips blank and whitespace-only lines" do
      assert lines("\n   \n\t\r\na\n \t \nb") == ["a", "b"]
    end

    test "skips comment lines, but keeps them with a nil prefix" do
      text = "# head\na\n  # indented\nb # trailing\n"
      assert lines(text) == ["a", "b # trailing"]
      assert lines(text, nil) == ["# head", "a", "# indented", "b # trailing"]
    end

    test "yields the last line without a trailing newline" do
      assert lines("a\nb") == ["a", "b"]
      assert lines("only") == ["only"]
      assert lines("") == []
    end

    test "returns the halted value and stops calling fun" do
      result =
        Util.reduce_lines("a\nstop\nc\n", [], nil, fn
          "stop", acc -> {:halt, {:stopped, acc}}
          "c", _acc -> flunk("called after halt")
          line, acc -> {:cont, [line | acc]}
        end)

      assert result == {:stopped, ["a"]}
    end
  end

  describe "parse_int/1" do
    test "parses whole integers up to 19 characters" do
      assert Util.parse_int("42") == {:ok, 42}
      assert Util.parse_int("-7") == {:ok, -7}
      assert Util.parse_int("9223372036854775807") == {:ok, 9_223_372_036_854_775_807}
      assert Util.parse_int("-922337203685477580") == {:ok, -922_337_203_685_477_580}
    end

    test "rejects longer digit runs and trailing garbage" do
      assert Util.parse_int("12345678901234567890") == :error
      assert Util.parse_int(String.duplicate("9", 10_000)) == :error
      assert Util.parse_int("12x") == :error
      assert Util.parse_int("") == :error
    end
  end

  describe "parse_number/1" do
    test "parses integers and floats as floats" do
      assert Util.parse_number("3") == {:ok, 3.0}
      assert Util.parse_number("-2.5e1") == {:ok, -25.0}
    end

    test "rejects overflow, garbage and over-long input without raising" do
      assert Util.parse_number("1e400") == {:error, :bad_number}
      assert Util.parse_number("1.5abc") == {:error, :bad_number}
      assert Util.parse_number("0" <> String.duplicate("0", 300) <> "1") == {:error, :bad_number}
    end

    test "accepts input up to the length cap" do
      text = String.duplicate("0", 255) <> "1"
      assert byte_size(text) == 256
      assert Util.parse_number(text) == {:ok, 1.0}
    end
  end

  describe "own/1 and excerpt/1" do
    test "own/1 returns a binary that does not reference the input" do
      big = :binary.copy("x", Enum.random([100_000]))
      sub = binary_part(big, 10, 100)
      assert :binary.referenced_byte_size(sub) > 100

      owned = Util.own(sub)
      assert owned == sub
      assert :binary.referenced_byte_size(owned) == 100
    end

    test "excerpt/1 keeps short input and truncates long input to an owned copy" do
      assert Util.excerpt("short") == "short"

      long = String.duplicate("y", 10_000)
      ex = Util.excerpt(long)
      assert String.ends_with?(ex, "...")
      assert byte_size(ex) < 300
      assert :binary.referenced_byte_size(ex) < 1_000
    end
  end

  describe "cast_vertex/2" do
    test "uses existing atoms only when asked" do
      assert Util.cast_vertex("ok", true) == :ok
      assert Util.cast_vertex("ok", false) == "ok"

      assert Util.cast_vertex("grafi_util_test_no_such_atom", true) ==
               "grafi_util_test_no_such_atom"
    end

    test "a token over 255 characters stays a string" do
      token = String.duplicate("a", 300)
      assert Util.cast_vertex(token, true) == token
    end
  end

  describe "check_size/2" do
    test "returns :ok or {:too_large, size, max}" do
      assert Util.check_size("abc", max_bytes: 3) == :ok
      assert Util.check_size("abc", max_bytes: :infinity) == :ok
      assert Util.check_size("abcd", max_bytes: 3) == {:error, {:too_large, 4, 3}}
    end

    test "raises ArgumentError for an invalid :max_bytes" do
      for bad <- [0, -1, "10", 1.5] do
        assert_raise ArgumentError, ~r/:max_bytes/, fn ->
          Util.check_size("abc", max_bytes: bad)
        end
      end
    end
  end

  describe "field_splitter/1" do
    test "splits on whitespace runs or on an exact separator" do
      assert Util.field_splitter(nil).("a  b\tc") == ["a", "b", "c"]
      assert Util.field_splitter(",").("a b , c") == ["a b", "c"]
    end

    test "raises ArgumentError for an empty or non-string separator" do
      for bad <- ["", :comma, 44, [","]] do
        assert_raise ArgumentError, ~r/:separator/, fn -> Util.field_splitter(bad) end
      end
    end
  end
end
