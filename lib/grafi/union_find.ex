defmodule Grafi.UnionFind do
  @moduledoc """
  A persistent (immutable) Union-Find / Disjoint-Set forest with
  path compression and union-by-rank.

  Because Elixir data is immutable, every operation that mutates the
  structure — including `find/2`, which performs path compression —
  returns the updated `%Grafi.UnionFind{}`. Callers must thread the
  returned value through their pipeline to benefit from the amortised
  near-O(α(n)) bound.

  This module is a general-purpose primitive: it underpins Kruskal's
  MST in `Grafi.Algo.MST`, but it's also useful for any "are these two
  things in the same group?" problem (connected components, equivalence
  classes, percolation, image segmentation, etc.).

  ## Example

      iex> uf = Grafi.UnionFind.new([:a, :b, :c, :d])
      iex> Grafi.UnionFind.count_sets(uf)
      4
      iex> uf = uf |> Grafi.UnionFind.union(:a, :b) |> Grafi.UnionFind.union(:c, :d)
      iex> Grafi.UnionFind.count_sets(uf)
      2
      iex> Grafi.UnionFind.connected?(uf, :a, :b)
      true
      iex> Grafi.UnionFind.connected?(uf, :a, :c)
      false
  """

  @type item :: any()
  @type t :: %__MODULE__{
          parents: %{item() => item()},
          ranks: %{item() => non_neg_integer()}
        }

  defstruct parents: %{}, ranks: %{}

  @doc """
  Creates an empty Union-Find forest.

  ## Examples

      iex> Grafi.UnionFind.count_sets(Grafi.UnionFind.new())
      0
  """
  @spec new() :: t()
  def new, do: %__MODULE__{}

  @doc """
  Creates a Union-Find forest pre-populated with `items` as singletons.

  ## Examples

      iex> uf = Grafi.UnionFind.new([:a, :b, :c])
      iex> Grafi.UnionFind.count_sets(uf)
      3
  """
  @spec new(Enumerable.t()) :: t()
  def new(items) do
    Enum.reduce(items, %__MODULE__{}, &make_set(&2, &1))
  end

  @doc """
  Adds `x` as a singleton if it isn't already in the forest. Otherwise a
  no-op.
  """
  @spec make_set(t(), item()) :: t()
  def make_set(%__MODULE__{parents: p, ranks: r} = uf, x) do
    if Map.has_key?(p, x) do
      uf
    else
      %__MODULE__{parents: Map.put(p, x, x), ranks: Map.put(r, x, 0)}
    end
  end

  @doc """
  Finds the canonical representative (root) of the set containing `x`,
  performing path compression along the way.

  Returns `{root, updated_uf}`. If `x` is unknown it is implicitly
  inserted as a singleton, so `find/2` is always safe to call.

  ## Examples

      iex> uf = Grafi.UnionFind.new([:a, :b]) |> Grafi.UnionFind.union(:a, :b)
      iex> {root, _uf} = Grafi.UnionFind.find(uf, :a)
      iex> {root2, _uf} = Grafi.UnionFind.find(uf, :b)
      iex> root == root2
      true
  """
  @spec find(t(), item()) :: {item(), t()}
  def find(%__MODULE__{} = uf, x) do
    uf = make_set(uf, x)
    do_find(uf, x, [])
  end

  defp do_find(%__MODULE__{parents: p} = uf, x, path) do
    case Map.fetch!(p, x) do
      ^x -> {x, compress(uf, path, x)}
      parent -> do_find(uf, parent, [x | path])
    end
  end

  defp compress(uf, [], _root), do: uf

  defp compress(%__MODULE__{parents: p} = uf, path, root) do
    new_parents = Enum.reduce(path, p, fn node, acc -> Map.put(acc, node, root) end)
    %{uf | parents: new_parents}
  end

  @doc """
  Unions the sets containing `x` and `y`. Uses union-by-rank.

  Returns the updated forest. If `x` and `y` are already in the same
  set, the forest is returned unchanged (modulo any path compression
  performed by the internal `find/2` calls).
  """
  @spec union(t(), item(), item()) :: t()
  def union(%__MODULE__{} = uf, x, y) do
    {rx, uf} = find(uf, x)
    {ry, uf} = find(uf, y)

    if rx === ry do
      uf
    else
      # The match also proves `uf` is a struct, so plain map updates suffice
      # (Elixir 1.19's type checker warns on `%__MODULE__{uf | ...}` here).
      %__MODULE__{parents: p, ranks: r} = uf
      rank_x = Map.fetch!(r, rx)
      rank_y = Map.fetch!(r, ry)

      cond do
        rank_x < rank_y ->
          %{uf | parents: Map.put(p, rx, ry)}

        rank_x > rank_y ->
          %{uf | parents: Map.put(p, ry, rx)}

        true ->
          %{uf | parents: Map.put(p, ry, rx), ranks: Map.put(r, rx, rank_x + 1)}
      end
    end
  end

  @doc """
  Returns `true` if `x` and `y` belong to the same set.

  Unknown items are treated as singletons (and therefore never
  connected to anything else).
  """
  @spec connected?(t(), item(), item()) :: boolean()
  def connected?(%__MODULE__{parents: p}, x, y) do
    cond do
      not Map.has_key?(p, x) ->
        false

      not Map.has_key?(p, y) ->
        false

      true ->
        {rx, _} = find(%__MODULE__{parents: p, ranks: %{}}, x)
        {ry, _} = find(%__MODULE__{parents: p, ranks: %{}}, y)
        rx === ry
    end
  end

  @doc """
  Returns a snapshot of the partitions as `%{root => MapSet.t(members)}`.
  """
  @spec sets(t()) :: %{item() => MapSet.t()}
  def sets(%__MODULE__{parents: p} = uf) do
    Enum.reduce(Map.keys(p), %{}, fn item, acc ->
      {root, _} = find(uf, item)
      Map.update(acc, root, MapSet.new([item]), &MapSet.put(&1, item))
    end)
  end

  @doc """
  Returns the number of disjoint sets in the forest.

  ## Examples

      iex> uf = Grafi.UnionFind.new([:a, :b, :c])
      iex> Grafi.UnionFind.count_sets(uf)
      3
      iex> uf = Grafi.UnionFind.union(uf, :a, :b)
      iex> Grafi.UnionFind.count_sets(uf)
      2
  """
  @spec count_sets(t()) :: non_neg_integer()
  def count_sets(%__MODULE__{parents: p}) do
    Enum.count(p, fn {k, v} -> k === v end)
  end
end
