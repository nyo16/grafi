defmodule Grafi.Serialize.JSONTest do
  use ExUnit.Case, async: true

  alias Grafi.Graph
  alias Grafi.Serialize.JSON, as: GJSON

  defp edge_json(weight_fragment) do
    ~s({"type": "directed", "vertices": [], "edges": [{"from": "a", "to": "b"#{weight_fragment}}]})
  end

  describe "from_json/2 weights" do
    test "non-number weights return {:invalid_weight, value}" do
      assert GJSON.from_json(edge_json(~s(, "weight": "2.5"))) ==
               {:error, {:invalid_weight, "2.5"}}

      assert GJSON.from_json(edge_json(~s(, "weight": null))) == {:error, {:invalid_weight, nil}}
      assert GJSON.from_json(edge_json(~s(, "weight": true))) == {:error, {:invalid_weight, true}}
      assert GJSON.from_json(edge_json(~s(, "weight": [1]))) == {:error, {:invalid_weight, [1]}}

      assert GJSON.from_json(edge_json(~s(, "weight": {"v": 1}))) ==
               {:error, {:invalid_weight, %{"v" => 1}}}
    end

    test "numeric weights are kept and a missing weight defaults to 1.0" do
      assert [%{weight: 3}] = GJSON.from_json(edge_json(~s(, "weight": 3))) |> edges_ab()
      assert [%{weight: -0.5}] = GJSON.from_json(edge_json(~s(, "weight": -0.5))) |> edges_ab()
      assert [%{weight: 1.0}] = GJSON.from_json(edge_json("")) |> edges_ab()
    end

    test "integer weights outside the float range are rejected" do
      huge = String.duplicate("9", 400)

      assert {:error, {:invalid_weight, w}} = GJSON.from_json(edge_json(~s(, "weight": #{huge})))
      assert w == String.to_integer(huge)

      assert {:error, {:invalid_weight, _}} =
               GJSON.from_json(edge_json(~s(, "weight": -#{huge})))

      # The largest integer that still fits a float is kept.
      max = trunc(1.797_693_134_862_315_7e308)
      assert [%{weight: ^max}] = GJSON.from_json(edge_json(~s(, "weight": #{max}))) |> edges_ab()
    end
  end

  describe "from_json/2 labels" do
    test "array and object labels return {:invalid_label, value}" do
      assert GJSON.from_json(edge_json(~s(, "label": [1]))) == {:error, {:invalid_label, [1]}}

      assert GJSON.from_json(edge_json(~s(, "label": {"a": 1}))) ==
               {:error, {:invalid_label, %{"a" => 1}}}

      vertex = ~s({"type": "directed", "vertices": [{"id": "a", "label": ["x"]}], "edges": []})
      assert GJSON.from_json(vertex) == {:error, {:invalid_label, ["x"]}}
    end

    test "scalar labels are kept; null and false mean no label" do
      g = GJSON.from_json(edge_json(~s(, "label": "knows")))
      assert [%{label: "knows"}] = edges_ab(g)

      assert [%{label: nil}] = GJSON.from_json(edge_json(~s(, "label": null))) |> edges_ab()
      assert [%{label: nil}] = GJSON.from_json(edge_json(~s(, "label": false))) |> edges_ab()

      json = ~s({"type": "directed", "vertices": [{"id": "a", "label": 7}], "edges": []})
      assert Graph.label(GJSON.from_json(json), "a") == 7
    end
  end

  describe "from_json/2 :max_bytes" do
    test "rejects input above the limit with {:too_large, size, max}" do
      json = GJSON.to_json(Graph.new() |> Graph.add_edge("a", "b"))
      size = byte_size(json)

      assert GJSON.from_json(json, max_bytes: size - 1) == {:error, {:too_large, size, size - 1}}
      assert %Graph{} = GJSON.from_json(json, max_bytes: size)
      assert %Graph{} = GJSON.from_json(json, max_bytes: :infinity)
    end
  end

  defp edges_ab(g), do: Graph.edges_between(g, "a", "b")
end
