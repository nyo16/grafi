defmodule Grafi.Serialize.JSON do
  @moduledoc """
  Serialize and deserialize graphs to JSON.

  The schema is an adjacency-list representation:

      {
        "type": "directed" | "undirected",
        "vertices": [{"id": <any>, "label": <optional>}, ...],
        "edges":    [{"from": <id>, "to": <id>, "weight": <number>, "label": <optional>}, ...]
      }

  Uses Elixir's built-in `JSON` module (Elixir 1.18+) — no external JSON
  dependency is required.

  Note: JSON has no atom type — atom vertex IDs round-trip as strings.
  """

  alias Grafi.Graph
  alias Grafi.Serialize.Util

  @doc """
  Encodes a graph as a JSON string using the schema in the moduledoc.
  Vertex labels and edge labels are included only when present.
  """
  @spec to_json(Graph.t()) :: String.t()
  def to_json(%Graph{} = g) do
    data = %{
      type: g.type,
      vertices:
        Graph.vertices(g)
        |> Enum.map(fn v ->
          label = Graph.label(g, v)
          %{id: v} |> maybe_put(:label, label)
        end),
      edges:
        Graph.edges(g)
        |> Enum.map(fn e ->
          %{from: e.from, to: e.to, weight: e.weight}
          |> maybe_put(:label, e.label)
        end)
    }

    JSON.encode!(data)
  end

  @doc """
  Decodes a JSON string produced by `to_json/1` (or a hand-written one
  matching the schema) into a `Grafi.Graph`.

  ## Options
    * `:max_bytes` — maximum input size in bytes (default 64 MiB, or
      `:infinity`). Larger input returns `{:error, {:too_large, size, max}}`.

  Returns `{:ok, graph}` on success, or `{:error, reason}`:

    * `:malformed_json` — the input is not valid JSON or does not match the
      expected shape (missing `"type"`, `"vertices"`, or `"edges"`, or those
      fields have the wrong type).
    * `{:invalid_weight, value}` — an edge `"weight"` is present but is not a
      number (a string, `null`, a boolean, an array or an object), or is an
      integer too large to convert to a float. A missing weight defaults to
      `1.0`.
    * `{:invalid_label, value}` — a vertex or edge `"label"` is an array or
      an object; labels must be scalars.
    * `{:too_large, size, max}` — see `:max_bytes`.

  Unknown options raise `ArgumentError`.

  ## Examples

      iex> json = ~s({"type": "directed", "vertices": [], "edges": [{"from": 1, "to": 2}]})
      iex> {:ok, g} = Grafi.Serialize.JSON.from_json(json)
      iex> Grafi.Graph.num_edges(g)
      1
  """
  @spec from_json(String.t(), keyword()) ::
          {:ok, Graph.t()}
          | {:error,
             :malformed_json
             | {:invalid_weight, term()}
             | {:invalid_label, list() | map()}
             | {:too_large, non_neg_integer(), pos_integer()}}
  def from_json(json, opts \\ [])

  def from_json(json, opts) when is_binary(json) do
    opts = Keyword.validate!(opts, [:max_bytes])

    with :ok <- Util.check_size(json, opts) do
      decode(json)
    end
  end

  def from_json(_, opts) do
    Keyword.validate!(opts, [:max_bytes])
    {:error, :malformed_json}
  end

  @doc """
  Like `from_json/2`, but returns the graph and raises `ArgumentError`
  with the reason on failure.
  """
  @spec from_json!(String.t(), keyword()) :: Graph.t()
  def from_json!(json, opts \\ []), do: json |> from_json(opts) |> Util.unwrap!("JSON")

  defp decode(json) do
    with {:ok, data} <- JSON.decode(json),
         {:ok, type} <- decode_type(data),
         {:ok, vertices} <- fetch_list(data, "vertices"),
         {:ok, edges} <- fetch_list(data, "edges") do
      build_graph(type, vertices, edges)
    else
      _ -> {:error, :malformed_json}
    end
  end

  defp decode_type(%{"type" => "directed"}), do: {:ok, :directed}
  defp decode_type(%{"type" => "undirected"}), do: {:ok, :undirected}
  defp decode_type(_), do: :error

  defp fetch_list(data, key) do
    case Map.get(data, key) do
      list when is_list(list) -> {:ok, list}
      _ -> :error
    end
  end

  defp build_graph(type, vertices, edges) do
    with {:ok, g} <- reduce_vertices(Graph.new(type: type), vertices) do
      reduce_edges(g, edges)
    end
  end

  defp reduce_vertices(g, vertices) do
    Enum.reduce_while(vertices, {:ok, g}, fn
      %{"id" => id} = v, {:ok, acc} ->
        case fetch_label(v) do
          {:ok, opts} -> {:cont, {:ok, Graph.add_vertex(acc, id, opts)}}
          {:error, _} = error -> {:halt, error}
        end

      _bad, _acc ->
        {:halt, {:error, :malformed_json}}
    end)
  end

  defp reduce_edges(g, edges) do
    Enum.reduce_while(edges, {:ok, g}, fn
      %{"from" => from, "to" => to} = e, {:ok, acc} ->
        with {:ok, weight} <- fetch_weight(e),
             {:ok, label_opts} <- fetch_label(e) do
          {:cont, {:ok, Graph.add_edge(acc, from, to, [weight: weight] ++ label_opts)}}
        else
          {:error, _} = error -> {:halt, error}
        end

      _bad, _acc ->
        {:halt, {:error, :malformed_json}}
    end)
  end

  # Integers beyond the float range would raise ArithmeticError wherever a
  # weight meets a float. JSON floats are always finite (`1e400` does not
  # decode).
  @max_float_int trunc(1.797_693_134_862_315_7e308)

  defp fetch_weight(edge) do
    case Map.fetch(edge, "weight") do
      :error -> {:ok, 1.0}
      {:ok, w} when is_float(w) -> {:ok, w}
      {:ok, w} when is_integer(w) and abs(w) <= @max_float_int -> {:ok, w}
      {:ok, other} -> {:error, {:invalid_weight, other}}
    end
  end

  # A falsy (absent, `null` or `false`) label means no label.
  defp fetch_label(item) do
    case item["label"] do
      label when label in [nil, false] -> {:ok, []}
      label when is_map(label) or is_list(label) -> {:error, {:invalid_label, label}}
      label -> {:ok, [label: label]}
    end
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, val), do: Map.put(map, key, val)
end
