defmodule Grafi.EdgeTest do
  use ExUnit.Case, async: true

  alias Grafi.Edge

  describe "struct" do
    test "defaults weight to 1.0 and label to nil" do
      assert %Edge{from: :a, to: :b} == %Edge{from: :a, to: :b, weight: 1.0, label: nil}
    end

    test ":from and :to are required" do
      assert_raise ArgumentError, ~r/the following keys must also be given.*:from/, fn ->
        struct!(Edge, to: :b)
      end

      assert_raise ArgumentError, ~r/the following keys must also be given.*:to/, fn ->
        struct!(Edge, from: :a)
      end
    end
  end

  describe "Inspect" do
    test "shows endpoints and weight" do
      assert inspect(%Edge{from: :a, to: "b", weight: 2.5}) == ~s(#Grafi.Edge<:a -> "b", w: 2.5>)
    end

    test "inspects the weight, so integers and floats differ" do
      assert inspect(%Edge{from: 1, to: 2, weight: 3}) == "#Grafi.Edge<1 -> 2, w: 3>"
      assert inspect(%Edge{from: 1, to: 2, weight: 3.0}) == "#Grafi.Edge<1 -> 2, w: 3.0>"
    end

    test "shows a label when present, inspected" do
      e = %Edge{from: :a, to: :b, label: "road"}
      assert inspect(e) == ~s(#Grafi.Edge<:a -> :b, w: 1.0, label: "road">)

      assert inspect(%Edge{from: :a, to: :b, label: false}) ==
               "#Grafi.Edge<:a -> :b, w: 1.0, label: false>"
    end

    test "respects inspect options" do
      assert inspect(%Edge{from: 255, to: 16, weight: 10}, base: :hex) ==
               "#Grafi.Edge<0xFF -> 0x10, w: 0xA>"

      e = %Edge{from: :a, to: :b, label: String.duplicate("x", 20)}

      assert inspect(e, printable_limit: 3) ==
               ~s(#Grafi.Edge<:a -> :b, w: 1.0, label: "xxx" <> ...>)

      assert inspect(%Edge{from: [1, 2, 3], to: :b}, limit: 1) ==
               "#Grafi.Edge<[1, ...] -> :b, w: 1.0>"
    end
  end
end
