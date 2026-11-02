defmodule Grafi.Algo.Cliques do
  @dialyzer :no_opaque

  @moduledoc """
  Maximal clique enumeration via Bron–Kerbosch with pivoting.

  A **clique** is a set of mutually adjacent vertices; a **maximal clique**
  cannot be extended by adding another vertex. The **maximum clique** is the
  largest maximal clique (NP-hard in general).

  > #### Warning {: .warning}
  >
  > Clique enumeration is worst-case exponential in the number of vertices
  > and is NP-hard. These algorithms are intended for small or sparse graphs;
  > avoid running them on large dense inputs.

  All algorithms operate on the **underlying undirected** graph. Self-loops
  are ignored (a vertex is never considered adjacent to itself for the
  purposes of clique-finding).
  """

  alias Grafi.Algo.Neighborhood
  alias Grafi.Graph

  @doc """
  Enumerates every maximal clique using Bron–Kerbosch with pivot selection.

  Returns a list of `MapSet`s. Order of the result is unspecified.

  ## Options
    * `:max_results` — stop after this many maximal cliques have been found
      and return them. Defaults to `:infinity` (enumerate all). Because
      enumeration is worst-case exponential, set this when running on
      untrusted or large dense graphs to bound the work.

  ## Examples

      iex> g = Grafi.Graph.new(type: :undirected)
      ...>     |> Grafi.Graph.add_edges([{:a, :b}, {:b, :c}, {:c, :a}])
      iex> cliques = Grafi.Algo.Cliques.maximal_cliques(g)
      iex> length(cliques)
      1
      iex> MapSet.equal?(hd(cliques), MapSet.new([:a, :b, :c]))
      true
  """
  @spec maximal_cliques(Graph.t(), keyword()) :: [MapSet.t()]
  def maximal_cliques(%Graph{} = g, opts \\ []) do
    max = Keyword.get(opts, :max_results, :infinity)
    vs = Graph.vertices(g)

    if vs == [] do
      []
    else
      adj = Neighborhood.sets(g, self_loops: :drop)

      # bron_kerbosch throws once `max` cliques are collected; catch unwinds
      # the recursion and returns what we have. With the default :infinity
      # the count never matches, so every clique is enumerated.
      try do
        {_count, cliques} =
          bron_kerbosch(MapSet.new(), MapSet.new(vs), MapSet.new(), adj, {0, []}, max)

        cliques
      catch
        {:max_results, cliques} -> cliques
      end
    end
  end

  @doc """
  Returns one of the largest maximal cliques.

  Returns `MapSet.new()` for an empty graph. If several cliques tie for
  largest, an arbitrary one is returned.
  """
  @spec maximum_clique(Graph.t()) :: MapSet.t()
  def maximum_clique(%Graph{} = g) do
    case maximal_cliques(g) do
      [] -> MapSet.new()
      cliques -> Enum.max_by(cliques, &MapSet.size/1)
    end
  end

  @doc """
  Returns the **clique number** — the size of the maximum clique.

  Returns `0` for an empty graph.
  """
  @spec clique_number(Graph.t()) :: non_neg_integer()
  def clique_number(%Graph{} = g), do: g |> maximum_clique() |> MapSet.size()

  @doc "Convenience: number of maximal cliques in the graph."
  @spec count_cliques(Graph.t()) :: non_neg_integer()
  def count_cliques(%Graph{} = g), do: g |> maximal_cliques() |> length()

  # ── Internals ─────────────────────────────────────────────────────────

  # Bron–Kerbosch with pivot (Tomita-style choice: pivot maximizes
  # |P ∩ N(u)| to minimize the branching factor). `acc` is
  # `{count, cliques}`, so the `:max_results` check is O(1).
  defp bron_kerbosch(r, p, x, adj, {count, cliques} = acc, max) do
    if MapSet.size(p) == 0 and MapSet.size(x) == 0 do
      acc = {count + 1, [r | cliques]}
      if count + 1 == max, do: throw({:max_results, elem(acc, 1)})
      acc
    else
      do_bk(r, p, x, adj, acc, max)
    end
  end

  defp do_bk(r, p, x, adj, acc, max) do
    pivot = choose_pivot(p, x, adj)
    pivot_neighbors = Map.fetch!(adj, pivot)
    candidates = MapSet.difference(p, pivot_neighbors)

    {_, _, acc} =
      Enum.reduce(candidates, {p, x, acc}, fn v, {p_cur, x_cur, acc_cur} ->
        nv = Map.fetch!(adj, v)

        acc_cur =
          bron_kerbosch(
            MapSet.put(r, v),
            MapSet.intersection(p_cur, nv),
            MapSet.intersection(x_cur, nv),
            adj,
            acc_cur,
            max
          )

        {MapSet.delete(p_cur, v), MapSet.put(x_cur, v), acc_cur}
      end)

    acc
  end

  # Pick u in P ∪ X that maximizes |P ∩ N(u)|.
  defp choose_pivot(p, x, adj) do
    union = MapSet.union(p, x)

    Enum.max_by(union, fn u ->
      MapSet.size(MapSet.intersection(p, Map.fetch!(adj, u)))
    end)
  end
end
