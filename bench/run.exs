# bench/run.exs
#
#   mix bench                  # every complexity scenario (timing table)
#   mix bench kcore hungarian  # only scenarios whose id contains a word
#   mix bench engines          # NIF vs Elixir (Benchee), needs the NIF
#
# Complexity scenarios time each algorithm the algo-correctness-perf plan
# fixes, at two sizes, so a fix shows as a before/after table (recorded in
# the plan scratchpad). Each run is the best of 3 (one run when it takes
# over 2 s) and is cut off after 60 s. Inputs are seeded, so they are the
# same on every run.

defmodule Grafi.Bench do
  @moduledoc false

  alias Grafi.{DAG, Generators, Graph, Layout}

  alias Grafi.Algo.{
    Centrality,
    Cliques,
    Community,
    Connectivity,
    Cycles,
    Isomorphism,
    KCore,
    KShortestPath,
    LinkPrediction,
    Matching,
    Metrics,
    ShortestPath
  }

  alias Grafi.Serialize.GraphML

  @timeout 60_000

  # ── Inputs ──────────────────────────────────────────────────────────────

  defp seed!, do: :rand.seed(:exsss, {42, 42, 42})

  # n vertices, about n * avg_degree / 2 (undirected) or n * avg_degree
  # (directed) random edges with weights in (0, 10].
  def random_graph(n, avg_degree, type) do
    seed!()
    m = if type == :undirected, do: div(n * avg_degree, 2), else: n * avg_degree

    Enum.reduce(1..m, Graph.add_vertices(Graph.new(type: type), Enum.to_list(0..(n - 1))), fn _,
                                                                                              g ->
      u = :rand.uniform(n) - 1
      v = :rand.uniform(n) - 1
      if u == v, do: g, else: Graph.add_edge(g, u, v, weight: :rand.uniform() * 10)
    end)
  end

  # Edges `{a, b, weight: w}` with a < b, about 2 per vertex.
  def random_dag_edges(n) do
    seed!()

    for _ <- 1..(2 * n),
        a = :rand.uniform(n - 1) - 1,
        b = a + :rand.uniform(min(10, n - a - 1)),
        uniq: true,
        do: {a, b, [weight: :rand.uniform() * 10]}
  end

  def random_dag_graph(n) do
    Enum.reduce(random_dag_edges(n), Graph.new(), fn {a, b, opts}, g ->
      Graph.add_edge(g, a, b, opts)
    end)
  end

  def star(leaves) do
    Enum.reduce(1..leaves, Graph.new(type: :undirected), &Graph.add_edge(&2, 0, &1))
  end

  def bipartite(n, edges_per_left) do
    seed!()

    g =
      Enum.reduce(0..(n - 1), Graph.new(type: :undirected), fn i, g ->
        Enum.reduce(1..edges_per_left, g, fn _, acc ->
          Graph.add_edge(acc, {:l, i}, {:r, :rand.uniform(n) - 1})
        end)
      end)

    {g, for(i <- 0..(n - 1), do: {:l, i})}
  end

  def cost_matrix(n) do
    seed!()
    for _ <- 1..n, do: for(_ <- 1..n, do: :rand.uniform(1000))
  end

  def relabel(g) do
    mapping = g |> Graph.vertices() |> Map.new(&{&1, {:r, &1}})

    Enum.reduce(Graph.edges(g), Graph.new(type: g.type), fn e, acc ->
      Graph.add_edge(acc, mapping[e.from], mapping[e.to])
    end)
  end

  # ── Scenarios: {id, plan task, sizes, setup(size), run(input)} ─────────

  def scenarios do
    [
      {"delete_vertex", "A1.3", [1_000, 10_000], &random_graph(&1, 10, :undirected),
       fn g -> Enum.reduce(0..99, g, &Graph.delete_vertex(&2, &1)) end},
      {"yen", "A1.6", [10, 30], &Generators.grid(&1, &1, type: :undirected),
       fn g ->
         n = g |> Graph.vertices() |> Enum.max()
         KShortestPath.yen(g, {0, 0}, n, 5)
       end},
      {"bellman_ford", "A1.7", [1_000, 10_000], &random_graph(&1, 5, :directed),
       &ShortestPath.bellman_ford(&1, 0)},
      {"dijkstra_elixir_near_target", "A1.8", [10_000, 100_000], &random_graph(&1, 5, :directed),
       fn g -> ShortestPath.dijkstra(g, 0, hd(Graph.out_neighbors(g, 0)), engine: :elixir) end},
      {"hungarian", "A2.1", [100, 300], &cost_matrix/1, &Matching.hungarian/1},
      {"biconnected_components", "A2.2", [1_000, 10_000], &random_graph(&1, 3, :undirected),
       &Connectivity.biconnected_components/1},
      {"kcore_star", "A2.3", [10_000, 100_000], &star/1, &KCore.core_numbers/1},
      {"layout_sugiyama", "A2.4", [1_000, 5_000], &random_dag_graph/1, &Layout.sugiyama/1},
      {"triangle_count", "A2.5", [1_000, 10_000], &random_graph(&1, 10, :undirected),
       &Metrics.triangle_count/1},
      {"clustering_coefficient", "A2.5", [1_000, 10_000], &random_graph(&1, 10, :undirected),
       &Metrics.clustering_coefficient/1},
      {"transitivity", "A2.5", [1_000, 10_000], &random_graph(&1, 10, :undirected),
       &Metrics.transitivity/1},
      {"jaccard_1k_pairs", "A2.6", [1_000, 10_000],
       fn n ->
         g = random_graph(n, 10, :undirected)
         seed!()
         {g, for(_ <- 1..1_000, do: {:rand.uniform(n) - 1, :rand.uniform(n) - 1})}
       end, fn {g, pairs} -> LinkPrediction.jaccard(g, pairs) end},
      {"dag_add_edges", "A2.7", [1_000, 5_000], &random_dag_edges/1, &DAG.add_edges(DAG.new(), &1)},
      {"isomorphic_elixir", "A2.8", [100, 500],
       fn n ->
         g = Generators.random_regular(n, 3, seed: 1, type: :undirected)
         {g, relabel(g)}
       end, fn {a, b} -> Isomorphism.isomorphic?(a, b, engine: :elixir, timeout: :infinity) end},
      {"label_propagation_simple", "A2.9", [1_000, 10_000], &random_graph(&1, 6, :undirected),
       &Community.label_propagation_simple/1},
      {"hopcroft_karp", "A2.10", [1_000, 10_000], &bipartite(&1, 3),
       fn {g, left} -> Matching.hopcroft_karp(g, left) end},
      {"condensation", "A2.11", [1_000, 10_000], &random_graph(&1, 2, :directed),
       &Cycles.condensation/1},
      {"count_cliques", "A2.12", [100, 200],
       &Generators.erdos_renyi(&1, 0.3, seed: 1, type: :undirected), &Cliques.count_cliques/1},
      {"hits", "A2.13", [1_000, 10_000], &random_graph(&1, 5, :directed), &Centrality.hits/1},
      {"katz", "A2.13", [1_000, 10_000], &random_graph(&1, 5, :directed), &Centrality.katz/1},
      {"eigenvector", "A2.13", [1_000, 10_000], &random_graph(&1, 5, :undirected),
       &Centrality.eigenvector/1},
      {"graphml_parse", "A4.2", [1_000, 10_000],
       &GraphML.to_graphml(random_graph(&1, 5, :directed)), &GraphML.from_graphml/1}
    ]
  end

  # ── Timing ──────────────────────────────────────────────────────────────

  def run_complexity(filters) do
    IO.puts("| scenario | task | size | ms |")
    IO.puts("|---|---|---|---|")

    for {id, task, sizes, setup, run} <- scenarios(),
        filters == [] or Enum.any?(filters, &String.contains?(id, &1)),
        size <- sizes do
      input = setup.(size)
      IO.puts("| #{id} | #{task} | #{size} | #{time(fn -> run.(input) end)} |")
    end
  end

  defp time(fun) do
    case once(fun) do
      :timeout ->
        "timeout (> #{div(@timeout, 1000)} s)"

      us when us > 2_000_000 ->
        format(us)

      us ->
        [us | for(_ <- 1..2, do: once(fun))]
        |> Enum.reject(&(&1 == :timeout))
        |> Enum.min()
        |> format()
    end
  end

  defp once(fun) do
    task = Task.async(fn -> :timer.tc(fun) |> elem(0) end)

    case Task.yield(task, @timeout) || Task.shutdown(task, :brutal_kill) do
      {:ok, us} -> us
      _ -> :timeout
    end
  end

  defp format(us), do: :erlang.float_to_binary(us / 1000, decimals: 1)

  # ── Engines (Benchee) ───────────────────────────────────────────────────

  def run_engines do
    unless Grafi.NIF.available?(), do: Mix.raise("the engines group needs the NIF")

    inputs = %{
      "1k" => random_graph(1_000, 5, :directed),
      "10k" => random_graph(10_000, 5, :directed)
    }

    jobs =
      for {name, fun} <- [
            {"pagerank", &Centrality.pagerank/2},
            {"betweenness", &Centrality.betweenness/2},
            {"closeness", &Centrality.closeness/2},
            {"scc", &Cycles.strongly_connected_components/2}
          ],
          engine <- [:nif, :elixir],
          into: %{},
          do: {"#{name} #{engine}", fn g -> fun.(g, engine: engine) end}

    dijkstra =
      for engine <- [:nif, :elixir], into: %{} do
        {"dijkstra #{engine}", fn g -> ShortestPath.dijkstra(g, 0, 999, engine: engine) end}
      end

    Benchee.run(Map.merge(jobs, dijkstra),
      inputs: inputs,
      time: 2,
      warmup: 0.5,
      print: [configuration: false]
    )
  end
end

case System.argv() do
  ["engines"] -> Grafi.Bench.run_engines()
  filters -> Grafi.Bench.run_complexity(filters)
end
