defmodule Grafi.Args do
  @moduledoc false
  # Argument validation shared by the NIF-capable algorithms. It runs before
  # engine dispatch, so both engines reject exactly the same inputs with
  # ArgumentError.

  alias Grafi.Graph

  @doc """
  Fetches `:engine` from `opts` (default `:auto`), raising `ArgumentError`
  unless it is `:auto`, `:nif` or `:elixir`. Call it before any early return
  so an invalid engine is rejected on every input.
  """
  @spec engine!(keyword()) :: :auto | :nif | :elixir
  def engine!(opts) do
    case Keyword.get(opts, :engine, :auto) do
      engine when engine in [:auto, :nif, :elixir] ->
        engine

      other ->
        raise ArgumentError, "expected :engine to be :auto, :nif or :elixir, got: #{inspect(other)}"
    end
  end

  @doc """
  Fetches `key` from `opts` (or `default`) as a float, raising
  `ArgumentError` unless it is a number satisfying `valid?`. Integers are
  accepted and coerced, so `resolution: 2` is valid.
  """
  @spec float!(keyword(), atom(), number(), (float() -> boolean()), String.t()) :: float()
  def float!(opts, key, default, valid?, expected) do
    value = Keyword.get(opts, key, default)

    if is_number(value) and valid?.(value * 1.0) do
      value * 1.0
    else
      raise ArgumentError, "expected #{inspect(key)} to be #{expected}, got: #{inspect(value)}"
    end
  end

  @doc "Fetches `key` as a positive integer, raising `ArgumentError` otherwise."
  @spec pos_integer!(keyword(), atom(), pos_integer()) :: pos_integer()
  def pos_integer!(opts, key, default) do
    case Keyword.get(opts, key, default) do
      n when is_integer(n) and n > 0 ->
        n

      other ->
        raise ArgumentError,
              "expected #{inspect(key)} to be a positive integer, got: #{inspect(other)}"
    end
  end

  @doc "Fetches `key` as a boolean, raising `ArgumentError` otherwise."
  @spec boolean!(keyword(), atom(), boolean()) :: boolean()
  def boolean!(opts, key, default) do
    case Keyword.get(opts, key, default) do
      b when is_boolean(b) ->
        b

      other ->
        raise ArgumentError, "expected #{inspect(key)} to be a boolean, got: #{inspect(other)}"
    end
  end

  @doc "Returns `true` if any edge of `g` has a weight satisfying `pred`."
  @spec any_weight?(Graph.t(), (number() -> boolean())) :: boolean()
  def any_weight?(%Graph{out_edges: out}, pred) do
    Enum.any?(out, fn {_v, targets} ->
      Enum.any?(targets, fn {_to, edges} -> Enum.any?(edges, &pred.(&1.weight)) end)
    end)
  end

  @doc "Returns `true` if any edge of `g` has a negative weight."
  @spec negative_weight?(Graph.t()) :: boolean()
  def negative_weight?(%Graph{} = g), do: any_weight?(g, &(&1 < 0))

  @doc "Raises `ArgumentError` if any edge of `g` has a negative weight."
  @spec non_negative_weights!(Graph.t()) :: :ok
  def non_negative_weights!(%Graph{} = g) do
    if negative_weight?(g),
      do: raise(ArgumentError, "this algorithm requires non-negative edge weights"),
      else: :ok
  end

  @doc "Raises `ArgumentError` unless every edge of `g` has a positive weight."
  @spec positive_weights!(Graph.t()) :: :ok
  def positive_weights!(%Graph{} = g) do
    if any_weight?(g, &(&1 <= 0)),
      do: raise(ArgumentError, "this algorithm requires positive edge weights"),
      else: :ok
  end
end
