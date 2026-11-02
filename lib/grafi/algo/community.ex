defmodule Grafi.Algo.Community do
  @moduledoc """
  Community detection algorithms.

  ## Function map

    * `louvain/2`               — **requires NIF** (igraph)
    * `leiden/2`                — **requires NIF** (igraph)
    * `label_propagation/2`     — **requires NIF** (igraph)
    * `label_propagation_simple/2` — **pure Elixir**, always available; less
      accurate but useful for small graphs or when the NIF is not installed.

  NIF-backed functions accept `engine: :auto | :nif | :elixir` (see
  `Grafi.NIF`) and return `{:ok, result}` on success, or `{:error, reason}`:

    * `:nif_not_available` — the NIF is not loaded or disabled, or
      `engine: :elixir` was requested (there is no Elixir implementation)
    * `:directed_unsupported` — Louvain and Leiden need an undirected graph
    * `:negative_weight` — an edge weight is negative
    * `{:igraph, message}` — an unexpected igraph failure

  The pure-Elixir fallback returns the result map directly.
  """

  alias Grafi.Algo.Neighborhood
  alias Grafi.Args
  alias Grafi.Graph
  alias Grafi.NIF

  @type community_result :: %{
          membership: %{any() => non_neg_integer()},
          modularity: float(),
          n_communities: non_neg_integer(),
          communities: %{non_neg_integer() => [any()]}
        }

  @type error :: {:error, atom() | {:igraph, String.t()}}

  @doc """
  Louvain method (multi-level modularity optimization).
  Fast, widely used. Undirected graphs only.

  ## Options
    - `:engine` — `:auto | :nif | :elixir`, see `Grafi.NIF`
  """
  @spec louvain(Graph.t(), keyword()) :: {:ok, community_result()} | error()
  def louvain(%Graph{} = g, opts \\ []) do
    Args.engine!(opts)
    run(g, opts, &NIF.nif_louvain/1)
  end

  @doc """
  Leiden algorithm — improved Louvain with guaranteed connected communities.
  Undirected graphs only.

  ## Options
    - `:objective` — `:modularity` (default) or `:cpm` (Constant Potts
      Model). With `:modularity` the partition optimises the same quality
      function as Louvain.
    - `:resolution` — positive resolution parameter (default `1.0`; integers
      are accepted). Higher values produce more, smaller communities.
    - `:engine` — `:auto | :nif | :elixir`, see `Grafi.NIF`

  The returned `:modularity` is the partition's modularity at resolution 1,
  whatever the objective, so it is comparable to `louvain/2`'s.

  Raises `ArgumentError` for a non-positive `:resolution` or an unknown
  `:objective`.
  """
  @spec leiden(Graph.t(), keyword()) :: {:ok, community_result()} | error()
  def leiden(%Graph{} = g, opts \\ []) do
    Args.engine!(opts)
    resolution = Args.float!(opts, :resolution, 1.0, &(&1 > 0), "a positive number")

    objective =
      case Keyword.get(opts, :objective, :modularity) do
        obj when obj in [:modularity, :cpm] ->
          obj

        other ->
          raise ArgumentError,
                "expected :objective to be :modularity or :cpm, got: #{inspect(other)}"
      end

    run(g, opts, &NIF.nif_leiden(&1, resolution, objective))
  end

  @doc """
  Label propagation — near-linear time, non-deterministic.
  Very fast on large graphs.

  ## Options
    - `:engine` — `:auto | :nif | :elixir`, see `Grafi.NIF`
  """
  @spec label_propagation(Graph.t(), keyword()) :: {:ok, community_result()} | error()
  def label_propagation(%Graph{} = g, opts \\ []) do
    Args.engine!(opts)
    run(g, opts, &NIF.nif_label_propagation/1)
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
          neighbors = Neighborhood.neighbors(g, v, self_loops: :keep)

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

  # Community detection has no Elixir engine, so `:auto` uses the NIF at any
  # graph size and `:elixir` reports :nif_not_available.
  defp run(g, opts, nif_fun) do
    with :nif <- NIF.engine(g, opts, prefer: :nif),
         {_idx, csr} = Graph.to_csr(g),
         {membership, modularity, n} <- NIF.call(nif_fun.(csr)) do
      {:ok, build_result(csr, membership, modularity, n)}
    else
      :elixir -> {:error, :nif_not_available}
      {:error, _} = error -> error
    end
  end

  defp build_result(csr, membership_list, modularity, n) do
    membership = NIF.by_vertex(csr, membership_list)
    communities = Enum.group_by(Map.keys(membership), &membership[&1])

    %{
      membership: membership,
      modularity: modularity,
      n_communities: n,
      communities: communities
    }
  end
end
