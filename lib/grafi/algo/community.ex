defmodule Grafi.Algo.Community do
  @moduledoc """
  Community detection algorithms powered by igraph.

  These algorithms identify densely connected groups of vertices.
  All dispatch to igraph NIFs — there is no pure Elixir fallback for
  community detection as the algorithms are inherently complex.

  If the NIF is unavailable, functions return `{:error, :nif_not_available}`.
  """

  alias Grafi.Graph

  @type community_result :: %{
          membership: %{any() => non_neg_integer()},
          modularity: float(),
          n_communities: non_neg_integer(),
          communities: %{non_neg_integer() => [any()]}
        }

  @doc """
  Louvain method (multi-level modularity optimization).
  Fast, widely used. Works on undirected graphs.
  """
  @spec louvain(Graph.t()) :: {:ok, community_result()} | {:error, atom()}
  def louvain(%Graph{} = g) do
    with_nif(g, fn _idx, csr, rev ->
      {membership, modularity, n} = Grafi.NIF.nif_louvain(csr)
      build_result(membership, modularity, n, rev)
    end)
  end

  @doc """
  Leiden algorithm — improved Louvain with guaranteed connected communities.

  ## Options
    - `:resolution` — resolution parameter (default `1.0`).
      Higher values produce more, smaller communities.
  """
  @spec leiden(Graph.t(), keyword()) :: {:ok, community_result()} | {:error, atom()}
  def leiden(%Graph{} = g, opts \\ []) do
    resolution = Keyword.get(opts, :resolution, 1.0)

    with_nif(g, fn _idx, csr, rev ->
      {membership, quality, n} = Grafi.NIF.nif_leiden(csr, resolution)
      build_result(membership, quality, n, rev)
    end)
  end

  @doc """
  Label propagation — near-linear time, non-deterministic.
  Very fast on large graphs.
  """
  @spec label_propagation(Graph.t()) :: {:ok, community_result()} | {:error, atom()}
  def label_propagation(%Graph{} = g) do
    with_nif(g, fn _idx, csr, rev ->
      {membership, modularity, n} = Grafi.NIF.nif_label_propagation(csr)
      build_result(membership, modularity, n, rev)
    end)
  end

  # ── Pure Elixir: simple label propagation fallback ────────────────────

  @doc """
  Simple label propagation in pure Elixir. Less accurate than the
  igraph version but works without the NIF.
  """
  @spec label_propagation_simple(Graph.t(), keyword()) :: community_result()
  def label_propagation_simple(%Graph{} = g, opts \\ []) do
    max_iter = Keyword.get(opts, :iterations, 100)
    vs = Graph.vertices(g)
    labels = vs |> Enum.with_index() |> Map.new()

    labels =
      Enum.reduce(1..max_iter, labels, fn _, lab ->
        vs
        |> Enum.shuffle()
        |> Enum.reduce(lab, fn v, l ->
          neighbors = Graph.neighbors(g, v)

          if neighbors == [] do
            l
          else
            freqs = Enum.frequencies_by(neighbors, &l[&1])
            {best_label, _} = Enum.max_by(freqs, &elem(&1, 1))
            Map.put(l, v, best_label)
          end
        end)
      end)

    communities = Enum.group_by(vs, &labels[&1])
    n = map_size(communities)

    %{
      membership: labels,
      modularity: 0.0,
      n_communities: n,
      communities: communities
    }
  end

  # ── Internal ──────────────────────────────────────────────────────────

  defp with_nif(g, fun) do
    if Grafi.NIF.available?() do
      {idx, csr} = Graph.to_csr(g)
      Grafi.NIF.validate_csr!(csr)
      rev = Map.new(idx, fn {v, i} -> {i, v} end)
      {:ok, fun.(idx, csr, rev)}
    else
      {:error, :nif_not_available}
    end
  end

  defp build_result(membership_list, modularity, n, reverse_idx) do
    membership =
      membership_list
      |> Enum.with_index()
      |> Map.new(fn {comm_id, i} -> {reverse_idx[i], comm_id} end)

    communities = Enum.group_by(Map.keys(membership), &membership[&1])

    %{
      membership: membership,
      modularity: modularity,
      n_communities: n,
      communities: communities
    }
  end
end
