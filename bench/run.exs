# bench/run.exs
# Run with: mix bench
#
# Compares Grafi pure Elixir vs Grafi NIF (if available) vs :digraph

defmodule Grafi.Bench do
  @moduledoc false

  def random_graph(n, edge_factor \\ 3) do
    vertices = Enum.to_list(0..(n - 1))
    edges = for _ <- 1..(n * edge_factor) do
      {Enum.random(vertices), Enum.random(vertices), weight: :rand.uniform() * 10}
    end

    Grafi.new()
    |> Grafi.add_vertices(vertices)
    |> Grafi.add_edges(edges)
  end

  def random_dag(n) do
    # DAG: only edges from lower to higher index
    edges = for _ <- 1..(n * 2) do
      a = :rand.uniform(n - 1) - 1
      b = a + :rand.uniform(min(10, n - a - 1))
      {a, b, weight: :rand.uniform() * 10}
    end
    |> Enum.uniq_by(fn {a, b, _} -> {a, b} end)
    |> Enum.filter(fn {a, b, _} -> a < b and b < n end)

    Grafi.DAG.new()
    |> Grafi.DAG.add_edges(edges)
  end

  def random_digraph(n, edge_factor \\ 3) do
    g = :digraph.new()
    for i <- 0..(n - 1), do: :digraph.add_vertex(g, i)
    for _ <- 1..(n * edge_factor) do
      :digraph.add_edge(g, :rand.uniform(n) - 1, :rand.uniform(n) - 1)
    end
    g
  end

  def run do
    IO.puts("=== Grafi Benchmark Suite ===\n")
    IO.puts("NIF available: #{Grafi.NIF.available?()}\n")

    small = random_graph(100)
    medium = random_graph(1_000)

    small_dag = random_dag(100)

    small_digraph = random_digraph(100)
    medium_digraph = random_digraph(1_000)

    Benchee.run(
      %{
        # ── Construction ──
        "Grafi: build 1k graph" => fn ->
          random_graph(1_000)
        end,
        ":digraph: build 1k graph" => fn ->
          g = random_digraph(1_000)
          :digraph.delete(g)
        end,

        # ── BFS ──
        "Grafi: BFS 100" => fn ->
          Grafi.bfs(small, 0) |> Enum.to_list()
        end,
        ":digraph_utils: BFS 100" => fn ->
          :digraph_utils.reachable([0], small_digraph)
        end,

        # ── Dijkstra ──
        "Grafi: Dijkstra 100" => fn ->
          Grafi.shortest_path(small, 0, 99)
        end,

        # ── PageRank ──
        "Grafi: PageRank 100" => fn ->
          Grafi.pagerank(small, iterations: 50)
        end,
        "Grafi: PageRank 1k" => fn ->
          Grafi.pagerank(medium, iterations: 50)
        end,

        # ── SCC ──
        "Grafi: SCC 100" => fn ->
          Grafi.scc(small)
        end,

        # ── Cycle detection ──
        "Grafi: has_cycle? 100" => fn ->
          Grafi.has_cycle?(small)
        end,

        # ── DAG topo sort ──
        "Grafi.DAG: topo sort 100" => fn ->
          Grafi.DAG.topological_sort(small_dag)
        end,

        # ── DOT export ──
        "Grafi: to_dot 100" => fn ->
          Grafi.to_dot(small)
        end,
      },
      time: 3,
      warmup: 1,
      memory_time: 1,
      print: [configuration: false]
    )
  end
end

Grafi.Bench.run()
